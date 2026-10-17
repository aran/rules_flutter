# rules_flutter benchmark harness

Reference scripts that generate a synthetic Flutter workspace and measure build,
test, lint and analysis performance of `rules_flutter`. They are modelled on
`rules_dart`'s harness (`ai-docs/performance/harness/` in that repo) so the two
reviews' numbers can be read side by side. Same scenarios and the same JSON
shape where they apply; the Flutter-specific scenarios are added.

These are not repository tooling. `AGENTS.md` asks for repo tooling to be Dart
`dart_binary`s run with `bazel run`. Porting them would be the step to take if
they should become part of the repository.

## Files

| File | What it does |
| --- | --- |
| `gen_bench.py` | `gen_bench.py <out> <packages> <files_per_package> <rules_flutter checkout> [--rules-dart <checkout>] [--no-format]`. Writes the workspace, fetches it, and runs the Flutter SDK's `dart format` over it. |
| `suite.py` | `suite.py <rules_flutter checkout> <label> [analysis] [build] [test] [lint] [--size small\|full] [--rules-dart <checkout>] [--publish]`. Generates fresh workspaces under the bench root, runs the scenarios, writes `results/<label>.json`. |
| `bump.py` | The body-only edit `suite.py` applies to `packages/pkg0/lib/src/f0.dart`: `var total = N;` becomes `N+1`. |
| `prof.py` | Per-mnemonic action count and CPU seconds from a `--profile` trace. Also importable: `summarize()`. |
| `table.py` | `table.py <label> [<label> ...]` prints result files side by side as a Markdown table. |

Adapted from rules_dart's harness: `prof.py` and `table.py` keep its behaviour
and add the Flutter rows. `suite.py` and `gen_bench.py` keep its scenario set,
then add `kernel_inputs`, `fetch_footprint` and the Flutter app targets.

## Running

Set the scratch root. Default is `~/rules_flutter_bench`:

```
export RULES_FLUTTER_BENCH_DIR=/path/to/bench
```

Nothing generated goes in the checkout, except the result JSON that
`--publish` writes to `<checkout>/ai-docs/performance/results/`.

Small validation run (4 packages x 3 files; analysis variant 10 packages):

```
python3 ai-docs/performance/harness/suite.py <rules_flutter checkout> smoke_small --size small
```

Full baseline (30 packages x 20 files; analysis variant 80 packages x 30 files):

```
python3 ai-docs/performance/harness/suite.py <rules_flutter checkout> <label> --size full --publish
```

Against a local rules_dart, add `--rules-dart <rules_dart checkout>`. The
generated `.bazelrc` then gets `common --override_module=rules_dart=<path>`.

Every generated workspace's `.bazelrc` sets `startup --host_jvm_args=-Xmx4g`
and `common --jobs=8`, and `--lockfile_mode=off`. On a memory-capped host, set
`RULES_FLUTTER_BENCH_JOBS` to lower the job count. The result JSON records it as
`jobs`; compare only results with the same value.

**Output bases.** Each workspace gets its own Bazel output base, under
`<bench root>/ob/<label>/<workspace>/` (`ob/<label>/bench/`, `ob/<label>/bench_analysis/`).
`gen_bench.py` writes the path to the workspace's `.bazelrc.user`, so every bazel
call there uses it, including the fetch. A label always starts from an empty output
base: the suite deletes an earlier one with the same label first. This is what makes
`fetch_footprint` report only what this run fetched. The shared repository cache
keeps the re-fetch cheap. The suite runs `bazel shutdown` in every workspace it
used, in a `finally`, so no server outlives the run. The output base path of each
workspace is in the result JSON's `output_base` field.

Each output base is about 3-4 GB (the Flutter and Dart SDKs and the build outputs).
Delete `ob/<label>/` when that label is no longer needed. Shut down its server first,
with `bazel shutdown` in the workspace.

## Generated workspace

`gen_bench.py` writes:

- `MODULE.bazel`: `rules_flutter` as a `local_path_override` of the checkout.
  `rules_dart` 0.7.2 from the registry. `flutter.toolchain(flutter_version = "3.47.6")`
  and `flutter.pub(name = "deps")` with the root `pubspec.lock`.
- `.bazelrc`, `.bazelversion` (copied from the checkout), `analysis_options.yaml`.
  `build:lint` carries the dart analyze and format aspects, as rules_dart's does.
  Root `BUILD.bazel` holds `dart_analysis_options` and `dart_analysis_config`.
- `packages/pkgI/`: `lib/src/fF.dart` (F files), `lib/pkgI.dart` (exports them),
  `test/pkgI_test.dart`, and `BUILD.bazel`. Package I depends on pkg(I-1) and
  pkg(I-2).
- `app/`: `lib/main.dart` and `BUILD.bazel`, for the last package.

One package's `BUILD.bazel`, as generated for `pkg1` (dependency on `pkg0`):

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_library", "flutter_test")

