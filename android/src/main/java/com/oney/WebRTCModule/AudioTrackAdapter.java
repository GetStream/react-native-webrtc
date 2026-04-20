package com.oney.WebRTCModule;

import android.util.Log;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;

import org.webrtc.AudioTrack;
import org.webrtc.AudioTrackSink;

import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Fires the W3C 'unmute' event on a remote audio track when the first
 * decoded PCM buffer arrives via {@link AudioTrackSink}.
 *
 * IMPORTANT — only the initial muted → unmuted transition is detectable.
 * Subsequent mute events (e.g. network stall mid-call) cannot be detected
 * from the sink: Android's audio render path and WebRTC's NetEq synthesize
 * silence / PLC frames whenever RTP stops, so {@code onData} keeps firing
 * at a steady rate regardless of network state. For "remote participant
 * muted their mic" UI, use the out-of-band participant state from your
 * signaling layer — that is the correct source of truth, not this adapter.
 *
 * Only attach to remote audio tracks. {@code AudioTrackSink} callbacks
 * are not delivered for local tracks.
 */
public class AudioTrackAdapter {
    static final String TAG = AudioTrackAdapter.class.getCanonicalName();

    private final Map<String, FirstDataUnmuteSink> sinks = new HashMap<>();
    private final int peerConnectionId;
    private final WebRTCModule webRTCModule;

    public AudioTrackAdapter(WebRTCModule webRTCModule, int peerConnectionId) {
        this.peerConnectionId = peerConnectionId;
        this.webRTCModule = webRTCModule;
    }

    public void addAdapter(AudioTrack audioTrack) {
        String trackId = audioTrack.id();
        if (sinks.containsKey(trackId)) {
            Log.w(TAG, "Attempted to add adapter twice for track ID: " + trackId);
            return;
        }
        FirstDataUnmuteSink sink = new FirstDataUnmuteSink(trackId);
        sinks.put(trackId, sink);
        audioTrack.addSink(sink);
        Log.d(TAG, "Created adapter for " + trackId);
    }

    public void removeAdapter(AudioTrack audioTrack) {
        String trackId = audioTrack.id();
        FirstDataUnmuteSink sink = sinks.remove(trackId);
        if (sink == null) {
            Log.w(TAG, "removeAdapter - no adapter for " + trackId);
            return;
        }
        audioTrack.removeSink(sink);
        Log.d(TAG, "Deleted adapter for " + trackId);
    }

    private class FirstDataUnmuteSink implements AudioTrackSink {
        private final AtomicBoolean fired = new AtomicBoolean(false);
        private final String trackId;

        FirstDataUnmuteSink(String trackId) {
            this.trackId = trackId;
        }

        @Override
        public void onData(ByteBuffer audioData,
                           int bitsPerSample,
                           int sampleRate,
                           int numberOfChannels,
                           int numberOfFrames,
                           long absoluteCaptureTimestampMs) {
            if (!fired.compareAndSet(false, true)) {
                return;
            }
            WritableMap params = Arguments.createMap();
            params.putInt("pcId", peerConnectionId);
            params.putString("trackId", trackId);
            params.putBoolean("muted", false);
            Log.d(TAG, "Unmute event pcId: " + peerConnectionId + " trackId: " + trackId);
            webRTCModule.sendEvent("mediaStreamTrackMuteChanged", params);
        }
    }
}
