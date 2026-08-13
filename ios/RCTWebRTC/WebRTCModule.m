#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

#import <React/RCTBridge.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>

#import "AudioDeviceModuleObserver.h"
#import "RTCCameraPreviewViewManager.h"
#import "WebRTCModule+RTCMediaStream.h"
#import "WebRTCModule+RTCPeerConnection.h"
#import "WebRTCModule.h"
#import "WebRTCModuleOptions.h"

// Import Swift classes
// We need the following if and elif directives to properly import the generated Swift header for the module,
// handling both cases where CocoaPods module import path is available and where it is not.
// This ensures compatibility regardless of whether the project is built with frameworks enabled or as static libraries.
#if __has_include(<stream_react_native_webrtc/stream_react_native_webrtc-Swift.h>)
#import <stream_react_native_webrtc/stream_react_native_webrtc-Swift.h>
#elif __has_include("stream_react_native_webrtc-Swift.h")
#import "stream_react_native_webrtc-Swift.h"
#endif

@interface WebRTCModule ()

@property(nonatomic, strong) AudioDeviceModuleObserver *rtcAudioDeviceModuleObserver;

@end

@implementation WebRTCModule

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

- (void)dealloc {
    [_localTracks removeAllObjects];
    _localTracks = nil;
    [_localStreams removeAllObjects];
    _localStreams = nil;

    for (NSNumber *peerConnectionId in _peerConnections) {
        RTCPeerConnection *peerConnection = _peerConnections[peerConnectionId];
        peerConnection.delegate = nil;
        [peerConnection close];
    }
    [_peerConnections removeAllObjects];
    [_factoryRegistry disposeAll];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        WebRTCModuleOptions *options = [WebRTCModuleOptions sharedInstance];
        id<RTCAudioDevice> audioDevice = options.audioDevice;
        id<RTCVideoDecoderFactory> decoderFactory = options.videoDecoderFactory;
        id<RTCVideoEncoderFactory> encoderFactory = options.videoEncoderFactory;
        id<RTCAudioProcessingModule> audioProcessingModule = options.audioProcessingModule;
        NSDictionary *fieldTrials = options.fieldTrials;
        RTCLoggingSeverity loggingSeverity = options.loggingSeverity;

        // Temporarily disable field trials
        // this supposedly makes libwebrtc promptly detect wifi↔cellular route changes and reset the send-side BWE — and never enables WebRTC-Bwe-SafeResetOnRouteChange
        // // Initialize field trials.
        // if (fieldTrials == nil) {
        //     // Fix for dual-sim connectivity:
        //     // https://bugs.chromium.org/p/webrtc/issues/detail?id=10966
        //     fieldTrials = @{kRTCFieldTrialUseNWPathMonitor : kRTCFieldTrialEnabledValue};
        // }
        // RTCInitFieldTrialDictionary(fieldTrials);

        // Initialize logging.
        RTCSetMinDebugLogLevel(loggingSeverity);

        if (encoderFactory == nil) {
            RTCDefaultVideoEncoderFactory *videoEncoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
            RTCVideoEncoderFactorySimulcast *simulcastVideoEncoderFactory =
                [[RTCVideoEncoderFactorySimulcast alloc] initWithPrimary:videoEncoderFactory
                                                                fallback:videoEncoderFactory];
            encoderFactory = simulcastVideoEncoderFactory;
        }
        if (decoderFactory == nil) {
            decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        }
        _encoderFactory = encoderFactory;
        _decoderFactory = decoderFactory;

        RCTLogInfo(@"Using video encoder factory: %@", NSStringFromClass([encoderFactory class]));
        RCTLogInfo(@"Using video decoder factory: %@", NSStringFromClass([decoderFactory class]));

        // Always ensure an audio processing module exists so screen share
        // audio mixing can use capturePostProcessingDelegate at runtime.
        if (audioProcessingModule == nil && audioDevice == nil) {
            audioProcessingModule = [[RTCDefaultAudioProcessingModule alloc] initWithConfig:nil
                                                              capturePostProcessingDelegate:nil
                                                                renderPreProcessingDelegate:nil];
            options.audioProcessingModule = audioProcessingModule;
            RCTLogInfo(@"Created default audio processing module for screen share audio mixing");
        }
        
        _rtcAudioDeviceModuleObserver = [[AudioDeviceModuleObserver alloc] initWithWebRTCModule:self];

        // Capture the observer (not self) so the builder block doesn't retain the module.
        AudioDeviceModuleObserver *audioDeviceModuleObserver = _rtcAudioDeviceModuleObserver;

        self.factoryRegistry = [[PeerConnectionFactoryRegistry alloc]
            initWithBuilder:^PeerConnectionFactoryProvider *(NSString *factoryId, BOOL bypassVoiceProcessing) {
                return [PeerConnectionFactoryProvider buildWithId:factoryId
                                            bypassVoiceProcessing:bypassVoiceProcessing
                                                   encoderFactory:encoderFactory
                                                   decoderFactory:decoderFactory
                                            audioProcessingModule:options.audioProcessingModule
                                                      audioDevice:options.audioDevice
                                        audioDeviceModuleObserver:audioDeviceModuleObserver];
            }];

        _peerConnections = [NSMutableDictionary new];
        _localStreams = [NSMutableDictionary new];
        _localTracks = [NSMutableDictionary new];

        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, -1);
        _workerQueue = dispatch_queue_create("WebRTCModule.queue", attributes);
    }

    return self;
}

