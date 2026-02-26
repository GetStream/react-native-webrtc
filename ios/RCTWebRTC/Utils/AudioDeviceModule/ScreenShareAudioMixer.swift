//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import AVFoundation
import CoreMedia
import WebRTC

/// Mixes screen share audio (from RPScreenRecorder `.audioApp` buffers) into the
/// WebRTC microphone capture stream using `RTCAudioCustomProcessingDelegate`.
///
/// Screen audio samples are written into a ring buffer. WebRTC's audio processing
/// pipeline calls `audioProcessingProcess(_:)` on its own thread; this method reads
/// from the ring buffer and additively mixes the screen audio into the mic samples.
@objc public final class ScreenShareAudioMixer: NSObject, RTCAudioCustomProcessingDelegate {

    // MARK: - Ring buffer

    private var ringBuffer: [Float]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let ringCapacity: Int
    private let lock = NSLock()

    // MARK: - Audio conversion

    private let audioConverter = ScreenShareAudioConverter()

    // MARK: - State

    private var isMixing = false
    private var processingFormat: AVAudioFormat?

    // MARK: - Diagnostics

    private var processCallCount: Int = 0
    private var processWithDataCount: Int = 0
    private var enqueueCallCount: Int = 0
    private var enqueueWrittenCount: Int = 0
    private var enqueueSilenceCount: Int = 0
    private var enqueuePcmFailCount: Int = 0
    private var enqueueConvFailCount: Int = 0
    private var enqueueNoFormatCount: Int = 0
    private var formatLogged = false

    // MARK: - Init

    @objc public override init() {
        // 1 second at 48 kHz — enough to absorb jitter between
        // RPScreenRecorder delivery and WebRTC processing cadence.
        ringCapacity = 48000
        ringBuffer = [Float](repeating: 0, count: ringCapacity)
        super.init()
        NSLog("[ScreenShareAudio] Mixer instance created")
    }

    deinit {
        NSLog("[ScreenShareAudio] Mixer instance deallocated!")
    }

    // MARK: - RTCAudioCustomProcessingDelegate

