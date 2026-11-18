package com.oney.WebRTCModule;

import android.content.Context;
import android.media.AudioManager;
import android.media.MediaRecorder;
import android.os.Build;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.webrtc.AudioProcessingFactory;
import org.webrtc.NetworkMonitor;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.VideoDecoderFactory;
import org.webrtc.VideoEncoderFactory;
import org.webrtc.audio.AudioDeviceModule;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Owns one {@link PeerConnectionFactory} and the {@link AudioDeviceModule} (ADM) it is built with,
 * identified by a stable {@code id}. The ADM bakes in audio-configuration that cannot change at
 * runtime (hardware AEC/NS, audio source, sample rate, stereo), so each call gets its own factory
 * built with the audio profile it needs.
 *
 * <p>The video encoder/decoder factories are created once by {@link WebRTCModule} and shared across
 * all factories (passed in via {@link BuildOptions}). The ADM's sample-delivery callbacks
 * (screen-audio mixing, speech-activity detection, playback fan-out) are also supplied by the module
 * so that wiring stays in one place; this class only owns the factory + ADM lifecycle and the
 * profile-driven ADM build settings.
 */
class PeerConnectionFactoryProvider {
    private static final String TAG = "PeerConnectionFactoryProvider";

    static final class BuildOptions {
        @NonNull
        Context context;
        @NonNull
        VideoEncoderFactory videoEncoderFactory;
        @NonNull
        VideoDecoderFactory videoDecoderFactory;
        @Nullable
        AudioProcessingFactory audioProcessingFactory;
        /** The music / high-quality audio profile: disables HW AEC/NS, uses the raw mic source. */
        boolean bypassVoiceProcessing;
        /** Stereo microphone capture. Only takes effect under {@link #bypassVoiceProcessing}. */
        boolean stereoInputEnabled;
        /** Receives speaking-while-muted events; the module backs this with the RN event emitter. */
        @Nullable
        SpeechActivityDetector.Listener speechActivityListener;
        /**
         * Value of the {@code WebRTC-NetworkMonitorAutoDetect} field trial (empty when unset). Passed
         * to {@link NetworkMonitor#startMonitoring(Context, String)} so the detector this factory
         * keeps alive is configured exactly as the one native code would create.
         */
        @NonNull
        String networkMonitorFieldTrial = "";
    }

    @NonNull
    final String id;
    @NonNull
    final PeerConnectionFactory factory;
    @NonNull
    final AudioDeviceModule adm;
    final boolean bypassVoiceProcessing;

    final Set<Integer> ownedPcIds = ConcurrentHashMap.newKeySet();
    final Set<String> ownedTrackIds = ConcurrentHashMap.newKeySet();

    @NonNull
    private final Context applicationContext;
    @NonNull
    private final String networkMonitorFieldTrial;

    private volatile boolean disposed = false;

    // Whether this factory holds a reference on the process-wide Java NetworkMonitor.
    private boolean networkMonitorRetained = false;

    private PeerConnectionFactoryProvider(@NonNull String id, @NonNull PeerConnectionFactory factory,
                                          @NonNull AudioDeviceModule adm, boolean bypassVoiceProcessing,
                                          @NonNull Context applicationContext,
                                          @NonNull String networkMonitorFieldTrial) {
        this.id = id;
        this.factory = factory;
        this.adm = adm;
        this.bypassVoiceProcessing = bypassVoiceProcessing;
        this.applicationContext = applicationContext;
        this.networkMonitorFieldTrial = networkMonitorFieldTrial;
    }

    @NonNull
    static PeerConnectionFactoryProvider build(@NonNull String id, @NonNull BuildOptions options) {
        Log.d(TAG, "build() id=" + id + " bypassVoiceProcessing=" + options.bypassVoiceProcessing
                + " stereoInputEnabled=" + options.stereoInputEnabled);

        AudioDeviceModule adm = buildAudioDeviceModule(options);
        PeerConnectionFactory.Builder pcFactoryBuilder = PeerConnectionFactory.builder()
                                                                 .setAudioDeviceModule(adm)
                                                                 .setVideoEncoderFactory(options.videoEncoderFactory)
                                                                 .setVideoDecoderFactory(options.videoDecoderFactory);

        if (options.audioProcessingFactory != null) {
            pcFactoryBuilder.setAudioProcessingFactory(options.audioProcessingFactory);
        }

        PeerConnectionFactory factory = pcFactoryBuilder.createPeerConnectionFactory();

        return new PeerConnectionFactoryProvider(id, factory, adm, options.bypassVoiceProcessing,
                options.context.getApplicationContext(), options.networkMonitorFieldTrial);
    }

