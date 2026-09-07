package com.oney.WebRTCModule;

import android.util.Base64;
import android.util.Log;

import androidx.annotation.Nullable;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.ReadableType;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.WritableMap;

import org.webrtc.EncryptionManager;
import org.webrtc.RtpReceiver;
import org.webrtc.RtpSender;

import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Bridge over the native {@link EncryptionManager} (framed AES-GCM E2EE). Only control operations
 * and events cross the bridge, never media frames: the transforms run entirely inside libwebrtc.
 *
 * <p>The native binding reports failures by throwing unchecked exceptions while iOS returns an
 * error object. Both are normalized here into a {@code {error}} result map so the JS surface is
 * identical on both platforms.
 */
class EncryptionManagerBridge {
    static final String TAG = EncryptionManagerBridge.class.getCanonicalName();

    private final WebRTCModule webRTCModule;
    private final Map<String, EncryptionManager> managers = new HashMap<>();

    EncryptionManagerBridge(WebRTCModule webRTCModule) {
        this.webRTCModule = webRTCModule;
    }

    boolean isSupported() {
        return EncryptionManager.isSupported();
    }

    WritableMap create(ReadableMap options) {
        String userId = getString(options, "userId");
        if (userId == null || userId.isEmpty()) {
            return error("encryptionManagerCreate() requires a non-empty userId");
        }

        try {
            Integer algorithm = getInt(options, "algorithm");
            EncryptionManager manager = algorithm != null
                    ? EncryptionManager.create(userId, EncryptionManager.Algorithm.values()[algorithm])
                    : EncryptionManager.create(userId);

            String handle = UUID.randomUUID().toString();
            // The observer is wired before the handle is returned so no event can be missed.
            manager.setObserver(new EventObserver(handle));
            managers.put(handle, manager);

            WritableMap result = Arguments.createMap();
            result.putString("handle", handle);
            return result;
        } catch (RuntimeException e) {
            return error(e);
        }
    }

    WritableMap dispose(ReadableMap options) {
        String handle = getString(options, "handle");
        EncryptionManager manager = handle != null ? managers.get(handle) : null;
        if (manager == null) {
            // Disposing twice, or after a reload, is not an error.
            return Arguments.createMap();
        }

        try {
            manager.setObserver(null);
            manager.dispose();
        } catch (RuntimeException e) {
            // Deregistered only once the native cleanup succeeds, so a failed manager stays
            // reachable for a later dispose() or for disposeAll() on teardown.
            return error(e);
        }

        managers.remove(handle);
        return Arguments.createMap();
    }

    /**
     * Disposes every live manager. Called on module teardown (e.g. a bundle reload), where the peer
     * connections are about to be closed underneath any attached transform and nothing in JS can
     * survive to dispose them itself.
     */
    void disposeAll() {
        for (Map.Entry<String, EncryptionManager> entry : managers.entrySet()) {
            try {
                entry.getValue().setObserver(null);
                entry.getValue().dispose();
            } catch (RuntimeException e) {
                Log.w(TAG, "disposeAll(): error disposing manager " + entry.getKey(), e);
            }
        }
        managers.clear();
    }

    WritableMap setKey(ReadableMap options) {
        EncryptionManager manager = getManager(options);
        if (manager == null) {
            return error("encryptionManagerSetKey(): manager not found");
        }

        String userId = getString(options, "userId");
        Integer keyIndex = getKeyIndex(options);
        byte[] key = getKey(options);
        if (userId == null || userId.isEmpty() || keyIndex == null || key == null) {
            return error("encryptionManagerSetKey() requires userId, a keyIndex in 0-255 and key");
        }

        try {
            manager.setKey(userId, keyIndex, key);
            return Arguments.createMap();
        } catch (RuntimeException e) {
            return error(e);
        }
    }

    WritableMap setSharedKey(ReadableMap options) {
        EncryptionManager manager = getManager(options);
        if (manager == null) {
            return error("encryptionManagerSetSharedKey(): manager not found");
        }

        Integer keyIndex = getKeyIndex(options);
        byte[] key = getKey(options);
        if (keyIndex == null || key == null) {
            return error("encryptionManagerSetSharedKey() requires a keyIndex in 0-255 and key");
        }

        try {
            manager.setSharedKey(keyIndex, key);
            return Arguments.createMap();
        } catch (RuntimeException e) {
            return error(e);
        }
    }

    WritableMap removeKey(ReadableMap options) {
        EncryptionManager manager = getManager(options);
        if (manager == null) {
            return error("encryptionManagerRemoveKey(): manager not found");
        }

        String userId = getString(options, "userId");
        Integer keyIndex = getKeyIndex(options);
        if (userId == null || userId.isEmpty() || keyIndex == null) {
            return error("encryptionManagerRemoveKey() requires userId and a keyIndex in 0-255");
        }

        try {
            manager.removeKey(userId, keyIndex);
            return Arguments.createMap();
        } catch (RuntimeException e) {
            return error(e);
        }
    }

