#if TARGET_OS_IOS

#import "InAppScreenCaptureController.h"
#import "InAppScreenCapturer.h"

@interface InAppScreenCaptureController ()<CapturerEventsDelegate>
@end

@implementation InAppScreenCaptureController

- (instancetype)initWithCapturer:(nonnull InAppScreenCapturer *)capturer {
    self = [super init];
    if (self) {
        _capturer = capturer;
        _capturer.eventsDelegate = self;
        self.deviceId = @"in-app-screen-capture";
    }
    return self;
}

- (void)dealloc {
    [self.capturer stopCapture];
}

- (void)startCapture {
    [self.capturer startCapture];
}

- (void)stopCapture {
    [self.capturer stopCapture];
}

- (NSDictionary *)getSettings {
    return @{@"deviceId" : self.deviceId ?: @"in-app-screen-capture", @"groupId" : @"", @"frameRate" : @(30)};
}

#pragma mark - CapturerEventsDelegate

- (void)capturerDidEnd:(RTCVideoCapturer *)capturer {
    [self.eventsDelegate capturerDidEnd:capturer];
}

@end

#endif
