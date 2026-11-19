# Maintenance Chores

The recurring maintenance tasks of this repository: what starts each one, the
files it touches, the steps, and how to check the result. Keep the file lists
current as the tree changes; check what a path names before trusting it.

Some chores read sibling checkouts beside this one: `../flutter` is a clone of
[flutter/flutter](https://github.com/flutter/flutter), the source of truth for
release tags, and `../rules_dart` is a clone of
[rules_dart](https://github.com/aran/rules_dart), whose `overhead/` module
holds the tooling this repository shares with it (see AGENTS.md § Tooling).

---

## Flutter Version Bump

**Trigger**: New Flutter stable release.

**Authoritative source**: the tags of a flutter/flutter clone at `../flutter`
(or wherever `FLUTTER_REPO` points). Do not rely on web searches; they may be
stale. Run:

```sh
git -C ../flutter fetch --tags
git -C ../flutter tag -l '[0-9]*' | grep -v pre | sort -V | tail -5
```

The latest tag is the current stable release.

**Files**:

- `flutter/private/versions.bzl` — `FLUTTER_VERSIONS`, `FLUTTER_SDK_EXACT_PINS`,
  `FLUTTER_SDK_PACKAGES` and `ARTIFACT_CHECKSUMS`
- `MODULE.bazel` — `flutter_version` in the `flutter.toolchain()` call, and the
  `flutter_outline.toolchain()` calls below it (see step 5)
- Every `e2e/*/MODULE.bazel` — their own `flutter.toolchain()` calls
- `README.md` — the Requirements table, the `MODULE.bazel` snippets under
  Getting started and further down, and the `FlutterSdkInfo.version` example
  under Providers
- Everything else that names the old version: `git grep -l '<old-version>' --
  ':!*.lock'` lists it (tests, fixtures, the e2e custom engine's stand-in
  checkout). Some of these pin a version on purpose; read each before changing
  it.

**Procedure**:

1. Fetch tags and identify the latest stable version (see above).
2. Run `bazel run //tools/update_flutter_version -- <new-version>`. It looks up
   the engine revision from the tag, downloads and hashes each artifact, and
   prints the Starlark to put in `flutter/private/versions.bzl`, including the
   exact pins of the SDK's own packages and the list of those packages.
3. Copy the printed snippets into `flutter/private/versions.bzl`.
4. Update `flutter_version` in `MODULE.bazel`, the e2e workspaces and the
   README.
5. If the new release bundles a Dart version no other supported release does,
   give `//flutter/tests/outline_fixture` an SDK for it: a
   `flutter_outline.toolchain()` in the root `MODULE.bazel` and an entry in
   `OUTLINE_SDKS` in `flutter/tests/outline_fixture/outline_cutoff.bzl`. The
   fixture fails to load, saying so, while a Dart version in `versions.bzl` has
   no SDK there. Drop the entries of a Dart version no supported release uses
   any more.
6. Refresh the lock files (§ "Lock File Refresh").

**Verification**: `bazel test //... --config=deep` in the root. The `deep`
tier holds the tests that `bazel test //...` skips by default, the outline
fixture's builds under each extra SDK among them, and a bump can change which
Dart versions those need. Then `bazel test //...` in `e2e/smoke`.

---

## Bazel Version Bump

**Trigger**: New Bazel release (typically minor/patch within 9.x).

**Files**:

- Every `.bazelversion`: the repo root plus one per workspace with a
  `MODULE.bazel`. A workspace without one does
  not inherit the root's: bazelisk reads only its own workspace root and
  otherwise fetches the newest release, so a missing file silently runs a
  different Bazel than the rest of the sweep. `git ls-files '*.bazelversion'`
  is the list.
- `.bcr/presubmit.yml` — the `bazel:` matrix value (if the major version
  changes)
- `tools/preset.bazelrc` — generated for the Bazel version in use
  (§ "Bazelrc Preset")

**Procedure**:

1. Update all `.bazelversion` files to the new version.
2. If the major version changed, update the `.bcr/presubmit.yml` matrix.
3. Regenerate `tools/preset.bazelrc` (§ "Bazelrc Preset").
4. Refresh the lock files (§ "Lock File Refresh"): the lock records a format
   version that changes with Bazel's.

**Verification**: `bazel build //...` passes.

---

## Bazel Module Dependency Bumps

**Trigger**: Periodic (monthly) or when a dep releases a version we need.

**Files**:

- `MODULE.bazel` — `bazel_dep()` version strings
- Every `e2e/*/MODULE.bazel`: these
  declare their own `bazel_dep`s rather than inheriting the root's, so a
  root-only bump leaves them behind. `grep -l 'name = "<module>"'
  e2e/*/MODULE.bazel` lists the workspaces
  that declare a given module.

**Procedure**:

1. For each `bazel_dep` in the root `MODULE.bazel`, check the latest version on
   the Bazel Central Registry.
2. Update versions, skipping any already current.
3. Mirror the same versions into the e2e workspaces that declare them.
4. A bump of rules_android or rules_jvm_external can change the Maven locks:
   re-pin them (§ "Lock File Refresh").
5. Refresh the lock files.

**Verification**: `bazel build //...` passes.

---

## Lock File Refresh

**Trigger**: After any change to a `MODULE.bazel`, its transitive deps, or a
`.bazelversion`. The lock records a format version as well as registry hashes.

Every workspace's `MODULE.bazel.lock` is checked: the root's and each e2e
workspace's (their `.bazelrc` sets `--lockfile_mode=error`). The tools run
Bazel with every rc file Bazel reads, the gitignored `.bazelrc.user` included,
whose `--override_module` lines would put a local checkout's module graph into
a lock. Move the `.bazelrc.user` files aside (root and every e2e workspace)
before a refresh or a check, and put them back afterwards.

**Procedure**:

- Module locks, root and e2e:
  `bazel run --lockfile_mode=off @overhead//locks:refresh`
- Maven locks (`maven.install` lock files), one workspace at a time:
  `bazel run //tools/maven_locks -- --refresh <workspace>`, for example
  `e2e/smoke`.

**Verification**: `bazel run @overhead//locks:check` and `bazel run //tools/maven_locks`.
Run the first on macOS: it analyses `//...` in every workspace, and only macOS
can analyse the iOS rules.

---

## Bazelrc Preset

**Trigger**: A bump of overhead's commit or of `.bazelversion`.

**Files**: `tools/preset.bazelrc`, generated; the root `.bazelrc` imports it
first.

**Procedure**: `bazel run @overhead//preset`.

**Verification**: `bazel run @overhead//preset -- --check`, which CI also runs.

---

## Chrome for Testing and Linux Runtime Pins

**Trigger**: Periodic, or when a test needs a newer Chrome or Debian package.

**Files**: `flutter/private/versions.bzl` (`CHROME_FOR_TESTING`) and
`flutter/private/linux_runtime_pins.bzl`.

**Procedure**:

- Chrome: `bazel run //tools/update_chrome_for_testing` (the Stable channel) or
  `bazel run //tools/update_chrome_for_testing -- <version>`. It hashes each
  host's headless shell and prints the `CHROME_FOR_TESTING` entry to put in
  `versions.bzl`.
- Linux runtime: `bazel run //tools/update_linux_runtime -- <snapshot>`, a
  snapshot.debian.org timestamp such as `20261104T000000Z`. It writes
  `linux_runtime_pins.bzl`.

**Verification**: the web and Linux integration tests in `e2e/integration_test`
(docs/TESTING.md).

---

## Release Archive Contents

**Trigger**: Adding or removing an e2e workspace, or any top-level directory.

**Files**: `.gitattributes`

The release archive is `git archive` output, so `export-ignore` decides what a
consumer downloads, and what BCR presubmit runs against. Extracting an archive
and building it is the only thing that catches either of these:

- **Patterns must be anchored with a leading `/`.** Without one they match a
  basename at any depth: `e2e/` also stripped `tools/dev_tool/test/e2e/`, and
  that package's `glob(["test/e2e/**/*.dart"])` then failed the whole archive at
  load time with "glob pattern didn't match anything, but allow_empty is set to
  False".
- **`e2e/smoke` has to stay in.** `.bcr/presubmit.yml` names it as
  `module_path`, and BCR resolves that inside the extracted archive.

So `/e2e/` is excluded workspace by workspace rather than wholesale. **A new e2e
workspace needs a line here**, or it ships in the archive.

**Verification**: `bazel run //tools/consumer_archive` extracts HEAD's archive
to `e2e/external_module/rules_flutter`; then `bazel query @rules_flutter//...`
in `e2e/external_module` loads what a consumer gets. `git archive --format=tar
HEAD | tar t` should show `e2e/smoke/` and `tools/dev_tool/test/e2e/`, and no
other e2e workspace.

---

## BCR Presubmit Config

**Trigger**: When changing the test module or Bazel version requirements.

**Files**: `.bcr/presubmit.yml` — `module_path`, platform matrix, bazel matrix

**Procedure**: Update the YAML to match current requirements. Changes are rare
and usually come with another chore.

**Verification**: BCR presubmit passes after publishing.

---

## Documentation Accuracy

**Trigger**: After any structural change (new rules, new e2e workspaces, etc.).

**Files**:

- `README.md` — the user guide and the architecture document: examples table,
  installation snippet, version references
- `docs/TESTING.md` — the e2e workspace list, the sweep commands, the per-device
  tables
- `.github/workflows/ci.yaml` — the prose comments carry version claims of
  their own

**Procedure**: Review hardcoded counts, tables, version strings and paths
against the tree.

**Verification**: Read the changed sections against the code.

---

## Tool Version Bumps

**Trigger**: Periodic (monthly) or when a managed tool releases a version we need.

**Files**: none in this repository. `git-cliff`, `prek`, `typos` and `yamlfmt`
are pinned in rules_dart's `overhead/multitool.lock.json`, which every
repository that takes overhead as a dev dependency shares. Bump them there
(rules_dart's CHORES.md has the procedure), then bump the `commit` of the
`overhead` `git_override` in `MODULE.bazel` and the `uses:` refs in
`.github/workflows` to the new rules_dart commit; `bazel run @overhead//pins:check`
fails if they differ. A new overhead commit can change `tools/preset.bazelrc`
(§ "Bazelrc Preset").

**Verification**: `bazel run --enable_runfiles @overhead//lint:prek -- run --all-files --hook-stage manual` passes.

---

## Git Hook Bumps

**Trigger**: New versions of the git hooks (buildifier, etc.).

**Files**: `.pre-commit-config.yaml`

**Procedure**: `renovate.json` extends `:enablePreCommit`, but treat this as
manual until you have actually seen a Renovate PR land here.

Reconcile the revs that track something else in this repo:

- `keith/pre-commit-buildifier` is the only buildifier in this repository; pick
  the newest tag of the mirror. The fourth component is the mirror's own
  packaging revision and it tags only some of them.
- The commit-message, yamlfmt and typos hooks are local hooks that run
  overhead's pinned tools (see § "Tool Version Bumps").
- `pre-commit/mirrors-prettier` is archived upstream; `v3.1.0` is the last
  stable tag and is expected to stay pinned.

**Verification**: `prek run --all-files` passes.

---

## GitHub Workflow Dependency Bumps

**Trigger**: Periodic or when a dependency releases a version we need.

**Files**: All `.github/workflows/*.yaml` files.

**Procedure**:

Every `uses:` that is not local (`./.github/...`) is pinned to a full commit SHA
with the version in a trailing comment: `uses: owner/repo@<sha> # v1.2.3`
(`owner/repo/path@<sha> # v1.2.3` for a subpath). A bump changes both.

1. For each `uses:` reference, check the repo's tags/releases for newer versions.
2. Resolve the new tag to its commit. For an annotated tag, take the peeled
   `^{}` line (the commit), not the tag object:
   `git ls-remote https://github.com/owner/repo refs/tags/<tag> 'refs/tags/<tag>^{}'`
3. Replace the SHA and the comment together.
4. For reusable workflows, review changelogs for new inputs or breaking changes.

overhead's workflows (`aran/rules_dart/.github/workflows/overhead-*`) move with
the rules_dart commit instead (see § "Tool Version Bumps").

**Verification**: `bazel test //tools/ci_matrix:pinned_actions_test` passes (it
fails on a `uses:` that is not a 40-hex SHA with a `# <ref>` comment), and the CI
workflow runs successfully.
