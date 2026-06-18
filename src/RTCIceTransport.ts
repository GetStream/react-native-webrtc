import RTCIceCandidate from './RTCIceCandidate';
import { Event, EventTarget, getEventAttributeValue, setEventAttributeValue } from './vendor/event-target-shim';

export type RTCIceTransportState =
    | 'new'
    | 'checking'
    | 'connected'
    | 'completed'
    | 'disconnected'
    | 'failed'
    | 'closed';

export type RTCIceGathererState = 'new' | 'gathering' | 'complete';

export type RTCIceCandidatePair = {
    local: RTCIceCandidate,
    remote: RTCIceCandidate
};

type RTCIceTransportEventMap = {
    selectedcandidatepairchange: Event<'selectedcandidatepairchange'>,
    statechange: Event<'statechange'>,
    gatheringstatechange: Event<'gatheringstatechange'>
};

/**
 * Partial implementation of the W3C `RTCIceTransport` interface.
 *
 * This fork's WebRTC binaries do not expose the native ICE transport object, so
 * there is no per-transport native handle to bridge. Because Stream always uses
 * BUNDLE, a single ICE transport is shared by the whole `RTCPeerConnection`;
 * the owning connection owns one instance of this class and feeds it from the
 * peer-connection-level `peerConnectionSelectedCandidatePairChanged` event.
 *
 * `state` and `gatheringState` are best-effort values derived from the
 * connection's ICE state; they fire `statechange` / `gatheringstatechange`
 * when they transition. The selected candidate pair fires
 * `selectedcandidatepairchange`.
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/RTCIceTransport MDN}
 */
export default class RTCIceTransport extends EventTarget<RTCIceTransportEventMap> {
    _state: RTCIceTransportState = 'new';
    _gatheringState: RTCIceGathererState = 'new';
    _selectedCandidatePair: RTCIceCandidatePair | null = null;

    get state(): RTCIceTransportState {
        return this._state;
    }

    get gatheringState(): RTCIceGathererState {
        return this._gatheringState;
    }

    getSelectedCandidatePair(): RTCIceCandidatePair | null {
        return this._selectedCandidatePair;
    }

    get onselectedcandidatepairchange() {
        return getEventAttributeValue(this, 'selectedcandidatepairchange');
    }

    set onselectedcandidatepairchange(value) {
        setEventAttributeValue(this, 'selectedcandidatepairchange', value);
    }

    get onstatechange() {
        return getEventAttributeValue(this, 'statechange');
    }

    set onstatechange(value) {
        setEventAttributeValue(this, 'statechange', value);
    }

    get ongatheringstatechange() {
        return getEventAttributeValue(this, 'gatheringstatechange');
    }

    set ongatheringstatechange(value) {
        setEventAttributeValue(this, 'gatheringstatechange', value);
    }

    /**
     * @internal Called by the owning RTCPeerConnection when native reports a
     * selected candidate pair change. Not part of the public API.
     */
    _setSelectedCandidatePair(local: RTCIceCandidate | null, remote: RTCIceCandidate | null): void {
        // W3C getSelectedCandidatePair() is all-or-nothing and, once set, "will
        // always be available from that time forward" — it never reverts to
        // null. libwebrtc can fire a transient mid-transition event with only
        // one side resolved; ignore those so we never expose (or clobber an
        // existing pair with) a half-populated pair.
        if (!local || !remote) {
            return;
        }

        // The spec fires selectedcandidatepairchange only when a *different*
        // pair is selected. Native re-fires this callback as lastDataReceivedMs
        // updates with the same pair, so skip when nothing actually changed.
        const current = this._selectedCandidatePair;

        if (current
            && current.local.candidate === local.candidate
            && current.local.sdpMid === local.sdpMid
            && current.remote.candidate === remote.candidate
            && current.remote.sdpMid === remote.sdpMid) {
            return;
        }

        this._selectedCandidatePair = { local, remote };
        this.dispatchEvent(new Event('selectedcandidatepairchange'));
    }

    /**
     * @internal Derived from the owning RTCPeerConnection's iceConnectionState.
     * Fires `statechange` on an actual transition.
     */
    _setState(state: RTCIceTransportState): void {
        if (this._state === state) {
            return;
        }

        this._state = state;
        this.dispatchEvent(new Event('statechange'));
    }

    /**
     * @internal Derived from the owning RTCPeerConnection's iceGatheringState.
     * Fires `gatheringstatechange` on an actual transition.
     */
    _setGatheringState(state: RTCIceGathererState): void {
        if (this._gatheringState === state) {
            return;
        }

        this._gatheringState = state;
        this.dispatchEvent(new Event('gatheringstatechange'));
    }
}