- (RTCPeerConnectionFactory *)peerConnectionFactory {
    return [self.factoryRegistry getOrCreateDefault].factory;
}

- (AudioDeviceModule *)audioDeviceModule {
    return [self.factoryRegistry getOrCreateDefault].audioDeviceModule;
}

- (nullable AudioDeviceModule *)currentAudioDeviceModuleOrNil {
    return [self.factoryRegistry resolveCurrentOrNil].audioDeviceModule;
}

- (CaptureController *)adoptActiveCameraPreviewForSource:(RTCVideoSource *)source {
    id<RTCCameraPreviewControl> preview = self.activeCameraPreview;
    if (preview) {
        return [preview adoptCaptureForSource:source];
    }
    return nil;
}

- (RTCMediaStream *)streamForReactTag:(NSString *)reactTag {
    RTCMediaStream *stream = _localStreams[reactTag];
    if (!stream) {
        for (NSNumber *peerConnectionId in _peerConnections) {
            RTCPeerConnection *peerConnection = _peerConnections[peerConnectionId];
            stream = peerConnection.remoteStreams[reactTag];
            if (stream) {
                break;
            }
        }
    }
    return stream;
}

- (nullable RTCMediaStreamTrack *)trackForId:(NSString *)trackId {
    if (trackId.length == 0) {
        return nil;
    }
    RTCMediaStreamTrack *track = _localTracks[trackId];
    if (track) {
        return track;
    }
    for (NSNumber *peerConnectionId in _peerConnections) {
        RTCPeerConnection *peerConnection = _peerConnections[peerConnectionId];
        for (RTCRtpReceiver *receiver in peerConnection.receivers) {
            RTCMediaStreamTrack *received = receiver.track;
            if (received && [received.trackId isEqualToString:trackId]) {
                return received;
            }
        }
        for (RTCRtpSender *sender in peerConnection.senders) {
            RTCMediaStreamTrack *sent = sender.track;
            if (sent && [sent.trackId isEqualToString:trackId]) {
                return sent;
            }
        }
    }
    return nil;
}

RCT_EXPORT_MODULE();

- (dispatch_queue_t)methodQueue {
    return _workerQueue;
}

RCT_EXPORT_METHOD(createCallFactory
                  : (NSDictionary *)options resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    BOOL bypassVoiceProcessing = [options[@"bypassVoiceProcessing"] boolValue];

    // This makes default factory being disposed in a proper sequence.
    if ([self.factoryRegistry isBareForkDefaultLive]) {
        RCTLogInfo(@"createCallFactory(): tearing down stale bare-fork default (ordered) before "
                    "creating the call factory");
        [self disposeCurrentFactoryOrdered];
    }

    PeerConnectionFactoryProvider *factory = [self.factoryRegistry create:bypassVoiceProcessing];
    if (factory == nil) {
        reject(@"E_FACTORY_CREATE", @"Failed to create call factory: registry is disposed", nil);
        return;
    }
    resolve(nil);
}

RCT_EXPORT_METHOD(disposeCallFactory
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    resolve(@([self disposeCurrentFactoryOrdered]));
}

