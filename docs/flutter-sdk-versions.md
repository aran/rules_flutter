# Flutter SDK versions

How `rules_flutter` picks, pins, extends, and mirrors the Flutter SDK.

## Stock releases

`flutter/private/versions.bzl` lists every supported release: `FLUTTER_VERSIONS`
maps the tag to its engine revision, material-fonts GCS path, and framework
source-tarball sha256; `ARTIFACT_CHECKSUMS` maps each engine artifact to its
sha256. Every repository rule reads its checksums through
`flutter_source_sha256()` / `flutter_artifact_sha256()`, and a missing entry
fails the fetch naming the artifact and the version instead of accepting
whatever bytes the server returns. Nothing is ever fetched without a recorded
sha256.

## Root-pin-wins selection

Each module in the build graph may request `flutter.toolchain(flutter_version
= ...)` for the default toolchain name, but the root module's pin wins:
`select_toolchain_version()` (in `flutter/private/toolchain_selection.bzl`,
mirroring `rules_dart`) picks the root request when there is one, and the
highest requested version otherwise. A dependency can suggest a version;
only the root module decides. Pins accept a numeric dotted core with an
optional semver-style `-<prerelease>` and/or `+<build>` suffix
(`3.44.1-acme`, `3.45.0-0.1.pre`, `3.44.1+corp.7`): ordering is numeric on
the core, a prerelease sorts below its release, and build metadata never
decides. Anything else fails naming the offending version. Two
equal-rank requests spelled differently (`3.44.1` vs `3.44.1+corp.7`)
are a hard error naming both requesting modules — neither spelling is
deterministically "the same" SDK, so pin one with `flutter.toolchain(`
`flutter_version = ...)` in the root module instead of letting tag
order pick.

The same root-wins rule applies to `local_path`: a root
`flutter.toolchain(local_path = ...)` overrides same-name version requests
from dependencies (the override is printed as a NOTE), so a root that goes
offline never conflicts with a dependency that suggests a download. "Mixed"
is an error only when the root module itself sets both — `local_path` and
`flutter_version` in one tag, or a local tag and a download tag for the same
name. A `local_path` in a non-root module is always an error.

## Custom releases (`flutter.version`)

Only the root module may register versions `versions.bzl` does not list — an
older stable, a rebuild, an enterprise engine. Budget for it up front: every
release needs its `engine_revision`, `source_sha256`, `material_fonts_url`,
and one `artifact_sha256` entry per artifact the repositories fetch — 58 for
a current release, the same set `ARTIFACT_CHECKSUMS` lists per stock version
(`e2e/smoke`'s `3.47.70` tag copies 3.47.7's set verbatim):

```starlark
flutter.version(
    version = "3.47.70",
    engine_revision = "<engine commit the artifacts are published under>",
    source_sha256 = "<sha256 of the framework source tarball>",
    material_fonts_url = "flutter_infra_release/flutter/fonts/<...>/fonts.zip",
    artifact_sha256 = {
        "dart-sdk-linux-x64.zip": "<sha256>",
        # ... one entry per artifact the repositories fetch
    },
)
flutter.toolchain(
    name = "custom",
    flutter_version = "3.47.70",
)
```

`merge_custom_versions()` folds root registrations into copies of the stock
tables, so every repository rule keeps reading through the same lookup
functions — now against the merged tables. The guards are:

- A `flutter.version` tag in a non-root module fails the build.
- Registering a version `versions.bzl` already lists fails (a custom release
  is never a silent override of a stock one).
- `version`, `engine_revision`, `source_sha256`, and `material_fonts_url`
  are all mandatory.
- A fetched artifact without a checksum in the merged table fails exactly
  like a stock one does, naming the artifact and the version — and the
  message points at the tag's own `artifact_sha256` for custom versions
  rather than at `versions.bzl`.

`engine_base_url` and `source_url` point a custom release at a replacement
origin serving the same layout (an enterprise mirror of the engine revision
directory, a vendored source tarball). They are per-release origins, not
general mirrors: plain host mirroring stays Bazel's job — see below.

