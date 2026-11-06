#include "VST3Instance.h"

#include <algorithm>
#include <cstring>
#include <map>

#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace mrec {

/// Receives parameter edits from the plug-in editor.
class ComponentHandler : public U::Implements<U::Directly<IComponentHandler>> {
public:
    explicit ComponentHandler(VST3Instance* owner) : owner(owner) {}

    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override {
        owner->queueParameter(id, value);
        return kResultOk;
    }
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32) override { return kResultOk; }

private:
    VST3Instance* owner;
};

namespace {

/// The host context given to every plug-in. Created once.
void ensureHostContext() {
    static HostApplication* application = [] {
        auto* host = new HostApplication();
        PluginContextFactory::instance().setPluginContext(host);
        return host;
    }();
    (void)application;
}

/// VST3 modules are loaded once per process and never unloaded: unloading at exit
/// runs the plug-in's exit code after the process started to tear down, which crashes
/// some plug-ins. The cache is allocated on the heap so no destructor runs at exit.
VST3::Hosting::Module::Ptr loadModule(const std::string& path, std::string& error) {
    static auto* lock = new std::mutex();
    static auto* modules = new std::map<std::string, VST3::Hosting::Module::Ptr>();
    std::lock_guard<std::mutex> guard(*lock);
    auto found = modules->find(path);
    if (found != modules->end()) {
        return found->second;
    }
    auto module = VST3::Hosting::Module::create(path, error);
    if (module) {
        (*modules)[path] = module;
    }
    return module;
}

bool sameID(const std::string& a, const std::string& b) {
    return a.size() == b.size() &&
           std::equal(a.begin(), a.end(), b.begin(),
                      [](char x, char y) { return std::toupper(x) == std::toupper(y); });
}

void copyStream(MemoryStream& stream, std::vector<char>& out) {
    out.assign(stream.getData(), stream.getData() + stream.getSize());
}

} // namespace

VST3Instance::VST3Instance() = default;

std::unique_ptr<VST3Instance> VST3Instance::load(
    const std::string& path, const std::string& classID, std::string& error) {
    ensureHostContext();
    auto module = loadModule(path, error);
    if (!module) {
        if (error.empty()) error = "Cannot load the VST3 bundle.";
        return nullptr;
    }

    const auto& factory = module->getFactory();
    VST3::Hosting::ClassInfo chosen;
    bool found = false;
    for (const auto& info : factory.classInfos()) {
        if (info.category() != kVstAudioEffectClass) continue;
        if (classID.empty() || sameID(info.ID().toString(false), classID) ||
            sameID(info.ID().toString(true), classID)) {
            chosen = info;
            found = true;
            break;
        }
    }
    if (!found) {
        error = "No audio effect found in this VST3 bundle.";
        return nullptr;
    }

    std::unique_ptr<VST3Instance> instance(new VST3Instance());
    instance->module = module;
    instance->pluginName = chosen.name();
    instance->provider = owned(new PlugProvider(factory, chosen, true));
    if (!instance->provider->initialize()) {
        error = "Cannot initialize " + chosen.name() + ".";
        return nullptr;
    }
    instance->component = instance->provider->getComponentPtr();
    instance->editController = instance->provider->getControllerPtr();
    instance->processor = U::cast<IAudioProcessor>(instance->component);
    if (!instance->component || !instance->processor) {
        error = chosen.name() + " has no audio processor.";
        return nullptr;
    }
    if (instance->component->getBusCount(kAudio, kInput) == 0 ||
        instance->component->getBusCount(kAudio, kOutput) == 0) {
        error = chosen.name() + " is not an audio effect (no audio input or output).";
        return nullptr;
    }

    instance->handler = owned(new ComponentHandler(instance.get()));
    if (instance->editController) {
        instance->editController->setComponentHandler(instance->handler);
    }
    return instance;
}

VST3Instance::~VST3Instance() {
    teardown();
    if (editController) {
        editController->setComponentHandler(nullptr);
    }
    processor = nullptr;
    component = nullptr;
    editController = nullptr;
    // The provider terminates the plug-in, so it goes last.
    provider = nullptr;
}

bool VST3Instance::setup(double rate, int32 maxFrames, std::string& error) {
    teardown();
    sampleRate = rate;

    if (processor->canProcessSampleSize(kSample32) != kResultTrue) {
        error = pluginName + " does not process 32-bit float audio.";
        return false;
    }
    ProcessSetup processSetup {kRealtime, kSample32, maxFrames, rate};
    if (processor->setupProcessing(processSetup) != kResultOk) {
        error = pluginName + " refused the sample rate or block size.";
        return false;
    }

    // Main buses in stereo, other buses (side chains) as the plug-in wants them, but inactive.
    int32 inputCount = component->getBusCount(kAudio, kInput);
    int32 outputCount = component->getBusCount(kAudio, kOutput);
    std::vector<SpeakerArrangement> inputs(inputCount), outputs(outputCount);
    for (int32 i = 0; i < inputCount; ++i) processor->getBusArrangement(kInput, i, inputs[i]);
    for (int32 i = 0; i < outputCount; ++i) processor->getBusArrangement(kOutput, i, outputs[i]);
    inputs[0] = SpeakerArr::kStereo;
    outputs[0] = SpeakerArr::kStereo;
    // If the plug-in refuses stereo, it keeps its own layout. Mono is handled when copying.
    processor->setBusArrangements(inputs.data(), inputCount, outputs.data(), outputCount);

    for (int32 i = 0; i < inputCount; ++i) component->activateBus(kAudio, kInput, i, i == 0);
    for (int32 i = 0; i < outputCount; ++i) component->activateBus(kAudio, kOutput, i, i == 0);
    for (int32 i = 0; i < component->getBusCount(kEvent, kInput); ++i)
        component->activateBus(kEvent, kInput, i, false);

    if (component->setActive(true) != kResultOk) {
        error = "Cannot activate " + pluginName + ".";
        return false;
    }
    processData.prepare(*component, maxFrames, kSample32);
    // Silence every buffer once; only the main buses are filled later.
    for (int32 b = 0; b < processData.numInputs; ++b)
        for (int32 c = 0; c < processData.inputs[b].numChannels; ++c)
            std::memset(processData.inputs[b].channelBuffers32[c], 0, sizeof(float) * maxFrames);
    inputChanges.setMaxParameters(256);
    processData.inputParameterChanges = &inputChanges;
    outputChanges.setMaxParameters(256);
    processData.outputParameterChanges = &outputChanges;
    {
        std::lock_guard<std::mutex> guard(outgoingLock);
        outgoing.reserve(256);
    }
    processData.processContext = &context;

    context = {};
    context.sampleRate = rate;
    context.tempo = 120;
    context.timeSigNumerator = 4;
    context.timeSigDenominator = 4;
    context.state = ProcessContext::kPlaying | ProcessContext::kTempoValid | ProcessContext::kTimeSigValid;

    processor->setProcessing(true);
    active.store(true);
    return true;
}

