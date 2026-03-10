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

    // MARK: - Init

    @objc public override init() {
        super.init()
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

        guard isMixing else { return }

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
        guard !isMixing else { return }
        isMixing = true
    }

    /// Stop audio mixing and detach nodes from the engine.
    @objc public func stopMixing() {
        guard isMixing else { return }
        isMixing = false

        playerNode.stop()
        if let engine = currentEngine {
            detachNodes(from: engine)
        }
        audioConverter.reset()
    }

    /// Receive a screen audio CMSampleBuffer from InAppScreenCapturer.
    @objc public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isMixing, let targetFormat = graphFormat else { return }

        // 1. CMSampleBuffer → AVAudioPCMBuffer
        guard let pcm = audioConverter.pcmBuffer(from: sampleBuffer) else { return }

        // 2. Silence detection
        if ScreenShareAudioConverter.isSilent(pcm) { return }

        // 3. Convert to graph format (e.g. 48 kHz / 1 ch / float32)
        let buffer: AVAudioPCMBuffer
        if pcm.format.sampleRate != targetFormat.sampleRate
            || pcm.format.channelCount != targetFormat.channelCount
            || pcm.format.commonFormat != targetFormat.commonFormat
            || pcm.format.isInterleaved != targetFormat.isInterleaved {
            guard let converted = audioConverter.convertIfRequired(pcm, to: targetFormat) else { return }
            buffer = converted
        } else {
            buffer = pcm
        }

        // 4. Schedule on player node
        guard nodesAttached else { return }

        playerNode.scheduleBuffer(buffer)

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    // MARK: - Private graph management

    private func attachAndWireNodes(
        engine: AVAudioEngine,
        source: AVAudioNode?,
        destination: AVAudioNode,
        format: AVAudioFormat
    ) {
        detachNodes(from: engine)

        engine.attach(mixerNode)
        engine.attach(playerNode)

        if let source = source {
            engine.connect(source, to: mixerNode, format: format)
        }
        engine.connect(playerNode, to: mixerNode, format: format)
        engine.connect(mixerNode, to: destination, format: format)

        nodesAttached = true
    }

    private func detachNodes(from engine: AVAudioEngine) {
        guard nodesAttached else { return }

        engine.detach(playerNode)
        engine.detach(mixerNode)
        nodesAttached = false
    }
}
