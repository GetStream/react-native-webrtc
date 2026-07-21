#if !TARGET_OS_TV

#import <AVFoundation/AVFoundation.h>

#import <React/RCTLog.h>
#import <React/RCTView.h>

#import <WebRTC/RTCCameraVideoCapturer.h>
#import <WebRTC/RTCVideoCapturer.h>
#import <WebRTC/RTCVideoFrame.h>
#if TARGET_OS_OSX
#import <WebRTC/RTCMTLNSVideoView.h>
#else
#import <WebRTC/RTCVideoRenderingView.h>
#endif

#import "RTCCameraPreviewViewManager.h"
#import "VideoCaptureController.h"
#import "WebRTCModule.h"

typedef NS_ENUM(NSInteger, RTCCameraPreviewObjectFit) {
    /**
     * The contain value defined by https://www.w3.org/TR/css3-images/#object-fit:
     *
     * The replaced content is sized to maintain its aspect ratio while fitting
     * within the element's content box.
     */
    RTCCameraPreviewObjectFitContain = 1,
    /**
     * The cover value defined by https://www.w3.org/TR/css3-images/#object-fit:
     *
     * The replaced content is sized to maintain its aspect ratio while filling
     * the element's entire content box.
     */
    RTCCameraPreviewObjectFitCover
};

/**
 * Unlike RTCVideoView, this view does NOT render a WebRTC track. It drives an
 * RTCCameraVideoCapturer directly (via VideoCaptureController for device/format/fps
 * selection) and forwards the captured frames straight to its renderer — without ever
 * creating an RTCVideoSource, an RTCVideoTrack, or touching the RTCPeerConnectionFactory.
 *
 * It is intended for the call lobby, before any peer connection factory exists. At join the running
 * capturer is reused by the published WebRTC track: its delegate is re-pointed at the track's video
 * source while the camera keeps running, so the preview and the published track share one session.
 */
@interface StreamCameraPreviewView : RCTView <RTCVideoCapturerDelegate, RTCCameraPreviewControl>

@property(nonatomic) BOOL mirror;

@property(nonatomic) RTCCameraPreviewObjectFit objectFit;

#if TARGET_OS_OSX
@property(nonatomic, readonly) RTCMTLNSVideoView *videoView;
#else
@property(nonatomic, readonly) RTCVideoRenderingView *videoView;
#endif

/**
 * Reference to the main WebRTC RN module.
 */
@property(nonatomic, weak) WebRTCModule *module;

@property(nonatomic) BOOL isActive;

@property(nonatomic, copy) NSString *facing;
@property(nonatomic, copy) NSString *deviceId;

@property(nonatomic) NSInteger captureWidth;
@property(nonatomic) NSInteger captureHeight;

@end

@implementation StreamCameraPreviewView {
    VideoCaptureController *_captureController;
    BOOL _capturing;
    // Once the camera has been handed off to the WebRTC capturer at join, never re-acquire it
    // (a stray prop transaction must not restart capture and contend with the published track).
    BOOL _handedOff;
    // Serial queue for the blocking capture start/stop calls (VideoCaptureController waits on a
    // semaphore for the AVCaptureSession). Must not run on the main thread, or the UI blocks while
    // the camera session starts/stops.
    dispatch_queue_t _captureQueue;
}

@synthesize videoView = _videoView;

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _facing = @"front";
        _mirror = YES;
        _objectFit = RTCCameraPreviewObjectFitCover;
        _captureWidth = 1280;
        _captureHeight = 720;
        _capturing = NO;
        _captureQueue = dispatch_queue_create("io.getstream.camerapreview", DISPATCH_QUEUE_SERIAL);

#if TARGET_OS_OSX
        RTCMTLNSVideoView *subview = [[RTCMTLNSVideoView alloc] initWithFrame:CGRectZero];
        subview.wantsLayer = true;
        _videoView = subview;
#else
        RTCVideoRenderingView *subview = [[RTCVideoRenderingView alloc] initWithFrame:CGRectZero];
        subview.renderingBackend = RTCVideoRenderingBackendSharedMetal;
        _videoView = subview;
#endif
        [self addSubview:self.videoView];

        // Apply the initial visual state directly: the property setters short-circuit when the
        // incoming value equals the current one, so they would no-op for these defaults.
        self.videoView.transform = _mirror ? CGAffineTransformMakeScale(-1.0, 1.0) : CGAffineTransformIdentity;
#if !TARGET_OS_OSX
        if (_objectFit == RTCCameraPreviewObjectFitCover) {
            self.videoView.videoContentMode = UIViewContentModeScaleAspectFill;
        } else {
            self.videoView.videoContentMode = UIViewContentModeScaleAspectFit;
        }
#endif
    }

    return self;
}

- (void)dealloc {
    [self stopCapture];
}

