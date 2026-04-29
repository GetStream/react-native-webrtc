#import <AVFoundation/AVFoundation.h>
#import <WebRTC/RTCVideoCapturer.h>
#import "CapturerEventsDelegate.h"

NS_ASSUME_NONNULL_BEGIN

@interface InAppScreenCapturer : RTCVideoCapturer

@property(nonatomic, weak) id<CapturerEventsDelegate> eventsDelegate;

/// Callback invoked for each .audioApp CMSampleBuffer from RPScreenRecorder.
/// Set this before calling startCapture if audio mixing is desired.
@property(nonatomic, copy, nullable) void (^audioBufferHandler)(CMSampleBufferRef);

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate;
- (void)startCapture;
- (void)stopCapture;

@end

NS_ASSUME_NONNULL_END
