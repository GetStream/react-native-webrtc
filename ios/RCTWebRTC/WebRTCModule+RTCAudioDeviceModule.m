#import <objc/runtime.h>

#import <React/RCTBridge.h>
#import <React/RCTBridgeModule.h>

#import "WebRTCModule.h"

// Import Swift-generated header to reach PeerConnectionFactoryRegistry
#if __has_include(<stream_react_native_webrtc/stream_react_native_webrtc-Swift.h>)
#import <stream_react_native_webrtc/stream_react_native_webrtc-Swift.h>
#elif __has_include("stream_react_native_webrtc-Swift.h")
#import "stream_react_native_webrtc-Swift.h"
#endif

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

// Reads every property once: each ADM getter is a blocking hop to the WebRTC worker thread.
- (NSDictionary *)engineStateForADM:(RTCAudioDeviceModule *)adm {
    RTCAudioEngineAvailability availability = adm.engineAvailability;
    RTCAudioSession *session = [RTCAudioSession sharedInstance];
    return @{
        @"isPlaying" : @(adm.isPlaying),
        @"isRecording" : @(adm.isRecording),
        @"isEngineRunning" : @(adm.isEngineRunning),
        @"isMicrophoneMuted" : @(adm.isMicrophoneMuted),
        @"isRecordingAlwaysPreparedMode" : @(adm.isRecordingAlwaysPreparedMode),
        @"isInputAvailable" : @(availability.isInputAvailable),
        @"isOutputAvailable" : @(availability.isOutputAvailable),
        @"isVoiceProcessingEnabled" : @(adm.isVoiceProcessingEnabled),
        @"sessionCategory" : session.category ?: [NSNull null],
        @"sessionActive" : @(session.isActive),
    };
}

#pragma mark - Engine State

// Uses `resolveCurrentOrNil` (not RAW_ADM) so querying never builds a default factory.
RCT_EXPORT_METHOD(audioDeviceModuleGetEngineState
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    RTCAudioDeviceModule *adm = [self.factoryRegistry resolveCurrentOrNil].factory.audioDeviceModule;
    resolve(adm ? [self engineStateForADM:adm] : nil);
}

#pragma mark - Recording & Playback Control

RCT_EXPORT_METHOD(audioDeviceModuleStartPlayout
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM startPlayout]
                operation:@"start playout"
                     code:@"playout_error"
                  resolve:resolve
                   reject:reject];
}

RCT_EXPORT_METHOD(audioDeviceModuleStopPlayout
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM stopPlayout]
                operation:@"stop playout"
                     code:@"playout_error"
                  resolve:resolve
                   reject:reject];
}

RCT_EXPORT_METHOD(audioDeviceModuleStartRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM startRecording]
                operation:@"start recording"
                     code:@"recording_error"
                  resolve:resolve
                   reject:reject];
}

RCT_EXPORT_METHOD(audioDeviceModuleStopRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM stopRecording]
                operation:@"stop recording"
                     code:@"recording_error"
                  resolve:resolve
                   reject:reject];
}

RCT_EXPORT_METHOD(audioDeviceModuleStartLocalRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM initAndStartRecording]
                operation:@"start local recording"
                     code:@"recording_error"
                  resolve:resolve
                   reject:reject];
}

RCT_EXPORT_METHOD(audioDeviceModuleStopLocalRecording
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM stopRecording]
                operation:@"stop local recording"
                     code:@"recording_error"
                  resolve:resolve
                   reject:reject];
}

#pragma mark - Microphone Control

RCT_EXPORT_METHOD(audioDeviceModuleSetMicrophoneMuted
                  : (BOOL)muted resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM setMicrophoneMuted:muted]
                operation:@"set microphone mute"
                     code:@"mute_error"
                  resolve:resolve
                   reject:reject];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioDeviceModuleIsMicrophoneMuted) {
    return @(RAW_ADM.isMicrophoneMuted);
}

#pragma mark - Voice Processing

RCT_EXPORT_METHOD(audioDeviceModuleSetVoiceProcessingEnabled
                  : (BOOL)enabled resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self handleADMResult:[RAW_ADM setVoiceProcessingEnabled:enabled]
                operation:@"set voice processing"
                     code:@"voice_processing_error"
                  resolve:resolve
                   reject:reject];
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
    [self handleADMResult:[RAW_ADM setMuteMode:(RTCAudioEngineMuteMode)mode]
                operation:@"set mute mode"
                     code:@"mute_mode_error"
                  resolve:resolve
                   reject:reject];
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
    [self handleADMResult:[RAW_ADM setRecordingAlwaysPreparedMode:enabled]
                operation:@"set recording always prepared mode"
                     code:@"recording_always_prepared_mode_error"
                  resolve:resolve
                   reject:reject];
}

// TODO: Observer delegate "resolve" methods were skipped because our current
// `AudioDeviceModuleObserver` does not expose async JS-driven resolution hooks;
// the Swift `AudioDeviceModule` wrapper always returns success immediately.

@end

#undef RAW_ADM
