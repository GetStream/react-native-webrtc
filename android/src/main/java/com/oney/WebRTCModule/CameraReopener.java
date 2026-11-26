package com.oney.WebRTCModule;

import android.content.Context;
import android.hardware.camera2.CameraManager;
import android.os.Handler;
import android.os.Looper;

/**
 * Opens the camera again after another app took it away.
 *
 * <p>When another app opens a camera, Android closes ours, and libwebrtc stops capturing without
 * ever opening the camera again. This class then:
 * <ol>
 *   <li>tells the listener the video is paused,</li>
 *   <li>waits for Android's "try the camera again" signal,</li>
 *   <li>opens the camera again (same capturer, so the same track continues),</li>
 *   <li>tells the listener the video is back when the first frame arrives.</li>
 * </ol>
 * If opening fails because the other app still has the camera, it waits for the next signal.
 * After {@link #MAX_FAILED_REOPENS} failed tries, or on a camera error that is not about another
 * app, it gives up and the listener ends the track.
 *
 * <p><b>Android 10 (API 29) and newer only.</b> The "try again" signal is
 * {@link CameraManager.AvailabilityCallback#onCameraAccessPrioritiesChanged()}, which does not
 * exist before Android 10. On older versions the signal never comes: the video stays paused until
 * the app turns the camera off and on.
 *
 * <p>Threads: every method can be called from any thread. The state is only read and written on
 * the main thread, except {@link #cameraWanted}, which is guarded by {@link #lock}.
 */
class CameraReopener {

    /** What the camera controller does for this class. */
    interface Listener {
        /** Open the camera again on the same capturer. */
        void reopenCamera();

        /** The video stopped (paused = true) or came back (paused = false). The track stays live. */
        void onPausedChanged(boolean paused);

        /** We could not get the camera back. End the track, so the app shows the camera as off. */
        void onGaveUp();
    }

    private enum State {
        /** The camera works, or the app turned it off. */
        IDLE,
        /** The camera was taken. We are registered with Android and wait for the signal. */
        WAITING_FOR_SIGNAL,
        /** The signal came. The camera opens after {@link #REOPEN_DELAY_MS}. */
        REOPEN_SCHEDULED,
        /** We called reopenCamera() and wait for the first frame or a failure. */
        REOPENING
    }

    /** Gives the other app time to finish closing the camera. */
    private static final long REOPEN_DELAY_MS = 500;

    private static final int MAX_FAILED_REOPENS = 3;

    private final CameraManager cameraManager;
    private final Listener listener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Runnable reopenNowRunnable = this::reopenNow;

    // Main thread only.
    private State state = State.IDLE;
    private int failedReopens = 0;
    private boolean paused = false;

    private final Object lock = new Object();

    /** True while the app wants the camera on (between startCapture and stopCapture). */
    private volatile boolean cameraWanted = false;

    private final CameraManager.AvailabilityCallback retrySignal = new CameraManager.AvailabilityCallback() {
        // No @Override, so this compiles with a compileSdkVersion below 29.
        public void onCameraAccessPrioritiesChanged() {
            onRetrySignal();
        }
    };

    CameraReopener(Context context, Listener listener) {
        this.cameraManager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
        this.listener = listener;
    }

    /**
     * The app turned the camera on (true) or off (false). When it is off, we stop waiting and
     * never open the camera again by ourselves.
     */
    void setCameraWanted(boolean wanted) {
        synchronized (lock) {
            cameraWanted = wanted;
        }
        if (!wanted) {
            mainHandler.post(() -> {
                stopListening();
                mainHandler.removeCallbacks(reopenNowRunnable);
                state = State.IDLE;
                failedReopens = 0;
                // Keep "paused": if the app turns the camera on again, the first frame
                // sends "back".
            });
        }
    }

    /** Android closed our camera, usually because another app opened a camera. */
    void onCameraTaken() {
        mainHandler.post(() -> {
            if (!cameraWanted) {
                return;
            }
            switch (state) {
                case IDLE:
                    setPaused(true);
                    startListening();
                    break;
                case REOPENING:
                    // Our try failed: the other app still has the camera.
                    onReopenFailed();
                    break;
                case WAITING_FOR_SIGNAL:
                case REOPEN_SCHEDULED:
                    // Called again while we already wait: nothing to do.
                    break;
            }
        });
    }

    /** The camera could not be opened, or a fatal camera error happened. */
    void onCameraError() {
        mainHandler.post(() -> {
            if (!cameraWanted) {
                return;
            }
            switch (state) {
                case REOPENING:
                    // Our try failed. On Samsung this is "too many other open camera devices"
                    // while the Camera app still runs.
                    onReopenFailed();
                    break;
                case IDLE:
                    // Not caused by another app (for example a broken camera): waiting won't help.
                    giveUp();
                    break;
                case WAITING_FOR_SIGNAL:
                case REOPEN_SCHEDULED:
                    // We already wait for the camera: nothing to do.
                    break;
            }
        });
    }

    /** The first frame arrived from a newly opened camera. */
    void onFramesArrived() {
        mainHandler.post(() -> {
            state = State.IDLE;
            failedReopens = 0;
            setPaused(false);
        });
    }

    private void onRetrySignal() {
        // Android may send several signals in a row: only the first one counts.
        if (state != State.WAITING_FOR_SIGNAL) {
            return;
        }
        stopListening();
        state = State.REOPEN_SCHEDULED;
        mainHandler.postDelayed(reopenNowRunnable, REOPEN_DELAY_MS);
    }

    private void reopenNow() {
        if (state != State.REOPEN_SCHEDULED) {
            return;
        }
        // Check and open while holding the lock: a setCameraWanted(false) from another thread
        // either runs before (we don't open) or after (its stopCapture closes what we opened).
        synchronized (lock) {
            if (!cameraWanted) {
                state = State.IDLE;
                return;
            }
            state = State.REOPENING;
            listener.reopenCamera();
        }
    }

    private void onReopenFailed() {
        failedReopens++;
        if (failedReopens >= MAX_FAILED_REOPENS) {
            giveUp();
            return;
        }
        startListening();
    }

    private void giveUp() {
        stopListening();
        mainHandler.removeCallbacks(reopenNowRunnable);
        state = State.IDLE;
        failedReopens = 0;
        paused = false;
        listener.onGaveUp();
    }

    private void startListening() {
        state = State.WAITING_FOR_SIGNAL;
        cameraManager.registerAvailabilityCallback(retrySignal, mainHandler);
    }

    private void stopListening() {
        cameraManager.unregisterAvailabilityCallback(retrySignal);
    }

    private void setPaused(boolean newPaused) {
        if (paused == newPaused) {
            return;
        }
        paused = newPaused;
        listener.onPausedChanged(newPaused);
    }
}
