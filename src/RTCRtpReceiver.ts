import { NativeModules } from 'react-native';

import MediaStreamTrack from './MediaStreamTrack';
import RTCDtlsTransport from './RTCDtlsTransport';
import RTCRtpCapabilities from './RTCRtpCapabilities';
import { RTCRtpParametersInit } from './RTCRtpParameters';
import RTCRtpReceiveParameters from './RTCRtpReceiveParameters';

const { WebRTCModule } = NativeModules;

export default class RTCRtpReceiver {
    _id: string;
    _peerConnectionId: number;
    _track: MediaStreamTrack | null = null;
    _rtpParameters: RTCRtpReceiveParameters;
    _transport: RTCDtlsTransport | null = null;

    constructor(info: {
        peerConnectionId: number,
        id: string,
        track?: MediaStreamTrack,
        rtpParameters: RTCRtpParametersInit,
        transport?: RTCDtlsTransport | null
    }) {
        this._id = info.id;
        this._peerConnectionId = info.peerConnectionId;
        this._rtpParameters = new RTCRtpReceiveParameters(info.rtpParameters);
        this._transport = info.transport ?? null;

        if (info.track) {
            this._track = info.track;
        }
    }

    static getCapabilities(kind: 'audio' | 'video'): RTCRtpCapabilities {
        return WebRTCModule.receiverGetCapabilities(kind);
    }

    getStats() {
        return WebRTCModule.receiverGetStats(this._peerConnectionId, this._id).then(data =>
            /* On both Android and iOS it is faster to construct a single
            JSON string representing the Map of StatsReports and have it
            pass through the React Native bridge rather than the Map of
            StatsReports. While the implementations do try to be faster in
            general, the stress is on being faster to pass through the React
            Native bridge which is a bottleneck that tends to be visible in
            the UI when there is congestion involving UI-related passing.
            */
            new Map(JSON.parse(data))
        );
    }

    getParameters(): RTCRtpReceiveParameters {
        return this._rtpParameters;
    }

    get id() {
        return this._id;
    }

    get track() {
        return this._track;
    }

    /**
     * The DTLS transport over which media for this receiver is received. Under
     * `max-bundle` this is the single transport shared by the whole
     * RTCPeerConnection. Null when the receiver has no connection yet, or when
     * the connection uses a non-`max-bundle` policy (where a single shared
     * transport cannot be represented faithfully).
     * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpReceiver/transport MDN}
     */
    get transport(): RTCDtlsTransport | null {
        return this._transport;
    }
}
