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

// Accessed only on the worker queue. Lifecycle requests wait for both teardown phases.
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *pendingFactoryOperations;
@property(nonatomic, assign) BOOL factoryDisposalPending;

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
        _pendingFactoryOperations = [NSMutableArray new];

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

    [self runFactoryOperation:^{
        void (^create)(void) = ^{
            PeerConnectionFactoryProvider *factory = [self.factoryRegistry create:bypassVoiceProcessing];
            if (factory == nil) {
                reject(@"E_FACTORY_CREATE", @"Failed to create call factory: registry is disposed", nil);
                return;
            }
            resolve(nil);
        };

        // Tear a stale bare-fork default down in order first. The teardown is two-phase, so the new
        // factory must be built from the completion — building it inline would create it while the
        // old factory's PeerConnections were still alive.
        if ([self.factoryRegistry isBareForkDefaultLive]) {
            RCTLogInfo(@"createCallFactory(): tearing down stale bare-fork default (ordered) before "
                        "creating the call factory");
            [self disposeCurrentFactoryOrdered:^(BOOL disposed) {
                create();
            }];
        } else {
            create();
        }
    }];
}

RCT_EXPORT_METHOD(disposeCallFactory
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self runFactoryOperation:^{
        [self disposeCurrentFactoryOrdered:^(BOOL disposed) {
            resolve(@(disposed));
        }];
    }];
}

// Must be called on the worker queue (the module's methodQueue).
- (void)runFactoryOperation:(dispatch_block_t)operation {
    [self.pendingFactoryOperations addObject:operation];
    [self drainFactoryOperations];
}

- (void)drainFactoryOperations {
    while (!self.factoryDisposalPending && self.pendingFactoryOperations.count > 0) {
        dispatch_block_t operation = self.pendingFactoryOperations.firstObject;
        [self.pendingFactoryOperations removeObjectAtIndex:0];
        operation();
    }
}

/**
 * Disposes the live factory and its dependents in order: PeerConnections → local tracks → local
 * streams → video-effects processor → factory + ADM. Everything is ARC-refcounted, so the factory
 * is freed only when its LAST reference drops — every dependent that strong-refs it (PCs, tracks,
 * streams, and the videoEffectProcessor associated object) must be released first or the factory
 * leaks. No-op unless this is the last reference; `onDisposed` receives whether the factory was
 * actually disposed.
 *
 * Split across two worker-queue turns: phase 1 only closes the PeerConnections, phase 2 disposes
 * them and everything else. -[RTCPeerConnection close] is synchronous and its delegate callbacks
 * dispatch_async onto the worker queue before it returns, so phase 2 (queued after them) runs
 * only once that backlog has drained against still-registered PeerConnections.
 */
- (void)disposeCurrentFactoryOrdered:(void (^)(BOOL disposed))onDisposed {
    if (![self.factoryRegistry releaseReference]) {
        onDisposed(NO);
        return;
    }

    self.factoryDisposalPending = YES;
    for (NSNumber *pcId in [self.peerConnections.allKeys copy]) {
        @try {
            [self peerConnectionClose:pcId];
        } @catch (NSException *e) {
            RCTLogWarn(@"disposeCurrentFactoryOrdered(): error closing pc %@: %@", pcId, e.reason);
        }
    }

    dispatch_async(self.workerQueue, ^{
        @try {
            [self disposeCurrentFactoryDependents];
            onDisposed([self.factoryRegistry disposeCurrent]);
        } @finally {
            self.factoryDisposalPending = NO;
            [self drainFactoryOperations];
        }
    });
}

- (void)disposeCurrentFactoryDependents {
    for (NSNumber *pcId in [self.peerConnections.allKeys copy]) {
        @try {
            [self peerConnectionDispose:pcId];
        } @catch (NSException *e) {
            RCTLogWarn(@"disposeCurrentFactoryOrdered(): error disposing pc %@: %@", pcId, e.reason);
        }
    }

    for (NSString *trackId in [self.localTracks.allKeys copy]) {
        @try {
            [self mediaStreamTrackRelease:trackId];
        } @catch (NSException *e) {
            RCTLogWarn(@"disposeCurrentFactoryOrdered(): error disposing track %@: %@", trackId, e.reason);
        }
    }

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

    self.videoEffectProcessor = nil;
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
