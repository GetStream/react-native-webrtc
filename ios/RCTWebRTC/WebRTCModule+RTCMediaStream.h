#import "CaptureController.h"
#import "VideoEffectProcessor.h"
#import "WebRTCModule.h"

@interface WebRTCModule (RTCMediaStream)

@property(nonatomic, strong) VideoEffectProcessor *videoEffectProcessor;

- (RTCVideoTrack *)createVideoTrackWithCaptureController:
    (CaptureController * (^)(RTCVideoSource *))captureControllerCreator;
- (NSArray *)createMediaStream:(NSArray<RTCMediaStreamTrack *> *)tracks;

- (void)addLocalVideoTrackDimensionDetection:(RTCVideoTrack *)videoTrack;
- (void)removeLocalVideoTrackDimensionDetection:(RTCVideoTrack *)videoTrack;

- (RTCMediaStreamTrack *)trackForId:(nonnull NSString *)trackId pcId:(nonnull NSNumber *)pcId;
@end