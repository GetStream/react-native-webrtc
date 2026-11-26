#!/usr/bin/env bash
#
# Device check: the camera comes back after another app takes it (Android 10+).
#
# Steps:
#   1. Start GumTestApp and tap "Start" (the camera turns on).
#   2. Open the system Camera app. Android takes our camera away.
#      Expected: our camera is disconnected.
#   3. Go back to GumTestApp.
#      Expected: the camera opens again and frames arrive. The track is not ended.
#   4. Expected: the JS track (GumTestApp's own listeners, App.js) got "mute" and then
#      "unmute", it is the same track as before, and it is still live.
#   5. Tap "Flip". Expected: the camera switches and frames arrive
#      (before the fix this failed with "switchCamera: camera is not running").
#
# Before the fix (CameraReopener), step 3 fails: libwebrtc stops the camera when Android
# takes it, and nothing opens it again, so no frame arrives after going back.
#
# This checks the device log (logcat): native lines from the fork and JS lines that
# GumTestApp writes with console.log, so it needs a debug build.
#
# Before running:
#   - Connect one Android 10+ device (or set ANDROID_SERIAL to pick one).
#   - Install GumTestApp: cd examples/GumTestApp/android && ./gradlew :app:installDebug
#   - Start Metro: cd examples/GumTestApp && npx react-native start
#
# Usage:
#   examples/GumTestApp/e2e/camera-taken-by-other-app.sh
#
# Options (environment variables):
#   ANDROID_SERIAL       device to use when more than one is connected
#   OTHER_APP_SECONDS    how long the Camera app stays open (default 5)
#   TIMEOUT_SECONDS      how long to wait for each expected log line (default 20)
#   LOG_FILE             where to save the logcat output (default: a temp file)
#
# Exit codes: 0 = passed, 1 = failed, 2 = skipped (Android older than 10).

set -euo pipefail

APP_ID="com.gumtestapp"
OTHER_APP_SECONDS="${OTHER_APP_SECONDS:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-20}"
LOG_FILE="${LOG_FILE:-$(mktemp -t camera-taken-by-other-app).log}"

TEST_START_TIME=""

# Saves the device log of this run, so it can be read after a failure.
save_log() {
    if [ -n "$TEST_START_TIME" ]; then
        logs_since "$TEST_START_TIME" > "$LOG_FILE" 2>/dev/null || true
        echo "Logcat saved to: $LOG_FILE"
    fi
}

step() { echo ""; echo "== $*"; }
pass() { echo "   PASS: $*"; }
fail() {
    echo "   FAIL: $*"
    echo ""
    save_log
    exit 1
}

# The device's current time, in the format logcat uses ("MM-DD hh:mm:ss.mmm").
# Each check reads only the log lines written after a time like this.
device_time() { adb shell date +'%m-%d\ %H:%M:%S.000' | tr -d '\r'; }

# All log lines written on the device since the given time.
# Read fresh from the device on every call, so no line arrives late.
logs_since() { adb logcat -d -v time -T "$1"; }

# Waits until a log line matching the pattern appears after the given time.
# Usage: wait_for_log <pattern> <since> <description>
wait_for_log() {
    local pattern="$1" since="$2" description="$3"
    local waited=0
    while [ "$waited" -lt $((TIMEOUT_SECONDS * 2)) ]; do
        if logs_since "$since" | grep -qE "$pattern"; then
            pass "$description"
            return 0
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    fail "$description (no log line matching '$pattern' within ${TIMEOUT_SECONDS}s)"
}

# Fails unless a log line matching the pattern already appeared after the given time.
# Usage: expect_log <pattern> <since> <description>
expect_log() {
    local pattern="$1" since="$2" description="$3"
    if ! logs_since "$since" | grep -qE "$pattern"; then
        fail "$description (no log line matching '$pattern')"
    fi
    pass "$description"
}