flutter_library(
    name = "pkg1",
    package_name = "pkg1",
    srcs = glob(["lib/**/*.dart"]),
    visibility = ["//visibility:public"],
    deps = [
        "//packages/pkg0",
        "@deps//:flutter",
    ],
)

flutter_test(
    name = "pkg1_test",
    package_name = "pkg1",
    main = "test/pkg1_test.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = [
        "//packages/pkg0",
        "@deps//:flutter",
        "@deps//:flutter_test",
    ],
)
```

The `app/` targets are `flutter_kernel_target` (`app_kernel`, debug kernel),
`flutter_web_app` (`app_web`), `flutter_application` (`app`) and `flutter_linux_app`
(`app_linux`). The `flutter_application` and `flutter_linux_app` pair is included
because it built on the reference host; see the report for the outcome.

Each widget test pumps a `MaterialApp` around `WPxF(value: 1)` and checks
`find.byType`. Every package's `pkgI.dart` exports its files, so the test
imports the package through `srcs`, as `hello_world` does.

## Scenarios

Each build-type scenario writes `results/<label>.<name>.json.gz`, a
`--noslim_profile --profile` trace, and reads it with `prof.py`.

| Result key | Group | Measures |
| --- | --- | --- |
| `reanalysis_<N>pkg_s`, `..._runs_s` | analysis | Median of three `build //... --nobuild` runs, each with a fresh `--define`, so each run re-analyses every target. `N` is 10 (small) or 80 (full). |
| `clean_build` | build | `bazel clean`, then `build //...`. Wall time, sandboxed actions, per-mnemonic actions and CPU. |
| `fetch_footprint` | build | After the clean build: the `dart` and `flutter` directories in the output base's `external/`, each with `du -sm`, plus whether `rules_dart++dart+dart_linux-x64` was fetched. Pub spokes (`__`, `+deps`, `ext_pub`) are excluded. |
| `body_edit_build` | build | `bump.py` on `pkg0/lib/src/f0.dart`, then `build //...`. |
| `api_edit_build` | build | Adds a public function to the same file, then `build //...`. The file is then restored and rebuilt, untimed. |
| `null_build` (and `null_build_s`) | build | `build //...` with nothing changed. |
| `test_run` | test | `test //... --nocache_test_results`. Per-test seconds are the `TestRunner` CPU divided by the count. |
| `test_runfiles` | test | Files and MB under one `flutter_test`'s runfiles tree, following symlinks. `pkg5` for full, `pkg1` for small. |
| `kernel_inputs` | test | For that test's `FlutterKernelCompile`, from `bazel aquery --output=jsonproto`: the input artifacts, expanded through their depsets, counted and sized on disk. Includes SDK tool inputs; `external_mb` is the part under `external/`. |
| `lint_clean` | lint | `bazel clean`, then `build --config=lint //...`. |
| `lint_body_edit` | lint | Another `bump.py` edit, then `build --config=lint //...`. |

The sandbox count is every action whose sandbox label ends in `-sandbox`. On
the reference host Bazel used `processwrapper-sandbox`, not `linux-sandbox`.

Mnemonics kept: `FlutterKernelCompile`, `FlutterShaderCompile`,
`FlutterAssetBundle`, `TestRunner`, `DartAnalyze`, `DartFormat`, `DartCompile`,
`CopyToDirectory`, `SymlinkTree`, and any mnemonic starting with `Flutter` or `Dart`.

## Reading the numbers

**Steady** (repeat closely between runs on the same host):

- Action counts for each mnemonic in each build scenario.
- CPU seconds per mnemonic, summed over actions. These vary a little, but
  far less than wall time.
- `sandboxed`, the count of sandboxed actions.
- `kernel_inputs` and `test_runfiles`: file counts and sizes.
- `fetch_footprint`, once the repos are fetched.

**Noisy** (wall time):

- Every `wall_s`, `reanalysis_*`, `null_build_s`, and `per_test_s`. Wall time
  includes Bazel startup and whatever else the machine is doing. Run on a quiet
  machine, and read the median, not one run.
- Anything that depends on a cache warm-up. The `clean_build` and `lint_clean`
  numbers assume a cleared action cache for this workspace only.

The machine is shared when you run this. Check the load before a baseline,
and say in the report what else was running.

## Notes

- `gen_bench.py` fetches the workspace with `bazel build //... --nobuild`
  before formatting, because the SDK's `dart` only exists once the Flutter repos
  are fetched. It finds it at `external/*flutter*/dart-sdk/bin/dart` in the output
  base. Under Bazel 9 the repo is `rules_flutter++flutter+flutter_linux-x64`.
- The formatting run uses a throwaway `HOME` next to the workspace, so the SDK
  does not write into the real home directory.
- The generated `pubspec.lock` and `pubspec.yaml` come from
  `e2e/hello_world`, not `e2e/web_example`. The web example's lock has no
  `flutter_test` entry, and the tests need `@deps//:flutter_test`.
- `bazel clean` runs only in generated workspaces under the bench root. Never
  `--expunge`.
