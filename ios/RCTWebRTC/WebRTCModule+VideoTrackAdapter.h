
#import <WebRTC/RTCPeerConnection.h>
#import "WebRTCModule.h"

@interface RTCPeerConnection (VideoTrackAdapter)

@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *videoTrackAdapters;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *videoDimensionDetectors;

- (void)addVideoTrackAdapter:(RTCVideoTrack *)track;
- (void)removeVideoTrackAdapter:(RTCVideoTrack *)track;

- (void)addVideoDimensionDetector:(RTCVideoTrack *)track;
- (void)removeVideoDimensionDetector:(RTCVideoTrack *)track;

@end
