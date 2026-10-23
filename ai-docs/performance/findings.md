# Findings

Facts established by measurement or by reading the code. Each one says how it
was established, so it can be rechecked when Flutter, Dart or Bazel moves.
Unless stated otherwise: rules_flutter `51b22bb`, Flutter 3.47.6 (bundled Dart
3.13.5), Bazel 9.2.0, Linux x64.

## Baseline: root workspace

`bazel test //... --jobs=16`, run clean against the published rules_dart 0.7.2:

- 338 tests pass, 2 iOS tests skip, 464 targets analysed.
- 360 s wall time, of which about 112 s is first-time downloads.
- Critical path 59.7 s.
- 14,287 processes.

Against rules_dart `main` at `95089ce`, through `--override_module` with
`--lockfile_mode=off`, the suite stays green:

- The 85 tests that re-ran, all `dart_test`s in `//tools/dev_tool` and
  `//flutter/private/tools` plus the two analyze fixtures, pass.
- The other 253 results were cached. Their inputs did not change, so that is
  sound.
- The e2e workspaces were not run, and they hold nearly all real Flutter
  compiles (plan 0.1).

## Where a Flutter target's cost goes (read from the code)

- **Every `flutter_test` and application compiles its whole program.**
  - `flutter_compile_kernel` (`flutter/private/common.bzl`) and
    `_flutter_test_impl` (`flutter/private/flutter_test.bzl`) hand
    frontend_server every transitive source.
  - `package:flutter` alone is 695 `.dart` files (24 MB), compiled again for
    every test.
  - Nothing is shared between targets.
- **Every Flutter action takes the whole SDK.**
  - `FlutterSdkInfo.tool_files` (`flutter/toolchain.bzl`) is all of `dart-sdk/`
    plus the patched SDK: 1,049 files, 654 MB.
  - It is an input of every `FlutterKernelCompile`, `FlutterShaderCompile` and
    `FlutterAssetBundle` action, and part of every `flutter_test`'s runfiles.
  - The kernel compile itself reads `dartaotruntime` (5.7 MB), the
    frontend_server snapshot (17 MB) and a platform dill.
- **Build-step scripts are JIT-compiled on every action.**
  - `kernel_filter.dart`, `compile_shader.dart`, `generate_asset_manifest.dart`,
    `bundle_app.dart`, the manifest and plist mergers and `web_template.dart`
    are run as `dart <script>.dart` straight from source
    (`flutter/private/tools/BUILD.bazel` says so).
  - Only `flutter_test_runner` and `pub_runner` are compiled (`compile_mode =
    "exe"`).
- **Every test repeats the same shader and asset work.**
  - Each `flutter_test` compiles `package:flutter`'s two shaders
    (`ink_sparkle.frag`, `stretch_effect.frag`) under its own output path, so N
    tests run 2N identical compiles.
  - Each compile goes through the `compile_shader.dart` wrapper with the whole
    SDK as input, because the `tester` stage list has SkSL plus Vulkan.
  - Each test also builds its own `flutter_assets/` tree.
- **Analysis repeats work.** `_flutter_test_impl` flattens
  `DartInfo.transitive_packages` three times (`_can_bootstrap`,
  `_has_flutter_test`, `check_unreplaced_hooks`), as well as the transitive
  sources. This is not profiled yet.

## Two Dart SDKs in every Flutter workspace

- rules_dart's `MODULE.bazel` registers its default toolchain (Dart 3.13.5) for
  every consumer: `register_toolchains("@dart_toolchains//:all")`, not a dev
  dependency.
- rules_flutter's engine repository (`flutter_engine_artifacts`,
  `flutter/repositories.bzl`) ships the Flutter-bundled Dart SDK under
  `dart-sdk/`.
- Both were fetched in the baseline run, 642 MB each:
  `rules_dart++dart+dart_linux-x64` and `+flutter+flutter_linux-x64/dart-sdk`.
- Who uses which:
  - **Flutter's Dart** (`FlutterSdkInfo.dart`/`dartaotruntime`/`tool_files`):
    the kernel compile, shader and asset-bundle steps, and every script in
    `flutter/private/tools`.
  - **rules_dart's Dart** (`@rules_dart//dart:toolchain_type` and
    `:exec_tools_toolchain_type`):
    - the `dart_analyze` aspect over Flutter targets (analysis, format check,
      fix);
    - `dart_codegen`;
    - every `dart_test` and `dart_binary`, including rules_flutter's own
      `flutter_test_runner`;
    - `flutter_application`'s link hooks (`flutter_application.bzl:205`).
