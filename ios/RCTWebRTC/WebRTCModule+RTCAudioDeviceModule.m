#import <objc/runtime.h>

#import <React/RCTBridge.h>
#import <React/RCTBridgeModule.h>

#import "WebRTCModule.h"

// The underlying `RTCAudioDeviceModule` is owned by the `RTCPeerConnectionFactory`.
// `WebRTCModule.audioDeviceModule` is a Swift wrapper around it, so we reach for the
// raw device module here when we need to call APIs that are only defined on
// `RTCAudioDeviceModule`.
#define RAW_ADM (self.peerConnectionFactory.audioDeviceModule)

@implementation WebRTCModule (RTCAudioDeviceModule)

- (void)handleADMResult:(NSInteger)result
              operation:(NSString *)op
                   code:(NSString *)code
                resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject {
    if (result == 0) {
        resolve(nil);
    } else {
        reject(code, [NSString stringWithFormat:@"Failed to %@: %ld", op, (long)result], nil);
    }
}

#pragma mark - Recording & Playback Control

RCT_EXPORT_METHOD(audioDeviceModuleStartPlayout
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM startPlayout] operation:@"start playout" code:@"playout_error" resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(audioDeviceModuleStopPlayout
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM stopPlayout] operation:@"stop playout" code:@"playout_error" resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(audioDeviceModuleStartRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM startRecording] operation:@"start recording" code:@"recording_error" resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(audioDeviceModuleStopRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM stopRecording] operation:@"stop recording" code:@"recording_error" resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(audioDeviceModuleStartLocalRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM initAndStartRecording] operation:@"start local recording" code:@"recording_error" resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(audioDeviceModuleStopLocalRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM stopRecording] operation:@"stop local recording" code:@"recording_error" resolve:resolve reject:reject];
}

#pragma mark - Microphone Control

RCT_EXPORT_METHOD(audioDeviceModuleSetMicrophoneMuted
                  : (BOOL)muted resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM setMicrophoneMuted:muted] operation:@"set microphone mute" code:@"mute_error" resolve:resolve reject:reject];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsMicrophoneMuted) {
    return @(RAW_ADM.isMicrophoneMuted);
}

#pragma mark - Voice Processing

RCT_EXPORT_METHOD(audioDeviceModuleSetVoiceProcessingEnabled
                  : (BOOL)enabled resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM setVoiceProcessingEnabled:enabled] operation:@"set voice processing" code:@"voice_processing_error" resolve:resolve reject:reject];
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
    [self handleADMResult:[RAW_ADM setMuteMode:(RTCAudioEngineMuteMode)mode] operation:@"set mute mode" code:@"mute_mode_error" resolve:resolve reject:reject];
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
    [self handleADMResult:[RAW_ADM setRecordingAlwaysPreparedMode:enabled] operation:@"set recording always prepared mode" code:@"recording_always_prepared_mode_error" resolve:resolve reject:reject];
}

// TODO: `getEngineAvailability` / `setEngineAvailability` were dropped because the
// Stream WebRTC SDK does not expose `RTCAudioEngineAvailability` / `-setEngineAvailability:`.
// The closest equivalent is `RTCAudioEngineState` via `engineState`, but the
// semantics differ and the JS API isn't consumed anywhere yet.

// TODO: Observer delegate "resolve" methods were skipped because our current
// `AudioDeviceModuleObserver` does not expose async JS-driven resolution hooks;
// the Swift `AudioDeviceModule` wrapper always returns success immediately.

@end

#undef RAW_ADM
