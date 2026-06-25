import { NativeModules } from 'react-native';

const { WebRTCModule } = NativeModules;

export interface CallFactoryOptions {
    /**
     * Music / high-quality audio profile: builds the AudioDeviceModule with hardware AEC/NS disabled
     * and the raw mic source so the unprocessed signal reaches WebRTC. Baked in at construction —
     * immutable for the life of the factory.
     */
    bypassVoiceProcessing?: boolean;
    /**
     * Builds the AudioDeviceModule for stereo microphone capture. Android only; ignored on iOS.
     * Baked in at construction — immutable for the life of the factory.
     */
    stereoInputEnabled?: boolean;
}

/**
 * Handle to the native call PeerConnectionFactory (and its AudioDeviceModule). Creating one builds a
 * fresh native factory and makes it the single live factory, so the standard globals
 * (`mediaDevices.getUserMedia` / `new RTCPeerConnection`) resolve to it for the life of the call.
 * Create one per call and {@link dispose} it when the call ends.
 */
export default class CallFactory {
    /** Builds a fresh native factory with the given audio profile and makes it the live factory. */
    static async create(options: CallFactoryOptions = {}): Promise<CallFactory> {
        await WebRTCModule.createCallFactory({
            bypassVoiceProcessing: options.bypassVoiceProcessing ?? false,
            stereoInputEnabled: options.stereoInputEnabled ?? false
        });

        return new CallFactory();
    }

    /** Disposes the live call factory and its ADM. Resolves to true if a factory was disposed. */
    dispose(): Promise<boolean> {
        return WebRTCModule.disposeCallFactory();
    }
}
