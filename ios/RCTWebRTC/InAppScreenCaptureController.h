#import <Foundation/Foundation.h>
#import "CaptureController.h"
#import "CapturerEventsDelegate.h"

NS_ASSUME_NONNULL_BEGIN

@class InAppScreenCapturer;

@interface InAppScreenCaptureController : CaptureController

- (instancetype)initWithCapturer:(nonnull InAppScreenCapturer *)capturer;

/// The underlying RPScreenRecorder-based capturer.
@property(nonatomic, strong, readonly) InAppScreenCapturer *capturer;

@end

NS_ASSUME_NONNULL_END