`e2e/smoke` registers release `3.47.70`, an enterprise-style rebuild label
over 3.47.7's bytes, and resolves a toolchain from it. `material_fonts_url`
takes a GCS path as above; a full `https://` URL is used as-is.

## Offline SDKs (`local_path`)

`flutter.toolchain(local_path = ...)` sources every repository out of a
pre-extracted Flutter SDK instead of the network. The SDK must be a complete
install that has run `flutter precache` for every platform the build touches:

```starlark
flutter.toolchain(
    name = "local",
    local_path = "third_party/flutter",
)
```

```sh
# One host's desktop tools plus every target platform (Android, iOS, macOS,
# Linux, Windows, web). Repeat on each host OS you build on: the host-tools
# directories (`bin/cache/artifacts/engine/<host>/`) are per host.
flutter precache --android --ios --web --linux --windows --macos
# ... or everything for every host at once:
flutter precache --all-platforms
```

A relative path resolves against the main workspace root; an absolute path is
used as-is. `~` is not expanded: `local_path = "~/flutter"` resolves to a
literal `~` directory under the workspace root, not the home directory —
spell the home directory out. Each repository symlinks the SDK subtree it needs out of the
`bin/cache` layout and fails — never falling back to the network — when a
piece is absent:

- `bin/cache/dart-sdk` (the Flutter-bundled Dart SDK) and
  `bin/cache/flutter.version.json` (the version stamp every check reads);
- `bin/cache/artifacts/engine/<host>/` host tools, where `<host>` is per host
  OS family: `darwin-x64` on every Mac (even Apple Silicon), `linux-x64`,
  `linux-arm64`, or `windows-x64`;
- `bin/cache/artifacts/engine/common/` (debug and product patched SDKs),
  `bin/cache/artifacts/material_fonts/`, and `bin/cache/flutter_web_sdk/`;
- per-target engines: `ios*` / `android-*` (device and simulator, every mode),
  `darwin-x64*` / `linux-<arch>` / `windows-<arch>*` desktop engines (the
  macOS one as `FlutterMacOS.xcframework`), and the `android-*-release/` and
  `android-*-profile/` cross-compile `gen_snapshot` binaries;
- `packages/` (the framework sources), `packages/flutter_tools/` (the
  `gen-l10n` generator subset), and `bin/cache/pkg/sky_engine/` (the analyzer
  package).

Linked trees are watched, so SDK edits invalidate the repositories. Files a
fetch must modify (the dartdev AOT snapshot, the gen-l10n subset) are staged
as repo-owned copies. The SDK tree itself is never written: every `BUILD`
file lands in a repo-owned directory, and links are never written through,
so a read-only system-wide install works. A `pubspec.lock` with a `flutter:`
floor is checked against the local SDK's own version at fetch time, exactly
like the download-mode pin.

Only the root module may use `local_path`, and it is mutually exclusive with
downloading. `e2e/smoke` resolves a toolchain from a checked-in `fake_sdk`
tree this way; the tree mirrors the real cache layout above with placeholder
files (see `flutter precache --all-platforms` on a real install for the
reference), so the offline fetch paths run in CI without a 7 GB SDK.

## Mirrors

To serve stock bytes from a local mirror, keep the stock version and point
Bazel at the mirror with `--downloader_config` (see `tools/preset.bazelrc`
for the commented example): the recorded sha256 still verifies every byte,
so a mirror cannot smuggle in different artifacts. `engine_base_url` /
`source_url` exist for releases whose bytes genuinely live elsewhere, not
for mirroring stock releases.

## Adding a stock release

```sh
bazel run //tools/update_flutter_version -- 3.44.8
```

The tool reads the engine revision from the Flutter tag, downloads each
artifact, and prints the `FLUTTER_VERSIONS` entry plus the
`ARTIFACT_CHECKSUMS` table to paste into `flutter/private/versions.bzl`.
Existing entries are never touched: adding a release is append-only.
