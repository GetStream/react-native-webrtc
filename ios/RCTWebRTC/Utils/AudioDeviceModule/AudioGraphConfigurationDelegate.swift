//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import AVFoundation

/// Protocol that allows external code to hook into AVAudioEngine lifecycle
/// events synchronously. Callbacks fire on WebRTC's audio thread.
///
/// Implementations must perform any AVAudioEngine graph modifications
/// synchronously within the callback — async dispatch will race with
/// WebRTC's `ConfigureVoiceProcessingNode`.
@objc public protocol AudioGraphConfigurationDelegate: AnyObject {

    /// Called when WebRTC (re)configures the engine's input graph.
    /// This fires during engine setup, **before** `willStartEngine`.
    ///
    /// - Parameters:
    ///   - engine: The current `AVAudioEngine` instance.
    ///   - source: The upstream node (VP input), or `nil` when voice processing is disabled.
    ///   - destination: The node that receives the input stream (WebRTC capture mixer).
    ///   - format: The expected audio format for the input path.
    func onConfigureInputFromSource(
        _ engine: AVAudioEngine,
        source: AVAudioNode?,
        destination: AVAudioNode,
        format: AVAudioFormat
    )

    /// Called when the engine is about to be released/deallocated.
    @objc optional func onWillReleaseEngine(_ engine: AVAudioEngine)

    /// Called after the engine has fully stopped.
    @objc optional func onDidStopEngine(_ engine: AVAudioEngine)

    /// Called after the engine has been disabled.
    @objc optional func onDidDisableEngine(_ engine: AVAudioEngine)
}
