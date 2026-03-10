//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import AVFoundation
import CoreMedia
import WebRTC

/// Mixes screen share audio (from RPScreenRecorder `.audioApp` buffers) into the
/// WebRTC microphone capture stream by inserting an `AVAudioPlayerNode` and
/// `AVAudioMixerNode` into the engine's input graph.
///
/// Graph topology (wired in `onConfigureInputFromSource`):
/// ```
/// source (mic VP) --> mixerNode --> destination (WebRTC capture)
///                        ^
/// playerNode -----------/
/// ```
///
/// The mixer stays dormant (no nodes attached) until `startMixing` is called.
/// Screen audio buffers are scheduled on the player node via `enqueue(_:)`.
@objc public final class ScreenShareAudioMixer: NSObject, AudioGraphConfigurationDelegate {

    // MARK: - Audio graph nodes

    private let playerNode = AVAudioPlayerNode()
    private let mixerNode = AVAudioMixerNode()

    // MARK: - Audio conversion

    private let audioConverter = ScreenShareAudioConverter()

    // MARK: - State

    private var isMixing = false

    /// The engine reference from the last `onConfigureInputFromSource` call.
    /// Used to detach nodes on cleanup.
    private weak var currentEngine: AVAudioEngine?

    /// Format of the input graph path, used for converting screen audio.
    private var graphFormat: AVAudioFormat?

    /// Whether our nodes are currently attached to the engine.
    private var nodesAttached = false

    // MARK: - Diagnostics

    private var enqueueCallCount: Int = 0
    private var enqueueScheduledCount: Int = 0
    private var enqueueSilenceCount: Int = 0
    private var enqueuePcmFailCount: Int = 0
    private var enqueueConvFailCount: Int = 0
    private var formatLogged = false

    // MARK: - Init

    @objc public override init() {
        super.init()
        NSLog("[ScreenShareAudio] Mixer instance created (graph approach)")
    }

    deinit {
        NSLog("[ScreenShareAudio] Mixer instance deallocated!")
    }

    // MARK: - AudioGraphConfigurationDelegate

    public func onConfigureInputFromSource(
        _ engine: AVAudioEngine,
        source: AVAudioNode?,
        destination: AVAudioNode,
        format: AVAudioFormat
    ) {
        currentEngine = engine
        graphFormat = format

        guard isMixing else {
            NSLog("[ScreenShareAudio] onConfigureInputFromSource: not mixing, skipping graph modification")
            return
        }

        attachAndWireNodes(engine: engine, source: source, destination: destination, format: format)
    }

    public func onDidStopEngine(_ engine: AVAudioEngine) {
        detachNodes(from: engine)
    }

    public func onDidDisableEngine(_ engine: AVAudioEngine) {
        detachNodes(from: engine)
    }

    public func onWillReleaseEngine(_ engine: AVAudioEngine) {
        detachNodes(from: engine)
        currentEngine = nil
        graphFormat = nil
    }

    // MARK: - Public API

    /// Enable audio mixing. Call when screen share with audio starts.
    ///
    /// If the engine is already running (i.e., `onConfigureInputFromSource` has
    /// already fired), this triggers an ADM reconfiguration so the graph gets
    /// rewired with our nodes.
    @objc public func startMixing() {
        guard !isMixing else {
            NSLog("[ScreenShareAudio] startMixing called but already mixing")
            return
        }
        isMixing = true

        // Reset diagnostic counters
        enqueueCallCount = 0
        enqueueScheduledCount = 0
        enqueueSilenceCount = 0
        enqueuePcmFailCount = 0
        enqueueConvFailCount = 0
        formatLogged = false

        NSLog("[ScreenShareAudio] startMixing (graphFormat=%@)",
              graphFormat != nil ? "\(graphFormat!.sampleRate)Hz/\(graphFormat!.channelCount)ch" : "nil")
    }

    /// Stop audio mixing and detach nodes from the engine.
    @objc public func stopMixing() {
        guard isMixing else {
            NSLog("[ScreenShareAudio] stopMixing called but not mixing")
            return
        }
        isMixing = false

        NSLog("[ScreenShareAudio] stopMixing — FINAL STATS: enqueue=%d (scheduled=%d, silence=%d, pcmFail=%d, convFail=%d)",
              enqueueCallCount, enqueueScheduledCount, enqueueSilenceCount,
              enqueuePcmFailCount, enqueueConvFailCount)

        // Stop player and detach nodes
        playerNode.stop()
        if let engine = currentEngine {
            detachNodes(from: engine)
        }
        audioConverter.reset()
    }

    /// Receive a screen audio CMSampleBuffer from InAppScreenCapturer.
    @objc public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isMixing else { return }

        guard let targetFormat = graphFormat else {
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

        // One-time format logging
        if !formatLogged {
            formatLogged = true
            let srcFmt = pcm.format
            NSLog("[ScreenShareAudio] ENQUEUE FORMAT: screen=%gHz/%dch → target=%gHz/%dch",
                  srcFmt.sampleRate, srcFmt.channelCount,
                  targetFormat.sampleRate, targetFormat.channelCount)
        }

        // 2. Silence detection
        if ScreenShareAudioConverter.isSilent(pcm) {
            enqueueSilenceCount += 1
            return
        }

        // 3. Convert to graph format (e.g. 48 kHz / 1 ch / float32)
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

        // 4. Schedule on player node
        guard nodesAttached else {
            return
        }

        playerNode.scheduleBuffer(buffer)
        enqueueScheduledCount += 1

        // Start playback if not already playing
        if !playerNode.isPlaying {
            playerNode.play()
        }

        // Periodic stats (every ~50 buffers ≈ ~1s)
        if enqueueScheduledCount % 50 == 0 {
            NSLog("[ScreenShareAudio] ENQUEUE stats: calls=%d, scheduled=%d, silence=%d",
                  enqueueCallCount, enqueueScheduledCount, enqueueSilenceCount)
        }
    }

    // MARK: - Private graph management

    private func attachAndWireNodes(
        engine: AVAudioEngine,
        source: AVAudioNode?,
        destination: AVAudioNode,
        format: AVAudioFormat
    ) {
        // Detach if previously attached (e.g., engine reconfiguration)
        detachNodes(from: engine)

        engine.attach(mixerNode)
        engine.attach(playerNode)

        // Wire: source → mixerNode → destination
        if let source = source {
            engine.connect(source, to: mixerNode, format: format)
        }
        engine.connect(playerNode, to: mixerNode, format: format)
        engine.connect(mixerNode, to: destination, format: format)

        nodesAttached = true
        NSLog("[ScreenShareAudio] Graph wired: source(%@) → mixer → destination, format=%gHz/%dch",
              source != nil ? "VP" : "nil", format.sampleRate, format.channelCount)
    }

    private func detachNodes(from engine: AVAudioEngine) {
        guard nodesAttached else { return }

        // Detaching automatically disconnects all connections
        engine.detach(playerNode)
        engine.detach(mixerNode)
        nodesAttached = false

        NSLog("[ScreenShareAudio] Nodes detached from engine")
    }
}
