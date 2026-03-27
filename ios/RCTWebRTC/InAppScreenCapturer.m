#if TARGET_OS_IOS

#import <ReplayKit/ReplayKit.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrameBuffer.h>

#import "InAppScreenCapturer.h"

@implementation InAppScreenCapturer {
    BOOL _capturing;
    BOOL _shouldResumeOnForeground;
    BOOL _observingAppState;
}

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate {
    self = [super initWithDelegate:delegate];
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
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            NSLog(@"[InAppScreenCapturer] startCapture failed: %@", error.localizedDescription);
            strongSelf->_capturing = NO;
            [strongSelf.eventsDelegate capturerDidEnd:strongSelf];
            return;
        }

        // Capture started successfully — register for app lifecycle events.
        // Done here (not in startCapture) so the RPScreenRecorder permission
        // dialog doesn't trigger appWillResignActive before capture begins.
        [strongSelf registerAppStateObservers];
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

    [self unregisterAppStateObservers];

    [[RPScreenRecorder sharedRecorder] stopCaptureWithHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[InAppScreenCapturer] stopCapture error: %@", error.localizedDescription);
        }
    }];
}

#pragma mark - App Lifecycle

- (void)registerAppStateObservers {
    if (_observingAppState) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_observingAppState || !self->_capturing) return;
        self->_observingAppState = YES;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appDidBecomeActive)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appWillResignActive)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
    });
}

- (void)unregisterAppStateObservers {
    if (!_observingAppState) return;
    _observingAppState = NO;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidBecomeActiveNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillResignActiveNotification
                                                  object:nil];
}

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
        [self startRPScreenRecorder];
    }
}

- (void)dealloc {
    [self unregisterAppStateObservers];
    if (_capturing) {
        _capturing = NO;
        self.audioBufferHandler = nil;
        [[RPScreenRecorder sharedRecorder] stopCaptureWithHandler:nil];
    }
}

@end

#endif
