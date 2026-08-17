require 'json'
require 'fileutils'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# WebRTC version from https://github.com/GetStream/stream-video-swift-webrtc releases.
# 148.0.0 is not on CocoaPods trunk, so the xcframework is vendored directly instead of
# depending on the `StreamWebRTC` pod. The release asset below is the same one the
# `StreamWebRTC` podspec in that repo points at. CocoaPods skips `prepare_command` for
# `:path` pods (which is how React Native autolinks this module), so the fetch happens
# here — the podspec is plain Ruby, evaluated on every `pod install`.
webrtc_version   = '148.0.0'
webrtc_url       = "https://github.com/GetStream/stream-video-swift-webrtc/releases/download/#{webrtc_version}/WebRTC.xcframework.zip"
webrtc_dir       = File.join(__dir__, 'third_party')
webrtc_framework = File.join(webrtc_dir, 'WebRTC.xcframework')
webrtc_stamp     = File.join(webrtc_dir, '.webrtc-version')

unless File.directory?(webrtc_framework) && File.exist?(webrtc_stamp) && File.read(webrtc_stamp).strip == webrtc_url
  webrtc_zip = File.join(webrtc_dir, 'WebRTC.xcframework.zip')

  Pod::UI.puts "[stream-react-native-webrtc] Downloading WebRTC.xcframework #{webrtc_version}"

  FileUtils.mkdir_p(webrtc_dir)
  FileUtils.rm_rf([webrtc_framework, webrtc_stamp, webrtc_zip])

  raise "Failed to download #{webrtc_url}" unless system('curl', '-fSL', '--retry', '3', '-o', webrtc_zip, webrtc_url)
  raise "Failed to unzip #{webrtc_zip}" unless system('unzip', '-q', '-o', webrtc_zip, '-x', '__MACOSX/*', '-d', webrtc_dir)
  raise "#{webrtc_zip} did not contain WebRTC.xcframework" unless File.directory?(webrtc_framework)

  FileUtils.rm_f(webrtc_zip)
  File.write(webrtc_stamp, webrtc_url)
end

Pod::Spec.new do |s|
  s.name                = 'stream-react-native-webrtc'
  s.version             = package['version']
  s.summary             = package['description']
  s.homepage            = 'https://github.com/GetStream/react-native-webrtc'
  s.license             = package['license']
  s.author              = 'https://github.com/GetStream/react-native-webrtc/graphs/contributors'
  s.source              = { :git => 'git@github.com:GetStream/react-native-webrtc.git', :tag => 'release #{s.version}' }
  s.requires_arc        = true

  s.platform            = :ios, '13.0'

  s.preserve_paths      = 'ios/**/*'
  s.source_files        = 'ios/**/*.{h,m,mm,swift}'
  s.libraries           = 'c', 'sqlite3', 'stdc++'
  s.framework           = 'AudioToolbox','AVFoundation', 'CoreAudio', 'CoreGraphics', 'CoreVideo', 'GLKit', 'VideoToolbox'
  s.swift_version       = '5.0'
  s.dependency          'React-Core'
  # WebRTC version from https://github.com/GetStream/stream-video-swift-webrtc releases.
  # 148.0.0 is not yet published to CocoaPods trunk. so a temporary way to point at the pre-release xcframework published on GitHub releases.
  s.vendored_frameworks = 'third_party/WebRTC.xcframework'
  # Swift/Objective-C compatibility #https://blog.cocoapods.org/CocoaPods-1.5.0/
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