#if TARGET_OS_OSX
- (void)layout {
    [super layout];
    self.videoView.frame = self.bounds;
}
#else
- (void)layoutSubviews {
    [super layoutSubviews];
    // Size + position via bounds/center instead of `frame`: setting `frame` while a non-identity
    // `transform` (the mirror) is applied is undefined per UIKit and can clobber the mirroring.
    self.videoView.bounds = CGRectMake(0, 0, CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
    self.videoView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
}
#endif

- (void)setMirror:(BOOL)mirror {
    if (_mirror != mirror) {
        _mirror = mirror;

        self.videoView.transform = mirror ? CGAffineTransformMakeScale(-1.0, 1.0) : CGAffineTransformIdentity;
    }
}

- (void)setObjectFit:(RTCCameraPreviewObjectFit)fit {
    if (_objectFit != fit) {
        _objectFit = fit;

#if !TARGET_OS_OSX
        if (fit == RTCCameraPreviewObjectFitCover) {
            self.videoView.videoContentMode = UIViewContentModeScaleAspectFill;
        } else {
            self.videoView.videoContentMode = UIViewContentModeScaleAspectFit;
        }
#endif
    }
}

- (NSDictionary *)currentConstraints {
    NSMutableDictionary *constraints = [@{
        @"width" : @(self.captureWidth),
        @"height" : @(self.captureHeight),
        @"frameRate" : @30,
        @"facingMode" : [@"back" isEqualToString:self.facing] ? @"environment" : @"user"
    } mutableCopy];
    
    if (self.deviceId.length > 0) {
        constraints[@"deviceId"] = self.deviceId;
    }
    return constraints;
}

/**
 * Called by React Native once per prop transaction, after all props have been set.
 */
- (void)didSetProps:(NSArray<NSString *> *)changedProps {
    [self commitProps];
}

- (void)commitProps {
    if (_handedOff) {
        // Camera already handed to the WebRTC capturer; do not re-acquire.
        return;
    }

    NSDictionary *constraints = [self currentConstraints];

    if (self.isActive && !_capturing) {
        // Mark intent synchronously so a follow-up transaction doesn't double-start; do the
        // blocking create + startCapture off the main thread.
        _capturing = YES;
        self.module.activeCameraPreview = self;
        dispatch_async(_captureQueue, ^{
            if (self->_handedOff || !self->_capturing) {
                return;
            }
            if (!self->_captureController) {
                RTCCameraVideoCapturer *capturer = [[RTCCameraVideoCapturer alloc] initWithDelegate:self];
                self->_captureController = [[VideoCaptureController alloc] initWithCapturer:capturer
                                                                            andConstraints:constraints];
            } else {
                [self->_captureController applyConstraints:constraints error:nil];
            }
            [self->_captureController startCapture];
        });
    } else if (!self.isActive && _capturing) {
        _capturing = NO;

        [self clearActivePreview];

        dispatch_async(_captureQueue, ^{
            [self->_captureController stopCapture];
        });
    } else if (self.isActive && _capturing) {
        dispatch_async(_captureQueue, ^{
            [self->_captureController applyConstraints:constraints error:nil];
        });
    }
}

/**
 * Releases the camera. The (potentially slow) session teardown runs off the main thread so it never
 * blocks the UI. Used by dealloc and the camera-disable path; the join hand-off does NOT stop the
 * camera — it adopts the running capturer (see {@link adoptCaptureForSource:}).
 */
- (void)stopCapture {
    _capturing = NO;

    [self clearActivePreview];
    
    VideoCaptureController *controller = _captureController;
    _captureController = nil;
    if (!controller) {
        return;
    }
    dispatch_async(_captureQueue, ^{
        [controller stopCapture];
    });
}

- (void)clearActivePreview {
    if (self.module.activeCameraPreview == self) {
        self.module.activeCameraPreview = nil;
    }
}

#pragma mark - RTCCameraPreviewControl

- (CaptureController *)adoptCaptureForSource:(RTCVideoSource *)source {
    // Re-point the running capturer's delegate from this preview to the track's video source and
    // yield the controller. The camera is not stopped or restarted; frames flow into the track.
    _handedOff = YES;
    [self clearActivePreview];

    __block VideoCaptureController *controller = nil;
    // Serialize against any in-flight start on the capture queue, then take ownership atomically.
    dispatch_sync(_captureQueue, ^{
        controller = self->_captureController;
        // Re-point the running capturer's delegate to the track's source.
        controller.capturer.delegate = source;
        // Release our reference without stopping; the track now owns the capturer (via the
        // controller it retains) and the capturer keeps running.
        self->_captureController = nil;
    });
    return controller;
}

#pragma mark - RTCVideoCapturerDelegate

- (void)capturer:(RTCVideoCapturer *)capturer didCaptureVideoFrame:(RTCVideoFrame *)frame {
    // static int frameCount = 0;
    // if (frameCount++ % 60 == 0) {
    //     RCTLogInfo(@"[CameraPreview] frame %d -> renderer %dx%d", frameCount, (int)frame.width, (int)frame.height);
    // }
    [self.videoView renderFrame:frame];
}

@end

@implementation RTCCameraPreviewViewManager

RCT_EXPORT_MODULE()

- (RCTView *)view {
    StreamCameraPreviewView *v = [[StreamCameraPreviewView alloc] init];
    v.module = [self.bridge moduleForName:@"WebRTCModule"];
    v.clipsToBounds = YES;
    return v;
}

- (dispatch_queue_t)methodQueue {
    return dispatch_get_main_queue();
}

#pragma mark - View properties

RCT_EXPORT_VIEW_PROPERTY(mirror, BOOL)
RCT_EXPORT_VIEW_PROPERTY(facing, NSString *)
RCT_EXPORT_VIEW_PROPERTY(deviceId, NSString *)
RCT_EXPORT_VIEW_PROPERTY(isActive, BOOL)
RCT_EXPORT_VIEW_PROPERTY(captureWidth, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(captureHeight, NSInteger)

RCT_CUSTOM_VIEW_PROPERTY(objectFit, NSString *, StreamCameraPreviewView) {
    NSString *fitStr = json;
    view.objectFit = (fitStr && [fitStr isEqualToString:@"contain"]) ? RTCCameraPreviewObjectFitContain
                                                                      : RTCCameraPreviewObjectFitCover;
}

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

@end

#endif
