package com.oney.WebRTCModule;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;

/**
 * Tells you when the user is talking, by watching how loud the mic is over time.
 *
 * <p>How it works:
 * <ol>
 *   <li>Every ~10 ms the mic gives us a chunk of samples.</li>
 *   <li>Convert each chunk to one "loudness" number in dBFS (decibels relative
 *       to full scale): quiet room ≈ -60 dB, normal speech ≈ -30 to -20 dB,
 *       speaking close to the mic ≈ -15 to -10 dB.</li>
 *   <li>Track two things only: <b>when we last saw a loud chunk</b> and
 *       <b>when the current run of loud chunks started</b>.</li>
 *   <li>Fire {@code onSpeechStarted} once we've had loud chunks for
 *       {@link #START_CONFIRM_MS} in a row. Fire {@code onSpeechEnded} once
 *       {@link #SILENCE_TIMEOUT_MS} has passed with no loud chunks. The
 *       timeout is long enough to span natural between-word pauses.</li>
 * </ol>
 *
 * <p><b>Why this, not a rolling dB average?</b> Android's AGC (automatic gain
 * control) ramps the mic gain back up the instant speech stops, amplifying
 * room noise to -35 or -40 dB. A rolling average over that noise never drops
 * below the threshold, so {@code onSpeechEnded} would never fire. Looking at
 * "time since last loud peak" is immune to that — pauses between words are
 * short, but a real stop is sustained.
 *
 * <p><b>Alignment with stream-video-android.</b> stream-video-android's
 * {@code SoundInputProcessor} fires only an "edge-up" callback and relies on
 * the app layer to infer "stopped". We need the {@code ended} edge to match
 * the iOS contract, so we add the silence-timeout inference here using the
 * same {@code -45 dBFS} threshold they use.
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

    /** Above this dBFS level a chunk counts as "loud". Matches stream-video-android. */
    private static final double THRESHOLD_DB = -45.0;
    /** Require loud chunks for this long before firing started (rejects door slams). */
    private static final long START_CONFIRM_MS = 150;
    /** Fire ended after this long with no loud chunk (spans natural between-word pauses). */
    private static final long SILENCE_TIMEOUT_MS = 900;

    private final Listener listener;

    private boolean isSpeaking = false;
    /** Start of the current run of above-threshold chunks, or -1 if last chunk was quiet. */
    private long firstLoudMs = -1;
    /** Last time any chunk was above threshold, or -1 if never (or cleared on ended). */
    private long lastLoudMs = -1;

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

        // Normalize int16 samples to [-1.0, 1.0] BEFORE squaring so the resulting
        // dB value is dBFS (decibels relative to full scale). Without this, dB is
        // computed against a 1-sample-unit reference and silence reads as ~+40.
        double sumSquares = 0;
        for (int i = 0; i < numSamples; i++) {
            double sample = shorts.get(i) / (double) Short.MAX_VALUE;
            sumSquares += sample * sample;
        }

        double rms = Math.sqrt(sumSquares / numSamples);
        double db = (rms > 0) ? 20.0 * Math.log10(rms) : -100.0;

        long now = System.currentTimeMillis();

        if (db > THRESHOLD_DB) {
            // Loud chunk. Open a start window if one isn't already open, and
            // remember this as the most recent loud chunk for ended timing.
            lastLoudMs = now;
            if (firstLoudMs < 0) {
                firstLoudMs = now;
            }
            if (!isSpeaking && now - firstLoudMs >= START_CONFIRM_MS) {
                isSpeaking = true;
                listener.onSpeechStarted();
            }
        } else {
            // Quiet chunk. Cancel any in-progress start confirmation. If we're
            // already speaking, fire ended once the silence is long enough.
            firstLoudMs = -1;
            if (isSpeaking && lastLoudMs > 0 && now - lastLoudMs >= SILENCE_TIMEOUT_MS) {
                isSpeaking = false;
                lastLoudMs = -1;
                listener.onSpeechEnded();
            }
        }
    }

    /** Wipes state. Call on recorder start. No event fires. */
    void reset() {
        isSpeaking = false;
        firstLoudMs = -1;
        lastLoudMs = -1;
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
