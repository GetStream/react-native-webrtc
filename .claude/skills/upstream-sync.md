# Upstream Sync Skill

Sync the fork with one or more upstream remotes via cherry-pick + marker refs.
Use when the user says "sync with upstream", "cherry-pick from X", "merge upstream", or similar.

Environment note: `grep` may be shadowed by a shell wrapper that reports zero matches for
text that is plainly present. Confirm any negative with `/usr/bin/grep`.

## Marker refs: how "already reviewed" is tracked

A ref per upstream, `sync-marker/<remote>`, points at the last upstream commit we
triaged. Divergence is `sync-marker/<remote>..<remote>/master` — nothing is inferred
from history shape. Corollaries:

- PR merge strategy is irrelevant (squash/rebase/merge all safe): markers live outside
  `master`'s history. Before markers, tracking lived in merge commits and squashing
  silently broke it.
- Never infer "already synced" from the tree: a squashed sync PR copies upstream
  *content* without making upstream *commits* ancestors. The marker is the only record
  of what was triaged.

## Workflow

### 1. Explore divergence

```bash
git fetch <remote>
git log --oneline sync-marker/<remote>..<remote>/master --no-merges
```

No marker yet? Bootstrap from the last real merge of that remote
(`git log --merges --oneline master | grep <remote>`) or ask the user:
`git branch sync-marker/<remote> <that-upstream-commit>`.

Files touched per commit:

```bash
git log sync-marker/<remote>..<remote>/master --no-merges --format="%h %s" | while read hash msg; do
  echo "=== $hash $msg ==="; git diff-tree --no-commit-id --name-only -r $hash; echo
done
```

### 2. Triage commits

| Category | Action |
|----------|--------|
| Already in fork | SKIP |
| Release/version bumps | SKIP |
| Lock file only | SKIP |
| Native WebRTC lib version changes | SKIP (fork uses StreamWebRTC) |
| Merge commits | SKIP |
| Cosmetic formatting | SKIP (run formatters separately) |
| Bug fixes | CHERRY-PICK |
| New features | CHERRY-PICK (ask user) |
| Refactoring | CHERRY-PICK (evaluate risk) |
| Docs/CI/tools | Ask user |

Cross-check each pick — a commit is not trustworthy just because it exists:

- Equivalent already in fork? `git log --oneline <remote>/master..<branch> | grep -i "<keyword>"`
- Tried and reverted on *any* upstream? `git log --all --oneline -S "<key code snippet>"`
- Still on upstream HEAD, or undone by a later commit? `git show <remote>/master:<file> | grep "<key code>"`

### 3. Ask user

Present the triage. Ask about large/risky features, optional items, anything ambiguous.

### 4. Cherry-pick in order

```bash
git checkout -b sync/upstream-cherry-picks <base-branch>
```

Order: TS fixes → Android fixes → iOS fixes → small features → large features → docs.
On conflict: resolve, `git add`, `git cherry-pick --continue --no-edit`; if empty after
resolution, `git cherry-pick --skip`. Watch out for:

- `git add -A` re-adds files you removed — use `git rm -f` (not `--cached`).
- `--ours` only works on *conflicted* files; to drop unwanted changes in an auto-merged
  file use `git checkout HEAD -- <file>`.
- Duplicate declarations/imports/braces when keeping both sides of a conflict.
- Other forks' build files leaking in (e.g. `livekit-react-native-webrtc.podspec`) — `git rm` them.

### 5. Verify

Run ALL of these. Cherry-picks can pass `tsc` yet fail the native compile, and native
API names (enums, types, signatures) differ across WebRTC milestones.

```bash
npm run lint
cd examples/GumTestApp/android && ./gradlew assembleDebug
cd examples/GumTestApp/ios && pod install && \
  xcodebuild -workspace GumTestApp.xcworkspace -scheme GumTestApp \
  -sdk iphonesimulator -configuration Debug build
```

- One at a time, never two concurrently against `examples/GumTestApp` — a second run's
  `rm -rf Pods` pulls files out from under the first.
