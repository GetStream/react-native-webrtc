# Upstream Sync Skill

Sync fork with one or more upstream remotes via cherry-pick + merge-base advance.

## When to use

User says: "sync with upstream", "cherry-pick from X", "merge upstream", or similar.

## Workflow

### Phase 1: Explore divergence

```bash
git fetch <remote>
git log --oneline --right-only <branch>...<remote>/master --no-merges
```

For each upstream-only commit, get files changed:

```bash
git log --right-only <branch>...<remote>/master --no-merges --format="%h %s" | while read hash msg; do
  echo "=== $hash $msg ==="; git diff-tree --no-commit-id --name-only -r $hash; echo
done
```

### Phase 2: Triage commits

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

Check for equivalents: `git log --oneline --left-only <branch>...<remote>/master | grep -i "<keyword>"`

### Phase 3: Ask user

Present triage. Ask about large/risky features, optional items, anything ambiguous.

### Phase 4: Cherry-pick in order

```bash
git checkout -b sync/upstream-cherry-picks <base-branch>
```

Order: TS fixes → Android fixes → iOS fixes → small features → large features → docs.

If conflict: resolve, `git add`, `git cherry-pick --continue --no-edit`.
If empty after resolution: `git cherry-pick --skip`.

### Phase 5: Merge to advance merge-base

Without this, future merges replay ALL upstream commits including skipped ones.

```bash
git merge <remote>/master --no-commit

# Conflicted files — keep ours
git diff --name-only --diff-filter=U | xargs git checkout --ours
# Files deleted in our branch — remove
git rm <deleted-files>
# Auto-merged files — reset to our version
git diff --cached --name-only --diff-filter=M | xargs git checkout HEAD --
# Unwanted new files from upstream — remove
git diff --cached --name-only --diff-filter=A  # review, then:
git rm -f <unwanted-files>

git add -A
git diff --cached --stat HEAD  # should be empty or near-empty
git commit -m "merge: sync merge-base with <remote>/master"
```

Verify: `git log --oneline --right-only <branch>...<remote>/master | wc -l` should be `0`.

### Phase 6: Verify

Run ALL of these. Do not skip any.

```bash
npm run lint
cd examples/GumTestApp/android && ./gradlew assembleDebug
cd examples/GumTestApp/ios && pod install && \
  xcodebuild -workspace GumTestApp.xcworkspace -scheme GumTestApp \
  -sdk iphonesimulator -configuration Debug build
```

### Phase 7: Format native files

```bash
git ls-files | grep -e "\(\.java\|\.h\|\.m\)$" | grep -v examples | xargs npx clang-format -i
```

Rebuild Android + iOS to confirm, then commit.

### Phase 8: Update package-lock.json

If `package.json` dependencies changed, lock file will be stale.

```bash
npm install
git add package-lock.json && git commit -m "chore: update package-lock.json"
```

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

## Pitfalls

1. **Always run native builds, not just tsc.** Cherry-picks can pass tsc but fail gradlew/xcodebuild.

2. **Native API names differ across WebRTC versions.** Enum values, type names, and method signatures may not exist in our WebRTC SDK. After cherry-picking from a fork on a different WebRTC version, verify types exist before building.

3. **`git add -A` re-adds files you removed.** Use `git rm -f` (not `--cached`) to remove from both index and disk.

4. **Auto-merged files need `git checkout HEAD --`, not `--ours`.** `--ours` only works on conflicted files. For auto-merged files with unwanted changes, use `git checkout HEAD -- <file>`.

5. **Watch for duplicates after conflict resolution.** Duplicate variable declarations, closing braces, or imports when keeping both sides of a conflict.

6. **Advance merge-base for EVERY upstream remote.** If syncing with multiple upstreams, merge each one separately. Otherwise the un-advanced remote replays all its history on the next merge.

7. **Upstream podspec/build files leak into cherry-picks.** Other forks have their own podspec (e.g., `livekit-react-native-webrtc.podspec`). Always `git rm` them when they appear.

8. **Cross-check cherry-picks against all upstreams for reverts.** Before cherry-picking a commit from one upstream, search the other upstreams for the same change — it may have been tried and reverted. Run: `git log --all --oneline -S "<key code snippet>"` to find if the same change exists elsewhere in history with a subsequent revert.
