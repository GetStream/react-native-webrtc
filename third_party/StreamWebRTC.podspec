Pod::Spec.new do |s|
  s.name             = 'StreamWebRTC'
  s.version          = '148.0.0'
  s.summary          = 'Stream WebRTC 148.0.0 — locally-built RELEASE binary vendored in-repo'
  s.description      = <<-DESC
    Interim podspec vendoring a locally-built RELEASE (DCHECKs OFF) 148.0.0
    WebRTC.xcframework committed under third_party/ (dSYMs stripped). Built from
    the GetStream/webrtc source with `stream_enable_rendering_backend=true`.
    Replaces the DCHECK-enabled GitHub release zip (which aborted on call join at
    audio_rtp_receiver.cc:136) until 148.0.0 is published to CocoaPods trunk.
    Consume from a Podfile with:
      pod 'StreamWebRTC', :path => '../node_modules/stream-react-native-webrtc/third_party'
  DESC
  s.homepage         = 'https://github.com/GetStream/webrtc'
  s.license          = { :type => 'BSD' }
  s.author           = 'Stream.io Inc.'
  s.platform         = :ios, '13.0'
  s.source           = { :git => 'https://github.com/GetStream/webrtc.git', :tag => '148.0.0' }
  s.vendored_frameworks = 'WebRTC.xcframework'
end
