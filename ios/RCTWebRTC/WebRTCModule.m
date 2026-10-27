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

// ADM log lines forwarded to JS as `audioDeviceModuleEngineError`.
static NSString *const kAudioEngineDeviceLogPrefix = @"AudioEngineDevice::";
static const NSUInteger kEngineErrorBufferCapacity = 50;
static const NSUInteger kEngineErrorRateLimitCount = 20;
static const NSTimeInterval kEngineErrorRateLimitWindow = 10.0;
static const NSTimeInterval kEngineErrorFlushDelay = 1.0;

@interface WebRTCModule ()

@property(nonatomic, strong) AudioDeviceModuleObserver *rtcAudioDeviceModuleObserver;

// Engine error forwarding. `engineErrorLogger` is guarded by `engineErrorLoggerLock`, `engineErrorBuffer` by
// `engineErrorBufferLock` (appended from the WebRTC logging thread). The pending/rate-limit state below is only
// touched on `workerQueue`.
@property(nonatomic, strong) RTCCallbackLogger *engineErrorLogger;
@property(nonatomic, strong) NSLock *engineErrorLoggerLock;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *engineErrorBuffer;
@property(nonatomic, strong) NSLock *engineErrorBufferLock;
@property(nonatomic, strong) NSDictionary *pendingEngineError;
@property(nonatomic, assign) NSUInteger pendingEngineErrorRepeat;
@property(nonatomic, assign) NSUInteger droppedEngineErrorCount;
@property(nonatomic, assign) BOOL engineErrorFlushScheduled;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *engineErrorEmitTimes;

@end

@implementation WebRTCModule

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

- (void)dealloc {
    [self stopEngineErrorLogger];

    // Dispose E2EE managers. JS is gone, so nothing else can release them. The order
    // relative to the peer connections does not matter for safety.
    for (NSString *handle in _encryptionManagers) {
        RTC_OBJC_TYPE(RTCEncryptionManager) *manager = _encryptionManagers[handle];
        manager.delegate = nil;
        [manager dispose];
    }
    [_encryptionManagers removeAllObjects];
    _encryptionManagers = nil;

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
        _encryptionManagers = [NSMutableDictionary new];

        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, -1);
        _workerQueue = dispatch_queue_create("WebRTCModule.queue", attributes);

        [self startEngineErrorLogger];
    }

    return self;
}

- (void)invalidate {
    [self stopEngineErrorLogger];
    [super invalidate];
}

#pragma mark - Engine error forwarding

/**
 * Forwards ADM (`AudioEngineDevice::`) warning/error log lines to JS. The callback logger is a separate WebRTC log
 * sink with its own severity, so it works while console logging (`loggingSeverity`) stays off.
 */
