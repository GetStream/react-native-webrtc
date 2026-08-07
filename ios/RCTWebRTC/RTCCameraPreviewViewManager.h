#import <Foundation/Foundation.h>
#import <React/RCTViewManager.h>

@class CaptureController;
@class RTCVideoSource;

/**
 * Implemented by the lobby camera preview so its running capturer can be adopted by a WebRTC track
 * at join: the capturer's delegate is re-pointed at the track's video source, so the camera keeps
 * running and is never stopped or reopened.
 */
@protocol RTCCameraPreviewControl <NSObject>
/**
 * Re-points the running preview capturer's delegate to {@code source} and yields the capture
 * controller so the WebRTC track can take ownership — WITHOUT stopping the camera. Returns nil if
 * there is no running preview capturer to adopt.
 */
- (CaptureController *)adoptCaptureForSource:(RTCVideoSource *)source;
@end

@interface RTCCameraPreviewViewManager : RCTViewManager

@end
