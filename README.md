[<img src="https://avatars.githubusercontent.com/u/42463376" alt="React Native WebRTC" style="height: 6em;" />](https://github.com/react-native-webrtc/react-native-webrtc)

# React-Native-WebRTC

[![npm version](https://img.shields.io/npm/v/@stream-io/react-native-webrtc)](https://www.npmjs.com/package/@stream-io/react-native-webrtc)
[![npm downloads](https://img.shields.io/npm/dm/@stream-io/react-native-webrtc)](https://www.npmjs.com/package/@stream-io/react-native-webrtc)

A WebRTC module for React Native tailored for the [`@stream-io/video-react-native-sdk`](https://github.com/GetStream/stream-video-js) needs.

## Getting Started

Use one of the following preferred package install methods to immediately get going.  
Don't forget to follow platform guides below to cover any extra required steps.

**npm:** `npm install @stream-io/react-native-webrtc --save`  
**yarn:** `yarn add @stream-io/react-native-webrtc`  
**pnpm:** `pnpm install @stream-io/react-native-webrtc`

## Guides

- [Android Install](./Documentation/AndroidInstallation.md)
- [iOS Install](./Documentation/iOSInstallation.md)
- [tvOS Install](./Documentation/tvOSInstallation.md)
- [Basic Usage](./Documentation/BasicUsage.md)
- [Step by Step Call Guide](./Documentation/CallGuide.md)
- [Improving Call Reliability](./Documentation/ImprovingCallReliability.md)
- [Migrating to Unified Plan](https://docs.google.com/document/d/1-ZfikoUtoJa9k-GZG1daN0BU3IjIanQ_JSscHxQesvU/edit#heading=h.wuu7dx8tnifl)

## Example Projects

We have some very basic example projects included in the [examples](./examples) directory.  
Don't worry, there are plans to include a much more broader example with backend included.

## Releasing

Releases are automated with [semantic-release](https://semantic-release.gitbook.io/) via the
[`Release`](./.github/workflows/release.yml) workflow, which is triggered manually from the
Actions tab (**Run workflow**).

There is no channel input — **the branch you dispatch from selects the release channel**, using
the *"Use workflow from"* branch dropdown:

| Dispatch from | Version | npm dist-tag |
| :- | :- | :- |
| `master` | `145.1.0` | `latest` |
| `beta` | `145.1.0-beta.1` | `beta` |
| `alpha` | `145.1.0-alpha.1` | `alpha` |
| `<major>.x` (e.g. `145.x`) | `145.0.1` | `145.x` |

A branch only appears in the dropdown once it exists on the remote and contains the workflow
file, so `alpha`/`beta`/`<major>.x` need to be branched off `master` before their first use.

Tick **`dry_run`** to run `semantic-release --dry-run`: it computes the next version and prints
the release notes without publishing, tagging, or pushing.

The version is derived from the [Conventional Commits](https://www.conventionalcommits.org/)
since the last tag — never by hand-editing `package.json`. `feat:` yields a minor, `fix:` a
patch, and `refactor:` and any `deps`-scoped commit also yield a patch. Publishing uses npm
[Trusted Publishing](https://docs.npmjs.com/trusted-publishers) (OIDC), so no npm token is
involved.

## Related Projects

Looking for extra functionality coverage?  
The [react-native-webrtc](https://github.com/react-native-webrtc) organization provides a number of packages which are more than useful when developing Real Time Communication applications.
