//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Accelerate
import AudioToolbox
import AVFoundation
import CoreMedia

/// Converts RPScreenRecorder `.audioApp` CMSampleBuffers into
/// `AVAudioPCMBuffer`s suitable for scheduling on an `AVAudioPlayerNode`.
///
/// Handles:
/// - CMSampleBuffer → AVAudioPCMBuffer extraction via `CMSampleBufferCopyPCMDataIntoAudioBufferList`
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

    /// Extracts audio data from a `CMSampleBuffer` into an `AVAudioPCMBuffer`
    /// using Apple's `CMSampleBufferCopyPCMDataIntoAudioBufferList`.
    ///
    /// Matches the Swift SDK's `AVAudioPCMBuffer.from(_:)` implementation.
    func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        // Only linear PCM can be copied into AVAudioPCMBuffer.
        guard asbd.pointee.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }

        // Inspect format flags to build the correct AVAudioFormat.
        let formatFlags = asbd.pointee.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isBigEndian = (formatFlags & kAudioFormatFlagIsBigEndian) != 0
        let isInterleaved = (formatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let bitsPerChannel = Int(asbd.pointee.mBitsPerChannel)

        // Choose an AVAudioCommonFormat compatible with the sample format.
        let commonFormat: AVAudioCommonFormat
        if isFloat, bitsPerChannel == 32 {
            commonFormat = .pcmFormatFloat32
        } else if isSignedInt, bitsPerChannel == 16 {
            commonFormat = .pcmFormatInt16
        } else {
            return nil
        }

        // Build AVAudioFormat from explicit parameters (not streamDescription)
        // to ensure consistent format identity for downstream comparisons.
        guard let inputFormat = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: asbd.pointee.mSampleRate,
            channels: asbd.pointee.mChannelsPerFrame,
            interleaved: isInterleaved
        ) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return nil
        }

        pcmBuffer.frameLength = frameCount

        let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            return nil
        }

        // Prepare the destination AudioBufferList with correct byte sizes.
        let destinationList = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let bytesToCopy = Int(frameCount) * bytesPerFrame
        for index in 0..<destinationList.count {
            var destinationBuffer = destinationList[index]
            destinationBuffer.mDataByteSize = UInt32(bytesToCopy)
            destinationList[index] = destinationBuffer
        }

        // Use Apple's official API to copy PCM data into the AudioBufferList.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: destinationList.unsafeMutablePointer
        )
        guard status == noErr else {
            return nil
        }

        // Convert big-endian samples to native endianness in place.
        if isBigEndian {
            let bufferList = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
            for buffer in bufferList {
                guard let mData = buffer.mData else { continue }
                if commonFormat == .pcmFormatInt16 {
                    let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                    let intPtr = mData.assumingMemoryBound(to: Int16.self)
                    for i in 0..<sampleCount {
                        intPtr[i] = Int16(bigEndian: intPtr[i])
                    }
                } else if commonFormat == .pcmFormatFloat32 {
                    let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<UInt32>.size
                    let intPtr = mData.assumingMemoryBound(to: UInt32.self)
                    for i in 0..<sampleCount {
                        intPtr[i] = intPtr[i].byteSwapped
                    }
                }
            }
        }

        return pcmBuffer
    }

    // MARK: - Format conversion

    /// Converts `inputBuffer` to `outputFormat` if the formats differ.
    /// Returns the input buffer unchanged when formats already match.
    func convertIfRequired(
        _ inputBuffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
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
            return nil
        }

        // Calculate output frame capacity from sample rate ratio
        let inputFrames = Double(inputBuffer.frameLength)
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(max(1, ceil(inputFrames * ratio)))

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        var error: NSError?
        var didProvideData = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideData {
                outStatus.pointee = .noDataNow
                return nil
            }
            guard inputBuffer.frameLength > 0 else {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideData = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || error != nil {
            return nil
        }

        guard outputBuffer.frameLength > 0 else {
            return nil
        }

        return outputBuffer
    }

    // MARK: - Silence detection

    /// Returns `true` if the buffer is silent (RMS below -60 dB).
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

    private func formatsMatch(_ lhs: AVAudioFormat?, _ rhs: AVAudioFormat?) -> Bool {
        guard let lhs = lhs, let rhs = rhs else { return false }
        return lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }
}
