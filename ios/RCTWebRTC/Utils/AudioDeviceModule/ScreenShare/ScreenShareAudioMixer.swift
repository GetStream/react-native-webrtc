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

    /// Max screen-audio backlog kept in the ring buffer, in seconds. Bounds
    /// end-to-end latency while leaving enough cushion to absorb socket delivery
    /// bursts and producer/consumer clock jitter.
    private static let maxBufferedLatencySeconds = 0.1

    /// Guards the one-time "mic not capturing" warning.
    private var loggedNoTargetFormat = false

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
        loggedNoTargetFormat = false
    }

    /// Stop audio mixing.
    @objc public func stopMixing() {
        guard isMixing else { return }
        isMixing = false
        ringBuffer.reset()
        audioConverter.reset()
    }

    @objc public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isMixing else { return }
        guard let pcmBuffer = audioConverter.pcmBuffer(from: sampleBuffer) else { return }
        enqueue(pcmBuffer, trimBacklog: false)
    }

    @objc public func enqueuePCM(_ pcmBuffer: AVAudioPCMBuffer) {
        enqueue(pcmBuffer, trimBacklog: true)
    }

    /// Shared worker: converts `pcmBuffer` to the processing format, drops silent
    /// buffers, and writes it to the ring buffer.
    /// - Parameter trimBacklog: when `true` (default), caps the ring backlog to
    ///   `maxBufferedLatencySeconds` by dropping the oldest samples.
    private func enqueue(_ pcmBuffer: AVAudioPCMBuffer, trimBacklog: Bool = true) {
        guard isMixing else { return }
        guard let targetFmt = targetFormat else {
            if !loggedNoTargetFormat {
                loggedNoTargetFormat = true
                NSLog("[SSAudio][Mixer] enqueuePCM dropped: targetFormat nil (APM not initialized — is the mic capturing?)")
            }
            return
        }

        let buffer: AVAudioPCMBuffer
        if pcmBuffer.format.sampleRate != targetFmt.sampleRate
            || pcmBuffer.format.channelCount != targetFmt.channelCount
            || pcmBuffer.format.commonFormat != targetFmt.commonFormat
            || pcmBuffer.format.isInterleaved != targetFmt.isInterleaved {
            guard let converted = audioConverter.convertIfRequired(pcmBuffer, to: targetFmt) else { return }
            buffer = converted
        } else {
            buffer = pcmBuffer
        }

        if ScreenShareAudioConverter.isSilent(buffer) { return }

        guard let channelData = buffer.floatChannelData else { return }

        ringBuffer.write(channelData[0], count: Int(buffer.frameLength))

        if trimBacklog {
            // Bound backlog to ~maxBufferedLatencySeconds by dropping oldest, so the
            // buffer never pins full (which caused ~1s latency + dropped writes when
            // the producer runs slightly ahead of the consumer).
            let maxFrames = Int(processingSampleRate * Self.maxBufferedLatencySeconds)
            ringBuffer.trim(toMaxFrames: maxFrames)
        }
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