    /**
     * Holds a reference on libwebrtc's Java {@link NetworkMonitor} for this factory's lifetime.
     *
     * <p>Each PeerConnection's port allocator starts the native network monitor, which takes a
     * reference on the Java detector; the detector is destroyed when the last one is released. A
     * freshly created detector reports an empty network list until Android delivers
     * {@code onAvailable} asynchronously, so a PeerConnection created right after all others were
     * closed (e.g. during a rejoin) can see "no networks", finish gathering with zero candidates,
     * and only gather afterwards. Keeping the detector alive for the call keeps its network cache
     * populated, so every new PeerConnection gets the current networks synchronously.
     *
     * <p>Idempotent; released by {@link #dispose()}. Failures are logged and ignored, falling back to
     * the default libwebrtc behavior.
     */
    synchronized void retainNetworkMonitor() {
        if (disposed || networkMonitorRetained) {
            return;
        }
        try {
            NetworkMonitor.getInstance().startMonitoring(applicationContext, networkMonitorFieldTrial);
            networkMonitorRetained = true;
        } catch (Throwable t) {
            Log.w(TAG, "retainNetworkMonitor(): startMonitoring failed", t);
        }
    }

    private synchronized void releaseNetworkMonitor() {
        if (!networkMonitorRetained) {
            return;
        }
        networkMonitorRetained = false;
        try {
            NetworkMonitor.getInstance().stopMonitoring();
        } catch (Throwable t) {
            Log.w(TAG, "releaseNetworkMonitor(): stopMonitoring failed", t);
        }
    }

    /**
     * Extracts the value of the {@code WebRTC-NetworkMonitorAutoDetect} field trial from a field
     * trials string ({@code "Name1/Value1/Name2/Value2/"}), or returns an empty string when it is
     * absent. Mirrors the native {@code field_trials.Lookup("WebRTC-NetworkMonitorAutoDetect")}.
     */
    @NonNull
    static String networkMonitorFieldTrialValue(@Nullable String fieldTrials) {
        if (fieldTrials == null || fieldTrials.isEmpty()) {
            return "";
        }
        String[] parts = fieldTrials.split("/");
        for (int i = 0; i + 1 < parts.length; i += 2) {
            if ("WebRTC-NetworkMonitorAutoDetect".equals(parts[i])) {
                return parts[i + 1];
            }
        }
        return "";
    }

