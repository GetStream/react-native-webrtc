//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Foundation
import WebRTC

/// Owns one `RTCPeerConnectionFactory` and the AudioDeviceModule it is built with, identified by a
/// stable `factoryId`. The ADM type (`.audioEngine`) and the `bypassVoiceProcessing` flag are fixed
/// at construction, so each call gets its own factory built with the audio profile it needs.
///
/// The encoder/decoder factories and the audio-processing module are created once by `WebRTCModule`
/// and passed in; this class only owns the factory lifecycle and the profile-driven build settings.
@objc public final class PeerConnectionFactoryProvider: NSObject {

    @objc public let factoryId: String
    @objc public private(set) var factory: RTCPeerConnectionFactory?
    @objc public private(set) var audioDeviceModule: AudioDeviceModule?
    @objc public let bypassVoiceProcessing: Bool

    private var disposed = false

    private init(
        factoryId: String,
        factory: RTCPeerConnectionFactory,
        audioDeviceModule: AudioDeviceModule?,
        bypassVoiceProcessing: Bool
    ) {
        self.factoryId = factoryId
        self.factory = factory
        self.audioDeviceModule = audioDeviceModule
        self.bypassVoiceProcessing = bypassVoiceProcessing
        super.init()
    }

    @objc public static func build(
        withId factoryId: String,
        bypassVoiceProcessing: Bool,
        encoderFactory: RTCVideoEncoderFactory,
        decoderFactory: RTCVideoDecoderFactory,
        audioProcessingModule: RTCAudioProcessingModule?,
        audioDevice: RTCAudioDevice?,
        audioDeviceModuleObserver: RTCAudioDeviceModuleDelegate
    ) -> PeerConnectionFactoryProvider {
        let factory: RTCPeerConnectionFactory
        if let audioProcessingModule = audioProcessingModule {
            factory = RTCPeerConnectionFactory(
                audioDeviceModuleType: .audioEngine,
                bypassVoiceProcessing: bypassVoiceProcessing,
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory,
                audioProcessingModule: audioProcessingModule
            )
        } else if let audioDevice = audioDevice {
            factory = RTCPeerConnectionFactory(
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory,
                audioDevice: audioDevice
            )
        } else {
            factory = RTCPeerConnectionFactory(
                audioDeviceModuleType: .audioEngine,
                bypassVoiceProcessing: bypassVoiceProcessing,
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory,
                audioProcessingModule: nil
            )
        }
        factory.frameBufferPolicy = .copyToNV12

        let audioDeviceModule = AudioDeviceModule(
            source: factory.audioDeviceModule,
            delegateObserver: audioDeviceModuleObserver
        )

        return PeerConnectionFactoryProvider(
            factoryId: factoryId,
            factory: factory,
            audioDeviceModule: audioDeviceModule,
            bypassVoiceProcessing: bypassVoiceProcessing
        )
    }

    // MARK: - Lifecycle

    @objc public func isDisposed() -> Bool { disposed }

    @objc public func dispose() {
        guard !disposed else { return }
        disposed = true
        // Releasing the factory releases its raw ADM; drop the wrapper too (ARC handles teardown).
        audioDeviceModule = nil
        factory = nil
    }
}
