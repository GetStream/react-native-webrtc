import { Event, EventTarget, getEventAttributeValue, setEventAttributeValue } from 'event-target-shim';
import { NativeModules } from 'react-native';

import { addListener } from './EventEmitter';
import getDisplayMedia from './getDisplayMedia';
import getUserMedia, { Constraints } from './getUserMedia';

const { WebRTCModule } = NativeModules;

export type VideoTrackDimension = {
    width: number;
    height: number;
};

export const videoTrackDimensionChangedEventQueue = new Map<string, VideoTrackDimension>();

let listenersReady = false;

function ensureListeners() {
    if (listenersReady) {
        return;
    }

    addListener('MediaDevices', 'videoTrackDimensionChanged', (ev: any) => {
        // We only want to queue events for local tracks.
        if (ev.pcId !== -1) {
            return;
        }

        const { trackId, width, height } = ev;

        videoTrackDimensionChangedEventQueue.set(trackId, { width, height });
    });

    listenersReady = true;
}

type MediaDevicesEventMap = {
    devicechange: Event<'devicechange'>
}

class MediaDevices extends EventTarget<MediaDevicesEventMap> {
    get ondevicechange() {
        return getEventAttributeValue(this, 'devicechange');
    }

    set ondevicechange(value) {
        setEventAttributeValue(this, 'devicechange', value);
    }

    /**
     * W3C "Media Capture and Streams" compatible {@code enumerateDevices}
     * implementation.
     */
    enumerateDevices() {
        return new Promise(resolve => WebRTCModule.enumerateDevices(resolve));
    }

    /**
     * W3C "Screen Capture" compatible {@code getDisplayMedia} implementation.
     * See: https://w3c.github.io/mediacapture-screen-share/
     *
     * @returns {Promise}
     */
    getDisplayMedia() {
        ensureListeners();

        return getDisplayMedia();
    }

    /**
     * W3C "Media Capture and Streams" compatible {@code getUserMedia}
     * implementation.
     * See: https://www.w3.org/TR/mediacapture-streams/#dom-mediadevices-enumeratedevices
     *
     * @param {*} constraints
     * @returns {Promise}
     */
    getUserMedia(constraints: Constraints) {
        ensureListeners();

        return getUserMedia(constraints);
    }
}

export default new MediaDevices();
