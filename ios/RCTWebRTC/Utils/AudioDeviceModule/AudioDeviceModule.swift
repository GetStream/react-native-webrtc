//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import AudioToolbox
import AVFAudio
import AVFoundation
import Combine
import Foundation
import WebRTC

/// Bridges `RTCAudioDeviceModule` callbacks to Combine-based state so the
/// audio pipeline can stay in sync with application logic.
@objc public final class AudioDeviceModule: NSObject, RTCAudioDeviceModuleDelegate, Encodable, @unchecked Sendable {

    /// Audio device module errors
    enum AudioDeviceError: Error {
        case operationFailed(String, Int)
        
        var localizedDescription: String {
            switch self {
            case .operationFailed(let message, let code):
                return "\(message) (Error code: \(code))"
            }
        }
    }

    /// Helper constants used across the module.
    enum Constant {
        /// WebRTC interfaces return integer result codes. We use this typed/named
        /// constant to define the success of an operation.
        static let successResult = 0

        /// Audio pipeline floor in dB that we interpret as silence.
        static let silenceDB: Float = -160
    }

    /// Events emitted as the underlying audio engine changes state.
    public enum Event: Equatable, CustomStringConvertible {
        /// Outbound audio surpassed the silence threshold.
        case speechActivityStarted
        /// Outbound audio dropped back to silence.
        case speechActivityEnded
        /// A new `AVAudioEngine` instance has been created.
        case didCreateAudioEngine(AVAudioEngine)
        /// The engine is about to enable playout/recording paths.
        case willEnableAudioEngine(AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
        /// The engine is about to start rendering.
        case willStartAudioEngine(AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
        /// The engine has fully stopped.
        case didStopAudioEngine(AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
        /// The engine was disabled after stopping.
        case didDisableAudioEngine(AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
        /// The engine will be torn down.
        case willReleaseAudioEngine(AVAudioEngine)
        /// The input graph is configured with a new source node.
        case configureInputFromSource(AVAudioEngine, source: AVAudioNode?, destination: AVAudioNode, format: AVAudioFormat)
        /// The output graph is configured with a destination node.
        case configureOutputFromSource(AVAudioEngine, source: AVAudioNode, destination: AVAudioNode?, format: AVAudioFormat)
        /// Voice processing knobs changed.
        case didUpdateAudioProcessingState(
            voiceProcessingEnabled: Bool,
            voiceProcessingBypassed: Bool,
            voiceProcessingAGCEnabled: Bool,
            stereoPlayoutEnabled: Bool
        )

        public var description: String {
            switch self {
            case .speechActivityStarted:
                return ".speechActivityStarted"

            case .speechActivityEnded:
                return ".speechActivityEnded"

            case .didCreateAudioEngine(let engine):
                return ".didCreateAudioEngine(\(engine))"

            case .willEnableAudioEngine(let engine, let isPlayoutEnabled, let isRecordingEnabled):
                return ".willEnableAudioEngine(\(engine), isPlayoutEnabled:\(isPlayoutEnabled), isRecordingEnabled:\(isRecordingEnabled))"

            case .willStartAudioEngine(let engine, let isPlayoutEnabled, let isRecordingEnabled):
                return ".willStartAudioEngine(\(engine), isPlayoutEnabled:\(isPlayoutEnabled), isRecordingEnabled:\(isRecordingEnabled))"

            case .didStopAudioEngine(let engine, let isPlayoutEnabled, let isRecordingEnabled):
                return ".didStopAudioEngine(\(engine), isPlayoutEnabled:\(isPlayoutEnabled), isRecordingEnabled:\(isRecordingEnabled))"

            case .didDisableAudioEngine(let engine, let isPlayoutEnabled, let isRecordingEnabled):
                return ".didDisableAudioEngine(\(engine), isPlayoutEnabled:\(isPlayoutEnabled), isRecordingEnabled:\(isRecordingEnabled))"

            case .willReleaseAudioEngine(let engine):
                return ".willReleaseAudioEngine(\(engine))"

            case .configureInputFromSource(let engine, let source, let destination, let format):
                return ".configureInputFromSource(\(engine), source:\(source), destination:\(destination), format:\(format))"

            case .configureOutputFromSource(let engine, let source, let destination, let format):
                return ".configureOutputFromSource(\(engine), source:\(source), destination:\(destination?.description ?? "nil"), format:\(format))"

            case let .didUpdateAudioProcessingState(
                voiceProcessingEnabled,
                voiceProcessingBypassed,
                voiceProcessingAGCEnabled,
                stereoPlayoutEnabled
            ):
                return ".didUpdateAudioProcessingState(voiceProcessingEnabled:\(voiceProcessingEnabled), voiceProcessingBypassed:\(voiceProcessingBypassed), voiceProcessingAGCEnabled:\(voiceProcessingAGCEnabled), stereoPlayoutEnabled:\(stereoPlayoutEnabled))"
            }
        }
    }

    /// Tracks whether WebRTC is currently playing back audio.
    private let isPlayingSubject: CurrentValueSubject<Bool, Never>
    /// `true` while audio playout is active.
    @objc public var isPlaying: Bool { isPlayingSubject.value }
    /// Publisher that reflects playout activity changes.
    var isPlayingPublisher: AnyPublisher<Bool, Never> { isPlayingSubject.eraseToAnyPublisher() }

    /// Tracks whether WebRTC is capturing microphone samples.
    private let isRecordingSubject: CurrentValueSubject<Bool, Never>
    /// `true` while audio capture is active.
    @objc public var isRecording: Bool { isRecordingSubject.value }
    /// Publisher that reflects recording activity changes.
    var isRecordingPublisher: AnyPublisher<Bool, Never> { isRecordingSubject.eraseToAnyPublisher() }

    /// Tracks whether the microphone is muted at the ADM layer.
    private let isMicrophoneMutedSubject: CurrentValueSubject<Bool, Never>
    /// `true` if the microphone is muted.
    @objc public var isMicrophoneMuted: Bool { isMicrophoneMutedSubject.value }
    /// Publisher that reflects microphone mute changes.
    var isMicrophoneMutedPublisher: AnyPublisher<Bool, Never> { isMicrophoneMutedSubject.eraseToAnyPublisher() }

    /// Tracks whether stereo playout is configured.
    private let isStereoPlayoutEnabledSubject: CurrentValueSubject<Bool, Never>
    /// `true` if stereo playout is available and active.
    @objc public var isStereoPlayoutEnabled: Bool { isStereoPlayoutEnabledSubject.value }
    /// Publisher emitting stereo playout state.
    var isStereoPlayoutEnabledPublisher: AnyPublisher<Bool, Never> { isStereoPlayoutEnabledSubject.eraseToAnyPublisher() }

    /// Tracks whether VP processing is currently bypassed.
    private let isVoiceProcessingBypassedSubject: CurrentValueSubject<Bool, Never>
    /// `true` if the voice processing unit is bypassed.
    @objc public var isVoiceProcessingBypassed: Bool { isVoiceProcessingBypassedSubject.value }
    /// Publisher emitting VP bypass changes.
    var isVoiceProcessingBypassedPublisher: AnyPublisher<Bool, Never> { isVoiceProcessingBypassedSubject.eraseToAnyPublisher() }

    /// Tracks whether voice processing is enabled.
    private let isVoiceProcessingEnabledSubject: CurrentValueSubject<Bool, Never>
    /// `true` when Apple VP is active.
    @objc public var isVoiceProcessingEnabled: Bool { isVoiceProcessingEnabledSubject.value }
    /// Publisher emitting VP enablement changes.
    var isVoiceProcessingEnabledPublisher: AnyPublisher<Bool, Never> { isVoiceProcessingEnabledSubject.eraseToAnyPublisher() }

    /// Tracks whether automatic gain control is enabled inside VP.
    private let isVoiceProcessingAGCEnabledSubject: CurrentValueSubject<Bool, Never>
    /// `true` while AGC is active.
    @objc public var isVoiceProcessingAGCEnabled: Bool { isVoiceProcessingAGCEnabledSubject.value }
    /// Publisher emitting AGC changes.
    var isVoiceProcessingAGCEnabledPublisher: AnyPublisher<Bool, Never> { isVoiceProcessingAGCEnabledSubject.eraseToAnyPublisher() }

    /// Observes RMS audio levels (in dB) derived from the input tap.
    private let audioLevelSubject = CurrentValueSubject<Float, Never>(Constant.silenceDB) // default to silence
    /// Latest measured audio level.
    @objc public var audioLevel: Float { audioLevelSubject.value }
    /// Publisher emitting audio level updates.
    var audioLevelPublisher: AnyPublisher<Float, Never> { audioLevelSubject.eraseToAnyPublisher() }

    /// Wrapper around WebRTC `RTCAudioDeviceModule`.
    private let source: any RTCAudioDeviceModuleControlling

    /// Serial queue used to deliver events to observers.
    private let dispatchQueue: DispatchQueue
    /// Internal relay that feeds `publisher`.
    private let subject: PassthroughSubject<Event, Never>
    /// Object that taps engine nodes and publishes audio level data.
    private var audioLevelsAdapter: AudioEngineNodeAdapting
    /// Public stream of `Event` values describing engine transitions.
    public let publisher: AnyPublisher<Event, Never>

    /// Strong reference to the current engine so we can introspect it if needed.
    @objc public var engine: AVAudioEngine?

    /// Screen share audio mixer. Implements `RTCAudioCustomProcessingDelegate`
    /// and is set as `capturePostProcessingDelegate` on the
    /// `RTCDefaultAudioProcessingModule` when screen share audio mixing starts.
    @objc public let screenShareAudioMixer = ScreenShareAudioMixer()

    /// Secondary observer that receives forwarded delegate callbacks.
    /// This allows the AudioDeviceModuleObserver to receive events and forward them to JS.
    private let delegateObserver: RTCAudioDeviceModuleDelegate

    /// Textual diagnostics for logging and debugging.
    @objc public override var description: String {
        "{ " +
            "isPlaying:\(isPlaying)" +
            ", isRecording:\(isRecording)" +
            ", isMicrophoneMuted:\(isMicrophoneMuted)" +
            ", isStereoPlayoutEnabled:\(isStereoPlayoutEnabled)" +
            ", isVoiceProcessingBypassed:\(isVoiceProcessingBypassed)" +
            ", isVoiceProcessingEnabled:\(isVoiceProcessingEnabled)" +
            ", isVoiceProcessingAGCEnabled:\(isVoiceProcessingAGCEnabled)" +
            ", audioLevel:\(audioLevel)" +
            ", source:\(source)" +
            " }"
    }

    /// Creates a module that mirrors the provided WebRTC audio device module.
    /// - Parameters:
    ///   - source: The audio device module implementation to observe.
    ///   - delegateObserver: The observer that receives forwarded delegate callbacks.
    ///   - audioLevelsNodeAdapter: Adapter for audio level monitoring.
    init(
        _ source: any RTCAudioDeviceModuleControlling,
        delegateObserver: RTCAudioDeviceModuleDelegate,
        audioLevelsNodeAdapter: AudioEngineNodeAdapting = AudioEngineLevelNodeAdapter()
    ) {
        self.source = source
        self.delegateObserver = delegateObserver
        self.isPlayingSubject = .init(source.isPlaying)
        self.isRecordingSubject = .init(source.isRecording)
        self.isMicrophoneMutedSubject = .init(source.isMicrophoneMuted)
        self.isStereoPlayoutEnabledSubject = .init(source.isStereoPlayoutEnabled)
        self.isVoiceProcessingBypassedSubject = .init(source.isVoiceProcessingBypassed)
        self.isVoiceProcessingEnabledSubject = .init(source.isVoiceProcessingEnabled)
        self.isVoiceProcessingAGCEnabledSubject = .init(source.isVoiceProcessingAGCEnabled)
        self.audioLevelsAdapter = audioLevelsNodeAdapter

        let dispatchQueue = DispatchQueue(label: "io.getstream.audiodevicemodule", qos: .userInteractive)
        let subject = PassthroughSubject<Event, Never>()
        self.subject = subject
        self.dispatchQueue = dispatchQueue
        self.publisher = subject
            .receive(on: dispatchQueue)
            .eraseToAnyPublisher()
        super.init()

        audioLevelsAdapter.subject = audioLevelSubject
        source.observer = self
    }
    
    /// Objective-C compatible convenience initializer.
    /// - Parameters:
    ///   - source: The RTCAudioDeviceModule to wrap.
    ///   - delegateObserver: The observer that receives forwarded delegate callbacks.
    @objc public
    convenience init(source: RTCAudioDeviceModule, delegateObserver: RTCAudioDeviceModuleDelegate) {
        self.init(source as any RTCAudioDeviceModuleControlling, delegateObserver: delegateObserver, audioLevelsNodeAdapter: AudioEngineLevelNodeAdapter())
    }

    // MARK: - Engine hooks

    /// Synchronous hook run before an engine is enabled. Non-zero fails the enable.
    public typealias EngineWillEnableHook = (_ isPlayoutEnabled: Bool, _ isRecordingEnabled: Bool) -> Int
    /// Synchronous hook run right before an engine starts. Cannot fail the start.
    public typealias EngineWillStartHook = (_ isPlayoutEnabled: Bool, _ isRecordingEnabled: Bool) -> Void
    /// Synchronous hook run after an engine is disabled.
    public typealias EngineDidDisableHook = (_ isPlayoutEnabled: Bool, _ isRecordingEnabled: Bool) -> Void
    /// Hook run once a call factory's ADM has been created and registered.
    public typealias ModuleDidCreateHook = (_ module: AudioDeviceModule) -> Void

    /// Opaque token returned by ``addEngineHooks(willEnable:willStart:didDisable:didCreateModule:)``.
    private final class EngineHooksToken: NSObject {}

    /// A registered set of engine hooks.
    private struct EngineHooksEntry {
        let token: EngineHooksToken
        let willEnable: EngineWillEnableHook?
        let willStart: EngineWillStartHook?
        let didDisable: EngineDidDisableHook?
        let didCreateModule: ModuleDidCreateHook?
    }

    /// Process-wide hooks, in registration order. Guarded by `engineHooksLock`.
    private static var engineHooks: [EngineHooksEntry] = []
    private static let engineHooksLock = NSLock()

    /// Registers synchronous engine hooks for native consumers.
    ///
    /// - `willEnable`: called synchronously on the WebRTC worker thread BEFORE each fresh engine is
    ///   enabled, before any `publisher` event. Runs once per engine build, including voice-processing
    ///   retries and the speaker-only fallback: keep it cheap and idempotent (skip `setCategory` if
    ///   unchanged; call `RTCAudioSession.setActive(true)` only if you have not activated yet, because
    ///   activations are counted). Configure the audio session here. Return non-zero to fail the enable
    ///   (WebRTC rolls it back and reports the error); the remaining hooks are then skipped.
    /// - `willStart`: called synchronously on the WebRTC worker thread, inside the engine state
    ///   transition, right before the engine is started. Fires on every engine (re)start, including
    ///   restarts with no preceding `willEnable` (interruption end, route/device change). When both fire,
    ///   it runs after `willEnable`; voice-processing mute toggles happen in between. Cannot fail the start.
    /// - `didDisable`: called synchronously on the WebRTC worker thread after the engine is disabled.
    ///   Flags are the state AFTER the disable (both `false` = full stop). Cannot fail (teardown already
    ///   happened).
    /// - `didCreateModule`: called on the WebRTCModule method queue (NOT the WebRTC worker thread) when
    ///   `createCallFactory` has created a call factory and registered it as current, outside the registry
    ///   lock. Fires before `createCallFactory` resolves, so before any PeerConnection, track or engine
    ///   enable. ADM calls such as `setEngineAvailability` are allowed here. May fire again with the same
    ///   ADM (the live factory is shared on a concurrent join): keep it idempotent. Not fired for the
    ///   bare-fork default factory built lazily by `getOrCreateDefault`.
    ///
    /// `willEnable`, `willStart` and `didDisable` run inside the engine state transition: keep them cheap, do
    /// not call into the ADM, and do not block on other queues (deadlock risk).
    /// `RTCAudioSession.lockForConfiguration` is NOT re-entrant. `didCreateModule` is the exception.
    ///
    /// Process-wide: applies to every ADM instance (the ADM is rebuilt per call factory), so register once
    /// at module init. Hooks run in registration order. Several consumers may register; each must check
    /// audio session ownership itself.
    /// - Returns: An opaque token for ``removeEngineHooks(_:)``.
    @objc public static func addEngineHooks(
        willEnable: EngineWillEnableHook?,
        willStart: EngineWillStartHook? = nil,
        didDisable: EngineDidDisableHook?,
        didCreateModule: ModuleDidCreateHook? = nil
    ) -> NSObject {
        let token = EngineHooksToken()
        engineHooksLock.lock()
        engineHooks.append(
            .init(
                token: token,
                willEnable: willEnable,
                willStart: willStart,
                didDisable: didDisable,
                didCreateModule: didCreateModule
            )
        )
        engineHooksLock.unlock()
        return token
    }

    /// Unregisters hooks added with ``addEngineHooks(willEnable:willStart:didDisable:didCreateModule:)``.
    /// Unknown tokens are ignored.
    @objc public static func removeEngineHooks(_ token: NSObject) {
        engineHooksLock.lock()
        engineHooks.removeAll { $0.token === token }
        engineHooksLock.unlock()
    }

    /// Runs the registered `didCreateModule` hooks for a newly created call factory ADM.
    ///
    /// Internal: only `WebRTCModule.createCallFactory` calls this, after the factory is registered and
    /// outside the registry lock. `public` only so it is exposed in the generated `-Swift.h` header.
    @objc public static func notifyModuleCreated(_ module: AudioDeviceModule) {
        for entry in engineHooksSnapshot() {
            entry.didCreateModule?(module)
        }
    }

    /// Snapshot of the registered hooks; handlers must be invoked outside the lock.
    private static func engineHooksSnapshot() -> [EngineHooksEntry] {
        engineHooksLock.lock()
        defer { engineHooksLock.unlock() }
        return engineHooks
    }

    // MARK: - Recording

    /// Reinitializes the ADM, clearing its internal audio graph state.
    @objc public func reset() {
        _ = source.reset()
    }

    /// Sets how the microphone is muted (voice-processing vs input-mixer vs engine restart).
    /// - Returns: 0 on success, a non-zero WebRTC status otherwise.
    @objc public func setMuteMode(_ mode: RTCAudioEngineMuteMode) -> Int {
        source.setMuteMode(mode)
    }

    /// Keeps the recording (microphone-input) chain prepared even while muted, so the engine
    /// stays full-duplex instead of tearing the input path down.
    /// - Returns: 0 on success, a non-zero WebRTC status otherwise.
    @objc public func setRecordingAlwaysPreparedMode(_ enabled: Bool) -> Int {
        source.setRecordingAlwaysPreparedMode(enabled)
    }

    /// Switches between stereo and mono playout while keeping the recording
    /// state consistent across reinitializations.
    /// - Parameter isPreferred: `true` when stereo output should be used.
    @objc public func setStereoPlayoutPreference(_ isPreferred: Bool) {
        /// - Important: `.voiceProcessing` requires VP to be enabled in order to mute and
        /// `.restartEngine` rebuilds the whole graph. Each of them has different issues:
        /// - `.voiceProcessing`: as it requires VP to be enabled in order to mute/unmute that
        /// means that for outputs where VP is disabled (e.g. stereo) we cannot mute/unmute.
        /// - `.restartEngine`: rebuilds the whole graph and requires explicit calling of
        /// `initAndStartRecording` .
        _ = source.setMuteMode(isPreferred ? .inputMixer : .voiceProcessing)
        if isPreferred {
            _ = source.setRecordingAlwaysPreparedMode(false)
        }
        source.prefersStereoPlayout = isPreferred
        source.isVoiceProcessingBypassed = isPreferred
    }

    /// Starts or stops speaker playout on the ADM, retrying transient failures.
    /// - Parameter isActive: `true` to start playout, `false` to stop.
    /// - Throws: `AudioDeviceError` when WebRTC returns a non-zero status.
    @objc public func setPlayout(_ isActive: Bool) throws {
        guard isActive != isPlaying else {
            return
        }
        if isActive {
            if source.isPlayoutInitialized {
                try throwingExecution("Unable to start playout") {
                    source.startPlayout()
                }
            } else {
                try throwingExecution("Unable to initAndStart playout") {
                    source.initAndStartPlayout()
                }
            }
        } else {
            try throwingExecution("Unable to stop playout") {
                source.stopPlayout()
            }
        }
    }

    /// Enables or disables recording on the wrapped audio device module.
    /// - Parameter isEnabled: When `true` recording starts, otherwise stops.
    /// - Throws: `AudioDeviceError` when the underlying module reports a failure.
    @objc public func setRecording(_ isEnabled: Bool) throws {
        guard isEnabled != isRecording else {
            return
        }
        if isEnabled {
            if source.isRecordingInitialized {
                try throwingExecution("Unable to start recording") {
                    source.startRecording()
                }
            } else {
                try throwingExecution("Unable to initAndStart recording") {
                    source.initAndStartRecording()
                }
            }
        } else {
            try throwingExecution("Unable to stop recording") {
                source.stopRecording()
            }
        }

        isRecordingSubject.send(isEnabled)
    }

    /// Updates the muted state of the microphone for the wrapped module.
    /// - Parameter isMuted: `true` to mute the microphone, `false` to unmute.
    /// - Throws: `AudioDeviceError` when the underlying module reports a failure.
    @objc public func setMuted(_ isMuted: Bool) throws {
        guard isMuted != source.isMicrophoneMuted else {
            return
        }

        if !isMuted, !isRecording {
            try setRecording(true)
        }

        try throwingExecution("Unable to setMicrophoneMuted:\(isMuted)") {
            source.setMicrophoneMuted(isMuted)
        }

        isMicrophoneMutedSubject.send(isMuted)
    }

    /// Forces the ADM to recompute whether stereo output is supported.
    @objc public func refreshStereoPlayoutState() {
        source.refreshStereoPlayoutState()
    }

    /// Gates whether the internal `AVAudioEngine` may start/stop for input and output.
    ///
    /// This flag has the highest priority over any API that may start the engine
    /// (e.g., enabling the mic, ``startLocalRecording()``, or starting playback).
    ///
    /// - Behavior:
    ///   - When set to a disabled availability, the engine will stop if running,
    ///     and it will not start, even if recording or playback is requested.
    ///   - When set back to enabled, the engine will start as soon as possible
    ///     if recording and/or playback had been previously requested while disabled
    ///     (i.e., pending requests are honored once availability allows).
    ///
    /// This is useful when you need to set up connections without touching the audio
    /// device yet (e.g., CallKit flows), or to guarantee the engine remains off
    /// regardless of subscription/publication requests.
    public func setEngineAvailability(_ availability: RTCAudioEngineAvailability) -> Int {
        source.setEngineAvailability(availability)
    }

    /// The current engine availability for input and output.
    public var engineAvailability: RTCAudioEngineAvailability {
        source.engineAvailability
    }

    // MARK: - RTCAudioDeviceModuleDelegate

    /// Receives speech activity notifications emitted by WebRTC VAD.
    public func audioDeviceModule(
        _ audioDeviceModule: RTCAudioDeviceModule,
        didReceiveSpeechActivityEvent speechActivityEvent: RTCSpeechActivityEvent
    ) {
        switch speechActivityEvent {
        case .started:
            NSLog("[AudioDeviceModule] speechActivityStarted")
            subject.send(.speechActivityStarted)
        case .ended:
            NSLog("[AudioDeviceModule] speechActivityEnded")
            subject.send(.speechActivityEnded)
        @unknown default:
            break
        }
        
        // Forward to observer
        delegateObserver.audioDeviceModule(audioDeviceModule, didReceiveSpeechActivityEvent: speechActivityEvent)
    }

    /// Stores the created engine reference and emits an event so observers can
    /// hook into the audio graph configuration.
    public func audioDeviceModule(
        _ audioDeviceModule: RTCAudioDeviceModule,
        didCreateEngine engine: AVAudioEngine
    ) -> Int {
        self.engine = engine
        subject.send(.didCreateAudioEngine(engine))
        
        // Forward to observer
        delegateObserver.audioDeviceModule(audioDeviceModule, didCreateEngine: engine)
        
        return Constant.successResult
    }

    /// Keeps local playback/recording state in sync as WebRTC enables the
    /// corresponding engine paths. Runs the process-wide `willEnable` hooks
    /// first; the first non-zero result fails the enable and is returned as-is.
    public func audioDeviceModule(
        _ audioDeviceModule: RTCAudioDeviceModule,
        willEnableEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int {
        for entry in Self.engineHooksSnapshot() {
            guard let willEnable = entry.willEnable else { continue }
            let result = willEnable(isPlayoutEnabled, isRecordingEnabled)
            if result != Constant.successResult {
                NSLog("[AudioDeviceModule] willEnable hook failed with \(result)")
                return result
            }
        }

        subject.send(
            .willEnableAudioEngine(
                engine,
                isPlayoutEnabled: isPlayoutEnabled,
                isRecordingEnabled: isRecordingEnabled
            )
        )
        isPlayingSubject.send(isPlayoutEnabled)
        isRecordingSubject.send(isRecordingEnabled)
        
        // Forward to observer
        delegateObserver.audioDeviceModule(
            audioDeviceModule,
            willEnableEngine: engine,
            isPlayoutEnabled: isPlayoutEnabled,
            isRecordingEnabled: isRecordingEnabled
        )
        
        return Constant.successResult
    }

    /// Mirrors state when the engine is about to start running and delivering
    /// audio samples. Runs the process-wide `willStart` hooks first.
    public func audioDeviceModule(
        _ audioDeviceModule: RTCAudioDeviceModule,
        willStartEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int {
        for entry in Self.engineHooksSnapshot() {
            entry.willStart?(isPlayoutEnabled, isRecordingEnabled)
        }

        subject.send(
            .willStartAudioEngine(
                engine,
                isPlayoutEnabled: isPlayoutEnabled,
                isRecordingEnabled: isRecordingEnabled
            )
        )
        isPlayingSubject.send(isPlayoutEnabled)
        isRecordingSubject.send(isRecordingEnabled)

        // Forward to observer
        delegateObserver.audioDeviceModule(
            audioDeviceModule,
            willStartEngine: engine,
            isPlayoutEnabled: isPlayoutEnabled,
            isRecordingEnabled: isRecordingEnabled
        )

        return Constant.successResult
    }

    /// Updates state and notifies observers once the engine has completely
    /// stopped.
    public func audioDeviceModule(
        _ audioDeviceModule: RTCAudioDeviceModule,
        didStopEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int {
        subject.send(
            .didStopAudioEngine(
                engine,
                isPlayoutEnabled: isPlayoutEnabled,
                isRecordingEnabled: isRecordingEnabled
            )
        )
        isPlayingSubject.send(isPlayoutEnabled)
        isRecordingSubject.send(isRecordingEnabled)
        
        // Forward to observer
        delegateObserver.audioDeviceModule(
            audioDeviceModule,
            didStopEngine: engine,
            isPlayoutEnabled: isPlayoutEnabled,
            isRecordingEnabled: isRecordingEnabled
        )
        
        return Constant.successResult
    }

    /// Tracks when the engine has been disabled after stopping so clients can
    /// react (e.g., rebuilding audio graphs). Runs the process-wide `didDisable`
    /// hooks first.
    public func audioDeviceModule(
        _ audioDeviceModule: RTCAudioDeviceModule,
        didDisableEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int {
        for entry in Self.engineHooksSnapshot() {
            entry.didDisable?(isPlayoutEnabled, isRecordingEnabled)
        }

        subject.send(
            .didDisableAudioEngine(
                engine,
                isPlayoutEnabled: isPlayoutEnabled,
                isRecordingEnabled: isRecordingEnabled
            )
        )
        isPlayingSubject.send(isPlayoutEnabled)
        isRecordingSubject.send(isRecordingEnabled)
        
        // Forward to observer
        delegateObserver.audioDeviceModule(
            audioDeviceModule,
            didDisableEngine: engine,
            isPlayoutEnabled: isPlayoutEnabled,
            isRecordingEnabled: isRecordingEnabled
        )
        
        return Constant.successResult
    }

    /// Clears internal references before WebRTC disposes the engine.
    public func audioDeviceModule(
        _ audioDeviceModule: RTCAudioDeviceModule,
        willReleaseEngine engine: AVAudioEngine
    ) -> Int {
        if self.engine === engine {
            self.engine = nil
        }
        subject.send(.willReleaseAudioEngine(engine))
        audioLevelsAdapter.uninstall(on: 0)
        
        // Forward to observer
        delegateObserver.audioDeviceModule(audioDeviceModule, willReleaseEngine: engine)
        
        return Constant.successResult
    }

    /// Keeps observers informed when WebRTC sets up the input graph and installs
    /// an audio level tap to monitor microphone activity.
    public func audioDeviceModule(
        _ audioDeviceModule: RTCAudioDeviceModule,
        engine: AVAudioEngine,
        configureInputFromSource source: AVAudioNode?,
        toDestination destination: AVAudioNode,
        format: AVAudioFormat,
        context: [AnyHashable: Any]
    ) -> Int {
        subject.send(
            .configureInputFromSource(
                engine,
                source: source,
                destination: destination,
                format: format
            )
        )
        audioLevelsAdapter.installInputTap(
            on: destination,
            format: format,
            bus: 0,
            bufferSize: 1024
        )
        
        // Forward to observer
        delegateObserver.audioDeviceModule(
            audioDeviceModule,
            engine: engine,
            configureInputFromSource: source,
            toDestination: destination,
            format: format,
            context: context
        )
        
        return Constant.successResult
    }

    /// Emits an event whenever WebRTC reconfigures the output graph.
    public func audioDeviceModule(
        _ audioDeviceModule: RTCAudioDeviceModule,
        engine: AVAudioEngine,
        configureOutputFromSource source: AVAudioNode,
        toDestination destination: AVAudioNode?,
        format: AVAudioFormat,
        context: [AnyHashable: Any]
    ) -> Int {
        subject.send(
            .configureOutputFromSource(
                engine,
                source: source,
                destination: destination,
                format: format
            )
        )
        
        // Forward to observer
        delegateObserver.audioDeviceModule(
            audioDeviceModule,
            engine: engine,
            configureOutputFromSource: source,
            toDestination: destination,
            format: format,
            context: context
        )
        
        return Constant.successResult
    }

    /// Currently unused: CallKit/RoutePicker own the device selection UX.
    public func audioDeviceModuleDidUpdateDevices(
        _ audioDeviceModule: RTCAudioDeviceModule
    ) {
        // Forward to observer
        delegateObserver.audioDeviceModuleDidUpdateDevices(audioDeviceModule)
    }

    /// Mirrors state changes coming from CallKit/WebRTC voice-processing
    /// controls so UI can reflect the correct toggles.
    public func audioDeviceModule(
        _ module: RTCAudioDeviceModule,
        didUpdateAudioProcessingState state: RTCAudioProcessingState
    ) {
        subject.send(
            .didUpdateAudioProcessingState(
                voiceProcessingEnabled: state.voiceProcessingEnabled,
                voiceProcessingBypassed: state.voiceProcessingBypassed,
                voiceProcessingAGCEnabled: state.voiceProcessingAGCEnabled,
                stereoPlayoutEnabled: state.stereoPlayoutEnabled
            )
        )
        isVoiceProcessingEnabledSubject.send(state.voiceProcessingEnabled)
        isVoiceProcessingBypassedSubject.send(state.voiceProcessingBypassed)
        isVoiceProcessingAGCEnabledSubject.send(state.voiceProcessingAGCEnabled)
        isStereoPlayoutEnabledSubject.send(state.stereoPlayoutEnabled)
        
        // Forward to observer
        delegateObserver.audioDeviceModule(module, didUpdateAudioProcessingState: state)
    }

    /// Mirrors the subset of properties that can be encoded for debugging.
    private enum CodingKeys: String, CodingKey {
        case isPlaying
        case isRecording
        case isMicrophoneMuted
        case isStereoPlayoutEnabled
        case isVoiceProcessingBypassed
        case isVoiceProcessingEnabled
        case isVoiceProcessingAGCEnabled

        case audioLevel
    }

    /// Serializes the module state, primarily for diagnostic payloads.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isPlaying, forKey: .isPlaying)
        try container.encode(isRecording, forKey: .isRecording)
        try container.encode(isMicrophoneMuted, forKey: .isMicrophoneMuted)
        try container.encode(isStereoPlayoutEnabled, forKey: .isStereoPlayoutEnabled)
        try container.encode(isVoiceProcessingBypassed, forKey: .isVoiceProcessingBypassed)
        try container.encode(isVoiceProcessingEnabled, forKey: .isVoiceProcessingEnabled)
        try container.encode(isVoiceProcessingAGCEnabled, forKey: .isVoiceProcessingAGCEnabled)
        try container.encode(audioLevel, forKey: .audioLevel)
    }

    // MARK: - Private helpers

    /// Runs a WebRTC ADM call and translates its integer result into an
    /// `AudioDeviceError` enriched with call-site metadata.
    private func throwingExecution(
        _ message: @autoclosure () -> String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line,
        _ operation: () -> Int
    ) throws {
        let result = operation()

        guard result != Constant.successResult else {
            return
        }

        throw AudioDeviceError.operationFailed(message(), result)
    }
}
