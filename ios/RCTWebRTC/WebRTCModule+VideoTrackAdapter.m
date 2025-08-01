
#import <Foundation/Foundation.h>
#include <libkern/OSAtomic.h>
#import <objc/runtime.h>
#import <stdatomic.h>

#import <React/RCTBridge.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>

#import <WebRTC/RTCVideoRenderer.h>
#import <WebRTC/RTCVideoTrack.h>

#import "WebRTCModule+RTCPeerConnection.h"
#import "WebRTCModule+VideoTrackAdapter.h"
#import "WebRTCModule.h"

/* Mute detection timer intervals. The initial timeout will be longer to
 * accommodate for source startup.
 */
static const NSTimeInterval INITIAL_MUTE_DELAY = 3;
static const NSTimeInterval MUTE_DELAY = 1.5;

/* Entity responsible for detecting track mute / unmute events. It's implemented
 * as a video renderer, which counts the number of frames, and if it sees them
 * stalled for the default interval it will emit a mute event. If frames keep
 * being received, the track unmute event will be emitted.
 */
@interface TrackMuteDetector : NSObject<RTCVideoRenderer>

@property(copy, nonatomic) NSNumber *peerConnectionId;
@property(copy, nonatomic) NSString *trackId;
@property(weak, nonatomic) WebRTCModule *module;

@end

@implementation TrackMuteDetector {
    BOOL _disposed;
    atomic_ullong _frameCount;
    BOOL _muted;
    dispatch_source_t _timer;
}

- (instancetype)initWith:(NSNumber *)peerConnectionId trackId:(NSString *)trackId webRTCModule:(WebRTCModule *)module {
    self = [super init];
    if (self) {
        self.peerConnectionId = peerConnectionId;
        self.trackId = trackId;
        self.module = module;

        _disposed = NO;
        _frameCount = 0;
        _muted = NO;
        _timer = nil;
    }

    return self;
}

- (void)dispose {
    _disposed = YES;
    if (_timer != nil) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)emitMuteEvent:(BOOL)muted {
    [self.module sendEventWithName:kEventMediaStreamTrackMuteChanged
                              body:@{@"pcId" : self.peerConnectionId, @"trackId" : self.trackId, @"muted" : @(muted)}];
    RCTLog(@"[VideoTrackAdapter] %@ event for pc %@ track %@",
           muted ? @"Mute" : @"Unmute",
           self.peerConnectionId,
           self.trackId);
}

- (void)start {
    if (_disposed) {
        return;
    }

    if (_timer != nil) {
        dispatch_source_cancel(_timer);
    }

    // Create a timer using GCD, since NSTimer requires a runloop to be present
    // on the calling thread.
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());

    // Schedule the timer with a larger initial delay than the interval.
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, INITIAL_MUTE_DELAY * NSEC_PER_SEC),
                              MUTE_DELAY * NSEC_PER_SEC,
                              (1ull * NSEC_PER_SEC) / 10);

    __block unsigned long long lastFrameCount = _frameCount;
    dispatch_source_set_event_handler(_timer, ^() {
        if (self->_disposed) {
            return;
        }

        BOOL isMuted = lastFrameCount == self->_frameCount;
        if (isMuted != self->_muted) {
            self->_muted = isMuted;
            [self emitMuteEvent:isMuted];
        }

        lastFrameCount = self->_frameCount;
    });

    dispatch_resume(_timer);
}

- (void)renderFrame:(nullable RTCVideoFrame *)frame {
    atomic_fetch_add(&_frameCount, 1);
}

- (void)setSize:(CGSize)size {
    // XXX unneeded for our purposes, but part of RTCVideoRenderer.
}

@end

/* Entity responsible for detecting video dimension changes. It's implemented
 * as a video renderer, which monitors the setSize: method to detect when
 * video dimensions change and emits events accordingly.
 */

@implementation VideoDimensionDetector {
    BOOL _disposed;
    CGSize _currentSize;
    BOOL _hasInitialSize;
}

- (instancetype)initWith:(NSNumber *)peerConnectionId trackId:(NSString *)trackId webRTCModule:(WebRTCModule *)module {
    self = [super init];
    if (self) {
        self.peerConnectionId = peerConnectionId;
        self.trackId = trackId;
        self.module = module;

        _disposed = NO;
        _currentSize = CGSizeZero;
        _hasInitialSize = NO;
    }

    return self;
}

- (void)dispose {
    _disposed = YES;
}

