# Maintenance Chores

Central reference for all recurring maintenance tasks. Slash commands read this
file at runtime — keep file lists current as the repo evolves.

---

## Flutter Version Bump

**Trigger**: New Flutter stable release.

**Authoritative source**: The Flutter reference repo tags are the source of truth for the
latest stable version. Do NOT rely on web searches — they may be stale. Run:

```sh
git -C references/flutter fetch --tags
git -C references/flutter tag -l '[0-9]*' | grep -v pre | sort -V | tail -5
```

The latest tag is the current stable release.

**Files**:

- `flutter/private/versions.bzl` — `FLUTTER_VERSIONS` and `ARTIFACT_CHECKSUMS` dicts
- `MODULE.bazel` — `flutter_version` in `flutter.toolchain()` call
- All `e2e/*/MODULE.bazel` — `flutter_version` in `flutter.toolchain()` calls
- `e2e/_overlay_tests/*/MODULE.bazel` — same call, one directory deeper, so a
  `e2e/*/MODULE.bazel` glob misses it, and no CI job runs it to notice
- `README.md` — the "Flutter SDK" compatibility line, the installation snippet,
  and the `FlutterInfo.version` example

**Procedure**:

1. Fetch tags and identify the latest stable version (see above)
2. Run `bazel run //tools/update_flutter_version -- <new-version>` (requires Flutter reference
   repo at `references/flutter` with tags fetched)
3. Copy the printed snippets into `flutter/private/versions.bzl`
4. Update `flutter_version` in `MODULE.bazel` and all `e2e/*/MODULE.bazel` files
5. Regenerate lock files

**Verification**: `bazel test //flutter/tests:all` and `cd e2e/smoke && bazel test //...`

---

## Bazel Version Bump

**Trigger**: New Bazel release (typically minor/patch within 9.x).

**Files**:

- Every `.bazelversion` — the repo root plus one per workspace with a
  `MODULE.bazel`, including `e2e/_overlay_tests/*`. A workspace without one does
  not inherit the root's: bazelisk reads only its own workspace root and
  otherwise fetches the newest release, so a missing file silently runs a
  different Bazel than the rest of the sweep.
  `find . -name .bazelversion -not -path '*/bazel-*'` is the list.
- `.bcr/presubmit.yml` — `bazel:` matrix value (if major version changes)

**Procedure**:

1. Update all `.bazelversion` files to the new version
2. If the major version changed, update `.bcr/presubmit.yml` matrix
3. Regenerate lock files

**Verification**: `bazel build //...` passes.

**Automation**: `/bump-bazel {version}` slash command.

---

## Bazel Module Dependency Bumps

**Trigger**: Periodic (monthly) or when a dep releases a version we need.

**Files**:

- `MODULE.bazel` — `bazel_dep()` version strings
- Every `e2e/*/MODULE.bazel` and `e2e/_overlay_tests/*/MODULE.bazel` — these
  declare their own `bazel_dep`s rather than inheriting the root's, so a root-only
  bump leaves them behind. `bazel_skylib`, `rules_cc` and `apple_support` appear
  in most; `rules_android`, `rules_kotlin`, `rules_java`, `rules_jvm_external`
  and `rules_go` in the three Android ones; `llvm` only in
  `cross_compile_example`

**Procedure**:

1. For each `bazel_dep` in root `MODULE.bazel`, check latest version on BCR
2. Update versions, skip any already current
3. Mirror the same versions into the e2e workspaces that declare them
4. Regenerate lock files

**Verification**: `bazel build //...` passes.

**Automation**: `/bump-deps` slash command.

---

## Lock File Refresh

**Trigger**: After any change to the root `MODULE.bazel`, its transitive deps,
or `.bazelversion` — the lock records a format version (Bazel 9.1.0 writes 26,
9.2.0 writes 28) as well as registry hashes.

**Only the root lock is enforced.** Every `e2e/*` workspace sets
`--lockfile_mode=off` in its own `.bazelrc`, because each one is overridden onto
a sibling `rules_dart` in local development, and their locks are intentionally
left stale. Refreshing them produces a large diff that nothing checks.

**Procedure**: move `.bazelrc.user` aside — its `--override_module` line changes
the module graph away from the registry one CI resolves, and forces
`--lockfile_mode` off — then `bazel mod deps --lockfile_mode=update`, then put it
back. Any host will do.

The lock's pip `facts` are host-independent: rules_python
2.3.2 records the union of all three files instead (facts `v2`), and a cold
ubuntu-24.04 x86_64 VM and macOS arm64 now produce byte-identical locks — so
`.bazelrc` no longer relaxes `--lockfile_mode` per host, and there is no splicing
or Linux-only step left. Windows is unmeasured; see the comment in `.bazelrc`.

**A rules_python bump is still the one to slow down for.** It carries the
requirements files the facts are derived from, so the recording moves with it,
and it can move the facts *schema* — 2.0.0 to 2.3.2 went `v1` to `v2`, which
dropped the `index_urls` map and changed hashes from bare hex to `sha256:<hex>`.
Refresh all three
`tools/pip_lock_guard/rules_python_publish_requirements_{linux,darwin,windows}.txt`
copies from the release's `tools/publish/`, and update
`_expectedRulesPythonVersion` and `_expectedFactVersion` in
`tools/pip_lock_guard/pip_facts_test.dart`. That test re-derives the facts from
those copies and fails on any drift, on every host, so it is what tells you
whether the bump landed correctly.

