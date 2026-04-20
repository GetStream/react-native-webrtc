package com.oney.WebRTCModule;

import com.oney.WebRTCModule.audio.AudioProcessingFactoryProvider;

import org.webrtc.AudioProcessingFactory;
import org.webrtc.Loggable;
import org.webrtc.Logging;
import org.webrtc.VideoDecoderFactory;
import org.webrtc.VideoEncoderFactory;
import org.webrtc.audio.AudioDeviceModule;

import java.nio.ByteBuffer;
import java.util.concurrent.Callable;

public class WebRTCModuleOptions {
    private static WebRTCModuleOptions instance;

    public VideoEncoderFactory videoEncoderFactory;
    public VideoDecoderFactory videoDecoderFactory;
    public AudioDeviceModule audioDeviceModule;
    public Callable<AudioProcessingFactory> audioProcessingFactoryFactory;

    public Loggable injectableLogger;
    public Logging.Severity loggingSeverity;
    public String fieldTrials;
    public boolean enableMediaProjectionService;
    public AudioProcessingFactoryProvider audioProcessingFactoryProvider;
    public double defaultTrackVolume = 1.0;

    /**
     * Provider for screen share audio bytes. When set, the AudioDeviceModule's
     * AudioBufferCallback will mix screen audio into the mic buffer before
     * WebRTC processing. This allows screen audio mixing to work alongside
     * any audio processing factory (including noise cancellation).
     *
     * Set this when screen share audio capture starts, clear it when it stops.
     */
    public volatile ScreenAudioBytesProvider screenAudioBytesProvider;

    /**
     * Functional interface for providing screen audio bytes on demand.
     */
    public interface ScreenAudioBytesProvider {
        /**
         * Returns a ByteBuffer containing screen audio PCM data.
         *
         * @param bytesRequested number of bytes to read (matching mic buffer size)
         * @return ByteBuffer with screen audio, or null if not available
         */
        ByteBuffer getScreenAudioBytes(int bytesRequested);
    }

    public static WebRTCModuleOptions getInstance() {
        if (instance == null) {
            instance = new WebRTCModuleOptions();
        }

        return instance;
    }
}
