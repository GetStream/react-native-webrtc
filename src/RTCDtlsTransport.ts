import RTCIceTransport from './RTCIceTransport';
import { Event, EventTarget, getEventAttributeValue, setEventAttributeValue } from './vendor/event-target-shim';

export type RTCDtlsTransportState = 'new' | 'connecting' | 'connected' | 'closed' | 'failed';

type RTCDtlsTransportEventMap = {
    statechange: Event<'statechange'>
};

/**
 * Partial implementation of the W3C `RTCDtlsTransport` interface.
 *
 * This fork's WebRTC binaries do not expose the native DTLS transport object,
 * so this class is a thin JS wrapper. Because Stream always uses BUNDLE, a
 * single DTLS transport is shared by the whole `RTCPeerConnection`; the owning
 * connection creates one instance and hands it to every sender/receiver via
 * their `transport` property.
 *
 * The primary purpose is to expose `iceTransport`, which carries the
 * `selectedcandidatepairchange` event. `state` is a best-effort value derived
 * from the connection's `connectionState` and fires `statechange` when it
 * transitions.
 *
 * Limitation: only the single bundled transport is modeled. With a
 * `bundlePolicy` other than `max-bundle` (or a non-bundling peer) a connection
 * can negotiate multiple transports; this object then represents only one of
 * them, and every sender/receiver still reports it. `RTCPeerConnection` logs a
 * warning if it detects more than one ICE transport at runtime.
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/RTCDtlsTransport MDN}
 */
export default class RTCDtlsTransport extends EventTarget<RTCDtlsTransportEventMap> {
    _state: RTCDtlsTransportState = 'new';
    _iceTransport: RTCIceTransport;

    constructor(iceTransport: RTCIceTransport) {
        super();

        this._iceTransport = iceTransport;
    }

    get iceTransport(): RTCIceTransport {
        return this._iceTransport;
    }

    get state(): RTCDtlsTransportState {
        return this._state;
    }

    get onstatechange() {
        return getEventAttributeValue(this, 'statechange');
    }

    set onstatechange(value) {
        setEventAttributeValue(this, 'statechange', value);
    }

    /**
     * @internal Derived from the owning RTCPeerConnection's connectionState.
     * Fires `statechange` on an actual transition.
     */
    _setState(state: RTCDtlsTransportState): void {
        if (this._state === state) {
            return;
        }

        this._state = state;
        this.dispatchEvent(new Event('statechange'));
    }
}
