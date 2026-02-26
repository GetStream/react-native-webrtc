#import "WebRTCModuleOptions.h"

// Import Swift-generated header for ScreenShareAudioMixer
#if __has_include(<stream_react_native_webrtc/stream_react_native_webrtc-Swift.h>)
#import <stream_react_native_webrtc/stream_react_native_webrtc-Swift.h>
#elif __has_include("stream_react_native_webrtc-Swift.h")
#import "stream_react_native_webrtc-Swift.h"
#endif

@implementation WebRTCModuleOptions

#pragma mark - This class is a singleton

+ (instancetype)sharedInstance {
    static WebRTCModuleOptions *sharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });

    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        self.audioDevice = nil;
        self.fieldTrials = nil;
        self.videoEncoderFactory = nil;
        self.videoDecoderFactory = nil;
        self.loggingSeverity = RTCLoggingSeverityNone;
    }

    return self;
}

@end