- (void)startEngineErrorLogger {
    _engineErrorLoggerLock = [NSLock new];
    _engineErrorBuffer = [NSMutableArray new];
    _engineErrorBufferLock = [NSLock new];
    _engineErrorEmitTimes = [NSMutableArray new];

    // The handler runs synchronously on the WebRTC logging thread while WebRTC holds its global log mutex: no
    // RTC_LOG, no WebRTC API calls, no RCTLog, no blocking. It only buffers and hops to the worker queue. It
    // captures the buffer, lock and queue directly (never a strong self) so the module can't be released here.
    NSMutableArray<NSDictionary *> *buffer = _engineErrorBuffer;
    NSLock *bufferLock = _engineErrorBufferLock;
    dispatch_queue_t workerQueue = _workerQueue;
    __weak WebRTCModule *weakSelf = self;

    RTCCallbackLogger *logger = [RTCCallbackLogger new];
    logger.severity = RTCLoggingSeverityWarning;
    [logger startWithMessageAndSeverityHandler:^(NSString *message, RTCLoggingSeverity severity) {
        if (![message containsString:kAudioEngineDeviceLogPrefix]) {
            return;
        }
        NSDictionary *entry = @{
            @"message" : [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
            @"severity" : severity >= RTCLoggingSeverityError ? @"error" : @"warning",
            @"timestamp" : @([NSDate date].timeIntervalSince1970 * 1000.0),
        };

        [bufferLock lock];
        [buffer addObject:entry];
        if (buffer.count > kEngineErrorBufferCapacity) {
            [buffer removeObjectAtIndex:0];
        }
        [bufferLock unlock];

        dispatch_async(workerQueue, ^{
            [weakSelf enqueueEngineError:entry];
        });
    }];

    [_engineErrorLoggerLock lock];
    _engineErrorLogger = logger;
    [_engineErrorLoggerLock unlock];
}

// Idempotent. `stop` runs outside our lock: it takes WebRTC's global log mutex, which the handler already holds.
- (void)stopEngineErrorLogger {
    [_engineErrorLoggerLock lock];
    RTCCallbackLogger *logger = _engineErrorLogger;
    _engineErrorLogger = nil;
    [_engineErrorLoggerLock unlock];

    [logger stop];
}

- (NSArray<NSDictionary *> *)recentEngineErrors {
    [_engineErrorBufferLock lock];
    NSArray<NSDictionary *> *copy = [_engineErrorBuffer copy];
    [_engineErrorBufferLock unlock];
    return copy ?: @[];
}

/**
 * Runs on `workerQueue`. Consecutive identical lines collapse into one pending entry that is emitted (with
 * `repeat: n` when n > 1) as soon as a different line arrives, or by a single flush ~1 s after the pending entry
 * was started. This trades up to ~1 s of latency for simplicity.
 */
- (void)enqueueEngineError:(NSDictionary *)entry {
    if (self.pendingEngineError != nil && [self.pendingEngineError[@"message"] isEqualToString:entry[@"message"]]) {
        self.pendingEngineErrorRepeat += 1;
        return;
    }

    [self flushPendingEngineError];
    self.pendingEngineError = entry;
    self.pendingEngineErrorRepeat = 1;

    if (!self.engineErrorFlushScheduled) {
        self.engineErrorFlushScheduled = YES;
        __weak WebRTCModule *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEngineErrorFlushDelay * NSEC_PER_SEC)),
                       _workerQueue,
                       ^{
                           WebRTCModule *strongSelf = weakSelf;
                           strongSelf.engineErrorFlushScheduled = NO;
                           [strongSelf flushPendingEngineError];
                       });
    }
}

/**
 * Runs on `workerQueue`. Emits the pending entry, rate limited to `kEngineErrorRateLimitCount` events per rolling
 * `kEngineErrorRateLimitWindow`. Suppressed lines are reported as `dropped: n` on the next emitted event.
 */
- (void)flushPendingEngineError {
    NSDictionary *entry = self.pendingEngineError;
    NSUInteger repeat = self.pendingEngineErrorRepeat;
    self.pendingEngineError = nil;
    self.pendingEngineErrorRepeat = 0;
    // Same guard as AudioDeviceModuleObserver; lines stay in the ring buffer either way.
    if (entry == nil || self.bridge == nil) {
        return;
    }

    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    while (self.engineErrorEmitTimes.count > 0 &&
           now - self.engineErrorEmitTimes.firstObject.doubleValue >= kEngineErrorRateLimitWindow) {
        [self.engineErrorEmitTimes removeObjectAtIndex:0];
    }
    if (self.engineErrorEmitTimes.count >= kEngineErrorRateLimitCount) {
        self.droppedEngineErrorCount += repeat;
        return;
    }
    [self.engineErrorEmitTimes addObject:@(now)];

    NSMutableDictionary *body = [entry mutableCopy];
    if (repeat > 1) {
        body[@"repeat"] = @(repeat);
    }
    if (self.droppedEngineErrorCount > 0) {
        body[@"dropped"] = @(self.droppedEngineErrorCount);
        self.droppedEngineErrorCount = 0;
    }

    [self sendEventWithName:kEventAudioDeviceModuleEngineError body:body];
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
 * Disposes the live factory and its dependents in order: PeerConnections → local tracks → local
 * streams → video-effects processor → factory + ADM. Everything is ARC-refcounted, so the factory
 * is freed only when its LAST reference drops — every dependent that strong-refs it (PCs, tracks,
 * streams, and the videoEffectProcessor associated object) must be released first or the factory
 * leaks. No-op unless this is the last reference; returns whether it disposed the factory.
 */
- (BOOL)disposeCurrentFactoryOrdered {
    if (![self.factoryRegistry releaseReference]) {
        return NO;
    }

    for (NSNumber *pcId in [self.peerConnections.allKeys copy]) {
        @try {
            [self peerConnectionClose:pcId];
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
        kEventAudioDeviceModuleAudioProcessingStateUpdated,
        kEventAudioDeviceModuleEngineError,
        kEventEncryptionManagerEvent
    ];
}

@end
