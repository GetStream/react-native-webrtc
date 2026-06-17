package com.oney.WebRTCModule;

import android.content.Context;
import android.util.Log;
import android.widget.FrameLayout;

import androidx.annotation.Nullable;

import com.facebook.react.bridge.JavaOnlyMap;
import com.facebook.react.bridge.ReactContext;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import org.webrtc.Camera1Enumerator;
import org.webrtc.Camera2Enumerator;
import org.webrtc.CameraEnumerator;
import org.webrtc.EglBase;
import org.webrtc.RendererCommon.ScalingType;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.SurfaceViewRenderer;
import org.webrtc.VideoCapturer;

/**
 * <p>Unlike {@link WebRTCView}, this view does NOT render a WebRTC track. It drives a
 * {@link CameraCaptureController} directly and forwards the captured frames to an embedded
 * {@link SurfaceViewRenderer} via a {@link FanoutCapturerObserver} — without creating a
 * {@code VideoSource}, a {@code VideoTrack}, or touching the {@code PeerConnectionFactory}.
 *
 * <p>It is intended for the call lobby, before any peer connection factory exists. At join the
 * running camera session is adopted by the WebRTC track (see {@link #yieldForAdoption()}): the
 * per-call {@code VideoSource} is attached as the downstream of the {@link FanoutCapturerObserver},
 * so the camera keeps running and is never stopped or restarted. The preview keeps rendering until
 * this view unmounts.
 */
public class RTCCameraPreviewView extends FrameLayout {
    private static final String TAG = "RTCCameraPreviewView";
    private static final int DEFAULT_WIDTH = 1280;
    private static final int DEFAULT_HEIGHT = 720;
    private static final int DEFAULT_FPS = 30;

    private final SurfaceViewRenderer surfaceViewRenderer;

    private boolean rendererInitialized = false;

    // Desired props (applied as a batch via commitProps()).
    private String facing = "front";
    @Nullable
    private String deviceId;
    private boolean isActive = false;
    private int captureWidth = DEFAULT_WIDTH;
    private int captureHeight = DEFAULT_HEIGHT;

    // Serial executor for the blocking capture start/stop calls (CameraCaptureController.startCapture
    // and VideoCapturer.stopCapture block until the camera session changes state). These must NOT run
    // on the RN UI thread (commitProps/dispose are invoked there) or the UI freezes for the whole
    // camera start/stop. All fields below are owned by this executor's thread.
    private final ExecutorService captureExecutor = Executors.newSingleThreadExecutor();

    @Nullable
    private CameraCaptureController captureController;
    @Nullable
    private SurfaceTextureHelper surfaceTextureHelper;
    private boolean running = false;
    @Nullable
    private String runningFacing;
    @Nullable
    private String runningDeviceId;

    @Nullable
    private FanoutCapturerObserver fanoutObserver;

    private volatile boolean handedOff = false;

