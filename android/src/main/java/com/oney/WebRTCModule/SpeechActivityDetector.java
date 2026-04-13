package com.oney.WebRTCModule;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;
import java.util.Iterator;
import java.util.Map;
import java.util.TreeMap;

/**
 * Tells you when the user is talking, by measuring how loud the mic is.
 *
 * <p>How it works:
 * <ol>
 *   <li>Every ~10 ms the mic gives us a chunk of samples.</li>
 *   <li>Convert each chunk to one "loudness" number in decibels (dB):
 *       quiet room ≈ -60 dB, normal speech ≈ -30 to -20 dB.</li>
 *   <li>Keep the last 600 ms of dB values in a sliding window and average them.</li>
 *   <li>If the average crosses {@link #THRESHOLD_DB} (-45 dB) and stays on the
 *       other side for {@link #HYSTERESIS_MS} (200 ms), flip state and fire
 *       {@code onSpeechStarted} / {@code onSpeechEnded}. The 200 ms wait
 *       prevents flapping when the average bounces around the threshold.</li>
 * </ol>
 *
 * <p><b>Not "real" voice recognition.</b> This only looks at energy/loudness,
 * not voice features. Loud non-voice sounds (typing, door slams, music) will
 * trigger {@code onSpeechStarted}. iOS uses Apple's hardware VAD which is
 * smarter, but Android has no equivalent — same tradeoff stream-video-android
 * lives with.
 *
 * <p>Thread-safety: single-threaded — only the WebRTC audio thread should call
 * {@link #processBuffer}. Listener callbacks fire synchronously on that thread;
 * the listener is responsible for dispatching to the JS thread.
 */
class SpeechActivityDetector {

    interface Listener {
        void onSpeechStarted();
        void onSpeechEnded();
    }

    private static final double THRESHOLD_DB = -45.0;
    private static final long WINDOW_MS = 600;
    private static final long HYSTERESIS_MS = 200;

    private final Listener listener;
    private final TreeMap<Long, Double> windowEntries = new TreeMap<>();

    private boolean isSpeaking = false;
    /** Timestamp at which we first observed the candidate (opposite) state. */
    private long candidateStateStartMs = -1;

    SpeechActivityDetector(Listener listener) {
        this.listener = listener;
    }

    /**
     * Feed one mic chunk through the detector. Reads PCM16 LE samples from
     * {@code audioBuffer} without mutating its position/limit. May fire a
     * listener callback synchronously if state flips.
     *
     * <p>Must be called on the WebRTC audio thread, BEFORE any code that mutates
     * {@code audioBuffer} (e.g. screen-audio mixing) — otherwise the detector
     * sees post-mix audio and triggers on system sounds.
     */
    void processBuffer(ByteBuffer audioBuffer, int bytesRead) {
        if (bytesRead <= 0) {
            return;
        }

        // Work on a duplicate so we never mutate the caller's position/limit.
        ByteBuffer buf = audioBuffer.duplicate();
        buf.position(0);
        buf.limit(bytesRead);
        buf.order(ByteOrder.LITTLE_ENDIAN);
        ShortBuffer shorts = buf.asShortBuffer();

        int numSamples = shorts.remaining();
        if (numSamples == 0) {
            return;
        }

        double sumSquares = 0;
        for (int i = 0; i < numSamples; i++) {
            double sample = shorts.get(i);
            sumSquares += sample * sample;
        }

        double rms = Math.sqrt(sumSquares / numSamples);
        double db = (rms > 0) ? 20.0 * Math.log10(rms) : -100.0;

        long now = System.currentTimeMillis();

        // Add the new entry and prune stale ones.
        windowEntries.put(now, db);
        long cutoff = now - WINDOW_MS;
        Iterator<Map.Entry<Long, Double>> it = windowEntries.entrySet().iterator();
        while (it.hasNext()) {
            if (it.next().getKey() < cutoff) {
                it.remove();
            } else {
                break; // TreeMap is sorted — remaining entries are within the window.
            }
        }

        // Compute window average dB.
        double sum = 0;
        for (double value : windowEntries.values()) {
            sum += value;
        }
        double avgDb = sum / windowEntries.size();

        boolean aboveThreshold = avgDb > THRESHOLD_DB;

        if (aboveThreshold == isSpeaking) {
            // State matches — reset hysteresis counter.
            candidateStateStartMs = -1;
        } else {
            // State differs from current — track how long.
            if (candidateStateStartMs < 0) {
                candidateStateStartMs = now;
            }
            if (now - candidateStateStartMs >= HYSTERESIS_MS) {
                isSpeaking = aboveThreshold;
                candidateStateStartMs = -1;
                if (isSpeaking) {
                    listener.onSpeechStarted();
                } else {
                    listener.onSpeechEnded();
                }
            }
        }
    }

    /** Wipes the sliding window and state. Call on recorder start. No event fires. */
    void reset() {
        windowEntries.clear();
        isSpeaking = false;
        candidateStateStartMs = -1;
    }

    /**
     * Call on recorder stop. If we were in {@code started}, force-fires
     * {@code onSpeechEnded} so JS doesn't get latched, then resets.
     */
    void onRecordStop() {
        if (isSpeaking) {
            listener.onSpeechEnded();
        }
        reset();
    }
}