**Verification**: `bazel test //...` in the root passes, `pip_facts_test`
included. To check the lock the way CI does, move `.bazelrc.user` aside and run
`bazel mod deps --lockfile_mode=error`.

**Automation**: none.

---

## Release Archive Contents

**Trigger**: Adding or removing an e2e workspace, or any top-level directory.

**Files**: `.gitattributes`

The release archive is `git archive` output, so `export-ignore` decides what a
consumer downloads — and what BCR presubmit runs against. Extracting an archive
and building it is the only thing that catches either of these:

- **Patterns must be anchored with a leading `/`.** Without one they match a
  basename at any depth: `e2e/` also stripped `tools/dev_tool/test/e2e/`, and
  that package's `glob(["test/e2e/**/*.dart"])` then failed the whole archive at
  load time with "glob pattern didn't match anything, but allow_empty is set to
  False". The archive did not build at all, and nothing in CI looks at it.
- **`e2e/smoke` has to stay in.** `.bcr/presubmit.yml` names it as
  `module_path`, and BCR resolves that inside the extracted archive. It was
  excluded along with the rest of `e2e/`.

So `/e2e/` is excluded workspace by workspace rather than wholesale. **A new e2e
workspace needs a line here**, or it ships in the archive: the whole tree is 12MB
against a 1.5MB archive.

**Verification**: `git archive --format=tar HEAD | tar t` and check that
`e2e/smoke/` and `tools/dev_tool/test/e2e/` are present and no other e2e
workspace is. To check it builds, extract the archive somewhere clean and run
`bazel build --nobuild //...` — the load phase is what these mistakes break.

---

## BCR Presubmit Config

**Trigger**: When changing the test module or Bazel version requirements.

**Files**:

- `.bcr/presubmit.yml` — module_path, platform matrix, bazel matrix

**Procedure**: Update the YAML to match current requirements.

**Verification**: BCR presubmit passes after publishing.

**Automation**: Manual — changes are rare and coupled to other chores.

---

## Documentation Accuracy

**Trigger**: After any structural change (new rules, new e2e workspaces, etc.).

**Files**:

- `README.md` — examples table, installation snippet, version references. It is
  the architecture document too: `docs/ARCHITECTURE.md` was listed here long
  after it stopped existing, so check what a path names before trusting it
- `docs/TESTING.md` — the e2e workspace list, the sweep commands, the per-device
  tables
- `.github/workflows/ci.yaml` — the prose comments carry version claims of
  their own

**Procedure**: Review hardcoded counts, tables, and version strings against actual state.

**Verification**: Visual inspection.

---

## Multitool Version Bumps

**Trigger**: Periodic (monthly) or when a managed tool releases a version we need.

**Files**:

- `multitool.lock.json` — tool versions, URLs, and SHA-256 hashes

**Managed tools**: `yamlfmt`, `typos`

**Procedure**:

1. For each tool in `multitool.lock.json`, check its GitHub releases for newer versions
2. Download archives for all platform variants (macOS/Linux, arm64/x86_64)
3. Compute SHA-256 hashes and update the lockfile entries
4. Run `bazel run @multitool//tools/yamlfmt -- -lint .` and
   `bazel run @multitool//tools/typos -- .` to verify the updated tools work

**Verification**: Both tools run successfully against the repo.

Also update the matching `rev:` values in `.pre-commit-config.yaml` for yamlfmt
and typos to keep CI and local hooks in sync.

**Automation**: `/bump-multitool` slash command. Alternatively, install the
[multitool CLI](https://github.com/theoremlp/multitool) and run
`multitool --lockfile ./multitool.lock.json update`.

---

## Pre-commit Hook Bumps

**Trigger**: New versions of pre-commit hooks (buildifier, etc.).

**Files**:

- `.pre-commit-config.yaml`

**Procedure**: `renovate.json` extends `:enablePreCommit`, but treat this as
manual until you have actually seen a Renovate PR land here.

Reconcile the revs that track something else in this repo:

- `keith/pre-commit-buildifier` tracks `buildifier_prebuilt` in `MODULE.bazel`
  on the buildifier version — the first three components. The fourth is the
  ruleset's own packaging revision and the mirror repo tags only some of them
  (there is no 8.5.1.4), so a fourth-component gap is not drift.
- `google/yamlfmt` and `crate-ci/typos` track `multitool.lock.json` (see
  § "Multitool Version Bumps").
- `pre-commit/mirrors-prettier` is archived upstream; `v3.1.0` is the last
  stable tag and is expected to stay pinned.

**Verification**: `pre-commit run --all-files` passes.

**Automation**: Manual, per above.

---

## GitHub Workflow Dependency Bumps

**Trigger**: Periodic or when a dependency releases a version we need.

**Files**: All `.github/workflows/*.yaml` files.

**Procedure**:

1. For each `uses:` reference, check the repo's tags/releases for newer versions
2. Update the version ref
3. For reusable workflows, review changelogs for new inputs or breaking changes

**Verification**: CI workflow runs successfully.