    public func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        lock.lock()
        defer { lock.unlock() }
        processingFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRateHz),
            channels: AVAudioChannelCount(channels)
        )
        writeIndex = 0
        readIndex = 0
        NSLog("[ScreenShareAudio] audioProcessingInitialize: %dHz, %dch", sampleRateHz, channels)
    }

    public func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        guard isMixing else { return }
        lock.lock()
        defer { lock.unlock() }

        processCallCount += 1

        let frames = audioBuffer.frames
        let channelBuffer = audioBuffer.rawBuffer(forChannel: 0)

        // Mix ring buffer data into the mic capture if available
        let available = writeIndex - readIndex
        if available > 0 {
            let framesToRead = min(frames, available)
            for i in 0..<framesToRead {
                channelBuffer[i] += ringBuffer[(readIndex + i) % ringCapacity]
            }
            readIndex += framesToRead
            processWithDataCount += 1
        }

        // Periodic stats (every ~1s at 10ms cadence = 100 calls)
        if processCallCount % 100 == 0 {
            // Sample ring buffer amplitude at current read position
            var ringPeak: Float = 0
            let ringAvail = writeIndex - readIndex
            let samplesToCheck = min(ringAvail, 480)
            for i in 0..<samplesToCheck {
                ringPeak = max(ringPeak, abs(ringBuffer[(readIndex + i) % ringCapacity]))
            }
            NSLog("[ScreenShareAudio] PROCESS stats: calls=%d, withData=%d, ringAvail=%d, ringPeak=%g, enqueued=%d, written=%d",
                  processCallCount, processWithDataCount, ringAvail, ringPeak,
                  enqueueCallCount, enqueueWrittenCount)
        }
    }

    public func audioProcessingRelease() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        readIndex = 0
        processingFormat = nil
        NSLog("[ScreenShareAudio] audioProcessingRelease")
    }

    // MARK: - Public API

    /// Enable audio buffer processing. Call when screen share with audio starts.
    @objc public func startMixing() {
        lock.lock()
        defer { lock.unlock() }

        guard !isMixing else {
            NSLog("[ScreenShareAudio] startMixing called but already mixing")
            return
        }
        isMixing = true
        writeIndex = 0
        readIndex = 0

        // Reset diagnostic counters
        processCallCount = 0
        processWithDataCount = 0
        enqueueCallCount = 0
        enqueueWrittenCount = 0
        enqueueSilenceCount = 0
        enqueuePcmFailCount = 0
        enqueueConvFailCount = 0
        enqueueNoFormatCount = 0
        formatLogged = false

        NSLog("[ScreenShareAudio] startMixing (processingFormat=%@)",
              processingFormat != nil ? "\(processingFormat!.sampleRate)Hz/\(processingFormat!.channelCount)ch" : "nil")
    }

    /// Stop processing audio buffers.
    @objc public func stopMixing() {
        lock.lock()
        defer { lock.unlock() }

        guard isMixing else {
            NSLog("[ScreenShareAudio] stopMixing called but not mixing")
            return
        }
        isMixing = false

        NSLog("[ScreenShareAudio] stopMixing — FINAL STATS: process=%d (withData=%d), enqueue=%d (written=%d, silence=%d, pcmFail=%d, convFail=%d, noFmt=%d)",
              processCallCount, processWithDataCount,
              enqueueCallCount, enqueueWrittenCount, enqueueSilenceCount,
              enqueuePcmFailCount, enqueueConvFailCount, enqueueNoFormatCount)

        writeIndex = 0
        readIndex = 0
        audioConverter.reset()
    }

    /// Receive a screen audio CMSampleBuffer from InAppScreenCapturer.
    @objc public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isMixing else { return }

        guard let targetFormat = processingFormat else {
            enqueueNoFormatCount += 1
            if enqueueNoFormatCount <= 5 {
                NSLog("[ScreenShareAudio] ENQUEUE: no processingFormat yet (count=%d)", enqueueNoFormatCount)
            }
            return
        }

        enqueueCallCount += 1

        // 1. CMSampleBuffer → AVAudioPCMBuffer
        guard let pcm = audioConverter.pcmBuffer(from: sampleBuffer) else {
            enqueuePcmFailCount += 1
            if enqueuePcmFailCount <= 5 {
                NSLog("[ScreenShareAudio] ENQUEUE: pcmBuffer extraction failed (count=%d)", enqueuePcmFailCount)
            }
            return
        }

        // One-time format logging with full ASBD details
        if !formatLogged {
            formatLogged = true
            let srcFmt = pcm.format
            let asbd = srcFmt.streamDescription.pointee
            NSLog("[ScreenShareAudio] ENQUEUE FORMAT: screen=%gHz/%dch/fmt%d/interleaved=%d → target=%gHz/%dch",
                  srcFmt.sampleRate, srcFmt.channelCount, srcFmt.commonFormat.rawValue,
                  srcFmt.isInterleaved ? 1 : 0,
                  targetFormat.sampleRate, targetFormat.channelCount)
            NSLog("[ScreenShareAudio] ASBD: bitsPerCh=%d, bytesPerFrame=%d, bytesPerPacket=%d, formatFlags=0x%X, formatID=%d",
                  asbd.mBitsPerChannel, asbd.mBytesPerFrame, asbd.mBytesPerPacket,
                  asbd.mFormatFlags, asbd.mFormatID)
            // Check raw PCM amplitude
            var rawPeak: Float = 0
            if let floatCh = pcm.floatChannelData {
                for i in 0..<min(Int(pcm.frameLength), 1024) {
                    rawPeak = max(rawPeak, abs(floatCh[0][i]))
                }
                NSLog("[ScreenShareAudio] RAW PCM peak (float ch0): %g", rawPeak)
            } else if let int16Ch = pcm.int16ChannelData {
                var int16Peak: Int16 = 0
                for i in 0..<min(Int(pcm.frameLength), 1024) {
                    int16Peak = max(int16Peak, abs(int16Ch[0][i]))
                }
                NSLog("[ScreenShareAudio] RAW PCM peak (int16 ch0): %d", int16Peak)
            } else {
                NSLog("[ScreenShareAudio] RAW PCM: NO float or int16 channel data! commonFormat=%d", srcFmt.commonFormat.rawValue)
            }
        }

        // 2. Silence detection
        if ScreenShareAudioConverter.isSilent(pcm) {
            enqueueSilenceCount += 1
            return
        }

        // 3. Convert to processing format (e.g. 48 kHz / 1 ch / float32)
        let buffer: AVAudioPCMBuffer
        if pcm.format.sampleRate != targetFormat.sampleRate
            || pcm.format.channelCount != targetFormat.channelCount
            || pcm.format.commonFormat != targetFormat.commonFormat
            || pcm.format.isInterleaved != targetFormat.isInterleaved {
            guard let converted = audioConverter.convertIfRequired(pcm, to: targetFormat) else {
                enqueueConvFailCount += 1
                if enqueueConvFailCount <= 5 {
                    NSLog("[ScreenShareAudio] ENQUEUE: conversion failed (count=%d)", enqueueConvFailCount)
                }
                return
            }
            buffer = converted
        } else {
            buffer = pcm
        }

        // 4. Write to ring buffer
        guard let floatData = buffer.floatChannelData else {
            NSLog("[ScreenShareAudio] ENQUEUE: no floatChannelData after conversion!")
            return
        }
        let frames = Int(buffer.frameLength)

        // Periodic amplitude check on converted buffer (every 50th write)
        if enqueueWrittenCount % 50 == 0 {
            var peak: Float = 0
            for i in 0..<min(frames, 1024) {
                peak = max(peak, abs(floatData[0][i]))
            }
            NSLog("[ScreenShareAudio] CONVERTED peak amplitude: %g (frames=%d)", peak, frames)
        }

        lock.lock()
        defer { lock.unlock() }

        // Handle overflow: if ring is too full, advance read index
        let available = writeIndex - readIndex
        if available + frames > ringCapacity {
            readIndex = writeIndex + frames - ringCapacity
        }

        for i in 0..<frames {
            ringBuffer[(writeIndex + i) % ringCapacity] = floatData[0][i]
        }
        writeIndex += frames
        enqueueWrittenCount += 1

        // Periodic enqueue stats (every 50 ≈ ~1s)
        if enqueueWrittenCount % 50 == 0 {
            NSLog("[ScreenShareAudio] ENQUEUE stats: calls=%d, written=%d, frames=%d, ringAvail=%d, silence=%d",
                  enqueueCallCount, enqueueWrittenCount, frames, writeIndex - readIndex, enqueueSilenceCount)
        }
    }
}