    @NonNull
    private static JavaAudioDeviceModule buildAudioDeviceModule(@NonNull BuildOptions options) {
        JavaAudioDeviceModule.Builder builder = JavaAudioDeviceModule.builder(options.context);

        if (options.bypassVoiceProcessing) {
            // Music / high-quality profile: bypass the platform voice pipeline so the raw,
            // native-rate signal reaches WebRTC unmodified. Stereo input is opt-in (it requires the
            // bypassed pipeline, since the platform voice path is mono).
            builder.setUseHardwareAcousticEchoCanceler(false)
                    .setUseHardwareNoiseSuppressor(false)
                    .setUseStereoOutput(true)
                    // .setUseStereoInput(options.stereoInputEnabled)
                    // .setAudioSource(MediaRecorder.AudioSource.MIC)
                    .setOutputSampleRate(nativeOutputSampleRate(options.context));
        } else {
            // Default voice profile: hardware AEC/NS where the platform supports it.
            builder.setUseHardwareAcousticEchoCanceler(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    .setUseHardwareNoiseSuppressor(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    .setUseStereoOutput(true);
        }

        final SpeechActivityDetector speechDetector = options.speechActivityListener != null
                ? new SpeechActivityDetector(options.speechActivityListener)
                : null;

        // Speaking-while-muted detection + screen-audio mixing, run on every captured mic buffer.
        builder.setAudioBufferCallback(
                (audioBuffer, audioFormat, channelCount, sampleRate, bytesRead, captureTimeNs) -> {
                    // 1. Speech activity detection on raw mic data, BEFORE any mutation.
                    if (speechDetector != null) {
                        speechDetector.processBuffer(audioBuffer, bytesRead);
                    }
                    // 2. Screen-audio mixing — mutates audioBuffer in place.
                    if (bytesRead > 0) {
                        WebRTCModuleOptions.ScreenAudioBytesProvider provider =
                                WebRTCModuleOptions.getInstance().screenAudioBytesProvider;
                        if (provider != null) {
                            ByteBuffer screenBuffer = provider.getScreenAudioBytes(bytesRead);
                            if (screenBuffer != null && screenBuffer.remaining() > 0) {
                                mixScreenAudioIntoBuffer(audioBuffer, screenBuffer, bytesRead);
                            }
                        }
                    }
                    return captureTimeNs;
                });

        if (speechDetector != null) {
            builder.setAudioRecordStateCallback(new JavaAudioDeviceModule.AudioRecordStateCallback() {
                @Override
                public void onWebRtcAudioRecordStart() {
                    speechDetector.reset();
                }

                @Override
                public void onWebRtcAudioRecordStop() {
                    speechDetector.onRecordStop();
                }
            });
        }

        builder.setPlaybackSamplesReadyCallback(samples -> {
            // Fan-out to every registered consumer. The list is a CopyOnWriteArrayList so iteration is
            // safe even if a consumer registers/unregisters mid-call.
            for (JavaAudioDeviceModule.PlaybackSamplesReadyCallback obs :
                    WebRTCModuleOptions.getInstance().getPlaybackSamplesObservers()) {
                try {
                    obs.onWebRtcAudioTrackSamplesReady(samples);
                } catch (Throwable t) {
                    // Audio device module thread must not throw.
                    Log.w(TAG, "playback samples observer threw", t);
                }
            }
        });

        return builder.createAudioDeviceModule();
    }

    /**
     * Mixes screen audio into the microphone buffer using PCM 16-bit additive mixing with clamping.
     * Handles different buffer sizes safely: each buffer is read only within its own bounds. When one
     * buffer is shorter, the other's samples pass through unmodified (mic samples stay as-is, or
     * screen-only samples are written).
     */
    private static void mixScreenAudioIntoBuffer(ByteBuffer micBuffer, ByteBuffer screenBuffer, int bytesRead) {
        micBuffer.position(0);
        screenBuffer.position(0);

        micBuffer.order(ByteOrder.LITTLE_ENDIAN);
        screenBuffer.order(ByteOrder.LITTLE_ENDIAN);

        ShortBuffer micShorts = micBuffer.asShortBuffer();
        ShortBuffer screenShorts = screenBuffer.asShortBuffer();

        int micSamples = Math.min(bytesRead / 2, micShorts.remaining());
        int screenSamples = screenShorts.remaining();
        int totalSamples = Math.max(micSamples, screenSamples);

        for (int i = 0; i < totalSamples; i++) {
            int sum;
            if (i >= micSamples) {
                // Screen-only: mic buffer is shorter — write screen sample directly
                sum = screenShorts.get(i);
            } else if (i >= screenSamples) {
                // Mic-only: screen buffer is shorter — keep mic sample as-is
                break;
            } else {
                // Both buffers have data — add samples
                sum = micShorts.get(i) + screenShorts.get(i);
            }
            if (sum > Short.MAX_VALUE) sum = Short.MAX_VALUE;
            if (sum < Short.MIN_VALUE) sum = Short.MIN_VALUE;
            micShorts.put(i, (short) sum);
        }
    }

    private static int nativeOutputSampleRate(@NonNull Context context) {
        AudioManager am = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (am != null) {
            String rate = am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE);
            if (rate != null) {
                try {
                    return Integer.parseInt(rate);
                } catch (NumberFormatException e) {
                    Log.w(TAG, "failed to parse native output sample rate, using 48000: " + e.getMessage());
                }
            }
        }
        return 48000;
    }

    void dispose() {
        if (disposed) {
            return;
        }
        disposed = true;

        try {
            factory.dispose();
        } catch (Throwable t) {
            Log.w(TAG, "dispose(): factory.dispose() failed", t);
        }

        try {
            adm.release();
        } catch (Throwable t) {
            Log.w(TAG, "dispose(): adm.release() failed", t);
        }

        releaseNetworkMonitor();
    }

    boolean isDisposed() {
        return disposed;
    }
}
