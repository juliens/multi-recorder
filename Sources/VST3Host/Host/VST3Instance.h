// One VST3 plug-in instance: loading, processing, state and editor controller.
// C++ only, used by VST3AudioUnit.

#pragma once

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
#include "public.sdk/source/vst/hosting/plugprovider.h"
#include "public.sdk/source/vst/hosting/processdata.h"

namespace mrec {

class ComponentHandler;

class VST3Instance {
public:
    /// Loads the bundle (once per process) and creates the effect.
    /// `classID` empty means the first audio effect class of the bundle.
    static std::unique_ptr<VST3Instance> load(
        const std::string& path, const std::string& classID, std::string& error);

    ~VST3Instance();

    const std::string& name() const { return pluginName; }

    /// Prepares stereo processing. Called before rendering starts.
    bool setup(double sampleRate, Steinberg::int32 maxFrames, std::string& error);
    void teardown();
    bool isActive() const { return active.load(); }

    /// Real time safe. `input` and `output` are two channels of `frames` samples.
    /// They may be the same buffers.
    void process(float* const* input, float* const* output, Steinberg::int32 frames);

    bool getState(std::vector<char>& componentState, std::vector<char>& controllerState);
    void setState(const void* componentData, size_t componentSize, const void* controllerData,
                  size_t controllerSize);

    Steinberg::uint32 latencySamples() const;
    Steinberg::Vst::IEditController* controller() const { return editController.get(); }

    /// Parameter change made in the editor, sent to the processor on the next block.
    void queueParameter(Steinberg::Vst::ParamID id, Steinberg::Vst::ParamValue value);

    /// Main thread. Gives the editor controller the values the processor sent
    /// (meters, analysis results, parameters set by the plug-in itself).
    void flushOutputParameters();

private:
    VST3Instance();
    /// Audio thread. Keeps the last value of each parameter the processor sent.
    void collectOutputParameters();

    VST3::Hosting::Module::Ptr module;
    Steinberg::IPtr<Steinberg::Vst::PlugProvider> provider;
    Steinberg::IPtr<Steinberg::Vst::IComponent> component;
    Steinberg::IPtr<Steinberg::Vst::IAudioProcessor> processor;
    Steinberg::IPtr<Steinberg::Vst::IEditController> editController;
    Steinberg::IPtr<ComponentHandler> handler;

    Steinberg::Vst::HostProcessData processData;
    Steinberg::Vst::ParameterChanges inputChanges;
    Steinberg::Vst::ParameterChanges outputChanges;
    Steinberg::Vst::ProcessContext context {};

    std::atomic<bool> active {false};
    double sampleRate {48000};
    std::string pluginName;

    std::mutex pendingLock;
    std::vector<std::pair<Steinberg::Vst::ParamID, Steinberg::Vst::ParamValue>> pending;

    std::mutex outgoingLock;
    std::vector<std::pair<Steinberg::Vst::ParamID, Steinberg::Vst::ParamValue>> outgoing;
};

} // namespace mrec
