import { NativeModules, Platform } from 'react-native';

const { WebRTCModule } = NativeModules;

export enum AudioEngineMuteMode {
  Unknown = -1,
  VoiceProcessing = 0,
  RestartEngine = 1,
  InputMixer = 2,
}

/**
 * Returns the native WebRTCModule after verifying the platform is iOS/macOS.
 * Throws on Android where these audio device module APIs are not available.
 */
const getAudioDeviceModule = () => {
    if (Platform.OS === 'android') {
        throw new Error('AudioDeviceModule is only available on iOS/macOS');
    }

    return WebRTCModule;
};

/**
 * Audio Device Module API for controlling audio devices and settings.
 * iOS/macOS only - will throw on Android.
 */
export class AudioDeviceModule {
    /**
     * Start audio playback
     */
    static async startPlayout(): Promise<void> {
        return getAudioDeviceModule().audioDeviceModuleStartPlayout();
    }

    /**
     * Stop audio playback
     */
    static async stopPlayout(): Promise<void> {
        return getAudioDeviceModule().audioDeviceModuleStopPlayout();
    }

    /**
     * Start audio recording
     */
    static async startRecording(): Promise<void> {
        return getAudioDeviceModule().audioDeviceModuleStartRecording();
    }

    /**
     * Stop audio recording
     */
    static async stopRecording(): Promise<void> {
        return getAudioDeviceModule().audioDeviceModuleStopRecording();
    }

    /**
     * Initialize and start local audio recording (calls initAndStartRecording)
     */
    static async startLocalRecording(): Promise<void> {
        return getAudioDeviceModule().audioDeviceModuleStartLocalRecording();
    }

    /**
     * Stop local audio recording
     */
    static async stopLocalRecording(): Promise<void> {
        return getAudioDeviceModule().audioDeviceModuleStopLocalRecording();
    }

    /**
     * Mute or unmute the microphone
     */
    static async setMicrophoneMuted(muted: boolean): Promise<void> {
        return getAudioDeviceModule().audioDeviceModuleSetMicrophoneMuted(muted);
    }

    /**
     * Check if microphone is currently muted
     */
    static isMicrophoneMuted(): boolean {
        return getAudioDeviceModule().audioDeviceModuleIsMicrophoneMuted();
    }

    /**
     * Enable or disable voice processing (requires engine restart)
     */
    static async setVoiceProcessingEnabled(enabled: boolean): Promise<void> {
        return getAudioDeviceModule().audioDeviceModuleSetVoiceProcessingEnabled(enabled);
    }

    /**
     * Check if voice processing is enabled
     */
    static isVoiceProcessingEnabled(): boolean {
        return getAudioDeviceModule().audioDeviceModuleIsVoiceProcessingEnabled();
    }

    /**
     * Temporarily bypass voice processing without restarting the engine
     */
    static setVoiceProcessingBypassed(bypassed: boolean): void {
        getAudioDeviceModule().audioDeviceModuleSetVoiceProcessingBypassed(bypassed);
    }

    /**
     * Check if voice processing is currently bypassed
     */
    static isVoiceProcessingBypassed(): boolean {
        return getAudioDeviceModule().audioDeviceModuleIsVoiceProcessingBypassed();
    }

    /**
     * Enable or disable Automatic Gain Control (AGC)
     */
    static setVoiceProcessingAGCEnabled(enabled: boolean): void {
        return getAudioDeviceModule().audioDeviceModuleSetVoiceProcessingAGCEnabled(enabled);
    }

    /**
     * Check if AGC is enabled
     */
    static isVoiceProcessingAGCEnabled(): boolean {
        return getAudioDeviceModule().audioDeviceModuleIsVoiceProcessingAGCEnabled();
    }

    /**
     * Check if audio is currently playing
     */
    static isPlaying(): boolean {
        return getAudioDeviceModule().audioDeviceModuleIsPlaying();
    }

    /**
     * Check if audio is currently recording
     */
    static isRecording(): boolean {
        return getAudioDeviceModule().audioDeviceModuleIsRecording();
    }

    /**
     * Check if the audio engine is running
     */
    static isEngineRunning(): boolean {
        return getAudioDeviceModule().audioDeviceModuleIsEngineRunning();
    }

    /**
     * Set the microphone mute mode
     */
    static async setMuteMode(mode: AudioEngineMuteMode): Promise<void> {
        return getAudioDeviceModule().audioDeviceModuleSetMuteMode(mode);
    }

    /**
     * Get the current mute mode
     */
    static getMuteMode(): AudioEngineMuteMode {
        return getAudioDeviceModule().audioDeviceModuleGetMuteMode();
    }

    /**
     * Enable or disable advanced audio ducking
     */
    static setAdvancedDuckingEnabled(enabled: boolean): void {
        return getAudioDeviceModule().audioDeviceModuleSetAdvancedDuckingEnabled(enabled);
    }

    /**
     * Check if advanced ducking is enabled
     */
    static isAdvancedDuckingEnabled(): boolean {
        return getAudioDeviceModule().audioDeviceModuleIsAdvancedDuckingEnabled();
    }

    /**
     * Set the audio ducking level (0-100)
     */
    static setDuckingLevel(level: number): void {
        getAudioDeviceModule();

        if (typeof level !== 'number' || isNaN(level)) {
            throw new TypeError(`setDuckingLevel: expected a number, got ${typeof level}`);
        }

        if (!Number.isInteger(level) || level < 0 || level > 100) {
            throw new RangeError(`setDuckingLevel: level must be an integer between 0 and 100, got ${level}`);
        }

        return WebRTCModule.audioDeviceModuleSetDuckingLevel(level);
    }

    /**
     * Get the current ducking level
     */
    static getDuckingLevel(): number {
        return getAudioDeviceModule().audioDeviceModuleGetDuckingLevel();
    }

    /**
     * Check if recording always prepared mode is enabled
     */
    static isRecordingAlwaysPreparedMode(): boolean {
        return getAudioDeviceModule().audioDeviceModuleIsRecordingAlwaysPreparedMode();
    }

    /**
     * Enable or disable recording always prepared mode
     */
    static async setRecordingAlwaysPreparedMode(enabled: boolean): Promise<void> {
        return getAudioDeviceModule().audioDeviceModuleSetRecordingAlwaysPreparedMode(enabled);
    }

    // TODO: getEngineAvailability / setEngineAvailability are not supported by the
    // Stream WebRTC SDK (no RTCAudioEngineAvailability type / setEngineAvailability:
    // method). Re-add if/when the native API lands.
}
