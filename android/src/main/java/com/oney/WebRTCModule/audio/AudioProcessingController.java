package com.oney.WebRTCModule.audio;

import org.webrtc.AudioProcessingFactory;
import org.webrtc.ExternalAudioProcessingFactory;

public class AudioProcessingController implements AudioProcessingFactoryProvider {
    /**
     * This is the audio processing module that will be applied to the audio stream after it is captured from the microphone.
     * This is useful for adding echo cancellation, noise suppression, etc.
     */
    public final AudioProcessingAdapter capturePostProcessing = new AudioProcessingAdapter();
    /**
     * This is the audio processing module that will be applied to the audio stream before it is rendered to the speaker.
     */
    public final AudioProcessingAdapter renderPreProcessing = new AudioProcessingAdapter();

    public ExternalAudioProcessingFactory externalAudioProcessingFactory;

    public AudioProcessingController() {
        // ExternalAudioProcessingFactory creation is deferred to getFactory()
        // because its constructor calls JNI native methods that require the
        // WebRTC native library to be loaded first (via PeerConnectionFactory.initialize()).
        // This allows AudioProcessingController to be safely instantiated in
        // MainApplication.onCreate() before the native library is loaded.
    }

    @Override
    public AudioProcessingFactory getFactory() {
        if (this.externalAudioProcessingFactory == null) {
            this.externalAudioProcessingFactory = new ExternalAudioProcessingFactory();
            this.externalAudioProcessingFactory.setCapturePostProcessing(capturePostProcessing);
            this.externalAudioProcessingFactory.setRenderPreProcessing(renderPreProcessing);
        }
        return this.externalAudioProcessingFactory;
    }
}