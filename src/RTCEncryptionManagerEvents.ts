import { NativeEventEmitter, NativeModules } from 'react-native';

const { WebRTCModule } = NativeModules;

/**
 * Track type of an encrypted stream. Screen-share audio is distinct from microphone audio: replay
 * state is kept per (userId, trackType), so collapsing the two mis-groups it.
 */
export enum RTCEncryptionTrackType {
    AUDIO = 0,
    VIDEO = 1,
    SCREEN_SHARE = 2,
    SCREEN_SHARE_AUDIO = 3,
}

export type RTCEncryptionEventType =
    | 'e2ee.decryption_failed'
    | 'e2ee.decryption_resumed'
    | 'e2ee.decryption_stalled'
    | 'e2ee.encryption_failed'
    | 'e2ee.missing_key'
    | 'e2ee.unencrypted_frame'
    | 'e2ee.unsupported_version'
    | 'e2ee.key_state'
    | 'e2ee.perf_report';

export interface RTCEncryptionUserKey {
    userId: string;
    keyIndex: number;
    /** 16-char hex of SHA-256(rawKey)[:8]. Never key material. */
    fingerprint: string;
}

export interface RTCEncryptionSharedKey {
    keyIndex: number;
    fingerprint: string;
    isActive: boolean;
}

/** Payload of `e2ee.key_state`. At most one shared key is active. */
export interface RTCEncryptionKeyState {
    perUserKeys: RTCEncryptionUserKey[];
    sharedKeys: RTCEncryptionSharedKey[];
}

/** One row of `e2ee.perf_report`. `codec` is set on encode samples only. */
export interface RTCEncryptionTrackPerf {
    userId: string;
    trackType: RTCEncryptionTrackType;
    codec?: string;
    fps: number;
    maxCryptoMs: number;
}

export interface RTCEncryptionEventData {
    /** Handle of the manager the event belongs to. */
    managerId: string;
    type: RTCEncryptionEventType;
    userId: string;
    trackType?: RTCEncryptionTrackType;
    keyIndex?: number;
    version?: number;
    reason?: string;
    keyState?: RTCEncryptionKeyState;
    encode?: RTCEncryptionTrackPerf[];
    decode?: RTCEncryptionTrackPerf[];
}

/**
 * Event emitter for native `RTCEncryptionManager` events. This is a dedicated emitter rather than an
 * entry in the NATIVE_EVENTS allowlist of EventEmitter.ts, so the allowlist does not have to stay
 * hand-synced with the native event constants.
 */
class RTCEncryptionManagerEventEmitter {
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
     * Subscribe to every `e2ee.*` event of every manager. Consumers filter by `managerId`.
     */
    addEncryptionManagerEventListener(listener: (data: RTCEncryptionEventData) => void) {
        if (!this.eventEmitter) {
            throw new Error('RTCEncryptionManagerEvents: native module not available');
        }

        return this.eventEmitter.addListener('encryptionManagerEvent', listener);
    }
}

export const encryptionManagerEvents = new RTCEncryptionManagerEventEmitter();
