package com.oney.WebRTCModule;

import com.oney.WebRTCModule.audio.AudioProcessingFactoryProvider;

import org.webrtc.AudioProcessingFactory;
import org.webrtc.Loggable;
import org.webrtc.Logging;
import org.webrtc.VideoDecoderFactory;
import org.webrtc.VideoEncoderFactory;
import org.webrtc.audio.AudioDeviceModule;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.nio.ByteBuffer;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CopyOnWriteArrayList;

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

    /**
     * Multi-consumer fan-out for the JADM playback-side data callback.
     * Consumers (e.g. a tracks recorder) register an observer here at
     * runtime. The single {@link JavaAudioDeviceModule.PlaybackSamplesReadyCallback}
     * installed on the {@link JavaAudioDeviceModule.Builder} forwards
     * each delivery to every registered observer. This lets the
     * playback-tap point be shared across features without requiring
     * a fork-side multi-callback API.
     *
     * Independent of {@link #audioProcessingFactoryProvider} — the
     * callback fires on the audio device module's render path, so it
     * works regardless of which audio processing factory is in use
     * (including third-party noise cancellation).
     */
    private final List<JavaAudioDeviceModule.PlaybackSamplesReadyCallback> playbackSamplesObservers =
            new CopyOnWriteArrayList<>();

    public void addPlaybackSamplesObserver(JavaAudioDeviceModule.PlaybackSamplesReadyCallback observer) {
        playbackSamplesObservers.add(observer);
    }

    public void removePlaybackSamplesObserver(JavaAudioDeviceModule.PlaybackSamplesReadyCallback observer) {
        playbackSamplesObservers.remove(observer);
    }

    /** Iteration-safe; returns the live CopyOnWriteArrayList. */
    public List<JavaAudioDeviceModule.PlaybackSamplesReadyCallback> getPlaybackSamplesObservers() {
        return playbackSamplesObservers;
    }

    public static WebRTCModuleOptions getInstance() {
        if (instance == null) {
            instance = new WebRTCModuleOptions();
        }

        return instance;
    }
}
