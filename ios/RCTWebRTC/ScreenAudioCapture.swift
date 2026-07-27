//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import AVFoundation
import Foundation

/// A length-prefixed binary frame is used (not `CFHTTPMessage`) because audio
/// frames are small and high-frequency: a single socket read routinely contains
/// several whole frames plus a partial one, which a header-terminated format
/// cannot reassemble without losing/corrupting the surplus bytes.
///
/// Layout (little-endian), fixed 24-byte header followed by `payloadLength` PCM bytes:
/// ```
/// offset  size  field
///   0      4    magic = 0x53534155 ("SSAU")
///   4      8    sampleRate (Float64 bit pattern)
///  12      2    channels (UInt16)
///  14      2    bitsPerChannel (UInt16)
///  16      1    isFloat (UInt8: 1/0)
///  17      1    isInterleaved (UInt8: 1/0)
///  18      2    reserved
///  20      4    payloadLength (UInt32)
///  24      …    interleaved PCM body
/// ```
enum ScreenAudioWireFormat {
    static let magic: UInt32 = 0x5353_4155 // "SSAU"
    static let headerSize = 24
}

@objc public final class ScreenAudioCapture: NSObject {

    private static let audioSocketFileName = "rtc_SSFD_audio"
    private static let appGroupInfoPlistKey = "RTCAppGroupIdentifier"

    private static let readChunkSize = 16 * 1024
    /// Safety cap: if the accumulator ever grows past this without yielding a
    /// valid frame, drop it to resync (guards against corruption/desync).
    private static let maxAccumulatorBytes = 1 * 1024 * 1024

    @objc public var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var connection: SocketConnection?
    private var accumulator = Data()

    @objc override public init() {
        super.init()
    }

    deinit {
        stop()
    }

    @objc public func start() {
        guard let path = Self.audioSocketPath() else { return }
        
        let connection = SocketConnection(filePath: path)
        self.connection = connection
        accumulator.removeAll(keepingCapacity: true)
        connection.open(with: self)
    }

    @objc public func stop() {
        connection?.close()
        connection = nil
        accumulator.removeAll(keepingCapacity: false)
    }

    // MARK: - Private

    private static func audioSocketPath() -> String? {
        guard let appGroup = Bundle.main.object(forInfoDictionaryKey: appGroupInfoPlistKey) as? String,
              !appGroup.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else {
            return nil
        }
        return container.appendingPathComponent(audioSocketFileName).path
    }

    private func readBytes(from stream: InputStream) {
        guard stream.hasBytesAvailable else { return }

        var chunk = [UInt8](repeating: 0, count: Self.readChunkSize)
        let numberOfBytesRead = stream.read(&chunk, maxLength: Self.readChunkSize)
        guard numberOfBytesRead > 0 else { return }

        accumulator.append(contentsOf: chunk[0..<numberOfBytesRead])
        drainFrames()

        if accumulator.count > Self.maxAccumulatorBytes {
            NSLog("[SSAudio][Recv] accumulator overflow (%d bytes) — resetting to resync", accumulator.count)
            accumulator.removeAll(keepingCapacity: true)
        }
    }

    /// Parses as many complete frames as the accumulator currently holds.
    private func drainFrames() {
        let headerSize = ScreenAudioWireFormat.headerSize

        while accumulator.count >= headerSize {
            let base = accumulator.startIndex

            // Resync on magic mismatch by dropping one byte at a time.
            guard accumulator.leUInt32(0) == ScreenAudioWireFormat.magic else {
                accumulator.removeFirst(1)
                continue
            }

            let payloadLength = Int(accumulator.leUInt32(20))
            let totalLength = headerSize + payloadLength
            guard payloadLength > 0, payloadLength <= Self.maxAccumulatorBytes else {
                // Corrupt length — drop the magic and resync.
                accumulator.removeFirst(1)
                continue
            }
            // Wait for the rest of the frame.
            if accumulator.count < totalLength { return }

            let sampleRate = Double(bitPattern: accumulator.leUInt64(4))
            let channels = UInt32(accumulator.leUInt16(12))
            let bits = Int(accumulator.leUInt16(14))
            let isFloat = accumulator[base + 16] != 0
            let isInterleaved = accumulator[base + 17] != 0
            let payload = accumulator.subdata(in: (base + headerSize)..<(base + totalLength))

            accumulator.removeFirst(totalLength)

            if let buffer = makePCMBuffer(payload: payload,
                                          sampleRate: sampleRate,
                                          channels: channels,
                                          bits: bits,
                                          isFloat: isFloat,
                                          isInterleaved: isInterleaved) {
                onAudioBuffer?(buffer)
            }
        }
    }

    /// Rebuilds an `AVAudioPCMBuffer` from a raw PCM payload + format fields.
    private func makePCMBuffer(payload: Data,
                               sampleRate: Double,
                               channels: UInt32,
                               bits: Int,
                               isFloat: Bool,
                               isInterleaved: Bool) -> AVAudioPCMBuffer? {
        guard sampleRate > 0, channels > 0, !payload.isEmpty else {
            NSLog("[SSAudio][Recv] makePCMBuffer FAILED: bad header sr=%.0f ch=%d bytes=%d", sampleRate, channels, payload.count)
            return nil
        }

        let commonFormat: AVAudioCommonFormat
        if isFloat, bits == 32 {
            commonFormat = .pcmFormatFloat32
        } else if !isFloat, bits == 16 {
            commonFormat = .pcmFormatInt16
        } else {
            NSLog("[SSAudio][Recv] makePCMBuffer FAILED: unsupported format isFloat=%d bits=%d", isFloat ? 1 : 0, bits)
            return nil
        }

        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: isInterleaved
        ) else {
            NSLog("[SSAudio][Recv] makePCMBuffer FAILED: AVAudioFormat nil")
            return nil
        }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }

        let frameCount = AVAudioFrameCount(payload.count / bytesPerFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            NSLog("[SSAudio][Recv] makePCMBuffer FAILED: frameCount=%d bytesPerFrame=%d bytes=%d", frameCount, bytesPerFrame, payload.count)
            return nil
        }
        buffer.frameLength = frameCount

        // Copy the interleaved PCM body into the buffer's backing storage.
        let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let dest = bufferList.first?.mData else { return nil }
        let bytesToCopy = min(Int(bufferList[0].mDataByteSize), payload.count)
        payload.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                memcpy(dest, src, bytesToCopy)
            }
        }

        return buffer
    }
}

extension ScreenAudioCapture: StreamDelegate {
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            if let input = aStream as? InputStream {
                readBytes(from: input)
            }
        case .endEncountered:
            stop()
        case .errorOccurred:
            NSLog("[SSAudio][Recv] audio socket stream error: %@", aStream.streamError?.localizedDescription ?? "")
        default:
            break
        }
    }
}

// MARK: - Little-endian Data readers

private extension Data {
    func leUInt16(_ offset: Int) -> UInt16 {
        let s = startIndex + offset
        return UInt16(self[s]) | (UInt16(self[s + 1]) << 8)
    }

    func leUInt32(_ offset: Int) -> UInt32 {
        let s = startIndex + offset
        return UInt32(self[s])
            | (UInt32(self[s + 1]) << 8)
            | (UInt32(self[s + 2]) << 16)
            | (UInt32(self[s + 3]) << 24)
    }

    func leUInt64(_ offset: Int) -> UInt64 {
        let s = startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(self[s + i]) << (8 * i)
        }
        return value
    }
}
