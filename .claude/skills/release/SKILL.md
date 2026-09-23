---
name: release
description: Release rules_flutter on its own — readiness checks against the published rules_dart, push, watch CI, tag, and drive the BCR PR until a clean module resolves the new version. Also re-publishes a version whose BCR PR is still open. Use when the user asks to cut, ship, publish or release rules_flutter. A rules_dart release that cascades here is driven from rules_dart's own release skill.
---

# Release rules_flutter

This releases **rules_flutter alone**. If the release needs a newer rules_dart,
that is rules_dart's release skill (`$HOME/Projects/rules_dart/.claude/skills/release`),
whose last phase cascades here; come back to this skill only once BCR **serves**
the rules_dart version you pin (see Phase 5, "served").

Run it with the user in the loop. Stop at any gate that is ambiguous or red; do not
power through failures, and never file a failure as flaky without evidence.

## Guardrails

- **Signed, always.** Commits and the release tag are signed. Commit signing uses the
  automation key from `~/.claude/settings.json`, which does not need 1Password; tag with
  `git tag -s`. Never pass `--no-gpg-sign` or push anything unsigned.
- **Pushing is separate from signing.** `git push` over SSH authenticates through the
  1Password SSH agent, which can stop answering mid-session (`communication with agent
failed`). The objects are already signed, so pushing over HTTPS with the `gh` login is
  fine:
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' push https://github.com/aran/rules_flutter.git <ref>`.
- **Trunk-based.** Commit straight to `main`; no PRs on rules_flutter. The BCR PR is the
  publish mechanism.
- **No `Co-Authored-By` trailers.**
- **The version number is the user's call.** Propose, then wait for an explicit yes.
- Read workspace lists from the files at run time (`.github/workflows/ci.yaml`,
  `docs/TESTING.md` § 3), not from memory.

---

## Phase 1 — Readiness

The bar is `CLAUDE.md`'s verification policy and `docs/TESTING.md`, applied to
**everything unreleased**: `git log $(git tag --sort=-v:refname | grep '^v' | head -1)..main`.

1. **Sync.** `git fetch origin --tags`; on `main`, tree clean, not behind `origin/main`.
2. **Test against the published rules_dart, not the sibling checkout.** Every workspace
   here has a gitignored `.bazelrc.user` that overrides rules_dart to
   `../rules_dart` and turns lockfile checking off, so an ordinary local sweep never tests
   the pin consumers get. Move them aside for this phase, keeping the disk-cache lines:

   ```sh
   find . -name .bazelrc.user -not -path "*/bazel-*" -not -path "./.claude/*"
   ```

   Back each one up outside the tree, rewrite it without the `override_module=rules_dart`
   and `lockfile_mode=off` lines, and restore every one at the end of the phase (count
   them before and after). Don't run this while another session builds in this tree.

3. **Locks.** In the root and each workspace that pins rules_dart (every `e2e/*`, plus
   `e2e/_overlay_tests/native_assets_synthetic`, which overrides it locally):
   `bazel build --nobuild --lockfile_mode=error //...` must pass. If it doesn't, regenerate
   with `bazel mod tidy --lockfile_mode=refresh` then
   `bazel build --nobuild --lockfile_mode=update //...`, verify again, and commit.
   `e2e/cross_compile_example` cannot take `//...`: check `:cross_linux`, then
   `:app_analyze_test :format_test` with `--platforms=@platforms//host`, as separate
   invocations.
4. **Full test surface, uncached.** `--nocache_test_results` on every run: a cache replay
   prints `PASSED` having run nothing. Root `//...` and every workspace in
   `docs/TESTING.md` § 3, including `cross_compile_example`'s two commands. Android
   workspaces need both variables, exported:
   ```sh
   export ANDROID_HOME=$HOME/Library/Android/sdk
   export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/<an installed version>   # ls $ANDROID_HOME/ndk
   ```
5. **Dev tool e2e suite** (it also holds the web rendering checks):
   `dart run tools/dev_tool/tool/e2e.dart`, with a Dart ≥ 3.12 first on `PATH`
   (`docs/TESTING.md` § 2), a booted iOS simulator and the `flutter_test` Android
   emulator. It needs the workspace to itself (a `git commit` runs Bazel through its
   hooks) and a machine that isn't saturated: read `uptime` first. Rerun any failure on
   its own before judging it, and report both results.
6. **Manual checks the unreleased commits call for** — `docs/TESTING.md`'s "Quick
   reference: what to test when" (macOS runtime test, hot reload and restart, device
   checks). Anything that changes what an app draws means seeing it render.
7. **Lint:** `pre-commit run --all-files` must leave the tree clean.
8. **Archive contents.** Consumers download `git archive` output, trimmed by
   `.gitattributes`. The only `e2e/` directory in it may be `e2e/smoke`, which
   `.bcr/presubmit.yml` runs:
   ```sh
   git archive HEAD | tar t | grep '^e2e/' | cut -d/ -f2 | sort -u   # expect: smoke
   ```
   A new e2e workspace ships in every release until it gets its own `export-ignore` line.
9. **Restore every `.bazelrc.user`** and confirm the count matches.

---

## Phase 2 — Version

```sh
git tag --sort=-v:refname | grep '^v' | head -1     # other tags exist, e.g. pre-squash-backup
```

Default: next patch. Minor if the unreleased commits carry a significant feature. Major
releases are never automatic. Propose it with the alternative and wait for a yes.

