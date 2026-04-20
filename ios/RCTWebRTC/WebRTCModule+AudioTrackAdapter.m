
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdatomic.h>

#import <React/RCTBridge.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>

#import <WebRTC/RTCAudioRenderer.h>
#import <WebRTC/RTCAudioTrack.h>

#import "WebRTCModule+AudioTrackAdapter.h"
#import "WebRTCModule+RTCPeerConnection.h"
#import "WebRTCModule.h"

/* Fires the W3C 'unmute' event on a remote audio track when the first
 * decoded PCM buffer arrives via RTCAudioRenderer.
 *
 * IMPORTANT — only the initial muted → unmuted transition is detectable.
 * Subsequent mute events (network stall mid-call) cannot be detected
 * from the renderer: the iOS audio render path and WebRTC's NetEq
 * synthesize silence / PLC frames whenever RTP stops, so
 * renderPCMBuffer: keeps firing at a steady rate regardless of network
 * state. For "remote participant muted their mic" UI, use the
 * out-of-band participant state from your signaling layer — that is the
 * correct source of truth, not this adapter.
 */
@interface FirstBufferUnmuteRenderer : NSObject<RTCAudioRenderer>

@property(copy, nonatomic) NSNumber *peerConnectionId;
@property(copy, nonatomic) NSString *trackId;
@property(weak, nonatomic) WebRTCModule *module;

- (instancetype)initWith:(NSNumber *)peerConnectionId
                 trackId:(NSString *)trackId
            webRTCModule:(WebRTCModule *)module;

@end

@implementation FirstBufferUnmuteRenderer {
    atomic_flag _fired;
}

- (instancetype)initWith:(NSNumber *)peerConnectionId
                 trackId:(NSString *)trackId
            webRTCModule:(WebRTCModule *)module {
    self = [super init];
    if (self) {
        self.peerConnectionId = peerConnectionId;
        self.trackId = trackId;
        self.module = module;
        atomic_flag_clear(&_fired);
    }
    return self;
}

- (void)renderPCMBuffer:(AVAudioPCMBuffer *)pcmBuffer {
    if (atomic_flag_test_and_set(&_fired)) {
        return;
    }
    [self.module sendEventWithName:kEventMediaStreamTrackMuteChanged
                              body:@{
                                  @"pcId" : self.peerConnectionId,
                                  @"trackId" : self.trackId,
                                  @"muted" : @NO
                              }];
    RCTLog(@"[AudioTrackAdapter] Unmute event for pc %@ track %@", self.peerConnectionId, self.trackId);
}

@end

@implementation RTCPeerConnection (AudioTrackAdapter)

- (NSMutableDictionary<NSString *, id> *)audioTrackAdapters {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setAudioTrackAdapters:(NSMutableDictionary<NSString *, id> *)audioTrackAdapters {
    objc_setAssociatedObject(
        self, @selector(audioTrackAdapters), audioTrackAdapters, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)addAudioTrackAdapter:(RTCAudioTrack *)track {
    NSString *trackId = track.trackId;
    if ([self.audioTrackAdapters objectForKey:trackId] != nil) {
        RCTLogWarn(@"[AudioTrackAdapter] Adapter already exists for track %@", trackId);
        return;
    }

    FirstBufferUnmuteRenderer *renderer = [[FirstBufferUnmuteRenderer alloc] initWith:self.reactTag
                                                                              trackId:trackId
                                                                         webRTCModule:self.webRTCModule];
    [self.audioTrackAdapters setObject:renderer forKey:trackId];
    [track addRenderer:renderer];

    RCTLogTrace(@"[AudioTrackAdapter] Adapter created for track %@", trackId);
}

- (void)removeAudioTrackAdapter:(RTCAudioTrack *)track {
    NSString *trackId = track.trackId;
    FirstBufferUnmuteRenderer *renderer = [self.audioTrackAdapters objectForKey:trackId];
    if (renderer == nil) {
        RCTLogWarn(@"[AudioTrackAdapter] Adapter doesn't exist for track %@", trackId);
        return;
    }

    [track removeRenderer:renderer];
    [self.audioTrackAdapters removeObjectForKey:trackId];
    RCTLogTrace(@"[AudioTrackAdapter] Adapter removed for track %@", trackId);
}

@end
