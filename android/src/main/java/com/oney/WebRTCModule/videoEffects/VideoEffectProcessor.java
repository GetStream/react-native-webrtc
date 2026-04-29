package com.oney.WebRTCModule.videoEffects;

import org.webrtc.SurfaceTextureHelper;
import org.webrtc.VideoFrame;
import org.webrtc.VideoProcessor;
import org.webrtc.VideoSink;

import java.util.List;

/**
 * Lightweight abstraction for an object that can receive video frames, process and add effects in
 * them, and pass them on to another object.
 */
public class VideoEffectProcessor implements VideoProcessor {
    private VideoSink mSink;
    final private SurfaceTextureHelper textureHelper;
    final private List<VideoFrameProcessor> videoFrameProcessors;
    private boolean disposed = false;

    public VideoEffectProcessor(List<VideoFrameProcessor> processors, SurfaceTextureHelper textureHelper) {
        this.textureHelper = textureHelper;
        this.videoFrameProcessors = processors;
    }

    @Override
    public void onCapturerStarted(boolean success) {}

    @Override
    public void onCapturerStopped() {}

    /**
     * Disposes each wrapped processor. Runs on the capturer handler so it fires
     * after any in-flight frame, letting implementations clean up GL state inline.
     * Idempotent. Not in onCapturerStopped because that also fires on pause.
     */
    public void dispose() {
        textureHelper.getHandler().post(() -> {
            if (disposed) return;
            disposed = true;
            for (VideoFrameProcessor processor : this.videoFrameProcessors) {
                processor.dispose();
            }
        });
    }

    @Override
    public void setSink(VideoSink sink) {
        mSink = sink;
    }

    /**
     * Called just after the frame is captured.
     * Will process the VideoFrame with the help of VideoFrameProcessor and send the processed
     * VideoFrame back to webrtc using onFrame method in VideoSink.
     * @param frame raw VideoFrame received from webrtc.
     */
    @Override
    public void onFrameCaptured(VideoFrame frame) {
        frame.retain();
        VideoFrame outputFrame = frame;
        for (VideoFrameProcessor processor : this.videoFrameProcessors) {
            final VideoFrame previousOutputFrame = outputFrame;
            outputFrame = processor.process(outputFrame, textureHelper);
            previousOutputFrame.release();
        }
        mSink.onFrame(outputFrame);
        outputFrame.release();
    }
}
