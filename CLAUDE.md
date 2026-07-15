# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`@stream-io/react-native-webrtc` is a **hard fork** of [`react-native-webrtc`](https://github.com/react-native-webrtc/react-native-webrtc), tailored for [`@stream-io/video-react-native-sdk`](https://github.com/GetStream/stream-video-js). The fork's reason to exist is that it swaps upstream's WebRTC binaries for Stream's own builds and adds Stream-specific native APIs (a custom audio engine and voice-activity detection).

The package version tracks the WebRTC milestone — `145.x` means it ships WebRTC M145.

## Commands

- `npm run lint` — `eslint --max-warnings 0 .` **plus** `tsc --noEmit`. This is the entire JS CI gate; there is no JS unit-test suite.
- `npm run lintfix` — same as lint but with `eslint --fix`.
- `npm run format` — `tools/format.sh`: runs `clang-format -i` over tracked `.java`/`.h`/`.m` files (excludes `examples/`).
- `npm run prepare` — `husky install && bob build` (compiles `src/` → `lib/`).

`lint` runs in CI after a **clean-tree check** (`git status --porcelain` must be empty). Never commit `bob build` output (`lib/`) or other generated files — a dirty tree fails CI.

Node version is pinned in `.nvmrc` (`v24`). `.npmrc` sets `legacy-peer-deps=true`, so use `npm ci` / `npm install` (peer deps are intentionally loose). ESLint config lives at `src/.eslintrc.cjs` and is strict: 4-space indent, single quotes, semicolons, `max-len` 120, alphabetized import groups with blank lines between them.

### Verifying changes (mirrors CI)

There are no JS tests — CI verifies by **compiling the example app** against the module. Always run the native build, not just `tsc`; cherry-picks and edits can pass `tsc` yet fail the native compile.

```bash
# Android (android_ci.yml)
cd examples/GumTestApp && npm install
cd android && ./gradlew assembleDebug

# iOS (ios_ci.yml)
cd examples/GumTestApp && npm install
cd ios && pod install
xcodebuild -workspace GumTestApp.xcworkspace -scheme GumTestApp \
  -destination generic/platform=iOS \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO clean build | xcpretty
```

## Architecture

Three layers bridged by a single native module named `WebRTCModule`:

1. **TS API surface (`src/`)** — implements the W3C WebRTC API (`RTCPeerConnection`, `MediaStream`, `MediaStreamTrack`, `mediaDevices`, `RTCDataChannel`, the `RTCRtp*` family, `RTCView`) on top of the native bridge. `src/index.ts` is the RN entry point and also exposes `registerGlobals()`, which installs these classes onto JS `global` so web-style WebRTC code runs unchanged.
2. **iOS native (`ios/RCTWebRTC/`)** — Objective-C `WebRTCModule`, an `RCTEventEmitter`, split into categories (`WebRTCModule+RTCPeerConnection.m`, `+RTCMediaStream`, `+RTCDataChannel`, `+Transceivers`, `+RTCAudioSession`, `+RTCAudioDeviceModule`, …). The Stream-specific audio engine lives under `ios/RCTWebRTC/Utils/AudioDeviceModule/`.
3. **Android native (`android/src/main/java/com/oney/WebRTCModule/`)** — `WebRTCModule.java` and helpers, with subpackages `audio/`, `videoEffects/`, and `webrtcutils/` (selective codec encoder/decoder factories). Camera helpers live in `org/webrtc/`.

### Native event flow

Native code fires events; the JS side fans them out. `src/EventEmitter.ts` subscribes once to each native event via `NativeEventEmitter`, then re-emits on a JS-only emitter that the TS classes listen to. The `NATIVE_EVENTS` array in `src/EventEmitter.ts` **must stay in sync** with the event-name constants declared natively (`ios/RCTWebRTC/WebRTCModule.h` and the Android equivalents). Adding a native event without registering it here means JS never receives it.

### Build / publish layout

`react-native-builder-bob` compiles `src/` to `lib/` in three targets (`commonjs`, `module`, `typescript`). Published consumers resolve `main` → `lib/commonjs`, `module` → `lib/module`, `types` → `lib/typescript`; React Native itself resolves `react-native` → `src/index.ts`.

## Stream-specific customizations (do not regress)

These are the whole point of the fork — never replace them with upstream equivalents:

- **iOS WebRTC binary**: the `StreamWebRTC` pod (from [`stream-video-swift-webrtc`](https://github.com/GetStream/stream-video-swift-webrtc)), pinned in `stream-react-native-webrtc.podspec`. Must **not** become `WebRTC`/`GoogleWebRTC`.
- **Android WebRTC binary**: `io.getstream:stream-video-webrtc-android` in `android/build.gradle`. Must **not** become `org.webrtc:google-webrtc`.
- **Custom audio engine**: `ios/RCTWebRTC/Utils/AudioDeviceModule/` and the TS APIs `src/AudioDeviceModule.ts` / `src/AudioDeviceModuleEvents.ts` (not present upstream).
- **Custom voice-activity detection**: `android/.../SpeechActivityDetector.java`.

Sanity check after any dependency edit: `grep -r "org.webrtc:google-webrtc\|webrtc-ios" --include="*.gradle" --include="*.podspec" .` must return nothing.

## Keeping the fork in sync with upstream

Pulling fixes/features from upstream `react-native-webrtc` (and sibling forks) is a recurring, error-prone task with strict preservation rules and merge-base mechanics. **Read `.claude/skills/upstream-sync.md` before doing any sync/cherry-pick/merge work** — it documents the triage table, the merge-base advancement step (and why squash-merging the sync PR breaks it), and the files that must never change during a sync.

## Releases

Automated via `semantic-release` (`.releaserc.json`, conventional-commits preset), triggered by the manually-dispatched `Release` workflow (`.github/workflows/release.yml`) on `master`, `beta` (prerelease), `release*`, and `*.x` branches. `refactor:` commits and any `deps`-scoped commit produce a patch release. Publishing uses npm Trusted Publishing (OIDC) — no npm token.
