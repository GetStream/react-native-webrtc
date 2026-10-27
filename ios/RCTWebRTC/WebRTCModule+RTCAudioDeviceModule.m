#import <AVFoundation/AVFoundation.h>
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

#pragma mark - Engine Recovery

- (BOOL)isMicrophonePermissionGranted {
#if TARGET_OS_OSX || TARGET_OS_TV
    return YES;
#else
    if (@available(iOS 17.0, *)) {
        return AVAudioApplication.sharedInstance.recordPermission == AVAudioApplicationRecordPermissionGranted;
    }
    return AVAudioSession.sharedInstance.recordPermission == AVAudioSessionRecordPermissionGranted;
#endif
}

// The ADM can record a failed AVAudioEngine start as running, so later starts are no-ops and the mic stays dead.
// Detects a dead (requested but not running) or output-only engine and restarts it. ADM return codes are reported
// in `codes`; this never rejects. Uses `resolveCurrentOrNil` (not RAW_ADM) so it never builds a default factory.
RCT_EXPORT_METHOD(audioDeviceModuleRecoverEngineIfNeeded
                  : (BOOL)wantsRecording resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    RTCAudioDeviceModule *adm = [self.factoryRegistry resolveCurrentOrNil].factory.audioDeviceModule;
    if (!adm) {
        resolve(@{@"result" : @"skipped", @"reason" : @"noCall", @"before" : [NSNull null], @"codes" : @{}});
        return;
    }

    NSDictionary *before = [self engineStateForADM:adm];
    BOOL isPlaying = [before[@"isPlaying"] boolValue];
    BOOL isRecording = [before[@"isRecording"] boolValue];
    BOOL isEngineRunning = [before[@"isEngineRunning"] boolValue];
    BOOL isInputAvailable = [before[@"isInputAvailable"] boolValue];
    BOOL isOutputAvailable = [before[@"isOutputAvailable"] boolValue];
    BOOL micGranted = [self isMicrophonePermissionGranted];

    BOOL needsInput = wantsRecording && micGranted && isInputAvailable;
    BOOL needsOutput = isPlaying && isOutputAvailable;

    NSMutableDictionary<NSString *, NSNumber *> *codes = [NSMutableDictionary dictionary];
    NSString *result;
    NSString *reason = nil;
    NSDictionary *after = nil;

    if (!needsInput && !needsOutput) {
        result = @"skipped";
        if ((wantsRecording && micGranted && !isInputAvailable) || (isPlaying && !isOutputAvailable)) {
            reason = @"gated";
        } else if (wantsRecording && !micGranted) {
            reason = @"noMicPermission";
        }
    } else if (!(needsInput && !isRecording) && isEngineRunning) {
        result = @"healthy";
    } else {
        if (needsInput) {
            // Straight-line (no early return) so prepared mode is always restored.
            BOOL wasPrepared = adm.isRecordingAlwaysPreparedMode;
            if (wasPrepared) {
                codes[@"setPreparedOff"] = @([adm setRecordingAlwaysPreparedMode:NO]);
            }
            if (isRecording) {
                codes[@"stopRecording"] = @([adm stopRecording]);
            }
            if (adm.isRecordingInitialized) {
                codes[@"startRecording"] = @([adm startRecording]);
            } else {
                codes[@"initAndStartRecording"] = @([adm initAndStartRecording]);
            }
            codes[@"unmute"] = @([adm setMicrophoneMuted:NO]);
            if (wasPrepared) {
                codes[@"restorePrepared"] = @([adm setRecordingAlwaysPreparedMode:YES]);
            }
        } else {
            codes[@"stopPlayout"] = @([adm stopPlayout]);
            codes[@"initPlayout"] = @([adm initPlayout]);
            codes[@"startPlayout"] = @([adm startPlayout]);
        }

        after = [self engineStateForADM:adm];
        BOOL afterRunning = [after[@"isEngineRunning"] boolValue];
        BOOL afterRecording = [after[@"isRecording"] boolValue];
        if (afterRunning && (!needsInput || afterRecording)) {
            result = @"recovered";
        } else if (afterRunning) {
            result = @"outputOnly";
        } else {
            result = @"failed";
        }
    }

    NSLog(@"[WebRTCModule] recoverEngineIfNeeded result=%@ reason=%@ before=%@ after=%@ codes=%@",
          result,
          reason,
          before,
          after,
          codes);

    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"result"] = result;
    response[@"reason"] = reason;
    response[@"before"] = before;
    response[@"after"] = after;
    response[@"codes"] = codes;
    resolve(response);
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
