package com.oney.WebRTCModule;

import android.util.Log;

import androidx.annotation.Nullable;

import org.webrtc.PeerConnectionFactory;

import java.util.UUID;

/**
 * Holds the single live {@link PeerConnectionFactoryProvider}.
 *
 * <p>Only ONE factory — hence one ADM — may be live at a time. The SDK builds the call factory at
 * join ({@link #create}) and disposes it at leave ({@link #dispose}). A lazily-built default covers
 * bare-fork / non-Stream globals usage when no call factory exists.
 *
 * <p>{@link WebRTCModule} supplies a {@link FactoryBuilder} that carries the native build inputs
 * (shared codec factories, ADM configuration, speech-activity listener); the registry only decides
 * <em>when</em> a factory is created, resolved, and disposed.
 */
class PeerConnectionFactoryRegistry {
    private static final String TAG = "PCFactoryRegistry";

    interface FactoryBuilder {
        PeerConnectionFactoryProvider build(String id, boolean bypassVoiceProcessing);
    }

    private final FactoryBuilder builder;

    @Nullable
    private PeerConnectionFactoryProvider currentFactory;

    private boolean currentIsBareForkDefault = false;

    private boolean disposed = false;

    PeerConnectionFactoryRegistry(FactoryBuilder builder) {
        this.builder = builder;
    }

    /**
     * Returns the live factory, building a bare-fork default on first use. Returns {@code null}
     * only after {@link #disposeAll()}.
     *
     * <p>A live per-call factory is returned as-is so ADM consumers act on the call's single ADM
     * rather than a phantom default. A real default is built only when no factory exists at all.
     */
    synchronized PeerConnectionFactoryProvider getOrCreateDefault() {
        if (currentFactory != null && !currentFactory.isDisposed()) {
            if (currentIsBareForkDefault) {
                // An op resolved to a lingering bare-fork default (no call factory ever took its
                // place). Normal in bare-fork use; in the Stream SDK it means an op fired outside
                // the join↔leave window. The build that created it already dumped a stack trace.
                Log.w(TAG, "⚠️ op resolved to the bare-fork DEFAULT factory " + currentFactory.id
                        + " (outside call window)");
            }
            return currentFactory;
        }
        if (disposed) {
            return null; // torn down; do not rebuild
        }
        return buildAndSetCurrent(false, true);
    }

    @Nullable
    PeerConnectionFactory defaultPeerConnectionFactory() {
        PeerConnectionFactoryProvider factory = getOrCreateDefault();
        return factory == null ? null : factory.factory;
    }

    /**
     * Returns the live factory if one exists, else null — NEVER builds a default. For ADM consumers
     * (in-call manager) that must follow the call's factory but must not trigger a default build
     * when no call is active (e.g. pre-join / post-leave).
     */
    @Nullable
    synchronized PeerConnectionFactoryProvider resolveCurrentOrNil() {
        if (currentFactory != null && !currentFactory.isDisposed()) {
            return currentFactory;
        }
        return null;
    }

    synchronized PeerConnectionFactoryProvider create(boolean bypassVoiceProcessing) {
        if (disposed) {
            throw new IllegalStateException("PeerConnectionFactoryRegistry is disposed");
        }
        // One factory at a time. A bare-fork default built pre-join is replaced cleanly. A live call
        // factory means a second concurrent join, which the single-ADM constraint cannot support:
        // keep it so the in-progress call's peer connections stay valid, and return it unchanged
        // rather than tearing the live call down.
        if (currentFactory != null && !currentFactory.isDisposed()) {
            PeerConnectionFactoryProvider existing = currentFactory;
            if (currentIsBareForkDefault) {
                Log.d(TAG, "disposed stale default before creating call factory");
                try {
                    existing.dispose();
                } catch (Exception e) {
                    Log.w(TAG, "create(): error disposing stale default " + existing.id, e);
                }
            } else {
                Log.w(TAG, "⚠️ call factory " + existing.id
                        + " already live; refusing to create a second — concurrent calls are unsupported");
                return existing;
            }
        }
        return buildAndSetCurrent(bypassVoiceProcessing, false);
    }

    private PeerConnectionFactoryProvider buildAndSetCurrent(boolean bypassVoiceProcessing, boolean isDefault) {
        String id = UUID.randomUUID().toString();
        PeerConnectionFactoryProvider factory = builder.build(id, bypassVoiceProcessing);
        currentFactory = factory;
        currentIsBareForkDefault = isDefault;
        String kind = isDefault ? "DEFAULT (bare-fork)" : "per-call";
        Log.d(TAG, "🏭 CREATED " + kind + " factory " + id + " (bypassVoiceProcessing=" + bypassVoiceProcessing + ")");
        if (isDefault) {
            // Should not happen during normal Stream SDK operation: every consumer resolves through
            // the live call factory built at join. A default build means something reached the
            // registry with no call factory present — dump the stack so the caller is identifiable.
            Log.w(TAG, "⚠️ default factory built with no call factory present. Trigger:",
                    new Throwable("default factory creation trace"));
        }
        return factory;
    }

    /**
     * Snapshot of the PeerConnection ids the live factory owns, or an empty list if none is live.
     * Returned as a copy so callers can dispose PCs (which mutates the underlying set via
     * {@link #unbindPeerConnection}) while iterating.
     */
    java.util.List<Integer> currentOwnedPcIds() {
        if (currentFactory == null) {
            return java.util.Collections.emptyList();
        }
        return new java.util.ArrayList<>(currentFactory.ownedPcIds);
    }

    /**
     * Snapshot of the track ids the live factory owns, or an empty list if none is live. Returned as
     * a copy so callers can dispose tracks (which mutates the underlying set via {@link #forgetTrack})
     * while iterating.
     */
    java.util.List<String> currentOwnedTrackIds() {
        if (currentFactory == null) {
            return java.util.Collections.emptyList();
        }
        return new java.util.ArrayList<>(currentFactory.ownedTrackIds);
    }

    void bindPeerConnection(int pcId, PeerConnectionFactoryProvider factory) {
        factory.ownedPcIds.add(pcId);
        Log.d(TAG, "bound pc " + pcId + " -> factory " + factory.id);
    }

    void unbindPeerConnection(int pcId) {
        if (currentFactory != null) {
            currentFactory.ownedPcIds.remove(pcId);
        }
    }

    void forgetTrack(String trackId) {
        if (currentFactory != null) {
            currentFactory.ownedTrackIds.remove(trackId);
        }
    }

    synchronized boolean disposeCurrent() {
        if (currentFactory == null) {
            Log.w(TAG, "disposeCurrent(): no live factory (already disposed?)");
            return false;
        }
        boolean wasDefault = currentIsBareForkDefault;
        String factoryId = currentFactory.id;
        currentFactory.dispose();
        currentFactory = null;
        currentIsBareForkDefault = false;
        Log.d(TAG, "🗑️ DISPOSED " + (wasDefault ? "DEFAULT (bare-fork)" : "per-call") + " factory " + factoryId);
        return true;
    }

    synchronized void disposeAll() {
        disposed = true;
        if (currentFactory != null) {
            String id = currentFactory.id;
            try {
                currentFactory.dispose();
                Log.d(TAG, "🗑️ DISPOSED factory " + id + " (module teardown)");
            } catch (Exception e) {
                Log.w(TAG, "disposeAll(): error disposing factory " + id, e);
            }
        }
        currentFactory = null;
        currentIsBareForkDefault = false;
    }
}
