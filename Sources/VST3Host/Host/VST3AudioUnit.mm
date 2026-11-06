#import "VST3Host.h"

#import <AppKit/AppKit.h>
#import <CoreAudioKit/CoreAudioKit.h>

#include <atomic>
#include <memory>
#include <vector>

#include "VST3Instance.h"
#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/gui/iplugview.h"

using namespace Steinberg;

const AudioComponentDescription VST3HostComponentDescription = {
    kAudioUnitType_Effect, 'vst3', 'MRec', 0, 0};

static NSString *const VST3HostErrorDomain = @"VST3Host";

static NSError *VST3HostError(const std::string &message) {
    return [NSError errorWithDomain:VST3HostErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : @(message.c_str())}];
}

// MARK: Render state

/// Everything the render block needs, so it does not touch Objective-C objects.
struct RenderState {
    mrec::VST3Instance *plugin = nullptr;
    std::atomic<bool> bypass {false};
    std::vector<float> left, right;
    AudioBufferList *input = nullptr;

    RenderState() {
        input = static_cast<AudioBufferList *>(
            calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer)));
        input->mNumberBuffers = 2;
    }

    ~RenderState() { free(input); }

    void allocate(AUAudioFrameCount maxFrames) {
        left.assign(maxFrames, 0);
        right.assign(maxFrames, 0);
    }

    AudioBufferList *prepareInput(AUAudioFrameCount frames) {
        float *channels[2] = {left.data(), right.data()};
        for (UInt32 i = 0; i < 2; ++i) {
            input->mBuffers[i].mNumberChannels = 1;
            input->mBuffers[i].mData = channels[i];
            input->mBuffers[i].mDataByteSize = frames * sizeof(float);
        }
        return input;
    }
};

// MARK: Editor

/// Resizes the window when the plug-in asks for it.
class PlugFrame : public U::Implements<U::Directly<IPlugFrame>> {
public:
    __weak NSView *container = nil;

    tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *newSize) override {
        if (!view || !newSize) return kInvalidArgument;
        NSSize size = NSMakeSize(newSize->getWidth(), newSize->getHeight());
        NSView *strongContainer = container;
        if (strongContainer.window) {
            [strongContainer.window setContentSize:size];
        }
        [strongContainer setFrameSize:size];
        view->onSize(newSize);
        return kResultTrue;
    }
};

@interface VST3EditorController : NSViewController
- (instancetype)initWithController:(Vst::IEditController *)controller;
@property(nonatomic, readonly) BOOL hasEditor;
@end

@implementation VST3EditorController {
    IPtr<IPlugView> _plugView;
    IPtr<PlugFrame> _frame;
    BOOL _attached;
}

- (instancetype)initWithController:(Vst::IEditController *)controller {
    self = [super initWithNibName:nil bundle:nil];
    if (self && controller) {
        _plugView = owned(controller->createView(Vst::ViewType::kEditor));
        if (_plugView && _plugView->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) {
            _plugView = nullptr;
        }
    }
    return self;
}

- (BOOL)hasEditor {
    return _plugView != nullptr;
}

- (void)loadView {
    ViewRect rect {0, 0, 480, 320};
    if (_plugView) {
        _plugView->getSize(&rect);
    }
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, rect.getWidth(), rect.getHeight())];
    self.view = container;
    self.preferredContentSize = container.frame.size;

    if (_plugView) {
        _frame = owned(new PlugFrame());
        _frame->container = container;
        _plugView->setFrame(_frame);
        _attached = _plugView->attached((__bridge void *)container, kPlatformTypeNSView) == kResultTrue;
    }
}

- (void)dealloc {
    if (_attached) {
        _plugView->removed();
        _attached = NO;
    }
    if (_plugView) {
        _plugView->setFrame(nullptr);
    }
}

@end

// MARK: Audio unit

@implementation VST3AudioUnit {
    AUAudioUnitBus *_inputBus;
    AUAudioUnitBus *_outputBus;
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
    std::unique_ptr<mrec::VST3Instance> _plugin;
    std::unique_ptr<RenderState> _render;
    NSTimer *_parameterTimer;
}

+ (void)registerOnce {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      [AUAudioUnit registerSubclass:self
             asComponentDescription:VST3HostComponentDescription
                               name:@"MultiRecorder: VST3 Host"
                            version:1];
    });
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)error {
    self = [super initWithComponentDescription:description options:options error:error];
    if (!self) return nil;

    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!_inputBus || !_outputBus) return nil;
    _inputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                            busType:AUAudioUnitBusTypeInput
                                                             busses:@[ _inputBus ]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                             busType:AUAudioUnitBusTypeOutput
                                                              busses:@[ _outputBus ]];
    _render = std::make_unique<RenderState>();
    self.maximumFramesToRender = 4096;
    return self;
}

- (AUAudioUnitBusArray *)inputBusses {
    return _inputBusArray;
}

- (AUAudioUnitBusArray *)outputBusses {
    return _outputBusArray;
}

- (BOOL)loadPluginAtPath:(NSString *)path classID:(NSString *)classID error:(NSError **)error {
    std::string message;
    auto plugin = mrec::VST3Instance::load(path.UTF8String, classID ? classID.UTF8String : "", message);
    if (!plugin) {
        if (error) *error = VST3HostError(message);
        return NO;
    }
    _plugin = std::move(plugin);
    _render->plugin = _plugin.get();
    [self startParameterTimer];
    return YES;
}

