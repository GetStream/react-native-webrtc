#if TARGET_OS_IOS

#import <ReplayKit/ReplayKit.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrameBuffer.h>

#import "InAppScreenCapturer.h"

@implementation InAppScreenCapturer {
    BOOL _capturing;
    BOOL _shouldResumeOnForeground;
}

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate {
    self = [super initWithDelegate:delegate];
    if (self) {
        // [[NSNotificationCenter defaultCenter] addObserver:self
        //                                          selector:@selector(appDidBecomeActive)
        //                                              name:UIApplicationDidBecomeActiveNotification
        //                                            object:nil];
        // [[NSNotificationCenter defaultCenter] addObserver:self
        //                                          selector:@selector(appWillResignActive)
        //                                              name:UIApplicationWillResignActiveNotification
        //                                            object:nil];
    }
    return self;
}

- (void)startCapture {
    if (_capturing) {
        return;
    }
    _capturing = YES;

    [self startRPScreenRecorder];
}

- (void)startRPScreenRecorder {
    RPScreenRecorder *recorder = [RPScreenRecorder sharedRecorder];
    recorder.microphoneEnabled = NO; // WebRTC handles mic input

    __weak __typeof__(self) weakSelf = self;
    [recorder startCaptureWithHandler:^(CMSampleBufferRef _Nonnull sampleBuffer,
                                        RPSampleBufferType bufferType,
                                        NSError * _Nullable error) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || error || !strongSelf->_capturing) {
            return;
        }

        switch (bufferType) {
            case RPSampleBufferTypeVideo:
                [strongSelf processVideoSampleBuffer:sampleBuffer];
                break;
            case RPSampleBufferTypeAudioApp:
                if (strongSelf.audioBufferHandler) {
                    strongSelf.audioBufferHandler(sampleBuffer);
                }
                break;
            case RPSampleBufferTypeAudioMic:
                // Ignored — WebRTC handles mic capture via AudioDeviceModule
                break;
        }
    } completionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[InAppScreenCapturer] startCapture failed: %@", error.localizedDescription);
            [weakSelf.eventsDelegate capturerDidEnd:weakSelf];
        }
    }];
}

- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }

    int64_t timeStampNs = (int64_t)(CMTimeGetSeconds(
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * NSEC_PER_SEC);

    RTCCVPixelBuffer *rtcPixelBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    RTCVideoFrame *videoFrame = [[RTCVideoFrame alloc] initWithBuffer:rtcPixelBuffer
                                                              rotation:RTCVideoRotation_0
                                                           timeStampNs:timeStampNs];

    [self.delegate capturer:self didCaptureVideoFrame:videoFrame];
}

- (void)stopCapture {
    if (!_capturing) {
        return;
    }
    _capturing = NO;
    _shouldResumeOnForeground = NO;
    self.audioBufferHandler = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [[RPScreenRecorder sharedRecorder] stopCaptureWithHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[InAppScreenCapturer] stopCapture error: %@", error.localizedDescription);
        }
    }];
}

#pragma mark - App Lifecycle

- (void)appWillResignActive {
    if (_capturing) {
        _shouldResumeOnForeground = YES;
        // Stop the RPScreenRecorder session — iOS suspends it in background anyway
        [[RPScreenRecorder sharedRecorder] stopCaptureWithHandler:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"[InAppScreenCapturer] background stop error: %@", error.localizedDescription);
            }
        }];
    }
}

- (void)appDidBecomeActive {
    if (_shouldResumeOnForeground && _capturing) {
        _shouldResumeOnForeground = NO;
        NSLog(@"[InAppScreenCapturer] Resuming capture after returning to foreground");
        [self startRPScreenRecorder];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_capturing) {
        _capturing = NO;
        self.audioBufferHandler = nil;
        [[RPScreenRecorder sharedRecorder] stopCaptureWithHandler:nil];
    }
}

@end

#endif
