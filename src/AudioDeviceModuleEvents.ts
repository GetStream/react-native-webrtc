import { NativeEventEmitter, NativeModules, Platform } from 'react-native';

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

export type AudioDeviceModuleEventData =
  | SpeechActivityEventData
  | EngineStateEventData
  | AudioProcessingStateEventData
  | Record<string, never>; // Empty object for events with no data

/**
 * Event emitter for RTCAudioDeviceModule delegate callbacks.
 * iOS/macOS only.
 */
class AudioDeviceModuleEventEmitter {
    private eventEmitter: NativeEventEmitter | null = null;

    public setupListeners() {
        // Only setup once (idempotent)
        if (this.eventEmitter !== null) {
            return;
        }

        if (Platform.OS !== 'android' && WebRTCModule) {
            this.eventEmitter = new NativeEventEmitter(WebRTCModule);
        }
    }

    /**
     * Subscribe to speech activity events (started/ended)
     */
    addSpeechActivityListener(listener: (data: SpeechActivityEventData) => void) {
        if (!this.eventEmitter) {
            throw new Error('AudioDeviceModuleEvents is only available on iOS/macOS');
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
}

export const audioDeviceModuleEvents = new AudioDeviceModuleEventEmitter();
