package com.oney.WebRTCModule;

import androidx.annotation.Nullable;

import org.webrtc.CapturerObserver;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSink;

/**
 * A {@link CapturerObserver} that fans captured frames out to two consumers:
 *
 * <ol>
 *   <li>a {@link VideoSink} renderer — the lobby camera preview, and</li>
 *   <li>an optional downstream {@link CapturerObserver} — the per-call {@code VideoSource}'s
 *       observer, attached at join.</li>
 * </ol>
 *
 * <p>Android's {@code VideoCapturer.initialize(...)} binds the capturer to a single observer for the
 * capturer's lifetime. Installing this fan-out as that observer lets one running camera session be
 * reused across the lobby -> join hand-off: the preview renders from the start, and the per-call
 * {@code VideoSource}'s observer is attached as {@code downstream} at join by flipping the pointer.
 * The camera never closes; frames simply start flowing to the WebRTC track in addition to the
 * preview.
 *
 * <p>All mutable fields are {@code volatile}: {@link #onFrameCaptured} runs on the capturer's frame
 * thread, while {@link #setDownstream}/{@link #setRenderer} are called from the getUserMedia worker
 * and the UI thread respectively.
 */
class FanoutCapturerObserver implements CapturerObserver {
    @Nullable
    private volatile VideoSink renderer;
    @Nullable
    private volatile CapturerObserver downstream;
    private volatile boolean started;

    FanoutCapturerObserver(@Nullable VideoSink renderer) {
        this.renderer = renderer;
    }

    void setRenderer(@Nullable VideoSink renderer) {
        this.renderer = renderer;
    }

    /**
     * Attaches (or clears) the downstream observer — the per-call {@code VideoSource}'s observer. If
     * the capturer is already running, the downstream missed the original {@code onCapturerStarted},
     * so replay it before frames begin flowing.
     */
    void setDownstream(@Nullable CapturerObserver downstream) {
        if (downstream != null && started) {
            downstream.onCapturerStarted(true);
        }
        this.downstream = downstream;
    }

    @Override
    public void onCapturerStarted(boolean success) {
        started = success;
        CapturerObserver d = downstream;
        if (d != null) {
            d.onCapturerStarted(success);
        }
    }

    @Override
    public void onCapturerStopped() {
        started = false;
        CapturerObserver d = downstream;
        if (d != null) {
            d.onCapturerStopped();
        }
    }

    @Override
    public void onFrameCaptured(VideoFrame frame) {
        VideoSink r = renderer;
        if (r != null) {
            r.onFrame(frame);
        }
        CapturerObserver d = downstream;
        if (d != null) {
            d.onFrameCaptured(frame);
        }
    }
}
