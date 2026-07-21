//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Foundation
import WebRTC

public typealias PeerConnectionFactoryBuilder = (_ factoryId: String, _ bypassVoiceProcessing: Bool)
    -> PeerConnectionFactoryProvider

/// Holds the single live `PeerConnectionFactoryProvider`.
///
/// Only ONE factory — hence one ADM, one `AVAudioEngine` on the shared `AVAudioSession` — may be
/// live at a time (a second engine crashes `IsFormatSampleRateAndChannelCountValid`). The SDK builds
/// the call factory at join (`create`) and disposes it at leave (`dispose`). A lazily-built default
/// covers bare-fork / non-Stream globals usage when no call factory exists.
///
/// `WebRTCModule` supplies the builder closure carrying the native build inputs (shared codec
/// factories, audio-processing module, audio device).
@objc public final class PeerConnectionFactoryRegistry: NSObject {

    private let builder: PeerConnectionFactoryBuilder
    private var currentFactory: PeerConnectionFactoryProvider?
    private var currentIsBareForkDefault = false
    private var disposed = false
    // Recursive so the reentrant resolve() -> getOrCreateDefault() path doesn't deadlock.
    private let lock = NSRecursiveLock()

    @objc public init(builder: @escaping PeerConnectionFactoryBuilder) {
        self.builder = builder
        super.init()
    }

    /// Returns the live factory, building a bare-fork default on first use. Nil only after
    /// `disposeAll()`. A live per-call factory is returned as-is so ADM consumers act on the call's
    /// single ADM. A real default is built only when no factory exists at all.
    @objc public func getOrCreateDefault() -> PeerConnectionFactoryProvider? {
        lock.lock()
        defer { lock.unlock() }
        if let currentFactory = currentFactory, !currentFactory.isDisposed() {
            if currentIsBareForkDefault {
                // An op resolved to a lingering bare-fork default (no call factory ever took its
                // place). Normal in bare-fork use; in the Stream SDK it means an op fired outside
                // the join↔leave window. The build that created it already dumped a stack trace.
                NSLog("[PCFactoryRegistry] ⚠️ op resolved to the bare-fork DEFAULT factory %@ (outside call window)",
                      currentFactory.factoryId)
            }
            return currentFactory
        }
        if disposed {
            return nil
        }
        return buildAndSetCurrent(bypassVoiceProcessing: false, isDefault: true)
    }

    /// Returns the live factory if one exists, else nil — NEVER builds a default. For ADM consumers
    /// (callingx / in-call manager) that must follow the call's factory but must not trigger a
    /// default build when no call is active (e.g. pre-join / post-leave).
    @objc public func resolveCurrentOrNil() -> PeerConnectionFactoryProvider? {
        lock.lock()
        defer { lock.unlock() }
        guard let currentFactory = currentFactory, !currentFactory.isDisposed() else { return nil }
        return currentFactory
    }

    @objc public func create(_ bypassVoiceProcessing: Bool) -> PeerConnectionFactoryProvider? {
        lock.lock()
        defer { lock.unlock() }
        if disposed {
            return nil
        }
        // One factory at a time. A bare-fork default built pre-join is replaced cleanly. A live call
        // factory means a second concurrent join, which the single-ADM/AVAudioEngine constraint
        // cannot support: keep it so the in-progress call's peer connections stay valid, and return
        // it unchanged rather than tearing the live call down.
        if let existing = currentFactory, !existing.isDisposed() {
            if currentIsBareForkDefault {
                NSLog("[PCFactoryRegistry] disposed stale default before creating call factory")
                existing.dispose()
            } else {
                NSLog("[PCFactoryRegistry] ⚠️ call factory %@ already live; refusing to create a second — concurrent calls are unsupported",
                      existing.factoryId)
                return existing
            }
        }
        return buildAndSetCurrent(bypassVoiceProcessing: bypassVoiceProcessing, isDefault: false)
    }

    private func buildAndSetCurrent(bypassVoiceProcessing: Bool, isDefault: Bool) -> PeerConnectionFactoryProvider {
        let factoryId = UUID().uuidString
        let factory = builder(factoryId, bypassVoiceProcessing)
        currentFactory = factory
        currentIsBareForkDefault = isDefault
        let kind = isDefault ? "DEFAULT (bare-fork)" : "per-call"
        NSLog("[PCFactoryRegistry] 🏭 CREATED %@ factory %@ (bypassVoiceProcessing=%@)",
              kind, factoryId, bypassVoiceProcessing ? "true" : "false")
        if isDefault {
            // Should not happen during normal Stream SDK operation: every consumer resolves through
            // the live call factory built at join. A default build means something reached the
            // registry with no call factory present — dump the call stack so the caller is identifiable.
            NSLog("[PCFactoryRegistry] ⚠️ default factory built with no call factory present. Trigger:\n%@",
                  Thread.callStackSymbols.joined(separator: "\n"))
        }
        return factory
    }

    /// Disposes the live call factory and clears it. Returns false when nothing is live.
    @objc public func disposeCurrent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let factory = currentFactory else {
            NSLog("[PCFactoryRegistry] disposeCurrent(): no live factory (already disposed?)")
            return false
        }
        let wasDefault = currentIsBareForkDefault
        let factoryId = factory.factoryId
        factory.dispose()
        currentFactory = nil
        currentIsBareForkDefault = false
        NSLog("[PCFactoryRegistry] 🗑️ DISPOSED %@ factory %@", wasDefault ? "DEFAULT (bare-fork)" : "per-call", factoryId)
        return true
    }

    @objc public func disposeAll() {
        lock.lock()
        defer { lock.unlock() }
        disposed = true
        if let factory = currentFactory {
            factory.dispose()
            NSLog("[PCFactoryRegistry] 🗑️ DISPOSED factory %@ (module teardown)", factory.factoryId)
        }
        currentFactory = nil
        currentIsBareForkDefault = false
    }
}
