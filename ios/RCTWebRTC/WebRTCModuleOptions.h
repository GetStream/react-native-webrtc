#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

@class InAppScreenCapturer;
NS_ASSUME_NONNULL_BEGIN

@interface WebRTCModuleOptions : NSObject

@property(nonatomic, strong, nullable) id<RTCVideoDecoderFactory> videoDecoderFactory;
@property(nonatomic, strong, nullable) id<RTCVideoEncoderFactory> videoEncoderFactory;
@property(nonatomic, strong, nullable) id<RTCAudioDevice> audioDevice;
@property(nonatomic, strong, nullable) id<RTCAudioProcessingModule> audioProcessingModule;

@property(nonatomic, strong, nullable) NSDictionary *fieldTrials;
@property(nonatomic, assign) RTCLoggingSeverity loggingSeverity;
@property(nonatomic, assign) BOOL enableMultitaskingCameraAccess;

/// When YES, the next getDisplayMedia() call will use RPScreenRecorder (in-app capture)
/// instead of the broadcast extension. Auto-cleared after use.
@property(nonatomic, assign) BOOL useInAppScreenCapture;

/// When YES, in-app screen capture will route .audioApp buffers to the audio mixer.
@property(nonatomic, assign) BOOL includeScreenShareAudio;

/// Weak reference to the current in-app screen capturer, set during
/// `createScreenCaptureVideoTrack` when in-app mode is used.
@property(nonatomic, weak, nullable) InAppScreenCapturer *activeInAppScreenCapturer;

@property(nonatomic, assign) double defaultTrackVolume;

#pragma mark - This class is a singleton

+ (instancetype _Nonnull)sharedInstance;

@end

NS_ASSUME_NONNULL_END
