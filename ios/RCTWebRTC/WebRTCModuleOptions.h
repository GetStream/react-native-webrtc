#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

@class InAppScreenCapturer;
@class RTCDefaultAudioProcessingModule;

NS_ASSUME_NONNULL_BEGIN

// Forward declare the Swift class — the actual import happens in the .m file.
@class ScreenShareAudioMixer;

@interface WebRTCModuleOptions : NSObject

@property(nonatomic, strong, nullable) id<RTCVideoDecoderFactory> videoDecoderFactory;
@property(nonatomic, strong, nullable) id<RTCVideoEncoderFactory> videoEncoderFactory;
@property(nonatomic, strong, nullable) id<RTCAudioDevice> audioDevice;
@property(nonatomic, strong, nullable) id<RTCAudioProcessingModule> audioProcessingModule;

/// Retained reference to the default audio processing module.
/// Used to dynamically set capturePostProcessingDelegate for screen share audio mixing.
@property(nonatomic, strong, nullable) RTCDefaultAudioProcessingModule *defaultAudioProcessingModule;

@property(nonatomic, strong, nullable) NSDictionary *fieldTrials;
@property(nonatomic, assign) RTCLoggingSeverity loggingSeverity;
@property(nonatomic, assign) BOOL enableMultitaskingCameraAccess;

/// When YES, the next getDisplayMedia() call will use RPScreenRecorder (in-app capture)
/// instead of the broadcast extension. Auto-cleared after use.
@property(nonatomic, assign) BOOL useInAppScreenCapture;

/// When YES, in-app screen capture will route .audioApp buffers to the audio mixer.
@property(nonatomic, assign) BOOL includeScreenShareAudio;

/// The active screen share audio mixer instance. Created by
/// `startScreenShareAudioMixing` and cleared by `stopScreenShareAudioMixing`.
@property(nonatomic, strong, nullable) ScreenShareAudioMixer *screenShareAudioMixer;

/// Weak reference to the current in-app screen capturer, set during
/// `createScreenCaptureVideoTrack` when in-app mode is used.
@property(nonatomic, weak, nullable) InAppScreenCapturer *activeInAppScreenCapturer;

#pragma mark - This class is a singleton

+ (instancetype _Nonnull)sharedInstance;

@end

NS_ASSUME_NONNULL_END
