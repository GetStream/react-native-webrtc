#import <objc/runtime.h>

#import <React/RCTBridge.h>
#import <React/RCTBridgeModule.h>

#import "AudioDeviceModuleObserver.h"
#import "WebRTCModule.h"

// The underlying `RTCAudioDeviceModule` is owned by the `RTCPeerConnectionFactory`.
// `WebRTCModule.audioDeviceModule` is a Swift wrapper around it, so we reach for the
// raw device module here when we need to call APIs that are only defined on
// `RTCAudioDeviceModule`.
#define RAW_ADM (self.peerConnectionFactory.audioDeviceModule)

@implementation WebRTCModule (RTCAudioDeviceModule)

#pragma mark - Recording & Playback Control

RCT_EXPORT_METHOD(audioDeviceModuleStartPlayout
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    NSInteger result = [RAW_ADM startPlayout];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(@"playout_error", [NSString stringWithFormat:@"Failed to start playout: %ld", (long)result], nil);
    }
}

RCT_EXPORT_METHOD(audioDeviceModuleStopPlayout
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    NSInteger result = [RAW_ADM stopPlayout];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(@"playout_error", [NSString stringWithFormat:@"Failed to stop playout: %ld", (long)result], nil);
    }
}

RCT_EXPORT_METHOD(audioDeviceModuleStartRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    NSInteger result = [RAW_ADM startRecording];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(@"recording_error", [NSString stringWithFormat:@"Failed to start recording: %ld", (long)result], nil);
    }
}

RCT_EXPORT_METHOD(audioDeviceModuleStopRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    NSInteger result = [RAW_ADM stopRecording];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(@"recording_error", [NSString stringWithFormat:@"Failed to stop recording: %ld", (long)result], nil);
    }
}

RCT_EXPORT_METHOD(audioDeviceModuleStartLocalRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    NSInteger result = [RAW_ADM initAndStartRecording];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(
            @"recording_error", [NSString stringWithFormat:@"Failed to start local recording: %ld", (long)result], nil);
    }
}

RCT_EXPORT_METHOD(audioDeviceModuleStopLocalRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    NSInteger result = [RAW_ADM stopRecording];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(
            @"recording_error", [NSString stringWithFormat:@"Failed to stop local recording: %ld", (long)result], nil);
    }
}

#pragma mark - Microphone Control

RCT_EXPORT_METHOD(audioDeviceModuleSetMicrophoneMuted
                  : (BOOL)muted resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    NSInteger result = [RAW_ADM setMicrophoneMuted:muted];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(@"mute_error", [NSString stringWithFormat:@"Failed to set microphone mute: %ld", (long)result], nil);
    }
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsMicrophoneMuted) {
    return @(RAW_ADM.isMicrophoneMuted);
}

#pragma mark - Voice Processing

RCT_EXPORT_METHOD(audioDeviceModuleSetVoiceProcessingEnabled
                  : (BOOL)enabled resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    NSInteger result = [RAW_ADM setVoiceProcessingEnabled:enabled];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(@"voice_processing_error",
               [NSString stringWithFormat:@"Failed to set voice processing: %ld", (long)result],
               nil);
    }
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsVoiceProcessingEnabled) {
    return @(RAW_ADM.isVoiceProcessingEnabled);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleSetVoiceProcessingBypassed : (BOOL)bypassed) {
    RAW_ADM.voiceProcessingBypassed = bypassed;
    return nil;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsVoiceProcessingBypassed) {
    return @(RAW_ADM.isVoiceProcessingBypassed);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleSetVoiceProcessingAGCEnabled : (BOOL)enabled) {
    RAW_ADM.voiceProcessingAGCEnabled = enabled;
    return nil;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsVoiceProcessingAGCEnabled) {
    return @(RAW_ADM.isVoiceProcessingAGCEnabled);
}

#pragma mark - Status

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsPlaying) {
    return @(RAW_ADM.isPlaying);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsRecording) {
    return @(RAW_ADM.isRecording);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsEngineRunning) {
    return @(RAW_ADM.isEngineRunning);
}

#pragma mark - Advanced Features

RCT_EXPORT_METHOD(audioDeviceModuleSetMuteMode
                  : (NSInteger)mode resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    NSInteger result = [RAW_ADM setMuteMode:(RTCAudioEngineMuteMode)mode];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(@"mute_mode_error", [NSString stringWithFormat:@"Failed to set mute mode: %ld", (long)result], nil);
    }
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleGetMuteMode) {
    return @(RAW_ADM.muteMode);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleSetAdvancedDuckingEnabled : (BOOL)enabled) {
    RAW_ADM.advancedDuckingEnabled = enabled;
    return nil;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsAdvancedDuckingEnabled) {
    return @(RAW_ADM.isAdvancedDuckingEnabled);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleSetDuckingLevel : (NSInteger)level) {
    RAW_ADM.duckingLevel = level;
    return nil;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleGetDuckingLevel) {
    return @(RAW_ADM.duckingLevel);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsRecordingAlwaysPreparedMode) {
    return @(RAW_ADM.recordingAlwaysPreparedMode);
}

RCT_EXPORT_METHOD(audioDeviceModuleSetRecordingAlwaysPreparedMode
                  : (BOOL)enabled resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    NSInteger result = [RAW_ADM setRecordingAlwaysPreparedMode:enabled];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(@"recording_always_prepared_mode_error",
               [NSString stringWithFormat:@"Failed to set recording always prepared mode: %ld", (long)result],
               nil);
    }
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleGetEngineAvailability) {
    RTCAudioEngineAvailability availability = RAW_ADM.engineAvailability;
    return @{
        @"isInputAvailable" : @(availability.isInputAvailable),
        @"isOutputAvailable" : @(availability.isOutputAvailable)
    };
}

RCT_EXPORT_METHOD(audioDeviceModuleSetEngineAvailability
                  : (NSDictionary *)availabilityDict resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    RTCAudioEngineAvailability availability;
    availability.isInputAvailable = [availabilityDict[@"isInputAvailable"] boolValue];
    availability.isOutputAvailable = [availabilityDict[@"isOutputAvailable"] boolValue];
    NSInteger result = [RAW_ADM setEngineAvailability:availability];
    if (result == 0) {
        resolve(nil);
    } else {
        reject(@"engine_availability_error",
               [NSString stringWithFormat:@"Failed to set engine availability: %ld", (long)result],
               nil);
    }
}

// TODO: Observer delegate "resolve" methods were skipped because our current
// `AudioDeviceModuleObserver` does not expose async JS-driven resolution hooks;
// the Swift `AudioDeviceModule` wrapper always returns success immediately.

@end

#undef RAW_ADM
