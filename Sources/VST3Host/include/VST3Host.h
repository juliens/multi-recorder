#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Component description of the VST3 host audio unit. It is registered in process only.
extern const AudioComponentDescription VST3HostComponentDescription;

/// An effect audio unit that runs a VST3 plug-in. Stereo in, stereo out.
///
/// Use: register once, instantiate `VST3HostComponentDescription` in process,
/// then call `loadPluginAtPath:classID:error:` before the unit is connected.
/// `fullState` holds the plug-in state, and `requestViewController` gives its editor.
@interface VST3AudioUnit : AUAudioUnit

+ (void)registerOnce;

/// `classID` is the 32 hex characters of the class ID. `nil` takes the first audio effect.
- (BOOL)loadPluginAtPath:(NSString *)path classID:(nullable NSString *)classID error:(NSError **)error;

@property(nonatomic, readonly, nullable) NSString *pluginName;

@end

NS_ASSUME_NONNULL_END
