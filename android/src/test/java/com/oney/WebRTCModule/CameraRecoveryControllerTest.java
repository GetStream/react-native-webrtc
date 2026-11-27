package com.oney.WebRTCModule;

import static org.junit.Assert.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.robolectric.shadows.ShadowLooper.shadowMainLooper;

import android.content.Context;
import android.hardware.camera2.CameraManager;
import android.os.Handler;

import androidx.annotation.Nullable;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Tests for {@link CameraRecoveryController}: what happens after another app takes our camera.
 *
 * <p>Android's CameraManager is replaced by a mock. The test plays Android: it reports the camera
 * as taken, sends "try again" signals, and reports frames or failures, then checks what
 * CameraRecoveryController asked the camera controller to do.
 */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class CameraRecoveryControllerTest {

    private static final String OUR_CAMERA = "1";

    private CameraManager cameraManager;
    private FakeController controller;
    private CameraRecoveryController recovery;

    @Before
    public void setUp() {
        cameraManager = mock(CameraManager.class);
        Context context = mock(Context.class);
        when(context.getSystemService(Context.CAMERA_SERVICE)).thenReturn(cameraManager);
        controller = new FakeController();
        recovery = new CameraRecoveryController(context, controller);

        // The app turns the camera on.
        recovery.setCaptureRequested(true);
        runMainThread();
    }

    // ---- The normal path ----

    @Test
    public void pausesTheVideoAndStartsListeningWhenAnotherAppTakesTheCamera() {
        cameraTaken();

        assertEquals(Arrays.asList("interrupted"), controller.calls);
        verify(cameraManager, times(1)).registerAvailabilityCallback(any(), any(Handler.class));
    }

    @Test
    public void opensTheCameraAgainHalfASecondAfterAndroidSaysTryAgain() {
        cameraTaken();

        prioritiesChanged();
        passTime(CameraRecoveryController.REOPEN_DELAY_MS - 1);
        assertEquals(0, controller.reopens());

        passTime(1);
        assertEquals(1, controller.reopens());
    }

    @Test
    public void resumesTheVideoAndStopsListeningWhenTheFirstFrameArrives() {
        cameraTaken();
        prioritiesChanged();
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);

        framesArrived();

        assertEquals(Arrays.asList("interrupted", "reopen", "resumed"), controller.calls);
        verify(cameraManager).unregisterAvailabilityCallback(any());
    }

    @Test
    public void listensOnlyOnceWhenTheCameraIsReportedTakenTwice() {
        cameraTaken();
        cameraTaken();

        assertEquals(Arrays.asList("interrupted"), controller.calls);
        verify(cameraManager, times(1)).registerAvailabilityCallback(any(), any(Handler.class));
    }

    @Test
    public void opensTheCameraOnlyOnceWhenSeveralSignalsArriveTogether() {
        cameraTaken();

        prioritiesChanged();
        prioritiesChanged();
        prioritiesChanged();
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);

        assertEquals(1, controller.reopens());
    }

    // ---- Review finding 1: no signal may be lost while a try is scheduled or running ----

    @Test
    public void triesAgainWithoutANewSignalWhenTheCameraWasFreedDuringAFailedTry() {
        cameraTaken();
        prioritiesChanged();
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);
        assertEquals(1, controller.reopens());

        // The other app frees the camera while our try is still running...
        prioritiesChanged();
        // ...and our try fails, because it started before the camera was free.
        openFailed();

        // No new signal comes from Android, but the signal during the try is not lost.
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);
        assertEquals(2, controller.reopens());
    }

    @Test
    public void keepsListeningWhileATryIsScheduledAndAfterTheTryFails() {
        cameraTaken();
        prioritiesChanged();
        prioritiesChanged(); // arrives while the try is scheduled: the scheduled try covers it
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);
        openFailed();

        // Still listening, so the next signal opens the camera again.
        verify(cameraManager, never()).unregisterAvailabilityCallback(any());
        prioritiesChanged();
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);
        assertEquals(2, controller.reopens());
    }

    // ---- Review finding 2: "our camera is free" is a signal too ----

    @Test
    public void opensTheCameraAgainWhenOurCameraBecomesFreeWithoutAPrioritySignal() {
        cameraTaken();
        CameraManager.AvailabilityCallback android = registeredCallback();
        android.onCameraUnavailable(OUR_CAMERA); // first report: the other app has it

        android.onCameraAvailable(OUR_CAMERA); // the other app freed it
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);

        assertEquals(1, controller.reopens());
    }

    // ---- Follow-up review: our camera is already free when we start listening ----

    @Test
    public void triesOnceWhenOurCameraIsAlreadyFreeWhenListeningStarts() {
        cameraTaken();
        CameraManager.AvailabilityCallback android = registeredCallback();

        // The other app released the camera before we started listening, and no priority
        // signal will come. The only thing Android sends is how our camera is now: free.
        android.onCameraAvailable(OUR_CAMERA);
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);

        assertEquals(1, controller.reopens());
    }

    @Test
    public void opensTheCameraOnALaterSignalWhenTheTryFromTheFirstReportFails() {
        cameraTaken();
        CameraManager.AvailabilityCallback android = registeredCallback();

        // Samsung: our camera looks free while the Camera app holds a private camera id, so
        // the try from the first report fails...
        android.onCameraAvailable(OUR_CAMERA);
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);
        openFailed();

        // ...and the Camera app closing later still brings the camera back.
        prioritiesChanged();
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);

        assertEquals(Arrays.asList("interrupted", "reopen", "reopen"), controller.calls);
    }

    @Test
    public void doesNotTryAgainWhenOurCameraIsReportedFreeAgainWithoutChanging() {
        cameraTaken();
        CameraManager.AvailabilityCallback android = registeredCallback();
        android.onCameraAvailable(OUR_CAMERA);
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);
        openFailed();

        // Still free, nothing changed: not a reason to try again.
        android.onCameraAvailable(OUR_CAMERA);
        android.onCameraAvailable(OUR_CAMERA);
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);

        assertEquals(1, controller.reopens());
    }

    @Test
    public void ignoresOtherCamerasBecomingFree() {
        cameraTaken();
        CameraManager.AvailabilityCallback android = registeredCallback();

        android.onCameraUnavailable("20");
        android.onCameraAvailable("20");
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);

        assertEquals(0, controller.reopens());
    }

    // ---- Review finding 3: work queued for an old session must not touch a new one ----

    @Test
    public void doesNotEndARestartedTrackBecauseOfAnErrorFromTheStoppedSession() {
        // An error from the current session is queued for the main thread...
        recovery.onCameraError();
        // ...and before it runs, the app turns the camera off and on again.
        recovery.setCaptureRequested(false);
        recovery.setCaptureRequested(true);
        runMainThread();

        assertEquals(new ArrayList<String>(), controller.calls);
    }

    @Test
    public void doesNotLetAnOldTurnOffCancelARecoveryOfTheNewSession() {
        recovery.setCaptureRequested(false);
        recovery.setCaptureRequested(true);
        recovery.onCameraDisconnected();
        runMainThread();

        prioritiesChanged();
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);

        assertEquals(Arrays.asList("interrupted", "reopen"), controller.calls);
    }

    // ---- The app turns the camera off ----

    @Test
    public void neverOpensTheCameraAfterTheAppTurnedItOffWhileWaiting() {
        cameraTaken();

        recovery.setCaptureRequested(false);
        runMainThread();
        prioritiesChanged();
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);

        assertEquals(0, controller.reopens());
        verify(cameraManager).unregisterAvailabilityCallback(any());
    }

    @Test
    public void neverOpensTheCameraWhenTheAppTurnsItOffDuringTheDelay() {
        cameraTaken();
        prioritiesChanged();

        passTime(CameraRecoveryController.REOPEN_DELAY_MS / 2);
        recovery.setCaptureRequested(false);
        passTime(CameraRecoveryController.REOPEN_DELAY_MS);

        assertEquals(0, controller.reopens());
    }

    @Test
    public void ignoresTheCameraBeingTakenWhileTheAppHasItTurnedOff() {
        recovery.setCaptureRequested(false);
        runMainThread();

        cameraTaken();

        assertEquals(new ArrayList<String>(), controller.calls);
        verify(cameraManager, never()).registerAvailabilityCallback(any(), any(Handler.class));
    }

    // ---- Giving up ----

    @Test
    public void endsTheTrackOnACameraErrorThatIsNotAboutAnotherApp() {
        recovery.onCameraError();
        runMainThread();

        assertEquals(Arrays.asList("recoveryFailed"), controller.calls);
    }

    @Test
    public void endsTheTrackAfterThreeFailedTries() {
        cameraTaken();
        for (int i = 0; i < CameraRecoveryController.MAX_FAILED_REOPENS; i++) {
            prioritiesChanged();
            passTime(CameraRecoveryController.REOPEN_DELAY_MS);
            openFailed();
        }

        assertEquals(CameraRecoveryController.MAX_FAILED_REOPENS, controller.reopens());
        assertEquals("recoveryFailed", controller.calls.get(controller.calls.size() - 1));
        verify(cameraManager).unregisterAvailabilityCallback(any());
    }

    // ---- Helpers: the test plays Android and the camera ----

    private void cameraTaken() {
        recovery.onCameraDisconnected();
        runMainThread();
    }

    private void openFailed() {
        recovery.onCameraError();
        runMainThread();
    }

    private void framesArrived() {
        recovery.onFramesArrived();
        runMainThread();
    }

    private void prioritiesChanged() {
        registeredCallback().onCameraAccessPrioritiesChanged();
        runMainThread();
    }

    private CameraManager.AvailabilityCallback registeredCallback() {
        ArgumentCaptor<CameraManager.AvailabilityCallback> captor =
                ArgumentCaptor.forClass(CameraManager.AvailabilityCallback.class);
        verify(cameraManager, org.mockito.Mockito.atLeastOnce())
                .registerAvailabilityCallback(captor.capture(), any(Handler.class));
        return captor.getValue();
    }

    /** Runs the work that is queued on the main thread now. */
    private static void runMainThread() {
        shadowMainLooper().idle();
    }

    /** Moves the main thread's clock forward and runs what is due. */
    private static void passTime(long millis) {
        shadowMainLooper().idleFor(Duration.ofMillis(millis));
    }

    /** Records what CameraRecoveryController asked the camera controller to do, in order. */
    private static class FakeController implements CameraRecoveryController.Listener {
        final List<String> calls = new ArrayList<>();

        @Override
        public void reopenCamera() {
            calls.add("reopen");
        }

        @Override
        public void onCaptureInterruptedChanged(boolean interrupted) {
            calls.add(interrupted ? "interrupted" : "resumed");
        }

        @Override
        public void onRecoveryFailed() {
            calls.add("recoveryFailed");
        }

        @Nullable
        @Override
        public String currentCameraId() {
            return OUR_CAMERA;
        }

        int reopens() {
            int count = 0;
            for (String call : calls) {
                if (call.equals("reopen")) {
                    count++;
                }
            }
            return count;
        }
    }
}