---

## Phase 3 — Push and watch CI

```sh
git push origin main
gh run list --repo aran/rules_flutter --workflow CI --branch main --limit 1
gh run watch <id> --repo aran/rules_flutter --exit-status
```

Every job must go green. A red job is fixed on `main` and CI watched again.

Known intermittent failure: "Web smoke (DWDS VM service)" failing with
`Chrome did not announce a DevTools debugging port within 15s` (2026-09-10 and
2026-09-23; green on rerun both times, cause unknown). One rerun of that job alone
(`gh run rerun <id> --failed`) is fair. A second failure, or any other job failing, is a
bug to fix before tagging.

---

## Phase 4 — Tag and release

1. **Check the auto-tagger.** `gh workflow list --all --repo aran/rules_flutter`. "Tag a
   Release" (`tag.yaml`, a daily `smlx/ccv` cron) was `disabled_manually` on 2026-09-23.
   If it is active, check it hasn't already tagged these commits:
   `git fetch --tags && git tag --sort=-v:refname | grep '^v' | head -1`.
2. **Tag signed, annotated**, on the commit CI just passed:
   ```sh
   git tag -s -m "rules_flutter $VERSION" $VERSION origin/main
   git push origin $VERSION
   ```
3. **Watch `Release`** (`release.yaml`: build, attest, release, then `publish` into
   `publish.yaml`):
   `gh run list --repo aran/rules_flutter --workflow Release --limit 1`, then `gh run watch`.
4. **A `publish` job failing on `Invalid username or token` is an expired PAT.** Only
   the push to the BCR fork failed, so do not re-tag. Replace `BCR_PUBLISH_TOKEN` with a
   classic PAT with `repo` and `workflow` scopes and no expiry. It is one token shared
   with rules_dart and rules_dart_proto, so update all three; rules_dart's release skill
   has the details. Then recover with
   `gh workflow run "Publish to BCR" --repo aran/rules_flutter -f tag_name=$VERSION`.

---

## Phase 5 — BCR PR: ready, merged, served

1. **Find it.** publish-to-bcr pushes the fork branch `rules_flutter-$VERSION` and opens a
   **draft** PR:
   ```sh
   gh pr list --repo bazelbuild/bazel-central-registry --search "rules_flutter in:title" --state open
   ```
2. **Check the diff before marking it ready:**
   - `presubmit.yml` must clear `ANDROID_HOME` and `ANDROID_NDK_HOME`. rules_android fetches
     the SDK for every build, and the macOS BCR agents carry build-tools 30.0.3, which
     it rejects before a single test runs.
   - After the first version is merged, the only hunk in `metadata.json` may be the
     `versions` array. Anything else, a key reorder included, sends the PR to manual review
     (see rules_dart's release skill, Phase 6). Keep `.bcr/metadata.template.json`'s
     maintainer keys in the order upstream stores them.
3. **`gh pr ready <n> --repo bazelbuild/bazel-central-registry`.** Existing modules
   auto-approve on a clean diff (the bot has been running every 3–5 hours). The **first**
   version of a module has no maintainers yet, so it waits for a human BCR reviewer, who
   may also have to start `bcr-presubmit`.
4. **Poll until merged:** `gh pr view <n> --repo bazelbuild/bazel-central-registry --json state,mergedAt`.
   Report presubmit failures and review comments to the user as they arrive.
5. **Served means a clean module resolves it.** Nothing else counts:

   ```sh
   d=$(mktemp -d) && cd "$d" && touch BUILD.bazel
   printf 'module(name="c",version="0.0.0")\nbazel_dep(name="rules_flutter",version="%s")\n' "${VERSION#v}" > MODULE.bazel
   bazel mod show_repo rules_flutter   # must print an http_archive with an integrity hash
   ```

   The registry repo, `metadata.json`, and even the storage bucket all show the version
   before `bcr.bazel.build` serves it. **Do not probe `bcr.bazel.build` for the module's
   files before the merge:** the CDN caches the 404 for an hour (`max-age=3600`), and
   that stretches the wait by up to an hour. Measured 2026-09-23 on rules_dart 0.6.5:
   uploaded a minute after the first probe, served 404 for another ~48 minutes.

---

## Re-publishing a version whose BCR PR is still open

Use this to put new commits into a version that BCR has **not merged yet**, keeping the
PR, its number and its review thread. Once a version is merged, it is immutable: release
the next version instead.

publish-to-bcr always pushes `rules_flutter-<tag>` with `git push --force` and treats "a
pull request already exists" as success. So publishing the same tag again updates the
open PR in place, rebased on current BCR main:

```sh
gh release delete $VERSION --repo aran/rules_flutter --cleanup-tag --yes   # release, assets, remote tag
git tag -d $VERSION
git tag -s -m "rules_flutter $VERSION" $VERSION origin/main
git push origin $VERSION                                                    # triggers release.yaml
```

Run all of Phases 1–3 first; this is a release like any other. Then watch `Release` and
check the PR: one new commit on the same branch, the new `source.json` integrity, and
matching `attestations.json`. Confirm the new archive's hash matches `source.json`:
`echo "sha256-$(curl -sL <url> | openssl dgst -sha256 -binary | base64)"`.

---

## Done

Report the version, the GitHub Release, the BCR PR and whether it is merged and served,
every test that was skipped or rerun and why, and anything left for the user.
