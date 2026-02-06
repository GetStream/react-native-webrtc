#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

#import <React/RCTBridge.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>

#import "AudioDeviceModuleObserver.h"
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

    _peerConnectionFactory = nil;
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

        // Initialize field trials.
        if (fieldTrials == nil) {
            // Fix for dual-sim connectivity:
            // https://bugs.chromium.org/p/webrtc/issues/detail?id=10966
            fieldTrials = @{kRTCFieldTrialUseNWPathMonitor : kRTCFieldTrialEnabledValue};
        }
        RTCInitFieldTrialDictionary(fieldTrials);

        // Initialize logging.
        RTCSetMinDebugLogLevel(loggingSeverity);

        if (encoderFactory == nil) {
            RTCDefaultVideoEncoderFactory *videoEncoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
            RTCVideoEncoderFactorySimulcast *simulcastVideoEncoderFactory = [[RTCVideoEncoderFactorySimulcast alloc] initWithPrimary:videoEncoderFactory fallback:videoEncoderFactory];
            encoderFactory = simulcastVideoEncoderFactory;
        }
        if (decoderFactory == nil) {
            decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        }
        _encoderFactory = encoderFactory;
        _decoderFactory = decoderFactory;

        RCTLogInfo(@"Using video encoder factory: %@", NSStringFromClass([encoderFactory class]));
        RCTLogInfo(@"Using video decoder factory: %@", NSStringFromClass([decoderFactory class]));

        if (audioProcessingModule != nil) {
            if (audioDevice != nil) {
                NSLog(@"Both audioProcessingModule and audioDevice are provided, but only one can be used. Ignoring audioDevice.");
            }
            RCTLogInfo(@"Using audio processing module: %@", NSStringFromClass([audioProcessingModule class]));
            _peerConnectionFactory =
                [[RTCPeerConnectionFactory alloc] initWithAudioDeviceModuleType:RTCAudioDeviceModuleTypeAudioEngine
                                                          bypassVoiceProcessing:NO
                                                                 encoderFactory:encoderFactory
                                                                 decoderFactory:decoderFactory
                                                          audioProcessingModule:audioProcessingModule];
        } else if (audioDevice != nil) {
            RCTLogInfo(@"Using custom audio device: %@", NSStringFromClass([audioDevice class]));
            _peerConnectionFactory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                                               decoderFactory:decoderFactory
                                                                                  audioDevice:audioDevice];
        } else {
            _peerConnectionFactory =
                [[RTCPeerConnectionFactory alloc] initWithAudioDeviceModuleType:RTCAudioDeviceModuleTypeAudioEngine
                                                          bypassVoiceProcessing:NO
                                                                 encoderFactory:encoderFactory
                                                                 decoderFactory:decoderFactory
                                                          audioProcessingModule:nil];
        }
        
        _rtcAudioDeviceModuleObserver = [[AudioDeviceModuleObserver alloc] initWithWebRTCModule:self];
        _audioDeviceModule = [[AudioDeviceModule alloc] initWithSource:_peerConnectionFactory.audioDeviceModule
                                                      delegateObserver:_rtcAudioDeviceModuleObserver];

        _peerConnections = [NSMutableDictionary new];
        _localStreams = [NSMutableDictionary new];
        _localTracks = [NSMutableDictionary new];

        _frameCryptors = [NSMutableDictionary new];
        _keyProviders = [NSMutableDictionary new];
        _dataPacketCryptors = [NSMutableDictionary new];

        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, -1);
        _workerQueue = dispatch_queue_create("WebRTCModule.queue", attributes);
    }

    return self;
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

RCT_EXPORT_MODULE();

- (dispatch_queue_t)methodQueue {
    return _workerQueue;
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
        kEventFrameCryptionStateChanged,
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