- Nothing ties the two versions together. They are both 3.13.5 today because
  rules_dart's default and Flutter 3.47.6's bundled Dart happen to match.
  `flutter/private/versions.bzl` lists 17 Flutter releases and records no Dart
  version for any of them.
- The layouts match. `dart-sdk/` in the Flutter engine repository has the same
  `bin/`, `lib/` and `version` layout as the root of rules_dart's SDK
  repository. rules_dart's `dart_toolchain`, `compile_files` and
  `runtime_files` declarations would apply to it unchanged, with a path prefix.
- The separate toolchain has no recorded rationale. `flutter/toolchain.bzl`
  dates from the initial scaffolding (`e5fbb95`) and mirrors the shape of
  rules_dart's `dart/toolchain.bzl`.
- What is genuinely Flutter's and not Dart's varies by target platform:
  - `gen_snapshot` (per target), the engine library, `flutter_tester`;
  - `impellerc` and `shader_lib`, `font-subset` and `const_finder`;
  - the patched platform dills that carry `dart:ui`;
  - the ICU data, the isolate snapshots, the Material font, the Linux sysroot.

## Modular compilation is possible with Flutter's own SDK

- Flutter's bundled `dart-sdk/bin/snapshots/` includes
  `kernel_worker_aot.dart.snapshot`. Its `--help` lists `--target` with `vm,
  flutter, flutter_runner, dart2js, dart2js_summary, dart2wasm, ddc`, and
  `--input-linked`, `--multi-root` and `--multi-root-scheme`.
- `patched-sdk/flutter_patched_sdk/` holds `platform_strong.dill` and
  `vm_outline_strong.dill`, the Flutter platform as a full kernel and as an
  outline.
- rules_dart's modules (their plan #7) can't be reused for Flutter as they
  are. They are compiled for `--target vm` against the standalone Dart
  platform, while Flutter code needs `--target flutter` against a platform
  that has `dart:ui`. Conditional imports on `dart.library.ui` also resolve
  differently.

## Tooling

- `bazel analyze-profile` no longer exists. Bazel 9.2.0, 9.3.0 and 10.0.0rc1
  all answer `'analyze-profile' is not a known command`.
- The `--profile` JSON trace is still written. rules_dart's
  `harness/prof.py` summarises it per mnemonic. Use `--noslim_profile`.

## Bazel versions (root `bazel test //...`, selected by `USE_BAZEL_VERSION`)

- **9.3.0**: 338 pass, 2 skipped, 353 s, with `--lockfile_mode=off`.
  - With the repository default `--lockfile_mode=error`, Bazel stops with
    `Missing checksum for registry file
    https://bcr.bazel.build/modules/apple_support/2.5.2/MODULE.bazel`.
  - Bumping needs the lockfile refresh `.bazelrc` describes.
- **10.0.0rc1**: analysis fails in C toolchain auto-configuration, not in
  these rules. Not diagnosed.
  - First `Cannot find gcc or CC`, although `gcc` is on PATH and 9.3.0 finds
    it.
  - With `--repo_env=CC=/usr/bin/gcc`, it fails with `key "ar" not found in
    dictionary`.

## Download checksums (audit, 2026-10-14)

- **rules_dart's SDK download is strict.** `dart/repositories.bzl` indexes
  `TOOL_VERSIONS[version][platform]`, so a missing checksum fails the fetch.
- **rules_flutter's checksums are optional.** Every engine download in
  `flutter/repositories.bzl` reads `ARTIFACT_CHECKSUMS.get(version,
  {}).get(path, "")`, and Bazel accepts any bytes for an empty `sha256`.
  - `ARTIFACT_CHECKSUMS` has 8 Flutter versions, 30–31 artifacts each,
    including `dart-sdk-<host>.zip` for all five hosts.
  - The Android engine artifacts (`android-<arch>-<mode>/artifacts.zip`) and
    Android `gen_snapshot` (`android-<arch>-release/<host>.zip`) are not in the
    table for any version, so today they download unverified.
  - `flutter_source_sha256()` and `LINUX_SYSROOT_CHECKSUMS[...]` are strict.