void VST3Instance::teardown() {
    if (!active.exchange(false)) return;
    processor->setProcessing(false);
    component->setActive(false);
}

void VST3Instance::process(float* const* input, float* const* output, int32 frames) {
    if (!active.load() || processData.numInputs == 0 || processData.numOutputs == 0) {
        if (input != output) {
            for (int c = 0; c < 2; ++c)
                if (input[c] != output[c]) std::memcpy(output[c], input[c], sizeof(float) * frames);
        }
        return;
    }

    auto& in = processData.inputs[0];
    for (int32 c = 0; c < in.numChannels; ++c)
        std::memcpy(in.channelBuffers32[c], input[std::min(c, 1)], sizeof(float) * frames);
    processData.numSamples = frames;

    inputChanges.clearQueue();
    outputChanges.clearQueue();
    if (pendingLock.try_lock()) {
        for (const auto& change : pending) {
            int32 queueIndex = 0;
            if (auto* queue = inputChanges.addParameterData(change.first, queueIndex)) {
                int32 pointIndex = 0;
                queue->addPoint(0, change.second, pointIndex);
            }
        }
        pending.clear();
        pendingLock.unlock();
    }

    processor->process(processData);
    context.projectTimeSamples += frames;
    collectOutputParameters();

    auto& out = processData.outputs[0];
    for (int c = 0; c < 2; ++c) {
        if (out.numChannels == 0) {
            std::memset(output[c], 0, sizeof(float) * frames);
        } else {
            std::memcpy(output[c], out.channelBuffers32[std::min(c, out.numChannels - 1)],
                        sizeof(float) * frames);
        }
    }
}

bool VST3Instance::getState(std::vector<char>& componentState, std::vector<char>& controllerState) {
    MemoryStream componentStream;
    if (component->getState(&componentStream) != kResultOk) return false;
    copyStream(componentStream, componentState);

    controllerState.clear();
    if (editController) {
        MemoryStream controllerStream;
        if (editController->getState(&controllerStream) == kResultOk) {
            copyStream(controllerStream, controllerState);
        }
    }
    return true;
}

void VST3Instance::setState(const void* componentData, size_t componentSize, const void* controllerData,
                            size_t controllerSize) {
    if (componentData && componentSize > 0) {
        MemoryStream stream(const_cast<void*>(componentData), static_cast<TSize>(componentSize));
        component->setState(&stream);
        if (editController) {
            stream.seek(0, IBStream::kIBSeekSet, nullptr);
            editController->setComponentState(&stream);
        }
    }
    if (editController && controllerData && controllerSize > 0) {
        MemoryStream stream(const_cast<void*>(controllerData), static_cast<TSize>(controllerSize));
        editController->setState(&stream);
    }
}

uint32 VST3Instance::latencySamples() const {
    return processor ? processor->getLatencySamples() : 0;
}

void VST3Instance::collectOutputParameters() {
    int32 count = outputChanges.getParameterCount();
    if (count == 0 || !outgoingLock.try_lock()) return;
    for (int32 i = 0; i < count; ++i) {
        auto* queue = outputChanges.getParameterData(i);
        if (!queue || queue->getPointCount() == 0) continue;
        int32 offset = 0;
        ParamValue value = 0;
        if (queue->getPoint(queue->getPointCount() - 1, offset, value) != kResultOk) continue;
        ParamID id = queue->getParameterId();
        bool updated = false;
        for (auto& change : outgoing) {
            if (change.first == id) {
                change.second = value;
                updated = true;
                break;
            }
        }
        // Capacity is reserved in setup, so this does not allocate in normal use.
        if (!updated && outgoing.size() < outgoing.capacity()) outgoing.emplace_back(id, value);
    }
    outgoingLock.unlock();
}

void VST3Instance::flushOutputParameters() {
    if (!editController) return;
    std::vector<std::pair<ParamID, ParamValue>> changes;
    {
        std::lock_guard<std::mutex> guard(outgoingLock);
        if (outgoing.empty()) return;
        changes.assign(outgoing.begin(), outgoing.end());
        outgoing.clear();
    }
    for (const auto& change : changes) {
        editController->setParamNormalized(change.first, change.second);
    }
}

void VST3Instance::queueParameter(ParamID id, ParamValue value) {
    std::lock_guard<std::mutex> guard(pendingLock);
    for (auto& change : pending) {
        if (change.first == id) {
            change.second = value;
            return;
        }
    }
    pending.emplace_back(id, value);
}

} // namespace mrec
