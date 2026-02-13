#import "AudioDeviceModuleObserver.h"
#import <React/RCTLog.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioDeviceModuleObserver ()

@property(weak, nonatomic) WebRTCModule *module;

@end

@implementation AudioDeviceModuleObserver

- (instancetype)initWithWebRTCModule:(WebRTCModule *)module {
    self = [super init];
    if (self) {
        self.module = module;
        RCTLog(@"[AudioDeviceModuleObserver] Initialized observer: %@ for module: %@", self, module);
    }
    return self;
}

#pragma mark - RTCAudioDeviceModuleDelegate

- (void)audioDeviceModule:(RTCAudioDeviceModule *)audioDeviceModule
    didReceiveSpeechActivityEvent:(RTCSpeechActivityEvent)speechActivityEvent {
    NSString *eventType = speechActivityEvent == RTCSpeechActivityEventStarted ? @"started" : @"ended";

    if (self.module.bridge != nil) {
        [self.module sendEventWithName:kEventAudioDeviceModuleSpeechActivity
                                  body:@{
                                      @"event" : eventType,
                                  }];
    }

    RCTLog(@"[AudioDeviceModuleObserver] Speech activity event: %@", eventType);
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule *)audioDeviceModule didCreateEngine:(AVAudioEngine *)engine {
    RCTLog(@"[AudioDeviceModuleObserver] Engine created");

    if (self.module.bridge != nil) {
        [self.module sendEventWithName:kEventAudioDeviceModuleEngineCreated body:@{}];
    }

    return 0; // Success
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule *)audioDeviceModule
              willEnableEngine:(AVAudioEngine *)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
    RCTLog(@"[AudioDeviceModuleObserver] Engine will enable - playout: %d, recording: %d",
           isPlayoutEnabled,
           isRecordingEnabled);

    if (self.module.bridge != nil) {
        [self.module sendEventWithName:kEventAudioDeviceModuleEngineWillEnable
                                  body:@{
                                      @"isPlayoutEnabled" : @(isPlayoutEnabled),
                                      @"isRecordingEnabled" : @(isRecordingEnabled),
                                  }];
    }

    return 0; // Success
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule *)audioDeviceModule
               willStartEngine:(AVAudioEngine *)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
    RCTLog(@"[AudioDeviceModuleObserver] Engine will start - playout: %d, recording: %d",
           isPlayoutEnabled,
           isRecordingEnabled);

    if (self.module.bridge != nil) {
        [self.module sendEventWithName:kEventAudioDeviceModuleEngineWillStart
                                  body:@{
                                      @"isPlayoutEnabled" : @(isPlayoutEnabled),
                                      @"isRecordingEnabled" : @(isRecordingEnabled),
                                  }];
    }

    return 0; // Success
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule *)audioDeviceModule
                 didStopEngine:(AVAudioEngine *)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
    RCTLog(@"[AudioDeviceModuleObserver] Engine did stop - playout: %d, recording: %d",
           isPlayoutEnabled,
           isRecordingEnabled);

    if (self.module.bridge != nil) {
        [self.module sendEventWithName:kEventAudioDeviceModuleEngineDidStop
                                  body:@{
                                      @"isPlayoutEnabled" : @(isPlayoutEnabled),
                                      @"isRecordingEnabled" : @(isRecordingEnabled),
                                  }];
    }

    return 0; // Success
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule *)audioDeviceModule
              didDisableEngine:(AVAudioEngine *)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
    RCTLog(@"[AudioDeviceModuleObserver] Engine did disable - playout: %d, recording: %d",
           isPlayoutEnabled,
           isRecordingEnabled);

    if (self.module.bridge != nil) {
        [self.module sendEventWithName:kEventAudioDeviceModuleEngineDidDisable
                                  body:@{
                                      @"isPlayoutEnabled" : @(isPlayoutEnabled),
                                      @"isRecordingEnabled" : @(isRecordingEnabled),
                                  }];
    }

    return 0; // Success
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule *)audioDeviceModule willReleaseEngine:(AVAudioEngine *)engine {
    RCTLog(@"[AudioDeviceModuleObserver] Engine will release");

    if (self.module.bridge != nil) {
        [self.module sendEventWithName:kEventAudioDeviceModuleEngineWillRelease body:@{}];
    }

    return 0; // Success
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule *)audioDeviceModule
                        engine:(AVAudioEngine *)engine
      configureInputFromSource:(nullable AVAudioNode *)source
                 toDestination:(AVAudioNode *)destination
                    withFormat:(AVAudioFormat *)format
                       context:(NSDictionary *)context {
    RCTLog(@"[AudioDeviceModuleObserver] Configure input - format: %@", format);
    return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule *)audioDeviceModule
                        engine:(AVAudioEngine *)engine
     configureOutputFromSource:(AVAudioNode *)source
                 toDestination:(nullable AVAudioNode *)destination
                    withFormat:(AVAudioFormat *)format
                       context:(NSDictionary *)context {
    RCTLog(@"[AudioDeviceModuleObserver] Configure output - format: %@", format);
    return 0;
}

- (void)audioDeviceModuleDidUpdateDevices:(RTCAudioDeviceModule *)audioDeviceModule {
    if (self.module.bridge != nil) {
        [self.module sendEventWithName:kEventAudioDeviceModuleDevicesUpdated body:@{}];
    }

    RCTLog(@"[AudioDeviceModuleObserver] Devices updated");
}

- (void)audioDeviceModule:(RTCAudioDeviceModule *)audioDeviceModule
    didUpdateAudioProcessingState:(RTCAudioProcessingState)state {
    if (self.module.bridge != nil) {
        [self.module sendEventWithName:kEventAudioDeviceModuleAudioProcessingStateUpdated
                                  body:@{
                                      @"voiceProcessingEnabled" : @(state.voiceProcessingEnabled),
                                      @"voiceProcessingBypassed" : @(state.voiceProcessingBypassed),
                                      @"voiceProcessingAGCEnabled" : @(state.voiceProcessingAGCEnabled),
                                      @"stereoPlayoutEnabled" : @(state.stereoPlayoutEnabled),
                                  }];
    }

    RCTLog(@"[AudioDeviceModuleObserver] Audio processing state updated - VP enabled: %d, VP bypassed: %d, AGC enabled: %d, stereo: %d",
           state.voiceProcessingEnabled,
           state.voiceProcessingBypassed,
           state.voiceProcessingAGCEnabled,
           state.stereoPlayoutEnabled);
}

@end

NS_ASSUME_NONNULL_END
