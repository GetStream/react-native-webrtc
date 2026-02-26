//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Accelerate
import AVFoundation
import CoreMedia

/// Converts RPScreenRecorder `.audioApp` CMSampleBuffers into
/// `AVAudioPCMBuffer`s suitable for scheduling on an `AVAudioPlayerNode`.
///
/// Handles:
/// - CMSampleBuffer → AVAudioPCMBuffer extraction (float32, int16, interleaved, non-interleaved)
/// - Sample rate / channel / format conversion via cached AVAudioConverter
/// - Silence detection via vDSP RMS analysis
final class ScreenShareAudioConverter {

    // MARK: - Constants

    /// Buffers with RMS below this threshold (in dB) are considered silent.
    private static let silenceThresholdDB: Float = -60.0

    // MARK: - Cached converter

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var converterOutputFormat: AVAudioFormat?

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    /// Extracts audio data from a `CMSampleBuffer` into an `AVAudioPCMBuffer`.
    ///
    /// Supports float32 and int16 PCM formats, both interleaved and
    /// non-interleaved layouts.
    func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            NSLog("[ScreenShareAudio] Converter: no format description in CMSampleBuffer")
            return nil
        }

        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            NSLog("[ScreenShareAudio] Converter: no ASBD in format description")
            return nil
        }

        guard let avFormat = AVAudioFormat(streamDescription: asbdPtr) else {
            NSLog("[ScreenShareAudio] Converter: failed to create AVAudioFormat from ASBD")
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer = dataPointer else {
            return nil
        }

        // Copy audio data into PCM buffer
        if let floatData = pcmBuffer.floatChannelData {
            let channelCount = Int(avFormat.channelCount)
            let bytesPerFrame = Int(avFormat.streamDescription.pointee.mBytesPerFrame)

            if avFormat.isInterleaved {
                // Interleaved: single buffer, copy all at once
                memcpy(floatData[0], dataPointer, min(totalLength, Int(frameCount) * bytesPerFrame))
            } else {
                // Non-interleaved: separate buffers per channel
                let framesSize = Int(frameCount) * MemoryLayout<Float>.size
                for ch in 0..<channelCount {
                    memcpy(floatData[ch], dataPointer.advanced(by: ch * framesSize), framesSize)
                }
            }
        } else if let int16Data = pcmBuffer.int16ChannelData {
            let bytesPerFrame = Int(avFormat.streamDescription.pointee.mBytesPerFrame)
            memcpy(int16Data[0], dataPointer, min(totalLength, Int(frameCount) * bytesPerFrame))
        } else {
            NSLog("[ScreenShareAudio] Converter: unsupported PCM format (no float or int16 channel data)")
            return nil
        }

        return pcmBuffer
    }

    // MARK: - Format conversion

    /// Converts `inputBuffer` to `outputFormat` if the formats differ.
    /// Returns the input buffer unchanged when formats already match.
    ///
    /// Uses mastering-quality sample rate conversion, matching the Swift SDK's
    /// `AudioConverter` implementation.
    func convertIfRequired(
        _ inputBuffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        // Identity optimization: skip conversion when formats match
        if formatsMatch(inputBuffer.format, outputFormat) {
            return inputBuffer
        }

        // Create or reuse converter for current format pair
        if converter == nil
            || !formatsMatch(converterInputFormat, inputBuffer.format)
            || !formatsMatch(converterOutputFormat, outputFormat) {
            converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converterInputFormat = inputBuffer.format
            converterOutputFormat = outputFormat
        }

        guard let converter = converter else {
            NSLog("[ScreenShareAudio] Converter: AVAudioConverter creation failed")
            return nil
        }

        // Calculate output frame capacity from sample rate ratio
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio))

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        var error: NSError?
        var hasData = true
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                outStatus.pointee = .haveData
                hasData = false
                return inputBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if let error = error {
            NSLog("[ScreenShareAudio] Converter: conversion error: \(error.localizedDescription)")
            return nil
        }

        return outputBuffer
    }

    // MARK: - Silence detection

    /// Returns `true` if the buffer is silent (RMS below -60 dB).
    ///
    /// For non-float formats (e.g., int16 from RPScreenRecorder), this returns
    /// `false` — silence detection requires float data for vDSP, and these
    /// buffers will be converted before scheduling anyway.
    static func isSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channelData = buffer.floatChannelData else {
            return false
        }

        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else {
            return true
        }

        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, frameCount)

        let rmsDB = 20 * log10(max(rms, Float.ulpOfOne))
        return rmsDB <= silenceThresholdDB
    }

    // MARK: - Cleanup

    func reset() {
        converter = nil
        converterInputFormat = nil
        converterOutputFormat = nil
    }

    // MARK: - Private

    /// Compares two formats by sample rate, channel count, common format,
    /// and interleaving — matching the Swift SDK's `AVAudioFormat+Equality`.
    private func formatsMatch(_ lhs: AVAudioFormat?, _ rhs: AVAudioFormat?) -> Bool {
        guard let lhs = lhs, let rhs = rhs else { return false }
        return lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }
}
