import { NativeEventEmitter, NativeModules } from 'react-native';

const { WebRTCModule } = NativeModules;

export type SpeechActivityEvent = 'started' | 'ended';

export interface SpeechActivityEventData {
  event: SpeechActivityEvent;
}

export interface EngineStateEventData {
  isPlayoutEnabled: boolean;
  isRecordingEnabled: boolean;
}

export interface AudioProcessingStateEventData {
  voiceProcessingEnabled: boolean;
  voiceProcessingBypassed: boolean;
  voiceProcessingAGCEnabled: boolean;
  stereoPlayoutEnabled: boolean;
}

/**
 * A WebRTC audio device module (`AudioEngineDevice::`) warning/error log line.
 * Consecutive identical lines are collapsed into one event with `repeat` (total count, when > 1).
 * `dropped` counts lines suppressed by the rate limit (max 20 events per 10 s) since the previous event.
 */
export interface EngineErrorEventData {
  message: string;
  severity: 'warning' | 'error';
  /** Milliseconds since epoch of the first occurrence. */
  timestamp: number;
  repeat?: number;
  dropped?: number;
}

export type AudioDeviceModuleEventData =
  | SpeechActivityEventData
  | EngineStateEventData
  | AudioProcessingStateEventData
  | EngineErrorEventData
  | Record<string, never>; // Empty object for events with no data

/**
 * Event emitter for RTCAudioDeviceModule delegate callbacks.
 * Speech activity events are supported on iOS, macOS, and Android.
 * Engine/audio-processing-state events remain iOS/macOS only.
 */
class AudioDeviceModuleEventEmitter {
    private eventEmitter: NativeEventEmitter | null = null;

    public setupListeners() {
        // Only setup once (idempotent)
        if (this.eventEmitter !== null) {
            return;
        }

        if (WebRTCModule) {
            this.eventEmitter = new NativeEventEmitter(WebRTCModule);
        }
    }

    /**
     * Subscribe to speech activity events (started/ended).
     * Supported on iOS, macOS, and Android.
     */
    addSpeechActivityListener(listener: (data: SpeechActivityEventData) => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents: native module not available');
        }

        return this.eventEmitter.addListener('audioDeviceModuleSpeechActivity', listener);
    }

    /**
     * Subscribe to devices updated event (input/output devices changed)
     */
    addDevicesUpdatedListener(listener: () => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents is only available on iOS/macOS');
        }

        return this.eventEmitter.addListener('audioDeviceModuleDevicesUpdated', listener);
    }

    /**
     * Subscribe to audio processing state updated event
     */
    addAudioProcessingStateUpdatedListener(listener: (data: AudioProcessingStateEventData) => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents is only available on iOS/macOS');
        }

        return this.eventEmitter.addListener('audioDeviceModuleAudioProcessingStateUpdated', listener);
    }

    /**
     * Subscribe to engine created event
     */
    addEngineCreatedListener(listener: () => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents is only available on iOS/macOS');
        }

        return this.eventEmitter.addListener('audioDeviceModuleEngineCreated', listener);
    }

    /**
     * Subscribe to engine will enable event
     */
    addEngineWillEnableListener(listener: (data: EngineStateEventData) => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents is only available on iOS/macOS');
        }

        return this.eventEmitter.addListener('audioDeviceModuleEngineWillEnable', listener);
    }

    /**
     * Subscribe to engine will start event
     */
    addEngineWillStartListener(listener: (data: EngineStateEventData) => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents is only available on iOS/macOS');
        }

        return this.eventEmitter.addListener('audioDeviceModuleEngineWillStart', listener);
    }

    /**
     * Subscribe to engine did stop event
     */
    addEngineDidStopListener(listener: (data: EngineStateEventData) => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents is only available on iOS/macOS');
        }

        return this.eventEmitter.addListener('audioDeviceModuleEngineDidStop', listener);
    }

    /**
     * Subscribe to engine did disable event
     */
    addEngineDidDisableListener(listener: (data: EngineStateEventData) => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents is only available on iOS/macOS');
        }

        return this.eventEmitter.addListener('audioDeviceModuleEngineDidDisable', listener);
    }

    /**
     * Subscribe to engine will release event
     */
    addEngineWillReleaseListener(listener: () => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents is only available on iOS/macOS');
        }

        return this.eventEmitter.addListener('audioDeviceModuleEngineWillRelease', listener);
    }

    /**
     * Subscribe to audio engine error events (ADM warning/error log lines).
     * iOS only; never fires on Android.
     */
    addEngineErrorListener(listener: (data: EngineErrorEventData) => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents is only available on iOS/macOS');
        }

        return this.eventEmitter.addListener('audioDeviceModuleEngineError', listener);
    }
}

export const audioDeviceModuleEvents = new AudioDeviceModuleEventEmitter();
