#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

#import <React/RCTBridge.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>

#import "AudioDeviceModuleObserver.h"
#import "RTCCameraPreviewViewManager.h"
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

        if (audioProcessingModule != nil && audioDevice != nil) {
            NSLog(@"Both audioProcessingModule and audioDevice are provided, but only one can be used. Ignoring "
                  @"audioDevice.");
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
    resolve(@([self.factoryRegistry disposeCurrent]));
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
