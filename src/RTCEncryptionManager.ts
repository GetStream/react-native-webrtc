import * as base64 from 'base64-js';
import { NativeModules, type EmitterSubscription } from 'react-native';

import {
    encryptionManagerEvents,
    type RTCEncryptionEventData,
    type RTCEncryptionEventType,
    RTCEncryptionTrackType,
} from './RTCEncryptionManagerEvents';
import RTCRtpReceiver from './RTCRtpReceiver';
import RTCRtpSender from './RTCRtpSender';

const { WebRTCModule } = NativeModules;

/** AES-GCM key size. Default is AES-128, i.e. 16-byte keys. */
export enum RTCEncryptionAlgorithm {
    AES_128_GCM = 0,
    AES_256_GCM = 1,
}

export interface RTCEncryptionManagerOptions {
    algorithm?: RTCEncryptionAlgorithm;
}

type NativeResult = { handle?: string, error?: string };

/**
 * End-to-end encryption of already-encoded media frames (framed AES-GCM). One manager holds the
 * keys and attaches encrypt/decrypt transforms to RTP senders and receivers; the SFU then forwards
 * ciphertext it cannot read.
 *
 * The key and attach operations are synchronous by design: an async attach would leave a window
 * where a sender exists before its transform is installed, which is a plaintext window. They throw
 * on failure so a caller can never mistake a failed attach for a successful one.
 *
 * There is no detach API. Once attached, the only exits are destroying the sender/receiver or
 * calling {@link dispose}, which drops in-flight frames rather than draining them. Nothing native
 * cleans a manager up when a peer connection closes, so callers must dispose explicitly.
 */
export default class RTCEncryptionManager {
    _handle: string;
    _disposed = false;
    _subscription: EmitterSubscription | null = null;
    _listeners: Map<RTCEncryptionEventType, Set<(data: RTCEncryptionEventData) => void>> = new Map();

    /** Native always supports encoded transforms, unlike the browser Encoded Transform API. */
    static isSupported(): boolean {
        return Boolean(WebRTCModule?.encryptionManagerIsSupported?.());
    }

    static create(userId: string, options: RTCEncryptionManagerOptions = {}): RTCEncryptionManager {
        const result: NativeResult = WebRTCModule.encryptionManagerCreate({
            userId,
            ...(options.algorithm === undefined ? {} : { algorithm: options.algorithm }),
        });

        if (result?.error || !result?.handle) {
            throw new Error(result?.error ?? 'Failed to create the encryption manager');
        }

        return new RTCEncryptionManager(result.handle);
    }

    constructor(handle: string) {
        this._handle = handle;
        this._registerEvents();
    }

    /**
     * Install a key for a participant. `rawKey` must be 16 bytes for AES-128 or 32 for AES-256, and
     * `keyIndex` must be in the 0-255 range.
     */
    setKey(userId: string, keyIndex: number, rawKey: Uint8Array): void {
        this._invoke('encryptionManagerSetKey', {
            userId,
            keyIndex,
            key: base64.fromByteArray(rawKey),
        });
    }

    /** Install a key shared by every participant of the call. */
    setSharedKey(keyIndex: number, rawKey: Uint8Array): void {
        this._invoke('encryptionManagerSetSharedKey', {
            keyIndex,
            key: base64.fromByteArray(rawKey),
        });
    }

    removeKey(userId: string, keyIndex: number): void {
        this._invoke('encryptionManagerRemoveKey', { userId, keyIndex });
    }

    removeAllKeys(userId: string): void {
        this._invoke('encryptionManagerRemoveAllKeys', { userId });
    }

    removeSharedKey(keyIndex: number): void {
        this._invoke('encryptionManagerRemoveSharedKey', { keyIndex });
    }

    /**
     * Attach the encrypt transform to a sender.
     *
     * `codec` is an exact lowercase pin (`opus`/`vp8`/`vp9`/`h264`); anything else fails closed.
     * Omitting it reads the codec from the frame. Omitting `trackType` defaults to audio vs video
     * from the sender, so screen-share types must be passed explicitly.
     */
    encrypt(sender: RTCRtpSender, codec?: string, trackType?: RTCEncryptionTrackType): void {
        this._invoke('encryptionManagerEncrypt', {
            peerConnectionId: sender._peerConnectionId,
            senderId: sender._id,
            ...(codec === undefined ? {} : { codec }),
            ...(trackType === undefined ? {} : { trackType }),
        });
    }

    /** Attach the decrypt transform to a receiver carrying `userId`'s media. */
    decrypt(receiver: RTCRtpReceiver, userId: string, trackType?: RTCEncryptionTrackType): void {
        this._invoke('encryptionManagerDecrypt', {
            peerConnectionId: receiver._peerConnectionId,
            receiverId: receiver._id,
            userId,
            ...(trackType === undefined ? {} : { trackType }),
        });
    }

    /** When enabled, `e2ee.perf_report` is emitted once per second. */
    enablePerformanceReporting(enabled: boolean): Promise<void> {
        this._assertNotDisposed();

        return WebRTCModule.encryptionManagerEnablePerformanceReporting(this._handle, enabled);
    }

    /** Ask for an `e2ee.key_state` event carrying the current key fingerprints. */
    requestKeyState(): Promise<void> {
        this._assertNotDisposed();

        return WebRTCModule.encryptionManagerRequestKeyState(this._handle);
    }

    on(type: RTCEncryptionEventType, listener: (data: RTCEncryptionEventData) => void): void {
        this._assertNotDisposed();

        let listeners = this._listeners.get(type);

        if (!listeners) {
            listeners = new Set();
            this._listeners.set(type, listeners);
        }

        listeners.add(listener);
    }

    off(type: RTCEncryptionEventType, listener: (data: RTCEncryptionEventData) => void): void {
        this._listeners.get(type)?.delete(listener);
    }

    /** Drops in-flight frames. Keys and transforms are released; the handle becomes unusable. */
    dispose(): void {
        if (this._disposed) {
            return;
        }

        // Marked disposed only once the native cleanup succeeds: the native side keeps a manager
        // registered when its cleanup throws, so a failed dispose() has to stay retryable here too.
        this._invoke('encryptionManagerDispose', {});

        this._disposed = true;
        this._subscription?.remove();
        this._subscription = null;
        this._listeners.clear();
    }

    _assertNotDisposed(): void {
        if (this._disposed) {
            throw new Error('RTCEncryptionManager has been disposed');
        }
    }

    _invoke(method: string, params: Record<string, unknown>): void {
        this._assertNotDisposed();

        const result: NativeResult = WebRTCModule[method]({ handle: this._handle, ...params });

        if (result?.error) {
            throw new Error(result.error);
        }
    }

    _registerEvents(): void {
        // Idempotent, and keeps this class usable when imported directly rather than via index.ts.
        encryptionManagerEvents.setupListeners();

        this._subscription = encryptionManagerEvents.addEncryptionManagerEventListener(ev => {
            if (ev.managerId !== this._handle) {
                return;
            }

            this._listeners.get(ev.type)?.forEach(listener => listener(ev));
        });
    }
}
