# Upstream Sync Skill

Sync fork with one or more upstream remotes via cherry-pick + marker refs.

## When to use

User says: "sync with upstream", "cherry-pick from X", "merge upstream", or similar.

## How we track "already reviewed"

A ref per upstream, `sync-marker/<remote>`, points at the last upstream commit we
triaged. Divergence is `sync-marker/<remote>..<remote>/master` — nothing is inferred
from history shape.

**Never merge an upstream ref into `master`.** Doing so makes every upstream commit an
ancestor of `master`, and semantic-release analyses `<lastTag>..master` by walking all
parents — so skipped upstream commits land in the version calculation and the changelog.
One stray `feat:` upstream turns a patch into a minor and credits us with code we never
shipped. Marker refs are not ancestors of `master`, so releases never see them.

That also means the PR merge strategy is irrelevant: squash, rebase, and merge are all
safe. (Before markers, tracking lived in merge commits and squashing silently broke it.)

## Workflow

### Phase 1: Explore divergence

```bash
git fetch <remote>
git log --oneline sync-marker/<remote>..<remote>/master --no-merges
```

If the marker does not exist yet, bootstrap it from the last real merge of that remote
(`git log --merges --oneline master | grep <remote>`) or ask the user, then create it:
`git branch sync-marker/<remote> <that-upstream-commit>`.

For each upstream-only commit, get files changed:

```bash
git log sync-marker/<remote>..<remote>/master --no-merges --format="%h %s" | while read hash msg; do
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

Check for equivalents: `git log --oneline <remote>/master..<branch> | grep -i "<keyword>"`

### Phase 3: Ask user

Present triage. Ask about large/risky features, optional items, anything ambiguous.

### Phase 4: Cherry-pick in order

```bash
git checkout -b sync/upstream-cherry-picks <base-branch>
```

Order: TS fixes → Android fixes → iOS fixes → small features → large features → docs.

If conflict: resolve, `git add`, `git cherry-pick --continue --no-edit`.
If empty after resolution: `git cherry-pick --skip`.

### Phase 5: Verify

Run ALL of these. Do not skip any.

```bash
npm run lint
cd examples/GumTestApp/android && ./gradlew assembleDebug
cd examples/GumTestApp/ios && pod install && \
  xcodebuild -workspace GumTestApp.xcworkspace -scheme GumTestApp \
  -sdk iphonesimulator -configuration Debug build
```

Run these one at a time, never two concurrently against `examples/GumTestApp` — a second
run's `rm -rf Pods` will pull files out from under the first and both fail confusingly.

Use `set -o pipefail`, or check the build's own exit code. Piping `xcodebuild` into `tail`
reports *tail's* status, so a failed build looks like exit 0. Confirm by grepping for
`** BUILD SUCCEEDED **`.

If `pod install` cannot satisfy the pinned `StreamWebRTC` version, the local CocoaPods
spec repo is stale — `pod install --repo-update`. Not a sync problem; CI checks out fresh.

### Phase 6: Format native files

```bash
git ls-files | grep -e "\(\.java\|\.h\|\.m\)$" | grep -v examples | xargs npx clang-format -i
```

This reformats pre-existing drift across many untouched files, because the local
clang-format version differs from whatever produced the committed formatting. Keep only
the files this sync actually touched and revert the rest — formatting is not a CI gate,
and a sync PR full of unrelated reformatting is unreviewable.

Rebuild Android + iOS to confirm, then commit.

### Phase 7: Update package-lock.json

If `package.json` dependencies changed, lock file will be stale. Note a `scripts`-only
change does **not** require this.

```bash
npm install
git add package-lock.json && git commit -m "chore: update package-lock.json"
```

### Phase 8: After the sync PR merges, move the markers

Do this **only once the PR has landed on `master`** — not at cherry-pick time. Moving a
marker for a PR that is later abandoned skips those upstream commits permanently.

Any merge strategy is fine (squash, rebase, or merge).

```bash
# for each remote synced in this round
git fetch <remote>
git branch -f sync-marker/<remote> <the upstream commit triaged in Phase 1>
git push --force-with-lease origin sync-marker/<remote>
```

Point the marker at the upstream tip you actually triaged, not a freshly fetched one —
upstream may have moved on while the PR was in review, and those newer commits have not
been reviewed. Then verify the divergence is empty:

```bash
git log --oneline sync-marker/<remote>..<remote>/master --no-merges  # only untriaged commits
```

Marker pushes trigger no CI: every workflow is scoped to `master` pushes, PRs targeting
`master`, or manual dispatch.

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

6. **Move the marker for EVERY upstream remote.** If syncing with multiple upstreams, each needs its own `sync-marker/<remote>`. A remote whose marker was not moved replays all its history next round.

7. **Upstream podspec/build files leak into cherry-picks.** Other forks have their own podspec (e.g., `livekit-react-native-webrtc.podspec`). Always `git rm` them when they appear.

8. **Cross-check cherry-picks against all upstreams for reverts.** Before cherry-picking a commit from one upstream, search the other upstreams for the same change — it may have been tried and reverted. Run: `git log --all --oneline -S "<key code snippet>"` to find if the same change exists elsewhere in history with a subsequent revert.

9. **Verify cherry-picked changes still exist on upstream HEAD.** A commit could have been added and later reverted/modified by a subsequent commit on the same upstream. After cherry-picking, verify the actual code still matches upstream's current state: `git show <remote>/master:<file> | grep "<key code>"`. Don't just trust that a commit was made — it may have been undone.

10. **Never merge an upstream ref into `master` to record progress.** This includes ghost merges (`git merge -s ours <remote>/master`), which keep the tree but still add the upstream parent. semantic-release analyses `<lastTag>..master` by walking all parents, so every skipped upstream commit enters the version calculation and the changelog — one upstream `feat:` turns a patch into a minor and credits us with code we never shipped. Move `sync-marker/<remote>` instead (Phase 8); it is not an ancestor of `master`, so releases never see it. Historical merges like `eface9a` / `d66ff60` predate this rule and are harmless only because later release tags absorbed them.

11. **Don't infer "already synced" from the tree.** A squashed sync PR copies upstream *content* into `master` without making upstream *commits* ancestors, so content checks and marker checks can disagree. `sync-marker/<remote>` is the only record of what was triaged; the tree tells you nothing about it.

12. **`grep` may be shadowed by a shell function or `ugrep`.** A wrapper can report zero matches for a string that is plainly present, which reads as "the cherry-pick did not apply." Confirm with `/usr/bin/grep` or `git show <ref>:<file> | sed -n 'N,Mp'` before concluding anything is missing.
