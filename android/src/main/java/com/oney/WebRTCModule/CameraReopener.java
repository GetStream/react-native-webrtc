package com.oney.WebRTCModule;

import android.content.Context;
import android.hardware.camera2.CameraManager;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.HashMap;
import java.util.Map;

/**
 * Opens the camera again after another app took it away.
 *
 * <p>When another app opens a camera, Android closes ours, and libwebrtc stops capturing without
 * ever opening the camera again. This class then:
 * <ol>
 *   <li>tells the listener the video is paused,</li>
 *   <li>listens to Android until a frame arrives again, and on each "try again" signal opens the
 *       camera again (same capturer, so the same track continues),</li>
 *   <li>tells the listener the video is back when the first frame arrives.</li>
 * </ol>
 * If opening fails because the other app still has the camera, it waits for the next signal.
 * After {@link #MAX_FAILED_REOPENS} failed tries, or on a camera error that is not about another
 * app, it gives up and the listener ends the track.
 *
 * <p>"Try again" signals:
 * <ul>
 *   <li>{@link CameraManager.AvailabilityCallback#onCameraAccessPrioritiesChanged()}, Android 10
 *       (API 29) and newer. Needed when the other app uses a camera id we can't see (the Samsung
 *       Camera app does), so our camera never looks busy.</li>
 *   <li>Our camera id changing from in use to free
 *       ({@link CameraManager.AvailabilityCallback#onCameraAvailable(String)}), all versions.
 *       Works when the other app used the same camera id.</li>
 *   <li>The first report after we start listening saying our camera is already free (the other
 *       app released it before we listened). This gives one try per recovery, not more.</li>
 * </ul>
 * On Android 9 and older only the second signal exists. If the other app used a different camera
 * id there, the video stays paused until the app turns the camera off and on.
 *
 * <p>Threads: every method can be called from any thread. The state is only read and written on
 * the main thread, except {@link #cameraWanted} and {@link #generation}, which are guarded by
 * {@link #lock}.
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

        /** The CameraManager id of the camera in use, or null if unknown. */
        @Nullable
        String currentCameraId();
    }

    private enum State {
        /** The camera works, or the app turned it off. Not listening to Android. */
        IDLE,
        /** The camera was taken. Listening to Android and waiting for a "try again" signal. */
        WAITING_FOR_SIGNAL,
        /** A signal came. The camera opens after {@link #REOPEN_DELAY_MS}. */
        REOPEN_SCHEDULED,
        /** We called reopenCamera() and wait for the first frame or a failure. */
        REOPENING
    }

    /** Gives the other app time to finish closing the camera. */
    static final long REOPEN_DELAY_MS = 500;

    static final int MAX_FAILED_REOPENS = 3;

    private final CameraManager cameraManager;
    private final Listener listener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Runnable reopenNowRunnable = this::reopenNow;

    // Main thread only.
    private State state = State.IDLE;
    private int failedReopens = 0;
    private boolean paused = false;
    /** A signal came while we were opening the camera. If that try fails, try again. */
    private boolean signalWhileReopening = false;
    /** The generation the current recovery belongs to. */
    private int episodeGeneration = 0;
    @Nullable
    private String episodeCameraId;
    /** Last known state of each camera id while listening: true = free, false = in use. */
    private final Map<String, Boolean> knownAvailability = new HashMap<>();
    /** We already tried once because the first report said our camera was free. */
    private boolean triedOnFirstReport = false;
    private boolean listening = false;

    private final Object lock = new Object();

    /** True while the app wants the camera on (between startCapture and stopCapture). */
    private boolean cameraWanted = false;

    /**
     * Goes up every time the app turns the camera on or off. Work that was queued for an older
     * generation (an error from a session that the app already stopped) is dropped.
     */
    private int generation = 0;

    private final CameraManager.AvailabilityCallback availabilityCallback =
            new CameraManager.AvailabilityCallback() {
                @Override
                public void onCameraAvailable(@NonNull String cameraId) {
                    onAvailabilityChanged(cameraId, true);
                }

                @Override
                public void onCameraUnavailable(@NonNull String cameraId) {
                    onAvailabilityChanged(cameraId, false);
                }

                // Android 10+. No @Override, so this compiles with a compileSdkVersion below 29.
                public void onCameraAccessPrioritiesChanged() {
                    onRetrySignal();
                }
            };

    CameraReopener(Context context, Listener listener) {
        this.cameraManager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
        this.listener = listener;
    }

    /**
     * The app turned the camera on (true) or off (false). Ends any recovery that belongs to an
     * earlier generation. When the camera is off, we never open it again by ourselves.
     */
    void setCameraWanted(boolean wanted) {
        final int newGeneration;
        synchronized (lock) {
            cameraWanted = wanted;
            generation++;
            newGeneration = generation;
        }
        mainHandler.post(() -> {
            // A recovery started for this generation or a newer one is not ours to end.
            if (state != State.IDLE && episodeGeneration >= newGeneration) {
                return;
            }
            endEpisode();
            // Keep "paused": if the app turns the camera on again, the first frame sends "back".
        });
    }

    /** Android closed our camera, usually because another app opened a camera. */
    void onCameraTaken() {
        final int eventGeneration = currentGeneration();
        mainHandler.post(() -> {
            if (!isCurrent(eventGeneration)) {
                return;
            }
            switch (state) {
                case IDLE:
                    startEpisode(eventGeneration);
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
        final int eventGeneration = currentGeneration();
        mainHandler.post(() -> {
            if (!isCurrent(eventGeneration)) {
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
        final int eventGeneration = currentGeneration();
        mainHandler.post(() -> {
            if (!isCurrent(eventGeneration)) {
                return;
            }
            endEpisode();
            setPaused(false);
        });
    }

    private void startEpisode(int eventGeneration) {
        episodeGeneration = eventGeneration;
        episodeCameraId = listener.currentCameraId();
        failedReopens = 0;
        signalWhileReopening = false;
        triedOnFirstReport = false;
        setPaused(true);
        state = State.WAITING_FOR_SIGNAL;
        startListening();
    }

    /** Stops listening and cancels a scheduled reopen. */
    private void endEpisode() {
        stopListening();
        mainHandler.removeCallbacks(reopenNowRunnable);
        state = State.IDLE;
        failedReopens = 0;
        signalWhileReopening = false;
        triedOnFirstReport = false;
        episodeCameraId = null;
    }

    private void onAvailabilityChanged(String cameraId, boolean available) {
        if (!listening) {
            return;
        }
        Boolean wasAvailable = knownAvailability.put(cameraId, available);
        if (!available || !cameraId.equals(episodeCameraId)) {
            // Only our camera becoming free matters.
            return;
        }
        if (Boolean.FALSE.equals(wasAvailable)) {
            // Our camera changed from in use to free.
            onRetrySignal();
        } else if (wasAvailable == null && !triedOnFirstReport) {
            // Android reports how every camera is right after we register. Our camera may already
            // be free (the other app released it before we started listening), so try once. On
            // Samsung this try can fail while the Camera app holds a private camera id; then we
            // wait for a real signal. A repeated "free" report never causes another try.
            triedOnFirstReport = true;
            onRetrySignal();
        }
    }

    private void onRetrySignal() {
        switch (state) {
            case WAITING_FOR_SIGNAL:
                state = State.REOPEN_SCHEDULED;
                mainHandler.postDelayed(reopenNowRunnable, REOPEN_DELAY_MS);
                break;
            case REOPENING:
                // The other app may have released the camera after our try started. If the try
                // fails, try again instead of waiting for a signal that already came.
                signalWhileReopening = true;
                break;
            case REOPEN_SCHEDULED:
                // The scheduled try starts after this signal, so it already covers it.
            case IDLE:
                break;
        }
    }

    private void reopenNow() {
        if (state != State.REOPEN_SCHEDULED) {
            return;
        }
        // Check and open while holding the lock: a setCameraWanted(false) from another thread
        // either runs before (we don't open) or after (its stopCapture closes what we opened).
        synchronized (lock) {
            if (!cameraWanted || generation != episodeGeneration) {
                endEpisode();
                return;
            }
            state = State.REOPENING;
            signalWhileReopening = false;
            listener.reopenCamera();
        }
    }

    private void onReopenFailed() {
        failedReopens++;
        if (failedReopens >= MAX_FAILED_REOPENS) {
            giveUp();
            return;
        }
        state = State.WAITING_FOR_SIGNAL;
        if (signalWhileReopening) {
            signalWhileReopening = false;
            onRetrySignal();
        }
    }

    private void giveUp() {
        endEpisode();
        paused = false;
        listener.onGaveUp();
    }

    private void startListening() {
        if (listening) {
            return;
        }
        listening = true;
        knownAvailability.clear();
        cameraManager.registerAvailabilityCallback(availabilityCallback, mainHandler);
    }

    private void stopListening() {
        if (!listening) {
            return;
        }
        listening = false;
        knownAvailability.clear();
        cameraManager.unregisterAvailabilityCallback(availabilityCallback);
    }

    private void setPaused(boolean newPaused) {
        if (paused == newPaused) {
            return;
        }
        paused = newPaused;
        listener.onPausedChanged(newPaused);
    }

    private int currentGeneration() {
        synchronized (lock) {
            return generation;
        }
    }

    /** True if the app still wants the camera and nothing turned it off or on since the event. */
    private boolean isCurrent(int eventGeneration) {
        synchronized (lock) {
            return cameraWanted && generation == eventGeneration;
        }
    }
}