- **Pub packages:** `flutter.pub` takes each hosted package's `sha256` from
  `pubspec.lock` (`description.sha256`). An entry without one downloads
  unverified (`flutter/extensions.bzl`, `flutter_pub_package.bzl`).

## Plan T is feasible on rules_dart 0.7.2 (read from the code)

- **Finding the SDK.** rules_dart derives the SDK directory from the `dart`
  binary (`sdk_path_from_dart`: strip `/bin/dart`), not from the repository
  root. So an SDK under `dart-sdk/` in Flutter's engine repository resolves
  correctly.
- **What T1 must mirror.** rules_dart registers, per host:
  - a `toolchain_type` toolchain, with exec and target both the host;
  - an `exec_tools_toolchain_type` toolchain, with exec constraints only;
  - desktop cross toolchains (`CROSS_TARGETS`, which reuse the host `dart`).
  T1 has to mirror all three, or the remaining resolutions fall back to
  rules_dart's registration and fetch its SDK.
- **The 0.7.2 attributes.** `dart_toolchain` in 0.7.2 takes `dart`,
  `sdk_root`, `version`, `target_os` and `target_arch`. `compile_files` and
  `runtime_files` exist only on rules_dart `main` (`b3c8dc3`).

## e2e against rules_dart `main` (plan 0.1, 2026-10-14)

- **What ran.** rules_dart `87e6772` (`--override_module`, run B) against the
  published 0.7.2 (run A), with `--nocache_test_results` on B.
- **Workspaces.** The CI Linux pair (`hello_world`, `codegen`), plus `smoke`,
  `dual_hub`, `plugin_example`, `ffi_example`, `ffi_plugin_example` and
  `web_example`.
- **Android stand-ins.** `hello_world` and `plugin_example` need an Android
  NDK and SDK that this host lacks. They ran with the NDK repository stubbed
  (`--override_repository=...androidndk=<empty repo>`); their Android targets
  then fail to load, the same way in A and B.
- **No regressions.** Every workspace has identical results in A and B:
  - `codegen`: 10 pass;
  - `smoke` and `dual_hub`: 1 pass each;
  - `ffi_example`: 4 pass;
  - `ffi_plugin_example`: 3 pass;
  - `web_example`: 12 pass;
  - `hello_world`: 14 pass, Android targets environmental;
  - `plugin_example`: 2 pass, Android environmental, plus bug B1 in both runs.
- **What B actually exercised** (from its `--profile`):
  - Re-ran: `DartAnalyze`, `DartFormat`, `DartCompile` and every `TestRunner`.
  - Cache hits: every `FlutterKernelCompile`, `FlutterShaderCompile` and
    `FlutterAssetBundle`. rules_dart `main` doesn't change their action keys,
    so bumping rules_dart is safe for Flutter's compile path, and its
    analysis/format/test changes pass on Flutter targets.
- **Rough per-action costs on `codegen`** (32-way parallel, so contended):
  - `TestRunner`: 17.8 s mean over 10 Flutter tests;
  - `DartAnalyze`: 8.3 s mean;
  - `DartFormat`: 5.9 s mean;
  - `CopyToDirectory`: 1.9 s mean.
  The benchmark (0.2) will measure these properly.

## Benchmark baseline and T1 (plan 0.2, 2026-10-14)

Full size (30 packages x 20 files, one widget test each, kernel + web + Linux
app; analysis variant 80 x 30), Bazel 9.2.0, `RULES_FLUTTER_BENCH_JOBS=4` on
an 8 GiB container. Raw data: `results/baseline_main.json` (rules at main
before H0/B1/T1; neither H0 nor B1 changes an action) and
`results/t1_one_dart.json` (main + T1). Times are summed action durations.

| Metric                                         | baseline       | T1             |
| ---------------------------------------------- | -------------- | -------------- |
| Fetched SDK repos                              | 2450 MB        | **1808 MB**    |
| rules_dart's Dart SDK fetched                  | yes            | **no**         |
| Clean build: kernel compiles / shader compiles | 33 / 64        | 33 / 64        |
| Leaf body edit: kernel compiles re-run         | 33 of 33       | 33 of 33       |
| Kernel inputs of one test                      | 2312 / 692 MB  | 2312 / 692 MB  |
| Test runfiles                                  | 1062 / 752 MB  | 1062 / 752 MB  |
| Lint after a body edit: analyze/format/copy    | 61 / 61 / 61   | 61 / 61 / 61   |
| Lint clean: copy actions                       | 998            | 998            |

