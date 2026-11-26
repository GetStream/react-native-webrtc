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
 * Tests for {@link CameraReopener}: what happens after another app takes our camera.
 *
 * <p>Android's CameraManager is replaced by a mock. The test plays Android: it reports the camera
 * as taken, sends "try again" signals, and reports frames or failures, then checks what
 * CameraReopener asked the camera controller to do.
 */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class CameraReopenerTest {

    private static final String OUR_CAMERA = "1";

    private CameraManager cameraManager;
    private FakeController controller;
    private CameraReopener reopener;

    @Before
    public void setUp() {
        cameraManager = mock(CameraManager.class);
        Context context = mock(Context.class);
        when(context.getSystemService(Context.CAMERA_SERVICE)).thenReturn(cameraManager);
        controller = new FakeController();
        reopener = new CameraReopener(context, controller);

        // The app turns the camera on.
        reopener.setCameraWanted(true);
        runMainThread();
    }

    // ---- The normal path ----

    @Test
    public void pausesTheVideoAndStartsListeningWhenAnotherAppTakesTheCamera() {
        cameraTaken();

        assertEquals(Arrays.asList("paused"), controller.calls);
        verify(cameraManager, times(1)).registerAvailabilityCallback(any(), any(Handler.class));
    }

    @Test
    public void opensTheCameraAgainHalfASecondAfterAndroidSaysTryAgain() {
        cameraTaken();

        prioritiesChanged();
        passTime(CameraReopener.REOPEN_DELAY_MS - 1);
        assertEquals(0, controller.reopens());

        passTime(1);
        assertEquals(1, controller.reopens());
    }

    @Test
    public void resumesTheVideoAndStopsListeningWhenTheFirstFrameArrives() {
        cameraTaken();
        prioritiesChanged();
        passTime(CameraReopener.REOPEN_DELAY_MS);

        framesArrived();

        assertEquals(Arrays.asList("paused", "reopen", "resumed"), controller.calls);
        verify(cameraManager).unregisterAvailabilityCallback(any());
    }

    @Test
    public void listensOnlyOnceWhenTheCameraIsReportedTakenTwice() {
        cameraTaken();
        cameraTaken();

        assertEquals(Arrays.asList("paused"), controller.calls);
        verify(cameraManager, times(1)).registerAvailabilityCallback(any(), any(Handler.class));
    }

    @Test
    public void opensTheCameraOnlyOnceWhenSeveralSignalsArriveTogether() {
        cameraTaken();

        prioritiesChanged();
        prioritiesChanged();
        prioritiesChanged();
        passTime(CameraReopener.REOPEN_DELAY_MS);

        assertEquals(1, controller.reopens());
    }

    // ---- Review finding 1: no signal may be lost while a try is scheduled or running ----

    @Test
    public void triesAgainWithoutANewSignalWhenTheCameraWasFreedDuringAFailedTry() {
        cameraTaken();
        prioritiesChanged();
        passTime(CameraReopener.REOPEN_DELAY_MS);
        assertEquals(1, controller.reopens());

        // The other app frees the camera while our try is still running...
        prioritiesChanged();
        // ...and our try fails, because it started before the camera was free.
        openFailed();

        // No new signal comes from Android, but the signal during the try is not lost.
        passTime(CameraReopener.REOPEN_DELAY_MS);
        assertEquals(2, controller.reopens());
    }

    @Test
    public void keepsListeningWhileATryIsScheduledAndAfterTheTryFails() {
        cameraTaken();
        prioritiesChanged();
        prioritiesChanged(); // arrives while the try is scheduled: the scheduled try covers it
        passTime(CameraReopener.REOPEN_DELAY_MS);
        openFailed();

        // Still listening, so the next signal opens the camera again.
        verify(cameraManager, never()).unregisterAvailabilityCallback(any());
        prioritiesChanged();
        passTime(CameraReopener.REOPEN_DELAY_MS);
        assertEquals(2, controller.reopens());
    }

    // ---- Review finding 2: "our camera is free" is a signal too ----

    @Test
    public void opensTheCameraAgainWhenOurCameraBecomesFreeWithoutAPrioritySignal() {
        cameraTaken();
        CameraManager.AvailabilityCallback android = registeredCallback();
        android.onCameraUnavailable(OUR_CAMERA); // first report: the other app has it

        android.onCameraAvailable(OUR_CAMERA); // the other app freed it
        passTime(CameraReopener.REOPEN_DELAY_MS);

        assertEquals(1, controller.reopens());
    }

    @Test
    public void ignoresTheFirstReportThatOurCameraIsFree() {
        cameraTaken();
        CameraManager.AvailabilityCallback android = registeredCallback();

        // Right after registering, Android reports how every camera is now. On Samsung our
        // camera looks free while the Camera app uses a private camera id, and opening it fails.
        android.onCameraAvailable(OUR_CAMERA);
        passTime(CameraReopener.REOPEN_DELAY_MS);

        assertEquals(0, controller.reopens());
    }

    @Test
    public void ignoresOtherCamerasBecomingFree() {
        cameraTaken();
        CameraManager.AvailabilityCallback android = registeredCallback();

        android.onCameraUnavailable("20");
        android.onCameraAvailable("20");
        passTime(CameraReopener.REOPEN_DELAY_MS);

        assertEquals(0, controller.reopens());
    }

    // ---- Review finding 3: work queued for an old session must not touch a new one ----

    @Test
    public void doesNotEndARestartedTrackBecauseOfAnErrorFromTheStoppedSession() {
        // An error from the current session is queued for the main thread...
        reopener.onCameraError();
        // ...and before it runs, the app turns the camera off and on again.
        reopener.setCameraWanted(false);
        reopener.setCameraWanted(true);
        runMainThread();

        assertEquals(new ArrayList<String>(), controller.calls);
    }

    @Test
    public void doesNotLetAnOldTurnOffCancelARecoveryOfTheNewSession() {
        reopener.setCameraWanted(false);
        reopener.setCameraWanted(true);
        reopener.onCameraTaken();
        runMainThread();

        prioritiesChanged();
        passTime(CameraReopener.REOPEN_DELAY_MS);

        assertEquals(Arrays.asList("paused", "reopen"), controller.calls);
    }

    // ---- The app turns the camera off ----

    @Test
    public void neverOpensTheCameraAfterTheAppTurnedItOffWhileWaiting() {
        cameraTaken();

        reopener.setCameraWanted(false);
        runMainThread();
        prioritiesChanged();
        passTime(CameraReopener.REOPEN_DELAY_MS);

        assertEquals(0, controller.reopens());
        verify(cameraManager).unregisterAvailabilityCallback(any());
    }

    @Test
    public void neverOpensTheCameraWhenTheAppTurnsItOffDuringTheDelay() {
        cameraTaken();
        prioritiesChanged();

        passTime(CameraReopener.REOPEN_DELAY_MS / 2);
        reopener.setCameraWanted(false);
        passTime(CameraReopener.REOPEN_DELAY_MS);

        assertEquals(0, controller.reopens());
    }

    @Test
    public void ignoresTheCameraBeingTakenWhileTheAppHasItTurnedOff() {
        reopener.setCameraWanted(false);
        runMainThread();

        cameraTaken();

        assertEquals(new ArrayList<String>(), controller.calls);
        verify(cameraManager, never()).registerAvailabilityCallback(any(), any(Handler.class));
    }

    // ---- Giving up ----

    @Test
    public void endsTheTrackOnACameraErrorThatIsNotAboutAnotherApp() {
        reopener.onCameraError();
        runMainThread();

        assertEquals(Arrays.asList("gaveUp"), controller.calls);
    }

    @Test
    public void endsTheTrackAfterThreeFailedTries() {
        cameraTaken();
        for (int i = 0; i < CameraReopener.MAX_FAILED_REOPENS; i++) {
            prioritiesChanged();
            passTime(CameraReopener.REOPEN_DELAY_MS);
            openFailed();
        }

        assertEquals(CameraReopener.MAX_FAILED_REOPENS, controller.reopens());
        assertEquals("gaveUp", controller.calls.get(controller.calls.size() - 1));
        verify(cameraManager).unregisterAvailabilityCallback(any());
    }

    // ---- Helpers: the test plays Android and the camera ----

    private void cameraTaken() {
        reopener.onCameraTaken();
        runMainThread();
    }

    private void openFailed() {
        reopener.onCameraError();
        runMainThread();
    }

    private void framesArrived() {
        reopener.onFramesArrived();
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

    /** Records what CameraReopener asked the camera controller to do, in order. */
    private static class FakeController implements CameraReopener.Listener {
        final List<String> calls = new ArrayList<>();

        @Override
        public void reopenCamera() {
            calls.add("reopen");
        }

        @Override
        public void onPausedChanged(boolean paused) {
            calls.add(paused ? "paused" : "resumed");
        }

        @Override
        public void onGaveUp() {
            calls.add("gaveUp");
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