- (void)emitDimensionChangeEvent:(CGSize)newSize {
    [self.module sendEventWithName:kEventVideoTrackDimensionChanged
                              body:@{
                                  @"pcId" : self.peerConnectionId,
                                  @"trackId" : self.trackId,
                                  @"width" : @(newSize.width),
                                  @"height" : @(newSize.height)
                              }];
    RCTLog(@"[VideoDimensionDetector] Dimension change event for pc %@ track %@: %fx%f",
           self.peerConnectionId,
           self.trackId,
           newSize.width,
           newSize.height);
}

- (void)renderFrame:(nullable RTCVideoFrame *)frame {
    // We don't need to do anything with frames for dimension detection
    // The setSize: method will be called automatically when dimensions change
}

- (void)setSize:(CGSize)size {
    if (_disposed) {
        return;
    }

    // Check if this is a meaningful size change
    if (!_hasInitialSize) {
        _currentSize = size;
        _hasInitialSize = YES;
        [self emitDimensionChangeEvent:size];
    } else if (!CGSizeEqualToSize(_currentSize, size)) {
        _currentSize = size;
        [self emitDimensionChangeEvent:size];
    }
}

@end

@implementation RTCPeerConnection (VideoTrackAdapter)

- (NSMutableDictionary<NSString *, id> *)videoTrackAdapters {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setVideoTrackAdapters:(NSMutableDictionary<NSString *, id> *)videoTrackAdapters {
    objc_setAssociatedObject(
        self, @selector(videoTrackAdapters), videoTrackAdapters, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSMutableDictionary<NSString *, id> *)videoDimensionDetectors {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setVideoDimensionDetectors:(NSMutableDictionary<NSString *, id> *)videoDimensionDetectors {
    objc_setAssociatedObject(
        self, @selector(videoDimensionDetectors), videoDimensionDetectors, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)addVideoTrackAdapter:(RTCVideoTrack *)track {
    NSString *trackId = track.trackId;
    if ([self.videoTrackAdapters objectForKey:trackId] != nil) {
        RCTLogWarn(@"[VideoTrackAdapter] Adapter already exists for track %@", trackId);
        return;
    }

    TrackMuteDetector *muteDetector = [[TrackMuteDetector alloc] initWith:self.reactTag
                                                                  trackId:trackId
                                                             webRTCModule:self.webRTCModule];
    [self.videoTrackAdapters setObject:muteDetector forKey:trackId];
    [track addRenderer:muteDetector];
    [muteDetector start];

    RCTLogTrace(@"[VideoTrackAdapter] Adapter created for track %@", trackId);
}

- (void)removeVideoTrackAdapter:(RTCVideoTrack *)track {
    NSString *trackId = track.trackId;
    TrackMuteDetector *muteDetector = [self.videoTrackAdapters objectForKey:trackId];
    if (muteDetector == nil) {
        RCTLogWarn(@"[VideoTrackAdapter] Adapter doesn't exist for track %@", trackId);
        return;
    }

    [track removeRenderer:muteDetector];
    [muteDetector dispose];
    [self.videoTrackAdapters removeObjectForKey:trackId];
    RCTLogTrace(@"[VideoTrackAdapter] Adapter removed for track %@", trackId);
}

- (void)addVideoDimensionDetector:(RTCVideoTrack *)track {
    NSString *trackId = track.trackId;
    if ([self.videoDimensionDetectors objectForKey:trackId] != nil) {
        RCTLogWarn(@"[VideoDimensionDetector] Detector already exists for track %@", trackId);
        return;
    }

    VideoDimensionDetector *dimensionDetector = [[VideoDimensionDetector alloc] initWith:self.reactTag
                                                                                  trackId:trackId
                                                                             webRTCModule:self.webRTCModule];
    [self.videoDimensionDetectors setObject:dimensionDetector forKey:trackId];
    [track addRenderer:dimensionDetector];

    RCTLogTrace(@"[VideoDimensionDetector] Detector created for track %@", trackId);
}

- (void)removeVideoDimensionDetector:(RTCVideoTrack *)track {
    NSString *trackId = track.trackId;
    VideoDimensionDetector *dimensionDetector = [self.videoDimensionDetectors objectForKey:trackId];
    if (dimensionDetector == nil) {
        RCTLogWarn(@"[VideoDimensionDetector] Detector doesn't exist for track %@", trackId);
        return;
    }

    [track removeRenderer:dimensionDetector];
    [dimensionDetector dispose];
    [self.videoDimensionDetectors removeObjectForKey:trackId];
    RCTLogTrace(@"[VideoDimensionDetector] Detector removed for track %@", trackId);
}

@end
