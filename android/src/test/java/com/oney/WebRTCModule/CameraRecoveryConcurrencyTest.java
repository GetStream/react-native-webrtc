package com.oney.WebRTCModule;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.robolectric.shadows.ShadowLooper.shadowMainLooper;

import android.content.Context;
import android.hardware.camera2.CameraManager;
import android.os.Handler;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.LooperMode;

import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Forces specific interleavings with a real worker thread and a paused main looper.
 * Timeouts bound failures; latches and blocked-thread observation establish the ordering.
 * No camera hardware or changes to production lock visibility are required.
 */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
@LooperMode(LooperMode.Mode.PAUSED)
public class CameraRecoveryConcurrencyTest {
    private static final long TIMEOUT_SECONDS = 5;

    private CameraManager cameraManager;
    private CameraRecoveryController.Listener listener;
    private CameraRecoveryController recovery;
    private ExecutorService cameraThread;

    @Before
    public void setUp() {
        cameraManager = mock(CameraManager.class);
        Context context = mock(Context.class);
        when(context.getSystemService(Context.CAMERA_SERVICE)).thenReturn(cameraManager);
        listener = mock(CameraRecoveryController.Listener.class);
        when(listener.currentCameraId()).thenReturn("1");
        recovery = new CameraRecoveryController(context, listener);
        cameraThread = Executors.newSingleThreadExecutor(work -> {
            Thread thread = new Thread(work, "camera-recovery-test-worker");
            thread.setDaemon(true);
            return thread;
        });
        recovery.setCaptureRequested(true);
        shadowMainLooper().idle();
    }

    @After
    public void tearDown() throws Exception {
        cameraThread.shutdownNow();
        assertTrue("Worker did not terminate", cameraThread.awaitTermination(TIMEOUT_SECONDS, TimeUnit.SECONDS));
        recovery.setCaptureRequested(false);
        shadowMainLooper().idle();
    }

    @Test
    public void cameraThreadIsNotBlockedWhenItReportsADisconnectDuringAReopen() {
        assertCallbackReturnsDuringReopen(recovery::onCameraDisconnected);
    }

    @Test
    public void cameraThreadIsNotBlockedWhenItReportsAnErrorDuringAReopen() {
        assertCallbackReturnsDuringReopen(recovery::onCameraError);
    }

    @Test
    public void cameraThreadIsNotBlockedWhenItReportsTheFirstFrameDuringAReopen() {
        assertCallbackReturnsDuringReopen(recovery::onFramesArrived);
    }

    @Test
    public void stoppingTheCameraBeforeTheDelayEndsMeansItIsNeverReopened() throws Exception {
        scheduleReopen();

        finish(cameraThread.submit(() -> recovery.setCaptureRequested(false)));
        runScheduledReopen();

        verify(listener, never()).reopenCamera();
        verify(cameraManager).unregisterAvailabilityCallback(any());
    }

    @Test
    public void stoppingTheCameraDuringAReopenWaitsAndThenStopsTheReopenedCamera() throws Exception {
        AtomicBoolean nativeCaptureRunning = new AtomicBoolean();
        AtomicReference<Thread> stoppingThread = new AtomicReference<>();
        AtomicReference<Future<?>> stopWork = new AtomicReference<>();
        CountDownLatch stopSubmitted = new CountDownLatch(1);

        doAnswer(invocation -> {
            stopWork.set(cameraThread.submit(() -> {
                stoppingThread.set(Thread.currentThread());
                stopSubmitted.countDown();
                // Mirrors CameraCaptureController.stopCapture(): intent first, native stop second.
                recovery.setCaptureRequested(false);
                nativeCaptureRunning.set(false);
            }));
            assertTrue("Stop worker did not start", stopSubmitted.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            awaitBlockedInCaptureRequest(stoppingThread.get());
            nativeCaptureRunning.set(true);
            return null;
        }).when(listener).reopenCamera();

        scheduleReopen();
        runScheduledReopen();
        finish(stopWork.get());
        shadowMainLooper().idle();

        assertFalse("Native stop must run after the protected native open", nativeCaptureRunning.get());
        verify(listener).reopenCamera();
        verify(cameraManager).unregisterAvailabilityCallback(any());
    }

    @Test
    public void eventsQueuedBeforeTheCameraWasTurnedOffAndOnAreIgnored() throws Exception {
        finish(cameraThread.submit(() -> {
            recovery.onCameraDisconnected();
            recovery.onCameraError();
            recovery.onFramesArrived();
        }));
        finish(cameraThread.submit(() -> {
            recovery.setCaptureRequested(false);
            recovery.setCaptureRequested(true);
        }));

        shadowMainLooper().idle();

        verify(listener, never()).onCaptureInterruptedChanged(anyBoolean());
        verify(listener, never()).onRecoveryFailed();
        verify(cameraManager, never()).registerAvailabilityCallback(any(), any(Handler.class));
    }

    @Test
    public void aTryScheduledBeforeTheCameraWasTurnedOffAndOnNeverRuns() throws Exception {
        scheduleReopen();
        finish(cameraThread.submit(() -> {
            recovery.setCaptureRequested(false);
            recovery.setCaptureRequested(true);
        }));

        runScheduledReopen();

        verify(listener, never()).reopenCamera();
        verify(listener, never()).onRecoveryFailed();
    }

    private void assertCallbackReturnsDuringReopen(Runnable event) {
        doAnswer(invocation -> {
            // Production holds its recovery lock while calling this listener. The worker must
            // enqueue its camera event and return without acquiring that lock.
            finish(cameraThread.submit(event));
            return null;
        }).when(listener).reopenCamera();

        scheduleReopen();
        runScheduledReopen();

        verify(listener).reopenCamera();
    }

    private void scheduleReopen() {
        recovery.onCameraDisconnected();
        shadowMainLooper().idle();
        ArgumentCaptor<CameraManager.AvailabilityCallback> callback =
                ArgumentCaptor.forClass(CameraManager.AvailabilityCallback.class);
        verify(cameraManager).registerAvailabilityCallback(callback.capture(), any(Handler.class));
        callback.getValue().onCameraAccessPrioritiesChanged();
    }

    private static void runScheduledReopen() {
        shadowMainLooper().idleFor(Duration.ofMillis(CameraRecoveryController.REOPEN_DELAY_MS));
    }

    private static void finish(Future<?> work) throws Exception {
        work.get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
    }

    private static void awaitBlockedInCaptureRequest(Thread thread) {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(TIMEOUT_SECONDS);
        while (System.nanoTime() < deadline) {
            if (thread.getState() == Thread.State.BLOCKED) {
                for (StackTraceElement frame : thread.getStackTrace()) {
                    if (frame.getClassName().equals(CameraRecoveryController.class.getName())
                            && frame.getMethodName().equals("setCaptureRequested")) {
                        return;
                    }
                }
            }
            if (!thread.isAlive()) {
                fail("Stop completed without waiting for the protected reopen");
            }
            Thread.yield();
        }
        fail("Stop did not block on the thread performing the protected reopen");
    }
}