Where the time goes (baseline):

- Lint dominates: clean lint is ~528 s wall; DartAnalyze 61 x ~12 s,
  DartFormat 61 x ~4.6 s, 998 CopyToDirectory. A one-line leaf edit re-runs
  every analyze, format and copy action. rules_dart `main` fixes the format
  and copy parts (`6d99c78`, `95089ce`); it reaches Flutter with the
  rules_dart bump (ask D).
- A leaf edit re-runs all 33 Flutter kernel compiles (~15 s each), because
  every test and app compiles its whole program: plan 2.1.
- 64 shader compiles in a clean build (two SDK shaders per test plus the
  app's), byte-identical across consumers: plan 1.3.
- Every kernel compile and every test carries the whole SDK: plan 1.1, T1b.

**Wall times on this host are noise, not signal.** The host is shared (load
average 9-12 from other workspaces). Between the two runs,
FlutterKernelCompile, whose inputs T1 does not change, moved +24% in the
body-edit scenario, and CopyToDirectory, a rules_dart action T1 does not touch,
moved 3x. T1's SDK is byte-identical to rules_dart's (1047 vs 1049 files; the
two extra are rules_dart's `BUILD.bazel` and `REPO.bazel`; the analysis server
snapshot is identical), so no action can be faster or slower under T1. Judge
changes on this host by action counts, input sizes and fetch footprint; wall
time needs a quiet machine or interleaved A/B runs.

## Compiled build-step tools (plan 1.2, `280bfb9`)

The build-step scripts ran as `dart script.dart` because, before T1, a
`dart_binary` compiled with rules_dart's Dart rather than Flutter's; no
technical reason was recorded. They are now `dart_binary(compile_mode = "exe")`
targets in `flutter/private/tools`, used with `cfg = "exec"`, and actions run
them directly. Only the asset bundle still takes `dart` and the SDK files, and
only with icon tree shaking on, because `const_finder` is a Dart snapshot.
Raw data: `results/p12_compiled_tools.json` (same setup as above).

| Metric                                 | T1             | 1.2              |
| -------------------------------------- | -------------- | ---------------- |
| Kernel inputs of one test              | 2312 / 692 MB  | **1269 / 69 MB** |
| Clean build: sandboxed actions         | 139            | 144              |
| Clean build: kernel compiles           | 33             | 33               |
| Clean build: compile CPU (tool builds) | 2.8 s          | 39.4 s           |
| Test runfiles                          | 1062 / 752 MB  | 1062 / 752 MB    |

- The kernel compile's inputs are now its program's sources plus the engine's
  `dartaotruntime`, frontend_server and platform dill. Sandbox setup and
  remote-execution input uploads shrink 10x by size per compile.
- The five extra actions (and ~37 s of CPU, once per output base) build the
  tools the benchmark uses: `kernel_filter`, `compile_shader`,
  `generate_asset_manifest`, `bundle_app` and `web_template`.
- Test runfiles still carry the SDK: plan 1.1.

## Shaders once per platform (plan 1.3, `14e5844`)

Shaders a dependency declares (the SDK's `ink_sparkle` / `stretch_effect`, a
`flutter_library`'s `shaders` and `pkg_shaders`) are compiled by an aspect on
`deps`, on the declaring target, once per platform: one aspect for
`flutter_test` (tester), one for the web bundle, one for the native apps (which
reads the platform from the target constraints, as the app rule does). Each
compiled file records its platform, and a consumer only takes those that match
its own; a target's own `shaders`, and every shader of a target with
`require_sksl_shaders = True`, still compile at the target. Bundle paths are
unchanged. Raw data: `results/p13_shaders_once.json`.

| Clean build                   | 1.2                              | 1.3                           |
| ----------------------------- | -------------------------------- | ----------------------------- |
| Shader compiles               | 64 (60 tester, 2 web, 2 Linux)   | **6** (2 each)                |
| Shader compile time (summed)  | 125 s                            | **38 s**                      |
| Sandboxed actions             | 144                              | **86**                        |

The count no longer grows with the number of tests and apps: it is the
number of distinct shaders times the platforms built.

## rules_flutter on rules_dart main (`4005f33`)

`rules_flutter` `2f2a861` (T1 + 1.2 + 1.3) measured against `rules_dart` `main`
at `4005f33` via `--override_module`, plus a local three-line
`Label("//dart:copy_toolchain_type")` fix in `dart/private/source_set.bzl`
(`0b0f033`; without it, analysis fails on every `flutter_test` with
`no such target '@@rules_flutter+//dart:copy_toolchain_type'`, reported as ask
K). Raw data: `results/main_dart_4005f33.json`.

| Metric | 1.3 (`p13_shaders_once`) | `main_dart_4005f33` |
| --- | --- | --- |
| Re-analysis, 80-pkg variant (median) | 7.46 s (`[7.80, 7.25, 7.46]`) | **1.60 s** (`[1.76, 1.60, 1.39]`) |
| Clean build: sandboxed actions | 86 | 92 (+6 `DartKernel`) |
| Clean build: tool compiles (`DartKernel` + `DartCompile`) | 0 + 6 (17.5 s) | 6 + 6 (5.6 s + 8.8 s) |
| Clean build: `FlutterKernelCompile` / `FlutterShaderCompile` | 33 / 6 | 33 / 6 |
| Kernel inputs of one test / test runfiles | 1269 (69.2 MB) / 1062 (752 MB) | 1269 (69.2 MB) / 1062 (752 MB) |
| Extracted external SDK dirs (`fetch_footprint`) | 1808 MB | 1808 MB |
| Lint clean: copy actions | 998 `CopyToDirectory` (563 s) | **122 `DartCopyTree`** (363 s) |
| Lint clean: `DartAnalyze` / `DartFormat` | 61 (817 s) / 61 (178 s) | 61 (716 s) / 61 (**106 s**) |
| Lint clean: tool compiles (`DartKernel` + `DartCompile`) | 0 + 8 (41.4 s) | 9 + 9 (12.0 s + 19.0 s) |
| Lint clean: sandboxed actions | 1208 | **342** |
| Lint after a body edit: analyze / format / copy re-run | 61 / 61 / 61 `CopyToDirectory` | 61 / **2** / 63 `DartCopyTree` |
| Lint after a body edit: sandboxed actions | 223 | **166** |

What the bump buys:

- **Lint copy actions drop 8.2x (`998 -> 122`), and `lint_clean` sandboxed
  actions drop 3.5x (`1,208 -> 342`).** `stage_config_project(...,
  copy_external = False)` (`95089ce`) names external pub and SDK packages in
  place in `package_config.json`, eliminating all 937 `.dart_analyze.extpkgs/*`
  copy actions. The remaining 122 `DartCopyTree` actions are two per analyzed
  target across the 61 workspace targets (`30 flutter_library + 30 flutter_test
  + 1 app_kernel`): one `.dart_analyze.proj/src` tree for `DartAnalyze` and one
  `.dart_analyze.format.proj/src` tree for `DartFormat`. `FileWrite` actions in
  `lint_clean` also fall from 2,347 to 1,533.
- **A leaf body edit re-runs 2 `DartFormat` actions instead of 61 (8.5 s vs
  199 s summed CPU).** `DartFormat` now stages only a target's own `.dart`
  files (`6d99c78`), so editing `packages/pkg0/lib/src/f0.dart` invalidates
  only `//packages/pkg0:pkg0` and `//packages/pkg0:pkg0_test`; the other 59
  targets' format trees and actions are cache hits.
- **Re-analysis of the 80-package graph drops 4.7x (`7.46 s -> 1.60 s`).**
  `colocate_packages`, `resolve_package_roots`, and
  `generate_dev_package_config` (all called by `flutter_compile_kernel` on
  every `flutter_test` and app) now index packages once with `package_index`
  and match each file in path-depth time via `package_for_index` (`0e3c404`),
  rather than scanning the package list per file.
- **`bazel_lib` and `yaml.bzl` are replaced on the Dart side (`84c8767`,
  `5387726`).** Directory assembly runs `//dart/private/tools:copy_tree`
  (mnemonic `DartCopyTree`; `table.py`'s `copies re-run` row queries
  `CopyToDirectory` and therefore prints `–` for `main_dart_4005f33`, where 63
  `DartCopyTree` actions ran).

What it costs and what remains:

- **Needs the `Label("//dart:copy_toolchain_type")` fix in `rules_dart` (ask
  K).** `dart/private/source_set.bzl` exported
  `COPY_TO_DIRECTORY_TOOLCHAINS = ["//dart:copy_toolchain_type"]` as a plain
  string and indexed `ctx.toolchains` with it, which resolves against
  `@@rules_flutter+` when a `rules_flutter` rule declares the toolchain or
  calls `colocate_packages`.
- **Two-stage tool compiles add 6 `DartKernel` actions in `clean_build` (9 in
  `lint_clean`, plus 1 `DartCompile` for `copy_tree`).**
  `dart_binary(compile_mode = "exe")` now runs `gen_kernel` (`DartKernel`)
  before `gen_snapshot` (`DartCompile`) to emit stable
  `org-dartlang-bazel:///` URIs (`d2120e8`). Summed tool-compile CPU in
  `clean_build` is 14.4 s (5.6 s + 8.8 s) vs 17.5 s before.
- **A leaf body edit still re-runs all 61 `DartAnalyze` and 63 `DartCopyTree`
  actions (61 `.dart_analyze.proj/src` + 2 `.dart_analyze.format.proj/src`).**
  Staging only a target's own sources for analysis requires
  `//dart:analyzer_summaries`, which stays off until ask B (rules_dart plan
  #17, embedding `sky_engine`'s `dart:ui` in the SDK summary) lands.
- **Dart toolchain actions still carry the whole 1,047-file / 642 MB
  `dart-sdk/` as inputs.** `rules_dart` `main` added optional `compile_files`,
  `runtime_files`, and `analyze_files` attributes to `dart_toolchain`
  (`b3c8dc3`), falling back to `tool_files` (`sdk_root`) when unset. Because
  `flutter/repositories.bzl` registers Flutter's Dart with `sdk_root =
  ":dart_sdk_files"` alone until ask E (plan #18 / plan T1b) lands, all 61
  `DartAnalyze`, 61 `DartFormat`, and 9 `DartKernel` / `DartCompile` actions
  still take the full SDK depset, and `find_sdk_kernel_tools` scans all 1,047
  files per tool compile.
- **Extracted vs downloaded SDK size.** `fetch_footprint` measures extracted
  directories under `external/` (1,808 MB: `flutter_linux-x64` at 824 MB and
  `flutter_web_sdk` at 759 MB each extract a 642 MB `dart-sdk/`, while
  `rules_dart`'s standalone SDK is not fetched). Bazel's repository cache is
  content-addressed by sha256, so the shared Dart SDK archive is downloaded at
  most once over the network but extracted twice on disk (plan D1/D2).

## Trimmed SDK action inputs and test runfiles (plan 1.1, `aa6944e`)

Each Flutter action now declares only the host SDK / engine files it actually
opens (`dart_vm_files`, `dart_pub_files`, `dart2wasm_files`, `dart2js_files`),
and `flutter_test` drops `flutter_sdk_info.tool_files` from its runfiles.
Verified in a hardlinked non-symlinked sandbox (`hermetic_replay.py`, where
`readlink("/proc/self/exe")` cannot escape into the full external repository).

| Metric | Before (`1.3`) | After (`1.1`, `aa6944e`) |
| --- | --- | --- |
| `flutter_test` runfiles (`//:impeller_shader_test`) | 1,055 files / 772.1 MiB | **6 files / 121.6 MiB** (-1,049 files, -650.5 MiB) |
| `FlutterAotElf` / `FlutterAotMacho` SDK inputs | 1,050 files (`tool_files`) | **0 files** (`gen_snapshot` only) |
| `FlutterAssetBundle` SDK inputs (debug / test) | 1,050 files (`tool_files`) | **0 files** (`inputs=3` total in `hello_world`) |
| `FlutterAssetBundle` SDK inputs (`-c opt` icon tree-shaking) | 1,050 files (`tool_files`) | **4 files** (`dart` + 3 `dart_vm_files`) |
| `FlutterDart2Wasm` SDK + web inputs | 2,645 files (`tool_files` + `web_sdk`) | **12 files** (11 `dart2wasm_files` + `dart2wasm_platform.dill`) |
| `FlutterDart2JS` SDK + web inputs | 2,645 files (`tool_files` + `web_sdk`) | **520 files** (8 `dart2js_files` + `dart2js_platform.dill` + 511 `web-sdk/lib/**`) |
| `@flutter_web_sdk//:web_sdk` filegroup | 1,595 files (754.4 MiB) | **542 files (44.0 MiB)** |
| `@rules_flutter//flutter:pub` SDK runfiles | 1,050 files (`tool_files`) | **4 files** (`dart_pub_files`) |

## Single Dart SDK extraction and lazy artifact repositories (plans D1 & D2, `ea4da34`, `6e742d6`)

- **D1 (`ea4da34`):** `@flutter_web_sdk` no longer downloads or extracts a
  second copy of the host Dart SDK (`dart-sdk/`). Instead, it rewrites the
  relative `"../dart-sdk/` include in `web-sdk/libraries.json` to reference the
  sibling host engine repository's `dart-sdk/` directory under `external/`, and
  aliases the DDC runtime helpers and `dart-sdk/lib/libraries.json` from the
  host repository. Every workspace now extracts `dart-sdk/bin/dart` at most
  **once** (`find <output_base>/external -path '*dart-sdk/bin/*' -name dart` = 1).
- **D2 (`6e742d6`):** Mode-specific and feature-specific Flutter archives
  (`flutter_patched_sdk_product.zip`, `material_fonts.zip`, `font-subset.zip`,
  darwin release `artifacts.zip`, and desktop engines/sysroots) now live in
  dedicated lazy repositories backed by optional sub-toolchains
  (`product_tools_toolchain_type`, `aot_toolchain_type`,
  `desktop_engine_toolchain_type`, `material_icons_toolchain_type`) gated by
  compilation mode and merged via `resolve_flutter_sdk_info(ctx)`.

Measured on a fresh `--output_base` and fresh `--repository_cache` on `linux-x64`:

| Build scenario | Network download (before -> after) | Extracted `external/` (before -> after) |
| --- | --- | --- |
| Single `flutter_test` (`//:hello_test`) | 584.9 MB -> **529.1 MB** (-55.8 MB) | 1,115.2 MB -> **841.9 MB** (-273.3 MB, -27.8%) |
| Web bundle (`e2e/web_example //:app`) | 615.8 MB -> **566.5 MB** (-49.3 MB) | 1,891.5 MB -> **967.9 MB** (-923.7 MB, -50.1%) |
| Linux debug bundle (`//:hello_world_linux`) | 584.4 MB -> **567.0 MB** (-17.4 MB) | 1,104.0 MB -> **1,057.1 MB** (-47.0 MB) |

## Consolidated Wave 3: modular `flutter_test`, stable URIs, trimmed `dart_toolchain`, and analyzer summaries (plans T2, T1b, 2.1, 2.2, 2.3, 2.4; `31b867a` + `rules_dart` `1756ca5`)

- **T2 (`48d3542`):** `resolve_exec_dart(ctx, flutter_sdk_info)` resolves the
  host `dart` executable from `@rules_dart//dart:exec_tools_toolchain_type` for
  `flutter_build_assets`, `flutter_web_bundle`, `flutter_pub`, and
  `flutter_sdk_binary`, deprecating `FlutterSdkInfo.dart`.
- **T1b (`31b867a`):** `flutter_engine_artifacts` calls
  `declare_dart_sdk_toolchains(prefix = "dart-sdk/")` from
  `@rules_dart//dart:repositories.bzl` (`0f1999b`) so `DartKernel`, `DartCompile`,
  `DartFormat`, `DartAnalyze`, and `DartAnalyzerSummary` stage only the narrow
  `compile_files`, `runtime_files`, and `analyze_files` SDK subsets.
- **2.4 (`4d86a32`):** Dropped `bazel_dep(name = "bazel_lib")` from `MODULE.bazel`.
- **2.2 (`ca41c64`):** `FlutterKernelCompile` emits multi-root
  `org-dartlang-app:///` `rootUri`s via `generate_stable_package_config(...,
  scheme = APP_SCHEME)` and always mounts `[ctx.bin_dir.path, "."]` under
  `--filesystem-scheme org-dartlang-app`, eliminating `DartCopyTree` package
  colocation and sandbox `file://` URIs in compiled `.dill` outputs.
- **2.1 (`35f7c5d`):** `flutter_kernel_module_aspect` (`flutter_kernel_module.bzl`)
  compiles each `DartInfo` dependency in a `flutter_test` closure once into a
  `<name>.flutter.kmod` directory via `kernel_module_action` (`--target flutter`,
  `platform_dill = flutter_sdk_info.platform_kernel_dill`,
  `extra_libraries = ["ui", "nativewrappers"]`, `scheme = APP_SCHEME`) using
  Bazel persistent `kernel_worker` instances. Each `flutter_test` compiles only
  its entry module (`<name>.flutter_entry.kmod`) and links reachable `.dill`
  components with `DartKernelLink`.
- **2.3 (`rules_dart` `aa0dc5b`):** `//dart:analyzer_summaries` embeds Flutter's
  `sky_engine` `lib/_embedder.yaml` (`dart:ui` et al.) into
  `<name>.embedder_sdk.sum` and analyzes Flutter libraries and tests against
  per-library `.sum` summaries in persistent `analyzer_summary` workers.

Raw data: `results/final_wave3.json` (`RULES_FLUTTER_BENCH_JOBS=4`, full 30x20 /
80x30 benchmark).

| Metric | `baseline_main` (`f60a24b`) | `t1_one_dart` (`7ba01b7`) | `p12_compiled_tools` (`280bfb9`) | `p13_shaders_once` (`14e5844`) | `main_dart_4005f33` (`2f2a861`) | `final_wave3` (`31b867a`) |
| --- | --- | --- | --- | --- | --- | --- |
| Re-analysis, 80-pkg variant (s) | 9.66 | 7.41 | 10.72 | 7.46 | 1.60 | **1.23** |
| Clean build wall (s) | 196.33 | 210.73 | 193.76 | 171.76 | 161.57 | **80.77** |
|   compile CPU (s) | 8.46 | 2.79 | 39.36 | 17.53 | 8.79 | 37.48 |
|   kernel compile CPU (`FlutterKernelCompile`, s) | 426.34 | 417.85 | 405.04 | 385.08 | 387.61 | **27.79** (3 app targets) |
|   modular kernel CPU (`DartKernel`, s) | – | – | – | – | 5.63 | **68.02** (90 modules, in workers) |
|   modular link actions (`DartKernelLink`) | – | – | – | – | – | **30** (4.99 s CPU) |
|   asset bundle CPU (s) | 73.89 | 62.25 | 58.18 | 70.52 | 102.22 | **3.61** |
|   sandboxed actions | 139 | 139 | 144 | 86 | 92 | **96** |
| Body edit rebuild wall (s) | 158.60 | 196.97 | 155.58 | 153.08 | 141.94 | **54.18** |
|   `FlutterKernelCompile` re-run | 33 | 33 | 33 | 33 | 33 | **3** (apps only) |
|   `DartKernel` modules re-run | – | – | – | – | – | **59** (67.37 s CPU, in workers) |
|   `DartKernelLink` re-run | – | – | – | – | – | **30** |
| API edit rebuild wall (s) | 157.47 | 179.08 | 163.63 | 149.93 | 142.20 | **54.39** |
| Null build (s) | 0.29 | 0.21 | 0.31 | 0.27 | 0.19 | **0.18** |
| Test run wall (s) | 11.77 | 14.52 | 12.40 | 12.54 | 9.97 | **9.17** |
|   per test (s) | 1.418 | 1.754 | 1.495 | 1.534 | 1.225 | **1.121** |
| Test runfiles (files / MB) | 1,062 / 752 | 1,062 / 752 | 1,062 / 752 | 1,062 / 752 | 1,062 / 752 | **13 / 88** |
| Extracted external SDK dirs (MB) | 2,450 | 1,808 | 1,808 | 1,808 | 1,808 | **1,116** |
|   `rules_dart` Dart SDK fetched | True | False | False | False | False | **False** |
| Lint clean wall (s) | 528.31 | 648.43 | 565.13 | 516.65 | 453.93 | **106.55** |
|   `DartAnalyze` CPU across 61 targets (s) | 732.0 | 954.0 | 840.0 | 817.0 | 716.0 | **9.61** (in summary workers) |
|   sandboxed actions | 1,261 | 1,261 | 1,266 | 1,208 | 342 | **401** |
| Lint body edit wall (s) | 463.12 | 535.36 | 512.14 | 479.67 | 430.74 | **55.75** |
|   `DartAnalyze` re-run | 61 | 61 | 61 | 61 | 61 | **2** (8.70 s CPU) |
|   `DartAnalyzerSummary` re-run | – | – | – | – | – | **1** (0.74 s CPU; early cutoff) |
|   `DartFormat` re-run | 61 | 61 | 61 | 61 | 2 | **2** |
|   staging copies re-run | 61 | 61 | 61 | 61 | 63 | **4** (`DartCopyTree`) |