    public RTCCameraPreviewView(Context context) {
        super(context);

        surfaceViewRenderer = new SurfaceViewRenderer(context);
        addView(surfaceViewRenderer, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        EglBase.Context sharedContext = EglUtils.getRootEglBaseContext();
        if (sharedContext != null) {
            surfaceViewRenderer.init(sharedContext, null);
            rendererInitialized = true;
        } else {
            Log.e(TAG, "Unable to obtain root EglBase context; preview will not render");
        }
        surfaceViewRenderer.setMirror(true);
        surfaceViewRenderer.setScalingType(ScalingType.SCALE_ASPECT_FILL);
    }

    void setFacing(@Nullable String facing) {
        this.facing = (facing == null) ? "front" : facing;
    }

    void setDeviceId(@Nullable String deviceId) {
        this.deviceId = deviceId;
    }

    void setIsActive(boolean isActive) {
        this.isActive = isActive;
    }

    void setMirror(boolean mirror) {
        surfaceViewRenderer.setMirror(mirror);
    }

    void setObjectFit(@Nullable String objectFit) {
        ScalingType type = "contain".equals(objectFit) ? ScalingType.SCALE_ASPECT_FIT : ScalingType.SCALE_ASPECT_FILL;
        surfaceViewRenderer.setScalingType(type);
    }

    void setCaptureWidth(int width) {
        if (width > 0) {
            this.captureWidth = width;
        }
    }

    void setCaptureHeight(int height) {
        if (height > 0) {
            this.captureHeight = height;
        }
    }

    void commitProps() {
        if (handedOff) {
            return;
        }

        final boolean active = isActive;
        final String reqFacing = facing;
        final String reqDeviceId = deviceId;
        WebRTCModule module = getModule();
        if (module != null) {
            if (active) {
                module.setActiveCameraPreview(this);
            } else {
                module.clearActiveCameraPreview(this);
            }
        }

        captureExecutor.execute(() -> reconcile(active, reqFacing, reqDeviceId));
    }

    private void reconcile(boolean active, String reqFacing, String reqDeviceId) {
        if (handedOff) {
            return;
        }

        if (active) {
            boolean configChanged = running
                    && (!stringsEqual(runningFacing, reqFacing) || !stringsEqual(runningDeviceId, reqDeviceId));
            if (running && !configChanged) {
                return;
            }

            if (running) {
                stopCaptureInternal();
            }
            startCaptureInternal(reqFacing, reqDeviceId);
        } else if (running) {
            stopCaptureInternal();
        }
    }

    private void startCaptureInternal(String reqFacing, @Nullable String reqDeviceId) {
        if (running || !rendererInitialized || handedOff) {
            return;
        }

        JavaOnlyMap constraints = new JavaOnlyMap();
        constraints.putInt("width", captureWidth);
        constraints.putInt("height", captureHeight);
        constraints.putInt("frameRate", DEFAULT_FPS);
        constraints.putString("facingMode", "back".equals(reqFacing) ? "environment" : "user");
        if (reqDeviceId != null) {
            constraints.putString("deviceId", reqDeviceId);
        }

        CameraEnumerator enumerator = Camera2Enumerator.isSupported(getContext())
                ? new Camera2Enumerator(getContext())
                : new Camera1Enumerator(false);

        captureController = new CameraCaptureController(getContext(), enumerator, constraints);
        captureController.initializeVideoCapturer();

        VideoCapturer videoCapturer = captureController.getVideoCapturer();
        if (videoCapturer == null) {
            Log.e(TAG, "Unable to create a camera capturer for preview");
            captureController = null;
            return;
        }
        
        EglBase.Context eglContext = EglUtils.getRootEglBaseContext();
        surfaceTextureHelper = SurfaceTextureHelper.create("PreviewCaptureThread", eglContext);

        if (surfaceTextureHelper == null) {
            Log.e(TAG, "Unable to create SurfaceTextureHelper for preview");
            captureController.dispose();
            captureController = null;
            return;
        }

        fanoutObserver = new FanoutCapturerObserver(surfaceViewRenderer);
        videoCapturer.initialize(surfaceTextureHelper, getContext(), fanoutObserver);
        captureController.startCapture();

        running = true;
        runningFacing = reqFacing;
        runningDeviceId = reqDeviceId;
    }

    private void stopCaptureInternal() {
        if (captureController != null) {
            captureController.stopCapture();
            captureController.dispose();
            captureController = null;
        }
        if (surfaceTextureHelper != null) {
            surfaceTextureHelper.dispose();
            surfaceTextureHelper = null;
        }
        running = false;
        runningFacing = null;
        runningDeviceId = null;
    }

    /**
     * Yields the running camera session to the WebRTC track: the caller attaches the per-call
     * {@code VideoSource}'s observer as the fan-out's downstream (see {@link FanoutCapturerObserver})
     * and takes ownership of the returned controller / surface texture helper. The camera is not
     * stopped — frames keep flowing. Returns {@code null} if there is no running capture to adopt
     * (caller should then create a fresh capturer). Invoked off the UI thread (getUserMedia worker).
     *
     * <p>This view keeps rendering the preview (it retains the fan-out and clears its renderer on
     * {@link #dispose()}); ownership of the capturer/controller transfers to the track.
     */
    @Nullable
    PreviewHandoff yieldForAdoption() {
        handedOff = true;
        clearActivePreview();
        final PreviewHandoff[] out = new PreviewHandoff[1];
        try {
            Future<?> done = captureExecutor.submit(() -> {
                if (running && captureController != null && surfaceTextureHelper != null && fanoutObserver != null) {
                    out[0] = new PreviewHandoff(captureController, surfaceTextureHelper, fanoutObserver);
                    // Release our ownership WITHOUT stopping: the track now owns the capturer (via the
                    // controller it retains) and the camera keeps running. We deliberately keep
                    // `fanoutObserver` so the preview keeps rendering until unmount.
                    captureController = null;
                    surfaceTextureHelper = null;
                    running = false;
                }
            });
            done.get();
        } catch (Exception e) {
            Log.e(TAG, "preview adoption yield failed", e);
        }
        return out[0];
    }

    void dispose() {
        handedOff = true;
        clearActivePreview();

        final boolean releaseRenderer = rendererInitialized;
        final FanoutCapturerObserver fanout = fanoutObserver;
        rendererInitialized = false;
        
        captureExecutor.execute(() -> {
            // Detach the preview renderer first so no frame reaches a released SurfaceViewRenderer
            // (the capturer may still be running if it was adopted by a track).
            if (fanout != null) {
                fanout.setRenderer(null);
            }
            stopCaptureInternal(); // no-op if the capturer was adopted (controller already null)
            if (releaseRenderer) {
                surfaceViewRenderer.release();
            }
        });
        
        captureExecutor.shutdown();
    }

    /** Bundle of the running capture state handed to a WebRTC track when it adopts the preview. */
    static class PreviewHandoff {
        final AbstractVideoCaptureController controller;
        final SurfaceTextureHelper surfaceTextureHelper;
        final FanoutCapturerObserver fanout;

        PreviewHandoff(AbstractVideoCaptureController controller, SurfaceTextureHelper surfaceTextureHelper,
                FanoutCapturerObserver fanout) {
            this.controller = controller;
            this.surfaceTextureHelper = surfaceTextureHelper;
            this.fanout = fanout;
        }
    }

    private void clearActivePreview() {
        WebRTCModule module = getModule();
        if (module != null) {
            module.clearActiveCameraPreview(this);
        }
    }

    @Nullable
    private WebRTCModule getModule() {
        Context context = getContext();
        if (context instanceof ReactContext) {
            return ((ReactContext) context).getNativeModule(WebRTCModule.class);
        }
        return null;
    }

    private static boolean stringsEqual(@Nullable String a, @Nullable String b) {
        return a == null ? b == null : a.equals(b);
    }
}
