Pod::Spec.new do |s|
  s.name             = 'StreamWebRTC'
  s.version          = '148.0.0'
  s.summary          = 'Stream WebRTC pre-release binary (148.0.0)'
  s.description      = <<-DESC
    Interim podspec pointing StreamWebRTC at the 148.0.0 pre-release xcframework
    published on GitHub releases, used until 148.0.0 is published to CocoaPods trunk.
  DESC
  s.homepage         = 'https://github.com/GetStream/webrtc'
  s.license          = { :type => 'BSD' }
  s.author           = 'Stream.io Inc.'
  s.platform         = :ios, '13.0'
  s.source           = { :http => 'https://github.com/GetStream/webrtc/releases/download/148.0.0/WebRTC.xcframework.zip' }
  s.vendored_frameworks = 'WebRTC.xcframework'
end
