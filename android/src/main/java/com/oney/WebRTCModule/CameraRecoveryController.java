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
 * Gets the camera back after Android disconnected it while the app still requests capture,
 * usually because another app opened a camera. libwebrtc stops capturing in that case and never
 * opens the camera again by itself. We reopen it on the same capturer, so the same track continues.
 *
 * <h2>Normal path (safeguards left out of this view)</h2>
 *
 * <p>Read the successful recovery in this order. Android's callbacks come later and on their own;
 * the arrows show the order of the lifecycle, not one call stack.
 *
 * <pre>{@code
 * onCameraDisconnected()                    // the capturer reports Android closed our camera
 *   -> startRecovery()
 *        -> setCaptureInterrupted(true)     -> Listener.onCaptureInterruptedChanged(true)  // track "mute"
 *        -> startListening()                -> CameraManager.registerAvailabilityCallback()
 *
 * Later, Android calls one of:
 *   onCameraAvailable(cameraId)             -> onAvailabilityChanged(cameraId, true) -> onRetrySignal()
 *   onCameraAccessPrioritiesChanged()                                                -> onRetrySignal()
 *
 * onRetrySignal()
 *   -> scheduleReopen()                     // runs reopenNow() after REOPEN_DELAY_MS
 *
 * reopenNow()
 *   -> Listener.reopenCamera()              // same capturer, same track
 *
 * Later, the capturer reports its first frame:
 *   onFramesArrived()
 *     -> endRecovery()                      -> CameraManager.unregisterAvailabilityCallback()
 *     -> setCaptureInterrupted(false)       -> Listener.onCaptureInterruptedChanged(false) // track "unmute"
 * }</pre>
 *
 * <p>This class does not poll. The delay starts only after an Android callback. The first
 * availability report after we start listening, saying our camera is already free, also allows one
 * try. A priority change means a try may work, not that the camera is free. Recovery succeeds when
 * the first frame arrives, not when {@code reopenCamera()} returns.
 *
 * <h2>Flow diagram (current code)</h2>
 *
 * <p>( ) = start or end, [ ] = step, &lt; &gt; = yes/no question, (W) and (S) = jump targets.
 *
 * <pre>{@code
 * ( START: the camera is running and the app requests capture )
 *                     |
 *                     v
 * [ onCameraDisconnected(): the capturer reports Android closed our camera ]
 *                     |
 *                     v
 * < still requested, same generation? > --no--> ( END: drop the event )
 *                     | yes
 *                     v
 * [ startRecovery(): Listener.onCaptureInterruptedChanged(true)  (track "mute"),
 *   startListening()  (register with CameraManager) ]
 *                     |
 *                     v
 * (W) [ WAITING_FOR_SIGNAL ]
 *                     |
 *                     v
 * < Android signal: priorities changed, or our camera   > --no--> keep waiting in (W)
 * < in use -> free, or the first report says it is free >
 * < (the first report counts once per recovery)         >
 *                     | yes
 *                     v
 * (S) [ scheduleReopen(): REOPEN_SCHEDULED. More signals now join this try ]
 *                     | after REOPEN_DELAY_MS (500 ms)
 *                     v
 * < reopenNow(), under the lock:      > --no--> [ endRecovery() ] --> ( END: the app stopped capture )
 * < still requested, same generation? >
 *                     | yes
 *                     v
 * [ REOPENING: Listener.reopenCamera() on the same capturer.
 *   A signal now sets retrySignalPending ]
 *                     |
 *                     v
 * < first frame arrived? > --yes--> [ onFramesArrived(): endRecovery(),
 *                     |               Listener.onCaptureInterruptedChanged(false)  (track "unmute") ]
 *                     |                                     |
 *                     |                                     v
 *                     |                  ( END: video is back on the same track )
 *                     | no: onCameraError() or onCameraDisconnected()
 *                     v
 * [ onReopenFailed(): failedReopens + 1 ]
 *                     |
 *                     v
 * < failedReopens == MAX_FAILED_REOPENS (3)? > --yes--> [ failRecovery(): Listener.onRecoveryFailed() ]
 *                     | no                                              |
 *                     v                                                 v
 * < retrySignalPending? > --yes--> go to (S)        ( END: track ended, the app shows the camera off )
 *                     | no
 *                     v
 *                 go to (W)
 *
 * Two more ways out:
 *
 * [ setCaptureRequested(false), at any point: the app stops capture ]
 *     --> new generation, endRecovery() --> ( END: we never reopen; older queued work is dropped )
 *
 * [ onCameraError() while the camera was working (IDLE) ]
 *     --> failRecovery(): Listener.onRecoveryFailed() --> ( END: track ended, camera shown off )
 * }</pre>
 *
 * <p>Not drawn: {@code onCameraDisconnected()} and {@code onCameraError()} are ignored while we wait
 * for a signal or a try is scheduled, and a signal is ignored when no recovery runs.
 *
 * <h2>The same path with overlapping events and cancelling</h2>
 *
 * <pre>{@code
 * The app starts or stops capture:
 *   setCaptureRequested(requested)
 *     -> record the request and start a new generation
 *     -> queued work from an older generation is dropped from now on
 *     -> on the main thread: end a recovery from an older generation (cancels its scheduled try)
 *
 * A capturer event arrives (onCameraDisconnected / onCameraError / onFramesArrived):
 *   -> note the current generation, queue the work on the main thread
 *   -> isCurrent(generation)?  no: drop it  (capture stopped or restarted since)
 *
 * onCameraDisconnected(), on the main thread:
 *   IDLE:                        startRecovery()
 *   REOPENING:                   onReopenFailed()   // our try was disconnected
 *   WAITING / REOPEN_SCHEDULED:  ignore             // already recovering
 *
 * onCameraError(), on the main thread:
 *   REOPENING:                   onReopenFailed()   // our try could not open the camera
 *   IDLE:                        failRecovery()     // the working camera failed: waiting won't help
 *   WAITING / REOPEN_SCHEDULED:  ignore
 *
 * An Android signal arrives -> onRetrySignal():
 *   WAITING_FOR_SIGNAL:          scheduleReopen()   // one try after REOPEN_DELAY_MS
 *   REOPEN_SCHEDULED:            ignore             // the scheduled try starts after this signal
 *   REOPENING:                   retrySignalPending = true
 *   IDLE:                        ignore
 *
 * reopenNow():
 *   -> under the lock: still requested and same generation?  no: endRecovery()
 *   -> REOPENING, then Listener.reopenCamera() while still holding the lock, so a stop from
 *      another thread runs either before (we don't open) or after (its stopCapture closes it)
 *
 * onReopenFailed():
 *   -> count the failed try; MAX_FAILED_REOPENS reached: failRecovery() -> Listener.onRecoveryFailed()
 *   -> otherwise wait again; if retrySignalPending: scheduleReopen() now
 * }</pre>
 *
 * <p>We keep listening while a try is scheduled or running, so a signal that arrives during a
 * failed try is not lost. A repeated "still free" report without a change in between never
 * schedules another try. {@link #MAX_FAILED_REOPENS} counts failed tries only and is not a
 * timeout: if Android never sends another useful signal, the recovery waits until the app stops
 * capture.
 *
 * <h2>Android versions</h2>
 *
 * <p>Access priority changes exist from API 29. Before that, recovery relies on availability
 * changes and the first availability report. If the other app holds the camera through a
 * different or private camera id there, and the first try fails, no later signal may come, and
 * capture stays interrupted until the app stops and starts capture.
 *
 * <h2>Threads</h2>
 *
 * <p>The four package-level methods ({@link #setCaptureRequested}, {@link #onCameraDisconnected},
 * {@link #onCameraError}, {@link #onFramesArrived}) can be called from any thread and queue their
 * work on the main thread. The {@link CameraManager} callbacks and all private methods run on the
 * main thread, which owns the recovery state. The lock rules are at the end of the class, in
 * "Capture session safeguards".
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

    // Recovery state: main thread only.
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

    // ---- Normal path, in order ----

    /**
     * Called by the capturer (camera thread) when Android closed our camera device, usually
     * because another app opened a camera. On the main thread: starts a recovery, or counts a
     * failed try if we were reopening. Next: {@link #startRecovery} or {@link #onReopenFailed}.
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

    /** Main thread. Tells the listener capture is interrupted and starts listening to Android. */
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

    /** Main thread. Android then reports every camera's current state, and later changes. */
    private void startListening() {
        if (listening) {
            return;
        }
        listening = true;
        knownAvailability.clear();
        cameraManager.registerAvailabilityCallback(availabilityCallback, mainHandler);
    }

    /**
     * Main thread, from the availability callback. Turns "our camera is free" into a signal:
     * a change from in use to free, or the first report (once per recovery).
     * Next: {@link #onRetrySignal}.
     */
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

    /**
     * Main thread, from an availability or access priority callback: the camera may be usable
     * again. While waiting, schedules one try; while a try runs, keeps the signal in case it
     * fails. Next: {@link #scheduleReopen}, then {@link #reopenNow}.
     */
    private void onRetrySignal() {
        switch (state) {
            case WAITING_FOR_SIGNAL:
                scheduleReopen();
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

    /** Main thread. Runs {@link #reopenNow} after {@link #REOPEN_DELAY_MS}. */
    private void scheduleReopen() {
        state = State.REOPEN_SCHEDULED;
        mainHandler.postDelayed(reopenNowRunnable, REOPEN_DELAY_MS);
    }

    /**
     * Main thread, {@link #REOPEN_DELAY_MS} after a signal. Opens the camera again if the app still
     * requests capture in the same generation. Next: {@link #onFramesArrived} on success, or
     * {@link #onCameraDisconnected} / {@link #onCameraError} leading to {@link #onReopenFailed}.
     */
    private void reopenNow() {
        if (state != State.REOPEN_SCHEDULED) {
            return;
        }
        // Check and open while holding the lock: a setCaptureRequested(false) from another thread
        // either runs before (we don't open) or after (its stopCapture closes what we opened).
        // Lock order: our lock, then the capturer's. The camera thread never takes our lock.
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

    /**
     * Called by the capturer (camera thread) when the first frame arrives from a newly opened
     * camera. On the main thread: ends a recovery and tells the listener capture works again.
     */
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

    /** Main thread. Stops listening and cancels a scheduled try. */
    private void endRecovery() {
        stopListening();
        mainHandler.removeCallbacks(reopenNowRunnable);
        state = State.IDLE;
        failedReopens = 0;
        retrySignalPending = false;
        initialAvailabilityRetryUsed = false;
        recoveryCameraId = null;
    }

    // ---- Failures ----

    /**
     * Called by the capturer (camera thread) when the camera could not be opened, or a fatal camera
     * error happened. On the main thread: counts a failed try if we were reopening; if the camera
     * was working, recovery fails, because waiting won't help. Ignored while we already wait.
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

    /**
     * Main thread. Counts a failed try. After {@link #MAX_FAILED_REOPENS}: {@link #failRecovery}.
     * Otherwise waits again, and schedules another try at once if a signal came during this one.
     */
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

    /** Main thread. Ends the recovery and tells the listener to end the track. */
    private void failRecovery() {
        endRecovery();
        captureInterrupted = false;
        listener.onRecoveryFailed();
    }

    // ---- The app starts and stops capture ----

    /**
     * Called by the camera controller (any thread) when the app started (true) or stopped (false)
     * capture. Starts a new generation, so work queued before is dropped, and on the main thread
     * ends a recovery from an earlier generation. While capture is not requested, we never open
     * the camera by ourselves.
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

    // ---- Small helpers (main thread) ----

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

    // ---- Capture session safeguards ----
    //
    // Two values are shared between threads:
    // - captureRequested: what the app asked for. Not proof that the camera runs.
    // - generation: goes up every time the app starts or stops capture.
    //
    // Both are written only under {@link #lock}. The capturer calls our package-level methods on the
    // camera thread while holding its own lock, so the camera thread must never wait for our lock:
    // it reads generation without the lock (it is volatile). Only the main thread and the thread
    // that starts or stops capture take our lock. reopenNow() holds our lock while it starts the
    // capturer (which takes the capturer's lock), so the order is always: our lock, then the
    // capturer's.
    //
    // Queued work carries the generation it was created in and is dropped by isCurrent() when the
    // app stopped or restarted capture since.

    private final Object lock = new Object();

    /** The app requests capture (between startCapture and stopCapture). Guarded by {@link #lock}. */
    private boolean captureRequested = false;

    /** Written under {@link #lock}; read without it on the camera thread. */
    private volatile int generation = 0;

    /** Any thread, without the lock: the camera thread must never wait for {@link #lock}. */
    private int currentGeneration() {
        return generation;
    }

    /** Main thread. True if the app still requests capture and did not stop or start it since. */
    private boolean isCurrent(int eventGeneration) {
        synchronized (lock) {
            return captureRequested && generation == eventGeneration;
        }
    }
}
