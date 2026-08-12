import { requireNativeComponent, ViewProps } from 'react-native';

/**
 * A WebRTC-free camera preview.
 *
 * Unlike {@link RTCView}, this component does NOT render a WebRTC track. It
 * drives the platform camera capturer directly and renders the captured frames
 * to a local view — without creating an `RTCVideoSource`, a track, or a
 * `PeerConnectionFactory`. It is intended for the call lobby, before any peer
 * connection factory exists.
 *
 * At join the running capturer is reused by the published WebRTC track: its
 * frames are routed into the track's video source while the camera keeps
 * running, so the preview and the published track share one camera session.
 *
 * Native prop validation was removed from RN in:
 * https://github.com/facebook/react-native/commit/8dc3ba0444c94d9bbb66295b5af885bff9b9cd34
 * So we list the props here for documentation purposes.
 */
interface RTCCameraPreviewViewProps extends ViewProps {
  /**
   * Which camera to preview. Ignored when {@link #deviceId} is set.
   *
   * facing: 'front' | 'back'
   */
  facing?: 'front' | 'back';

  /**
   * Explicit camera device id to preview. Takes precedence over
   * {@link #facing}.
   *
   * deviceId: string
   */
  deviceId?: string;

  /**
   * Whether the preview capture is running. Set to `false` to stop capturing
   * and release the camera (e.g. when leaving the lobby, or just before the
   * WebRTC capturer takes over at join).
   *
   * isActive: boolean
   */
  isActive?: boolean;

  /**
   * Whether the preview should be mirrored during rendering. Commonly enabled
   * for the user-facing (front) camera.
   *
   * mirror: boolean
   */
  mirror?: boolean;

  /**
   * Resembles the CSS style object-fit.
   *
   * objectFit: 'contain' | 'cover'
   */
  objectFit?: 'contain' | 'cover';

  /**
   * Capture width in pixels (landscape). Defaults to 1280. Set this to the
   * call's target resolution so the running capturer can be adopted by the
   * WebRTC track at join without reconfiguring.
   *
   * captureWidth: number
   */
  captureWidth?: number;

  /**
   * Capture height in pixels (landscape). Defaults to 720.
   *
   * captureHeight: number
   */
  captureHeight?: number;
}

export default requireNativeComponent<RTCCameraPreviewViewProps>(
    'RTCCameraPreviewView',
);
