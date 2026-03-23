//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Darwin
import Foundation

/// Thread-safe single-producer single-consumer ring buffer for Float32 audio samples.
///
/// Uses `os_unfair_lock` for minimal-overhead synchronization between the
/// ReplayKit callback thread (writer) and the audio render thread (reader).
/// The lock is uncontended in the vast majority of cases (different cadences),
/// making it suitable for real-time audio contexts.
final class AudioRingBuffer {

    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writePos: Int = 0
    private var readPos: Int = 0
    private var lock = os_unfair_lock_s()

    /// Creates a ring buffer with the given capacity in frames.
    /// - Parameter capacity: Maximum number of Float32 samples the buffer can hold.
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    /// Number of frames available to read (thread-safe).
    var availableToRead: Int {
        os_unfair_lock_lock(&lock)
        let result = _availableToRead
        os_unfair_lock_unlock(&lock)
        return result
    }

    // MARK: - Internal (lock held)

    private var _availableToRead: Int {
        let w = writePos
        let r = readPos
        return (w >= r) ? (w - r) : (capacity - r + w)
    }

    private var _availableToWrite: Int {
        // Reserve 1 slot to distinguish full from empty.
        return capacity - 1 - _availableToRead
    }

    // MARK: - Producer API (ReplayKit thread)

    /// Writes up to `count` samples from `source` into the ring buffer.
    /// - Returns: The number of samples actually written (may be less if buffer is full).
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let toWrite = min(count, _availableToWrite)
        guard toWrite > 0 else { return 0 }

        let w = writePos
        let firstPart = min(toWrite, capacity - w)
        let secondPart = toWrite - firstPart

        memcpy(buffer.advanced(by: w), source, firstPart * MemoryLayout<Float>.size)
        if secondPart > 0 {
            memcpy(buffer, source.advanced(by: firstPart), secondPart * MemoryLayout<Float>.size)
        }

        writePos = (w + toWrite) % capacity
        return toWrite
    }

    // MARK: - Consumer API (audio render thread)

    /// Reads up to `count` samples into `destination` from the ring buffer.
    /// - Returns: The number of samples actually read (may be less if buffer is empty).
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let toRead = min(count, _availableToRead)
        guard toRead > 0 else { return 0 }

        let r = readPos
        let firstPart = min(toRead, capacity - r)
        let secondPart = toRead - firstPart

        memcpy(destination, buffer.advanced(by: r), firstPart * MemoryLayout<Float>.size)
        if secondPart > 0 {
            memcpy(destination.advanced(by: firstPart), buffer, secondPart * MemoryLayout<Float>.size)
        }

        readPos = (r + toRead) % capacity
        return toRead
    }

    // MARK: - Reset

    /// Clears all buffered data. Call when not concurrently accessed by both
    /// producer and consumer, or when it is acceptable to lose data.
    func reset() {
        os_unfair_lock_lock(&lock)
        writePos = 0
        readPos = 0
        os_unfair_lock_unlock(&lock)
    }
}
