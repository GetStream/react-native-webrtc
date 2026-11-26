/**
 * Sample React Native App
 * https://github.com/facebook/react-native
 *
 * @format
 */
import React, {useState} from 'react';
import {
  Button,
  SafeAreaView,
  StyleSheet,
  View,
  StatusBar,
} from 'react-native';
import { mediaDevices, RTCView } from '@stream-io/react-native-webrtc';

// Logs what the JS track sees, so e2e/camera-taken-by-other-app.sh can check that the
// mute / unmute / ended events reach JavaScript (not only the native side).
const logTrackEvents = (track) => {
  const log = (what) =>
    console.log(`GumTestApp track ${what} id=${track.id} muted=${track.muted} readyState=${track.readyState}`);
  log('started');
  ['mute', 'unmute', 'ended'].forEach((type) => {
    track.addEventListener(type, () => log(type));
  });
};

const App = () => {
  const [stream, setStream] = useState(null);
  const start = async () => {
    console.log('start');
    if (!stream) {
      try {
        const s = await mediaDevices.getUserMedia({ video: true });
        logTrackEvents(s.getVideoTracks()[0]);
        setStream(s);
      } catch(e) {
        console.error(e);
      }
    }
  };
  const stop = () => {
    console.log('stop');
    if (stream) {
      stream.release();
      setStream(null);
    }
  };

  const flip = () => {
    console.log('flip');
    if (stream) {
      stream.getVideoTracks()[0]._switchCamera();
    }
  };

  const clone = () => {
    console.log('clone');
    if (stream) {
      const originalTrack = stream.getTracks()[0];
      const track = originalTrack.clone();
      console.log("original track id:", originalTrack.id)
      console.log("cloned track id:", track.id)
    }
  };

  return (
    <>
      <StatusBar barStyle="dark-content" />
      <SafeAreaView style={styles.body}>
      {
        stream &&
          <RTCView
            streamURL={stream.toURL()}
            style={styles.stream} />
      }
        <View
          style={styles.footer}>
          <Button
            title = "Start"
            onPress = {start} />
          <Button
            title = "Stop"
            onPress = {stop} />
          <Button
            title = "Flip"
            onPress = {flip} />
          <Button
            title = "Clone"
            onPress = {clone} />
        </View>
      </SafeAreaView>
    </>
  );
};

const styles = StyleSheet.create({
  body: {
    backgroundColor: '#fff',
    ...StyleSheet.absoluteFill
  },
  stream: {
    flex: 1
  },
  footer: {
    backgroundColor: '#f8f8f8',
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0
  },
});

export default App;
