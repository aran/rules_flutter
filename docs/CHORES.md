# Maintenance Chores

Central reference for all recurring maintenance tasks. Slash commands read this
file at runtime — keep file lists current as the repo evolves.

---

## Bazel Version Bump

**Trigger**: New Bazel release (typically minor/patch within 9.x).

**Files**:

- `.bazelversion`
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

**Procedure**:

1. For each `bazel_dep` in root `MODULE.bazel`, check latest version on BCR
2. Update versions, skip any already current
3. Regenerate lock files

**Verification**: `bazel build //...` passes.

**Automation**: `/bump-deps` slash command.

---

## Lock File Refresh

**Trigger**: After any change to `MODULE.bazel` files or their transitive deps.

**Workspaces** (directories containing `MODULE.bazel`):

- `.` (root)

**Procedure**: Run `bazel mod tidy --lockfile_mode=refresh` in each workspace.

**Verification**: All workspaces report success.

**Automation**: `/refresh-locks` slash command.

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

- `docs/ARCHITECTURE.md` — directory tree, provider table, testing table, e2e list
- `README.md` — examples table, installation snippet, version references

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

**Procedure**: Handled automatically by Renovate (`:enablePreCommit` preset).

**Verification**: Renovate opens PRs; CI runs pre-commit checks.

**Automation**: Renovate — no manual action needed.

---

## GitHub Workflow Dependency Bumps

**Trigger**: Periodic or when a dependency releases a version we need.

**Files**: All `.github/workflows/*.yaml` files.

**Procedure**:

1. For each `uses:` reference, check the repo's tags/releases for newer versions
2. Update the version ref
3. For reusable workflows, review changelogs for new inputs or breaking changes

**Verification**: CI workflow runs successfully.