/**
 * Disposes the live factory in order — PeerConnections, then local tracks, then the factory + its
 * ADM — and returns whether a factory was disposed. An RTCPeerConnectionFactory must not be released
 * while PeerConnections or tracks created from it are still alive (use-after-free in libwebrtc), so
 * its dependents are torn down first. Shared by disposeCallFactory (leave) and createCallFactory
 * (replacing a stale bare-fork default at join), mirroring Android's disposeCurrentFactoryOrdered.
 *
 * Reference-counted: when the factory is shared across concurrent calls, only the LAST consumer's
 * release actually tears it down (releaseReference returns NO for earlier releases). On iOS the
 * module's own peerConnections / localTracks maps are the factory's ownership registry — only one
 * factory is ever live — so every remaining entry belongs to the factory being disposed. A leaving
 * call's own PCs/tracks were already released by its leave() before this runs.
 *
 * Runs on the module's serial worker queue (methodQueue), so the reused peerConnectionClose/
 * peerConnectionDispose/mediaStreamTrackRelease calls execute synchronously on the same thread.
 */
- (BOOL)disposeCurrentFactoryOrdered {
    if (![self.factoryRegistry releaseReference]) {
        return NO;
    }

    // 1. Close + dispose the factory's PeerConnections first.
    for (NSNumber *pcId in [self.peerConnections.allKeys copy]) {
        @try {
            [self peerConnectionClose:pcId];
            [self peerConnectionDispose:pcId];
        } @catch (NSException *e) {
            RCTLogWarn(@"disposeCurrentFactoryOrdered(): error disposing pc %@: %@", pcId, e.reason);
        }
    }

    // 2. Stop capture + release owned local tracks (e.g. a camera capturer adopted from the lobby
    // preview) so the AVCaptureSession is torn down before the factory's video sources are freed.
    for (NSString *trackId in [self.localTracks.allKeys copy]) {
        @try {
            [self mediaStreamTrackRelease:trackId];
        } @catch (NSException *e) {
            RCTLogWarn(@"disposeCurrentFactoryOrdered(): error disposing track %@: %@", trackId, e.reason);
        }
    }

    // 2b. Release local streams. An RTCMediaStream strong-refs its tracks, and every track (and the
    // video/audio source behind it) strong-refs the RTCPeerConnectionFactory — so a leftover stream
    // transitively pins the factory even after the tracks are gone from localTracks. Drop the
    // stream's track refs, then the stream itself, so nothing keeps the factory alive.
    for (NSString *streamId in [self.localStreams.allKeys copy]) {
        @try {
            RTCMediaStream *stream = self.localStreams[streamId];
            for (RTCAudioTrack *t in [stream.audioTracks copy]) {
                [stream removeAudioTrack:t];
            }
            for (RTCVideoTrack *t in [stream.videoTracks copy]) {
                [stream removeVideoTrack:t];
            }
            [self mediaStreamRelease:streamId];
        } @catch (NSException *e) {
            RCTLogWarn(@"disposeCurrentFactoryOrdered(): error disposing stream %@: %@", streamId, e.reason);
        }
    }

    // 2c. Drop the video-effects processor. It is retained by the module via an OBJC_ASSOCIATION_RETAIN
    // associated object and strong-refs the RTCVideoSource (background-blur pipeline), which strong-refs
    // the factory. Nothing else clears it on leave, so it independently pins the factory across calls.
    self.videoEffectProcessor = nil;

    // 3. Now it is safe to dispose the factory + its ADM.
    return [self.factoryRegistry disposeCurrent];
}

- (NSArray<NSString *> *)supportedEvents {
    return @[
        kEventPeerConnectionSignalingStateChanged,
        kEventPeerConnectionStateChanged,
        kEventPeerConnectionOnRenegotiationNeeded,
        kEventPeerConnectionIceConnectionChanged,
        kEventPeerConnectionIceGatheringChanged,
        kEventPeerConnectionGotICECandidate,
        kEventPeerConnectionDidOpenDataChannel,
        kEventDataChannelDidChangeBufferedAmount,
        kEventDataChannelStateChanged,
        kEventDataChannelReceiveMessage,
        kEventMediaStreamTrackMuteChanged,
        kEventVideoTrackDimensionChanged,
        kEventMediaStreamTrackEnded,
        kEventPeerConnectionOnRemoveTrack,
        kEventPeerConnectionOnTrack,
        kEventAudioDeviceModuleSpeechActivity,
        kEventAudioDeviceModuleEngineCreated,
        kEventAudioDeviceModuleEngineWillEnable,
        kEventAudioDeviceModuleEngineWillStart,
        kEventAudioDeviceModuleEngineDidStop,
        kEventAudioDeviceModuleEngineDidDisable,
        kEventAudioDeviceModuleEngineWillRelease,
        kEventAudioDeviceModuleDevicesUpdated,
        kEventAudioDeviceModuleAudioProcessingStateUpdated
    ];
}

@end
