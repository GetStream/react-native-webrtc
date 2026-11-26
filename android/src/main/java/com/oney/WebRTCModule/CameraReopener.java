package com.oney.WebRTCModule;

import android.content.Context;
import android.hardware.camera2.CameraManager;
import android.os.Handler;
import android.os.Looper;

/**
 * Opens the camera again after another app took it away.
 *
 * It waits for Android's "try the camera again" signal
 * ({@code onCameraAccessPrioritiesChanged}, Android 10+), then runs {@code reopenCamera}.
 *
 * All state is read and written only on the main thread, so no lock is needed.
 */
class CameraReopener {
    private static final long REOPEN_DELAY_MS = 500;

    private final CameraManager cameraManager;
    private final Runnable reopenCamera;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    /** True while we are registered with Android and wait for the signal. */
    private boolean listening = false;

    /** True after the signal arrived, until the camera is opened (500 ms later). */
    private boolean reopenScheduled = false;

    private final CameraManager.AvailabilityCallback retrySignal = new CameraManager.AvailabilityCallback() {
        // Android 10+. No @Override, so this compiles with a compileSdkVersion below 29.
        public void onCameraAccessPrioritiesChanged() {
            onRetrySignal();
        }
    };

    CameraReopener(Context context, Runnable reopenCamera) {
        this.cameraManager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
        this.reopenCamera = reopenCamera;
    }

    /**
     * Starts waiting for the camera. Safe to call many times: while we already wait,
     * or while a reopen is already scheduled, extra calls do nothing.
     * Can be called from any thread.
     */
    void waitForCamera() {
        mainHandler.post(() -> {
            if (listening || reopenScheduled) {
                return;
            }
            listening = true;
            cameraManager.registerAvailabilityCallback(retrySignal, mainHandler);
        });
    }

    /** Runs on the main thread. Android may send several signals in a row: only the first counts. */
    private void onRetrySignal() {
        if (!listening) {
            return;
        }
        listening = false;
        cameraManager.unregisterAvailabilityCallback(retrySignal);
        reopenScheduled = true;
        mainHandler.postDelayed(this::reopenNow, REOPEN_DELAY_MS);
    }

    /** Runs on the main thread, 500 ms after the signal. */
    private void reopenNow() {
        reopenScheduled = false;
        reopenCamera.run();
    }
}
