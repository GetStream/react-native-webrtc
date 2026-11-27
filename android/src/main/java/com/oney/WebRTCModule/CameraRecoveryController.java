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
 * Gets the camera back after Android closed it, usually because another app opened a camera.
 * libwebrtc stops capturing in that case and never opens the camera again by itself.
 *
 * <p><b>Start.</b> A recovery starts when the camera is disconnected while the app still requests
 * capture. The listener is told capture is interrupted (the track stays live and gets "mute").
 *
 * <p><b>Recovery.</b> We listen to {@link CameraManager} for the whole recovery. A "try again"
 * signal while we wait schedules one try {@link #REOPEN_DELAY_MS} later, which opens the camera
 * again on the same capturer, so the same track continues. Signals while that try is scheduled
 * are merged into it. A signal while a try is running is kept: if that try fails, we schedule
 * another one right away. The signals are:
 * <ul>
 *   <li>Access priorities changed ({@code onCameraAccessPrioritiesChanged}, API 29+).</li>
 *   <li>Our camera changed from in use to free ({@code onCameraAvailable}, all API levels).</li>
 *   <li>The first availability report after we start listening says our camera is already free
 *       (all API levels). This gives one try per recovery. A repeated "free" report without a
 *       change in between never schedules another try.</li>
 * </ul>
 *
 * <p><b>Cancel.</b> When the app stops capture (or disposes the capturer), we stop listening,
 * drop the scheduled try, and never open the camera again by ourselves. Work queued before the
 * app turned capture off or on again is dropped (see {@link #generation}).
 *
 * <p><b>End.</b> The first frame from the reopened camera ends the recovery and the listener is
 * told capture is no longer interrupted ("unmute"). After {@link #MAX_FAILED_REOPENS} failed
 * tries, or on a camera error while capture was working (not caused by another app, for example a
 * broken camera), the listener is told recovery failed and ends the track.
 * {@link #MAX_FAILED_REOPENS} counts failed tries only; there is no timeout. If Android never sends
 * another signal, the recovery waits until the app stops capture.
 *
 * <p><b>Android versions.</b> Access priority changes exist from API 29. Before that, recovery
 * relies on availability changes and the first availability report. If the other app holds the
 * camera through a different or private camera id there, and the first try fails, no later signal
 * may come, and capture stays interrupted until the app stops and starts capture.
 *
 * <p><b>Threads.</b> The package-level methods ({@link #setCaptureRequested}, {@link
 * #onCameraDisconnected}, {@link #onCameraError}, {@link #onFramesArrived}) can be called from any
 * thread; they queue their work on the main thread. The {@link CameraManager} callbacks and all
 * private methods run on the main thread, which owns the recovery state. {@link #captureRequested}
 * and {@link #generation} are guarded by {@link #lock}. Queued work is checked against the
 * generation it was created in before it changes the recovery state. Note that
 * {@link #captureRequested} is the app's request, not proof that the camera is running.
 */
class CameraRecoveryController {

    /** What the camera controller does for this class. */
    interface Listener {
        /** Open the camera again on the same capturer. */
        void reopenCamera();

        /**
         * Capture was interrupted by the system (true) or works again (false). The track stays live.
         * This is not the user pausing their video.
         */
        void onCaptureInterruptedChanged(boolean interrupted);

        /** We could not get the camera back. End the track, so the app shows the camera as off. */
        void onRecoveryFailed();

        /** The CameraManager id of the camera in use, or null if unknown. */
        @Nullable
        String currentCameraId();
    }

    private enum State {
        /** No recovery: the camera works, or the app stopped capture. Not listening to Android. */
        IDLE,
        /** Recovering. Listening to Android and waiting for a "try again" signal. */
        WAITING_FOR_SIGNAL,
        /** A signal came. The camera opens after {@link #REOPEN_DELAY_MS}. */
        REOPEN_SCHEDULED,
        /** We called reopenCamera() and wait for the first frame or a failure. */
        REOPENING
    }

    /** Gives the other app time to finish closing the camera. */
    static final long REOPEN_DELAY_MS = 500;

    /** Failed tries before we give up. Not a time limit: see the class doc. */
    static final int MAX_FAILED_REOPENS = 3;

    private final CameraManager cameraManager;
    private final Listener listener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Runnable reopenNowRunnable = this::reopenNow;

    // Main thread only.
    private State state = State.IDLE;
    private int failedReopens = 0;
    /** We told the listener capture is interrupted, and frames have not come back yet. */
    private boolean captureInterrupted = false;
    /** A signal came while a try was running. If that try fails, schedule another one. */
    private boolean retrySignalPending = false;
    /** The generation the current recovery belongs to. */
    private int recoveryGeneration = 0;
    /** The CameraManager id of the camera we are getting back. */
    @Nullable
    private String recoveryCameraId;
    /** Last known state of each camera id while listening: true = free, false = in use. */
    private final Map<String, Boolean> knownAvailability = new HashMap<>();
    /**
     * This recovery already used its one try for "the first report says our camera is free".
     * Set even when a try was already scheduled and the report only joined it.
     */
    private boolean initialAvailabilityRetryUsed = false;
    private boolean listening = false;

    private final Object lock = new Object();

    /** The app requests capture (between startCapture and stopCapture). Guarded by {@link #lock}. */
    private boolean captureRequested = false;

    /**
     * Goes up every time the app starts or stops capture. Work that was queued in an older
     * generation (for example an error from a session the app already stopped) is dropped.
     * Guarded by {@link #lock}.
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

                // API 29+. No @Override, so this compiles with a compileSdkVersion below 29.
                // Seen on a Samsung Galaxy S21 Ultra (Android 15): the system Camera app uses a
                // private camera id, so our camera never looks busy and no availability change
                // comes when the Camera app closes. This signal is what brings the camera back.
                public void onCameraAccessPrioritiesChanged() {
                    onRetrySignal();
                }
            };

    CameraRecoveryController(Context context, Listener listener) {
        this.cameraManager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
        this.listener = listener;
    }

    /**
     * The app started (true) or stopped (false) capture. Starts a new generation and ends a
     * recovery from an earlier generation. While capture is not requested, we never open the
     * camera by ourselves.
     */
    void setCaptureRequested(boolean requested) {
        final int newGeneration;
        synchronized (lock) {
            captureRequested = requested;
            generation++;
            newGeneration = generation;
        }
        mainHandler.post(() -> {
            // A recovery started in this generation or a newer one is not ours to end.
            if (state != State.IDLE && recoveryGeneration >= newGeneration) {
                return;
            }
            endRecovery();
            // Keep captureInterrupted: if the app starts capture again, the first frame clears it.
        });
    }

    /**
     * Android closed our camera device, usually because another app opened a camera. Starts a
     * recovery, or counts a failed try if we were opening the camera again.
     */
    void onCameraDisconnected() {
        final int eventGeneration = currentGeneration();
        mainHandler.post(() -> {
            if (!isCurrent(eventGeneration)) {
                return;
            }
            switch (state) {
                case IDLE:
                    startRecovery(eventGeneration);
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

    /**
     * The camera could not be opened, or a fatal camera error happened. Counts a failed try if we
     * were opening the camera again; otherwise recovery fails, because waiting won't help.
     */
    void onCameraError() {
        final int eventGeneration = currentGeneration();
        mainHandler.post(() -> {
            if (!isCurrent(eventGeneration)) {
                return;
            }
            switch (state) {
                case REOPENING:
                    // Our try failed. Seen on Samsung while its Camera app still runs:
                    // "too many other open camera devices".
                    onReopenFailed();
                    break;
                case IDLE:
                    // Not caused by another app (for example a broken camera): waiting won't help.
                    failRecovery();
                    break;
                case WAITING_FOR_SIGNAL:
                case REOPEN_SCHEDULED:
                    // We already wait for the camera: nothing to do.
                    break;
            }
        });
    }

    /** The first frame arrived from a newly opened camera. Ends a recovery. */
    void onFramesArrived() {
        final int eventGeneration = currentGeneration();
        mainHandler.post(() -> {
            if (!isCurrent(eventGeneration)) {
                return;
            }
            endRecovery();
            setCaptureInterrupted(false);
        });
    }

    private void startRecovery(int eventGeneration) {
        recoveryGeneration = eventGeneration;
        recoveryCameraId = listener.currentCameraId();
        failedReopens = 0;
        retrySignalPending = false;
        initialAvailabilityRetryUsed = false;
        setCaptureInterrupted(true);
        state = State.WAITING_FOR_SIGNAL;
        startListening();
    }

    /** Stops listening and cancels a scheduled try. */
    private void endRecovery() {
        stopListening();
        mainHandler.removeCallbacks(reopenNowRunnable);
        state = State.IDLE;
        failedReopens = 0;
        retrySignalPending = false;
        initialAvailabilityRetryUsed = false;
        recoveryCameraId = null;
    }

    private void onAvailabilityChanged(String cameraId, boolean available) {
        if (!listening) {
            return;
        }
        Boolean wasAvailable = knownAvailability.put(cameraId, available);
        if (!available || !cameraId.equals(recoveryCameraId)) {
            // Only our camera becoming free matters.
            return;
        }
        if (Boolean.FALSE.equals(wasAvailable)) {
            // Our camera changed from in use to free.
            onRetrySignal();
        } else if (wasAvailable == null && !initialAvailabilityRetryUsed) {
            // Android reports how every camera is right after we register. Our camera may already
            // be free (the other app released it before we started listening), so try once.
            // Seen on Samsung: our camera is reported free while the Camera app holds a private
            // camera id, so this try fails and we wait for a priority change.
            initialAvailabilityRetryUsed = true;
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
                retrySignalPending = true;
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
        // Check and open while holding the lock: a setCaptureRequested(false) from another thread
        // either runs before (we don't open) or after (its stopCapture closes what we opened).
        synchronized (lock) {
            if (!captureRequested || generation != recoveryGeneration) {
                endRecovery();
                return;
            }
            state = State.REOPENING;
            retrySignalPending = false;
            listener.reopenCamera();
        }
    }

    private void onReopenFailed() {
        failedReopens++;
        if (failedReopens >= MAX_FAILED_REOPENS) {
            failRecovery();
            return;
        }
        state = State.WAITING_FOR_SIGNAL;
        if (retrySignalPending) {
            retrySignalPending = false;
            onRetrySignal();
        }
    }

    private void failRecovery() {
        endRecovery();
        captureInterrupted = false;
        listener.onRecoveryFailed();
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

    private void setCaptureInterrupted(boolean interrupted) {
        if (captureInterrupted == interrupted) {
            return;
        }
        captureInterrupted = interrupted;
        listener.onCaptureInterruptedChanged(interrupted);
    }

    private int currentGeneration() {
        synchronized (lock) {
            return generation;
        }
    }

    /** True if the app still requests capture and did not stop or start it since the event. */
    private boolean isCurrent(int eventGeneration) {
        synchronized (lock) {
            return captureRequested && generation == eventGeneration;
        }
    }
}
