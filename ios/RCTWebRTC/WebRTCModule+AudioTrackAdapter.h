
#import <WebRTC/RTCAudioRenderer.h>
#import <WebRTC/RTCPeerConnection.h>
#import "WebRTCModule.h"

@interface RTCPeerConnection (AudioTrackAdapter)

@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *audioTrackAdapters;

- (void)addAudioTrackAdapter:(RTCAudioTrack *)track;
- (void)removeAudioTrackAdapter:(RTCAudioTrack *)track;

@end