- `set -o pipefail`, or check the build's own exit code: `xcodebuild | tail` reports
  *tail's* status, so a failed build looks like exit 0. Grep for `** BUILD SUCCEEDED **`.
- `pod install` can't satisfy the pinned `StreamWebRTC`? Local spec repo is stale —
  `pod install --repo-update`. Not a sync problem; CI checks out fresh.

### 6. Format native files

```bash
git ls-files | grep -e "\(\.java\|\.h\|\.m\)$" | grep -v examples | xargs npx clang-format -i
```

This also reformats pre-existing drift in untouched files (clang-format version skew).
Keep only files this sync touched, revert the rest — formatting is not a CI gate and
unrelated reformatting makes the PR unreviewable. Rebuild both platforms, then commit.

### 7. Update package-lock.json

Only if `package.json` *dependencies* changed (`scripts`-only changes don't count):
`npm install && git add package-lock.json && git commit -m "chore: update package-lock.json"`.

### 8. After the sync PR merges, move the markers

Only once the PR has landed on `master` — moving a marker for an abandoned PR skips
those upstream commits permanently. Move the marker for **every** remote synced this
round; an unmoved marker replays that remote's whole history next time.

```bash
git fetch <remote>
git branch -f sync-marker/<remote> <the upstream commit triaged in Phase 1>
git push --force-with-lease origin sync-marker/<remote>
```

Point the marker at the tip you actually *triaged*, not a freshly fetched one — upstream
may have moved during review. Verify divergence is now empty (Phase 1 command). Marker
pushes trigger no CI (all workflows are scoped to `master` or manual dispatch).

## Preservation rules

These MUST NOT change during sync:

| File | Guard |
|------|-------|
| `android/build.gradle` | Must keep `io.getstream:stream-video-webrtc-android:*` |
| `stream-react-native-webrtc.podspec` | Must keep `StreamWebRTC` dependency |
| `ios/RCTWebRTC/Utils/AudioDeviceModule/` | Fork's custom audio engine — untouched |
| `SpeechActivityDetector.java` | Fork's custom VAD — untouched |
| `AudioDeviceModule.ts`, `AudioDeviceModuleEvents.ts` | Fork's custom TS APIs — untouched |

Post-sync: `grep -r "org.webrtc:google-webrtc\|webrtc-ios" --include="*.gradle" --include="*.podspec" .` must return nothing.

## Upstream refs, releases, and the GitHub banner

semantic-release analyses `<lastTag>..master` walking **all parents**: upstream commits
that become ancestors of `master` enter the version calculation and changelog — one
stray upstream `feat:` turns a patch into a minor and credits us with rejected code. So:

- **Never merge an upstream ref into `master` to record triage progress** — markers
  (Phase 8) exist for that.
- Merging an upstream ref (in practice a ghost merge, `git merge -s ours
  <remote>/master`: records the parent, tree stays byte-identical) is allowed **only**
  when immediately absorbed behind a **stable** release tag, before semantic-release
  next runs: `git tag vX.Y.Z HEAD && git push --atomic origin master vX.Y.Z`. The
  version is never published to npm — a harmless gap. Confirm with a Release workflow
  `dry_run` that the tag is picked as `lastRelease` and no upstream commit is listed.
  A prerelease tag does **not** work (the master channel ignores prerelease versions).
  Precedent: `eface9a`/`d66ff60` (absorbed by `v145.0.0` by luck), `v145.3.2`
  (deliberate, this procedure).
- Never move an already-published tag to absorb commits — the git tag must keep
  matching the npm tarball it shipped.

The **"N commits behind" banner** compares against the fork *parent* (livekit) only,
counts commits we triaged and rejected, and grows over time. Cosmetic, not a health
signal; zero it (if someone insists) with the ghost-merge+tag procedure above. **Never
click "Sync fork"** — it merges the parent's default branch wholesale, replacing
Stream's WebRTC binaries in violation of the preservation rules.
