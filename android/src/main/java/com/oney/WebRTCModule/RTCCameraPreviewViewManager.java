package com.oney.WebRTCModule;

import androidx.annotation.Nullable;

import com.facebook.react.uimanager.SimpleViewManager;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.annotations.ReactProp;

public class RTCCameraPreviewViewManager extends SimpleViewManager<RTCCameraPreviewView> {
    private static final String REACT_CLASS = "RTCCameraPreviewView";

    @Override
    public String getName() {
        return REACT_CLASS;
    }

    @Override
    public RTCCameraPreviewView createViewInstance(ThemedReactContext context) {
        return new RTCCameraPreviewView(context);
    }

    @ReactProp(name = "facing")
    public void setFacing(RTCCameraPreviewView view, @Nullable String facing) {
        view.setFacing(facing);
    }

    @ReactProp(name = "deviceId")
    public void setDeviceId(RTCCameraPreviewView view, @Nullable String deviceId) {
        view.setDeviceId(deviceId);
    }

    @ReactProp(name = "isActive", defaultBoolean = false)
    public void setIsActive(RTCCameraPreviewView view, boolean isActive) {
        view.setIsActive(isActive);
    }

    @ReactProp(name = "mirror", defaultBoolean = true)
    public void setMirror(RTCCameraPreviewView view, boolean mirror) {
        view.setMirror(mirror);
    }

    @ReactProp(name = "objectFit")
    public void setObjectFit(RTCCameraPreviewView view, @Nullable String objectFit) {
        view.setObjectFit(objectFit);
    }

    @ReactProp(name = "captureWidth", defaultInt = 1280)
    public void setCaptureWidth(RTCCameraPreviewView view, int width) {
        view.setCaptureWidth(width);
    }

    @ReactProp(name = "captureHeight", defaultInt = 720)
    public void setCaptureHeight(RTCCameraPreviewView view, int height) {
        view.setCaptureHeight(height);
    }

    @Override
    protected void onAfterUpdateTransaction(RTCCameraPreviewView view) {
        super.onAfterUpdateTransaction(view);
        view.commitProps();
    }

    @Override
    public void onDropViewInstance(RTCCameraPreviewView view) {
        view.dispose();
        super.onDropViewInstance(view);
    }
}