    WritableMap removeAllKeys(ReadableMap options) {
        EncryptionManager manager = getManager(options);
        if (manager == null) {
            return error("encryptionManagerRemoveAllKeys(): manager not found");
        }

        String userId = getString(options, "userId");
        if (userId == null || userId.isEmpty()) {
            return error("encryptionManagerRemoveAllKeys() requires userId");
        }

        try {
            manager.removeAllKeys(userId);
            return Arguments.createMap();
        } catch (RuntimeException e) {
            return error(e);
        }
    }

    WritableMap removeSharedKey(ReadableMap options) {
        EncryptionManager manager = getManager(options);
        if (manager == null) {
            return error("encryptionManagerRemoveSharedKey(): manager not found");
        }

        Integer keyIndex = getKeyIndex(options);
        if (keyIndex == null) {
            return error("encryptionManagerRemoveSharedKey() requires a keyIndex in 0-255");
        }

        try {
            manager.removeSharedKey(keyIndex);
            return Arguments.createMap();
        } catch (RuntimeException e) {
            return error(e);
        }
    }

    WritableMap encrypt(ReadableMap options) {
        EncryptionManager manager = getManager(options);
        if (manager == null) {
            return error("encryptionManagerEncrypt(): manager not found");
        }

        Integer peerConnectionId = getInt(options, "peerConnectionId");
        String senderId = getString(options, "senderId");
        if (peerConnectionId == null || senderId == null) {
            return error("encryptionManagerEncrypt() requires peerConnectionId and senderId");
        }

        PeerConnectionObserver pco = webRTCModule.getPeerConnectionObserver(peerConnectionId);
        if (pco == null) {
            return error("encryptionManagerEncrypt(): peer connection " + peerConnectionId + " not found");
        }

        RtpSender sender = pco.getSender(senderId);
        if (sender == null) {
            return error("encryptionManagerEncrypt(): sender " + senderId + " not found");
        }

        try {
            manager.encrypt(sender, getString(options, "codec"), parseTrackType(options));
            return Arguments.createMap();
        } catch (RuntimeException e) {
            return error(e);
        }
    }

    WritableMap decrypt(ReadableMap options) {
        EncryptionManager manager = getManager(options);
        if (manager == null) {
            return error("encryptionManagerDecrypt(): manager not found");
        }

        Integer peerConnectionId = getInt(options, "peerConnectionId");
        String receiverId = getString(options, "receiverId");
        String userId = getString(options, "userId");
        if (peerConnectionId == null || receiverId == null || userId == null || userId.isEmpty()) {
            return error("encryptionManagerDecrypt() requires peerConnectionId, receiverId and userId");
        }

        PeerConnectionObserver pco = webRTCModule.getPeerConnectionObserver(peerConnectionId);
        if (pco == null) {
            return error("encryptionManagerDecrypt(): peer connection " + peerConnectionId + " not found");
        }

        RtpReceiver receiver = pco.getReceiver(receiverId);
        if (receiver == null) {
            return error("encryptionManagerDecrypt(): receiver " + receiverId + " not found");
        }

        try {
            manager.decrypt(receiver, userId, parseTrackType(options));
            return Arguments.createMap();
        } catch (RuntimeException e) {
            return error(e);
        }
    }

    void enablePerformanceReporting(String handle, boolean enabled) {
        EncryptionManager manager = managers.get(handle);
        if (manager == null) {
            throw new IllegalStateException("manager not found");
        }

        manager.enablePerformanceReporting(enabled);
    }

    void requestKeyState(String handle) {
        EncryptionManager manager = managers.get(handle);
        if (manager == null) {
            throw new IllegalStateException("manager not found");
        }

        manager.requestKeyState();
    }

    private class EventObserver implements EncryptionManager.Observer {
        private final String handle;

        EventObserver(String handle) {
            this.handle = handle;
        }

        @Override
        public void onE2eeEvent(EncryptionManager.E2eeEvent event) {
            WritableMap params = Arguments.createMap();
            params.putString("managerId", handle);
            params.putString("type", event.type.name);
            params.putString("userId", event.userId);

            if (event.trackType != null) {
                params.putInt("trackType", event.trackType.getValue());
            }
            if (event.keyIndex != null) {
                params.putInt("keyIndex", event.keyIndex);
            }
            if (event.version != null) {
                params.putInt("version", event.version);
            }
            if (event.reason != null) {
                params.putString("reason", event.reason);
            }
            if (event.keyState != null) {
                params.putMap("keyState", keyStateToMap(event.keyState));
            }
            if (event.encode != null) {
                params.putArray("encode", trackPerfToArray(event.encode));
            }
            if (event.decode != null) {
                params.putArray("decode", trackPerfToArray(event.decode));
            }

            // This callback runs on the crypto worker; events must be emitted off it.
            ThreadUtils.runOnExecutor(() -> webRTCModule.sendEvent("encryptionManagerEvent", params));
        }
    }

