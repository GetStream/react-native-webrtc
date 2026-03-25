//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import AVFoundation
import CoreMedia
import WebRTC

/// Mixes screen share audio into the WebRTC microphone capture stream via
/// `RTCAudioCustomProcessingDelegate` — direct PCM additive mixing in the
/// WebRTC capture post-processing pipeline.
///
/// Set as `capturePostProcessingDelegate` on `RTCDefaultAudioProcessingModule`.
/// The delegate callback runs after AEC/AGC/NS, so screen audio passes through
/// without echo cancellation interference.
///
/// ```
/// RPScreenRecorder → convert → ring buffer → audioProcessingProcess → encoding
///                   (44100→48k)   (producer)       (consumer)
/// ```
///
/// **Important:** `RTCAudioBuffer` uses FloatS16 format (Float32 in the Int16
/// range -32768…32767). Audio from `AVAudioConverter` (normalized -1…1) must
/// be scaled by 32768 before mixing.
@objc public final class ScreenShareAudioMixer: NSObject, RTCAudioCustomProcessingDelegate {

    /// Ring buffer for passing converted audio from the RPScreenRecorder callback
    /// thread (producer) to the audio processing thread (consumer).
    /// Capacity: 1 second of mono Float32 at 48 kHz.
    private let ringBuffer = AudioRingBuffer(capacity: 48000)
    private let audioConverter = ScreenShareAudioConverter()

    private var isMixing = false
    /// Processing format from `audioProcessingInitialize`.
    private var processingSampleRate: Double = 0
    private var processingChannels: Int = 0
    private var targetFormat: AVAudioFormat?

    /// Scale factor: RTCAudioBuffer uses FloatS16 format (Float32 values in the
    /// Int16 range -32768…32767), NOT normalized Float32 (-1…1).
    /// AVAudioConverter produces normalized Float32, so we must scale up.
    private static let floatS16Scale: Float = 32768.0

    // MARK: - RTCAudioCustomProcessingDelegate

    /// Called by WebRTC when the processing pipeline initializes or reconfigures.
    /// May be called multiple times (e.g., on route changes).
    public func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        processingSampleRate = Double(sampleRate)
        processingChannels = channels

        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: processingSampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )

        ringBuffer.reset()
        audioConverter.reset()
    }

    /// Called on the audio processing thread for each captured audio chunk.
    /// Reads from the ring buffer and ADDs screen audio samples to the mic buffer.
    public func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        guard isMixing else { return }

        let frames = Int(audioBuffer.frames)
        let channels = Int(audioBuffer.channels)
        guard frames > 0, channels > 0 else { return }

        mixFromRingBuffer(into: audioBuffer, frames: frames, channels: channels)
    }

    /// Called when the processing pipeline is released.
    public func audioProcessingRelease() {
        ringBuffer.reset()
        targetFormat = nil
    }

    // MARK: - Public API

    /// Enable audio mixing. After this, `enqueue(_:)` writes to the ring buffer
    /// and the processing callback reads from it.
    @objc public func startMixing() {
        guard !isMixing else { return }
        ringBuffer.reset()
        isMixing = true
    }

    /// Stop audio mixing.
    @objc public func stopMixing() {
        guard isMixing else { return }
        isMixing = false
        ringBuffer.reset()
        audioConverter.reset()
    }

    /// Receive a screen audio CMSampleBuffer from InAppScreenCapturer.
    /// Converts to the processing format and writes to the ring buffer.
    @objc public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isMixing, let targetFmt = targetFormat else { return }

        guard let pcm = audioConverter.pcmBuffer(from: sampleBuffer) else { return }

        let buffer: AVAudioPCMBuffer
        if pcm.format.sampleRate != targetFmt.sampleRate
            || pcm.format.channelCount != targetFmt.channelCount
            || pcm.format.commonFormat != targetFmt.commonFormat
            || pcm.format.isInterleaved != targetFmt.isInterleaved {
            guard let converted = audioConverter.convertIfRequired(pcm, to: targetFmt) else { return }
            buffer = converted
        } else {
            buffer = pcm
        }

        if ScreenShareAudioConverter.isSilent(buffer) { return }

        guard let channelData = buffer.floatChannelData else { return }
        ringBuffer.write(channelData[0], count: Int(buffer.frameLength))
    }

    // MARK: - Private mixing

    /// Read from ring buffer and ADD to the mic audio buffer (additive mixing).
    /// Ring buffer contains normalized Float32 [-1,1] from AVAudioConverter;
    /// RTCAudioBuffer uses FloatS16 [-32768,32767], so we scale before adding.
    private func mixFromRingBuffer(into audioBuffer: RTCAudioBuffer, frames: Int, channels: Int) {
        let tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { tempBuffer.deallocate() }

        let framesRead = ringBuffer.read(into: tempBuffer, count: frames)
        guard framesRead > 0 else { return }

        for ch in 0..<channels {
            let channelData = audioBuffer.rawBuffer(forChannel: ch)
            for i in 0..<framesRead {
                channelData[i] += tempBuffer[i] * Self.floatS16Scale
            }
        }
    }
}