# Fails unless the first line matching <first> comes before the first line matching <second>.
# Usage: expect_first_before <first> <second> <since> <description>
expect_first_before() {
    local first="$1" second="$2" since="$3" description="$4"
    local lines first_line second_line
    lines="$(logs_since "$since")"
    first_line="$(echo "$lines" | grep -nE "$first" | head -1 | cut -d: -f1)"
    second_line="$(echo "$lines" | grep -nE "$second" | head -1 | cut -d: -f1)"
    if [ -z "$first_line" ] || [ -z "$second_line" ] || [ "$first_line" -ge "$second_line" ]; then
        fail "$description"
    fi
    pass "$description"
}

# Fails if a log line matching the pattern appears after the given time.
# Usage: expect_no_log <pattern> <since> <description>
expect_no_log() {
    local pattern="$1" since="$2" description="$3"
    local found
    found="$(logs_since "$since" | grep -E "$pattern" | head -1 || true)"
    if [ -n "$found" ]; then
        fail "$description (found: $found)"
    fi
    pass "$description"
}

# Prints "x y" for the first element on screen that matches, or nothing.
#   find_on_screen equals <label>    text or description equals the label (any case): its center
#   find_on_screen contains <label>  description contains the label (any case): its right end,
#                                    where React Native's dev warning bar has its close button
find_on_screen() {
    # uiautomator waits for the screen to be still and can hang while something animates
    # (for example Metro's loading bar), so give it at most 10 seconds.
    adb shell rm -f /sdcard/camera-e2e-ui.xml
    adb shell timeout 10 uiautomator dump /sdcard/camera-e2e-ui.xml >/dev/null 2>&1 || true
    adb exec-out cat /sdcard/camera-e2e-ui.xml 2>/dev/null | python3 -I -c '
import re, sys, xml.etree.ElementTree as ET
mode, label = sys.argv[1], sys.argv[2].lower()
try:
    root = ET.fromstring(sys.stdin.read())
except ET.ParseError:
    sys.exit(0)
for node in root.iter("node"):
    text, desc = node.get("text", "").lower(), node.get("content-desc", "").lower()
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
    if mode == "equals" and label in (text, desc):
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
    if mode == "contains" and label in desc:
        print(x2 - 45, (y1 + y2) // 2)
        break
' "$1" "$2"
}

# Debug builds show a yellow or red warning bar at the bottom of the screen. It covers the
# GumTestApp buttons, so close it (several bars can be stacked).
close_dev_warnings() {
    local i close_button
    for i in 1 2 3; do
        close_button="$(find_on_screen contains "open debugger to view")"
        if [ -z "$close_button" ]; then
            return 0
        fi
        # shellcheck disable=SC2086 # close_button is "x y"
        adb shell input tap $close_button
        sleep 0.5
    done
}

# Taps the first element on screen whose text or description equals the label (any case).
# Retries until the element appears or the timeout passes.
tap_on_screen() {
    local label="$1"
    local waited=0
    while [ "$waited" -lt $((TIMEOUT_SECONDS * 2)) ]; do
        close_dev_warnings
        local center
        center="$(find_on_screen equals "$label")"
        if [ -n "$center" ]; then
            # shellcheck disable=SC2086 # center is "x y"
            adb shell input tap $center
            pass "tapped \"$label\""
            return 0
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    fail "could not find \"$label\" on the screen within ${TIMEOUT_SECONDS}s"
}

# Taps the label until a log line matching the pattern appears (at most 3 taps, 5s apart).
# A tap can get lost while the app is still busy loading, so one tap is not always enough.
# Usage: tap_until_log <label> <pattern> <description>
tap_until_log() {
    local label="$1" pattern="$2" description="$3"
    local since attempt waited
    since="$(device_time)"
    for attempt in 1 2 3; do
        tap_on_screen "$label"
        waited=0
        while [ "$waited" -lt 10 ]; do
            if logs_since "$since" | grep -qE "$pattern"; then
                pass "$description"
                return 0
            fi
            sleep 0.5
            waited=$((waited + 1))
        done
        echo "   tap $attempt on \"$label\" had no effect yet, trying again"
    done
    fail "$description (no log line matching '$pattern' after 3 taps)"
}

step "Checking the device"
adb get-state >/dev/null 2>&1 || fail "no device found (connect one, or set ANDROID_SERIAL)"
SDK="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
MODEL="$(adb shell getprop ro.product.model | tr -d '\r')"
echo "   device: $MODEL, Android SDK $SDK"
if [ "$SDK" -lt 29 ]; then
    echo "   SKIPPED: the camera reopen needs Android 10 (SDK 29) or newer."
    exit 2
fi
adb shell pm path "$APP_ID" >/dev/null 2>&1 || fail "$APP_ID is not installed (see 'Before running' at the top)"
adb reverse tcp:8081 tcp:8081 >/dev/null
adb shell pm grant "$APP_ID" android.permission.CAMERA
pass "device ready"

step "1. Start GumTestApp and turn the camera on"
adb shell am force-stop "$APP_ID"
adb shell input keyevent KEYCODE_WAKEUP
TEST_START_TIME="$(device_time)"
adb shell am start -n "$APP_ID/.MainActivity" >/dev/null
tap_until_log "Start" "getUserMedia\(video\)" "app asked for the camera"
wait_for_log "CameraEventsHandler.onFirstFrameAvailable" "$TEST_START_TIME" "camera is sending frames"
wait_for_log "GumTestApp track started id=" "$TEST_START_TIME" "JS has the video track"
TRACK_ID="$(logs_since "$TEST_START_TIME" | grep -oE "GumTestApp track started id=[^ ]+" | tail -1 | sed 's/.*id=//')"
echo "   track id: $TRACK_ID"

step "2. Open the system Camera app for ${OTHER_APP_SECONDS}s"
TAKEN_TIME="$(device_time)"
adb shell am start -a android.media.action.STILL_IMAGE_CAMERA >/dev/null
wait_for_log "CameraEventsHandler.onCameraDisconnected" "$TAKEN_TIME" "Android took our camera"
sleep "$OTHER_APP_SECONDS"

step "3. Go back to GumTestApp"
BACK_TIME="$(device_time)"
adb shell am start -n "$APP_ID/.MainActivity" >/dev/null
# The bug: before the fix, the camera never opens again, so this check fails.
wait_for_log "CameraEventsHandler.onFirstFrameAvailable" "$BACK_TIME" "camera opened again and sends frames"
expect_no_log ": ended event trackId" "$TAKEN_TIME" "native side did not end the track"

step "4. Check what the JS track saw"
# The JS lines come from GumTestApp's own listeners (App.js), so they prove the events
# reached JavaScript, not only that the native side sent them.
JS_MUTE="GumTestApp track mute id=$TRACK_ID "
JS_UNMUTE="GumTestApp track unmute id=$TRACK_ID muted=false readyState=live"
expect_log "$JS_MUTE" "$TAKEN_TIME" "JS track got \"mute\" while the Camera app had the camera"
expect_log "$JS_UNMUTE" "$TAKEN_TIME" "the same JS track got \"unmute\" and is still live"
expect_first_before "$JS_MUTE" "$JS_UNMUTE" "$TAKEN_TIME" "\"mute\" came before \"unmute\""
expect_no_log "GumTestApp track ended" "$TAKEN_TIME" "JS track was not ended"

step "5. Flip the camera"
FLIP_TIME="$(device_time)"
tap_until_log "Flip" "CameraCapturer: switchCamera" "app asked to flip the camera"
wait_for_log "CameraCapturer: switchCamera done" "$FLIP_TIME" "camera switched"
wait_for_log "CameraEventsHandler.onFirstFrameAvailable" "$FLIP_TIME" "flipped camera sends frames"
expect_no_log "camera is not running" "$FLIP_TIME" "no \"camera is not running\" error"

echo ""
echo "PASSED"
save_log