    /** Key fingerprints only; raw key material never crosses the bridge. */
    private static WritableMap keyStateToMap(EncryptionManager.KeyStateReport keyState) {
        WritableArray perUserKeys = Arguments.createArray();
        for (EncryptionManager.UserKey key : keyState.perUserKeys) {
            WritableMap row = Arguments.createMap();
            row.putString("userId", key.userId);
            row.putInt("keyIndex", key.keyIndex);
            row.putString("fingerprint", key.fingerprint);
            perUserKeys.pushMap(row);
        }

        WritableArray sharedKeys = Arguments.createArray();
        for (EncryptionManager.SharedKey key : keyState.sharedKeys) {
            WritableMap row = Arguments.createMap();
            row.putInt("keyIndex", key.keyIndex);
            row.putString("fingerprint", key.fingerprint);
            row.putBoolean("isActive", key.isActive);
            sharedKeys.pushMap(row);
        }

        WritableMap map = Arguments.createMap();
        map.putArray("perUserKeys", perUserKeys);
        map.putArray("sharedKeys", sharedKeys);
        return map;
    }

    private static WritableArray trackPerfToArray(java.util.List<EncryptionManager.TrackPerf> samples) {
        WritableArray rows = Arguments.createArray();
        for (EncryptionManager.TrackPerf sample : samples) {
            WritableMap row = Arguments.createMap();
            row.putString("userId", sample.userId);
            row.putInt("trackType", sample.trackType.getValue());
            if (sample.codec != null) {
                row.putString("codec", sample.codec);
            }
            row.putDouble("fps", sample.fps);
            row.putDouble("maxCryptoMs", sample.maxCryptoMs);
            rows.pushMap(row);
        }

        return rows;
    }

    @Nullable
    private EncryptionManager getManager(ReadableMap options) {
        String handle = getString(options, "handle");
        return handle != null ? managers.get(handle) : null;
    }

    @Nullable
    private static byte[] getKey(ReadableMap options) {
        String key = getString(options, "key");
        if (key == null) {
            return null;
        }

        try {
            return Base64.decode(key, Base64.NO_WRAP);
        } catch (IllegalArgumentException e) {
            Log.w(TAG, "Failed to decode the key: " + e.getMessage());
            return null;
        }
    }

    /**
     * Absent means "read audio vs video from the sender/receiver"; screenshare must be explicit. A
     * value that is present but unusable is rejected rather than inferred: silently falling back
     * would group a screen-share-audio track with the microphone and share its replay window.
     */
    @Nullable
    private static EncryptionManager.TrackType parseTrackType(ReadableMap options) {
        if (!options.hasKey("trackType") || options.isNull("trackType")) {
            return null;
        }

        Integer trackType = getInt(options, "trackType");
        if (trackType == null || trackType < 0 || trackType >= EncryptionManager.TrackType.values().length) {
            throw new IllegalArgumentException("got an unusable trackType");
        }

        return EncryptionManager.TrackType.values()[trackType];
    }

    @Nullable
    private static String getString(ReadableMap options, String key) {
        if (!options.hasKey(key) || options.getType(key) != ReadableType.String) {
            return null;
        }

        return options.getString(key);
    }

    /**
     * A key index is validated before it is narrowed: {@link ReadableMap#getInt} truncates, so a
     * fractional or non-finite index would otherwise land silently on a valid slot instead of being
     * rejected -- {@code removeSharedKey(-0.5)} would delete slot 0.
     */
    @Nullable
    private static Integer getKeyIndex(ReadableMap options) {
        if (!options.hasKey("keyIndex") || options.getType("keyIndex") != ReadableType.Number) {
            return null;
        }

        // NaN fails the first comparison; the range check covers both infinities.
        double keyIndex = options.getDouble("keyIndex");
        if (keyIndex != Math.floor(keyIndex) || keyIndex < 0 || keyIndex > 255) {
            return null;
        }

        return (int) keyIndex;
    }

    @Nullable
    private static Integer getInt(ReadableMap options, String key) {
        if (!options.hasKey(key) || options.getType(key) != ReadableType.Number) {
            return null;
        }

        return options.getInt(key);
    }

    private static WritableMap error(RuntimeException e) {
        String message = e.getMessage();
        return error(message != null ? message : e.getClass().getSimpleName());
    }

    private static WritableMap error(String message) {
        WritableMap result = Arguments.createMap();
        result.putString("error", message);
        return result;
    }
}
