require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# WebRTC binary from https://github.com/GetStream/stream-video-swift-webrtc releases.
# CocoaPods trunk is read-only (permanently from 2026-12-02), so the `StreamWebRTC` pod can no longer be published there.
# The xcframework is vendored instead: same release asset the `StreamWebRTC` podspec in that
# repo points at. CocoaPods skips `prepare_command` for `:path` pods (how React Native
# autolinks this module), so the fetch happens here: the podspec is plain Ruby, evaluated
# on every `pod install`. The zip is cached per checksum; a stamp file skips re-extracting.
# When bumping: update both values. SHA-256 is of the WebRTC.xcframework.zip asset
# (`shasum -a 256 WebRTC.xcframework.zip`), not the SPM checksum in the release notes.
webrtc_version = '156.0.2'
webrtc_sha256  = 'adc58fbe5e8182951f45c1e180c78cd9467a8644cbabd79a08c7a06774beea25'

webrtc_url       = "https://github.com/GetStream/stream-video-swift-webrtc/releases/download/#{webrtc_version}/WebRTC.xcframework.zip"
webrtc_dir       = File.join(__dir__, 'third_party')
webrtc_framework = File.join(webrtc_dir, 'WebRTC.xcframework')
webrtc_stamp     = File.join(webrtc_dir, '.webrtc-version')

unless File.directory?(webrtc_framework) && File.exist?(webrtc_stamp) && File.read(webrtc_stamp).strip == webrtc_sha256
  # Zip cached per checksum outside node_modules, so clean installs and CI cache restores skip the 48MB download.
  cache_dir = File.join(ENV.fetch('XDG_CACHE_HOME', File.join(Dir.home, 'Library', 'Caches')), 'stream-react-native-webrtc')
  zip       = File.join(cache_dir, "WebRTC.xcframework-#{webrtc_sha256}.zip")
  FileUtils.mkdir_p(cache_dir)

  unless File.exist?(zip) && Digest::SHA256.file(zip).hexdigest == webrtc_sha256
    Pod::UI.puts "[stream-react-native-webrtc] Downloading WebRTC.xcframework #{webrtc_version}"
    partial = "#{zip}.#{Process.pid}.partial"
    begin
      raise "Failed to download #{webrtc_url}" unless system('curl', '-fsSL', '--retry', '3', '-o', partial, webrtc_url)

      actual = Digest::SHA256.file(partial).hexdigest
      raise "Checksum mismatch for #{webrtc_url}: expected #{webrtc_sha256}, got #{actual}" unless actual == webrtc_sha256

      FileUtils.mv(partial, zip)
    ensure
      FileUtils.rm_f(partial)
    end
  end

  FileUtils.mkdir_p(webrtc_dir)
  Dir.mktmpdir('stream-webrtc', webrtc_dir) do |tmp|
    raise "Failed to unzip #{zip}" unless system('unzip', '-q', '-o', zip, '-x', '__MACOSX/*', '-d', tmp)
    extracted = File.join(tmp, 'WebRTC.xcframework')
    raise "#{webrtc_url} did not contain WebRTC.xcframework" unless File.directory?(extracted)

    # Swap in only after a complete extract, so an interrupted install never leaves a partial framework.
    FileUtils.rm_rf([webrtc_framework, webrtc_stamp])
    FileUtils.mv(extracted, webrtc_framework)
    File.write(webrtc_stamp, webrtc_sha256)
  end
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
  # Stream WebRTC (StreamWebRTC), fetched above.
  s.vendored_frameworks = 'third_party/WebRTC.xcframework'
  # Swift/Objective-C compatibility #https://blog.cocoapods.org/CocoaPods-1.5.0/
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