/// Sends the processor's output parameters to the editor controller, on the main thread.
- (void)startParameterTimer {
    __weak VST3AudioUnit *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      VST3AudioUnit *strongSelf = weakSelf;
      if (!strongSelf || strongSelf->_parameterTimer) return;
      strongSelf->_parameterTimer = [NSTimer timerWithTimeInterval:1.0 / 30
                                                                    repeats:YES
                                                                      block:^(NSTimer *timer) {
                                                                        VST3AudioUnit *unit = weakSelf;
                                                                        if (!unit) {
                                                                            [timer invalidate];
                                                                            return;
                                                                        }
                                                                        if (unit->_plugin)
                                                                            unit->_plugin->flushOutputParameters();
                                                                      }];
      // Common modes: keep meters moving while a slider or a menu is tracking.
      [NSRunLoop.mainRunLoop addTimer:strongSelf->_parameterTimer forMode:NSRunLoopCommonModes];
    });
}

- (void)dealloc {
    [_parameterTimer invalidate];
}

- (NSString *)pluginName {
    return _plugin ? @(_plugin->name().c_str()) : nil;
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    if (!_plugin) {
        if (error) *error = VST3HostError("No VST3 plug-in loaded.");
        return NO;
    }
    if (_inputBus.format.channelCount != 2 || _outputBus.format.channelCount != 2) {
        if (error) *error = VST3HostError("The VST3 host only supports stereo.");
        return NO;
    }
    AUAudioFrameCount maxFrames = self.maximumFramesToRender;
    _render->allocate(maxFrames);
    std::string message;
    if (!_plugin->setup(_outputBus.format.sampleRate, static_cast<int32>(maxFrames), message)) {
        if (error) *error = VST3HostError(message);
        return NO;
    }
    return YES;
}

- (void)deallocateRenderResources {
    if (_plugin) _plugin->teardown();
    [super deallocateRenderResources];
}

- (void)setShouldBypassEffect:(BOOL)shouldBypassEffect {
    [super setShouldBypassEffect:shouldBypassEffect];
    _render->bypass.store(shouldBypassEffect);
}

- (NSTimeInterval)latency {
    if (!_plugin) return 0;
    return _plugin->latencySamples() / _outputBus.format.sampleRate;
}

- (AUInternalRenderBlock)internalRenderBlock {
    RenderState *state = _render.get();
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount, NSInteger outputBusNumber,
                              AudioBufferList *outputData, const AURenderEvent *realtimeEventListHead,
                              AURenderPullInputBlock pullInputBlock) {
      if (!pullInputBlock) return kAudioUnitErr_NoConnection;
      AudioBufferList *input = state->prepareInput(frameCount);
      AUAudioUnitStatus status = pullInputBlock(actionFlags, timestamp, frameCount, 0, input);
      if (status != noErr) return status;

      // Process in place when the engine gives no output memory.
      for (UInt32 i = 0; i < outputData->mNumberBuffers && i < 2; ++i) {
          if (outputData->mBuffers[i].mData == nullptr) {
              outputData->mBuffers[i].mData = input->mBuffers[i].mData;
          }
          outputData->mBuffers[i].mDataByteSize = frameCount * sizeof(float);
      }
      if (outputData->mNumberBuffers < 2) return kAudioUnitErr_FormatNotSupported;

      float *inputs[2] = {static_cast<float *>(input->mBuffers[0].mData),
                          static_cast<float *>(input->mBuffers[1].mData)};
      float *outputs[2] = {static_cast<float *>(outputData->mBuffers[0].mData),
                           static_cast<float *>(outputData->mBuffers[1].mData)};

      if (state->bypass.load() || !state->plugin || !state->plugin->isActive()) {
          for (int c = 0; c < 2; ++c) {
              if (outputs[c] != inputs[c]) memcpy(outputs[c], inputs[c], frameCount * sizeof(float));
          }
      } else {
          state->plugin->process(inputs, outputs, static_cast<int32>(frameCount));
      }
      return noErr;
    };
}

// MARK: State

- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary *state = [[super fullState] mutableCopy] ?: [NSMutableDictionary dictionary];
    std::vector<char> component, controller;
    if (_plugin && _plugin->getState(component, controller)) {
        state[@"vst3.component"] = [NSData dataWithBytes:component.data() length:component.size()];
        state[@"vst3.controller"] = [NSData dataWithBytes:controller.data() length:controller.size()];
    }
    return state;
}

- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    [super setFullState:fullState];
    if (!_plugin) return;
    NSData *component = fullState[@"vst3.component"];
    NSData *controller = fullState[@"vst3.controller"];
    if (![component isKindOfClass:[NSData class]]) return;
    if (![controller isKindOfClass:[NSData class]]) controller = nil;
    _plugin->setState(component.bytes, component.length, controller.bytes, controller.length);
}

// MARK: Editor

- (void)requestViewControllerWithCompletionHandler:(void (^)(AUViewControllerBase *_Nullable))completionHandler {
    if (!_plugin || !_plugin->controller()) {
        completionHandler(nil);
        return;
    }
    VST3EditorController *controller = [[VST3EditorController alloc] initWithController:_plugin->controller()];
    completionHandler(controller.hasEditor ? controller : nil);
}

@end
