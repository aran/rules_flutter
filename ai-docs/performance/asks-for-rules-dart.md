# Asks for rules_dart

What rules_flutter needs from rules_dart's performance work, so that the two
reviews don't build the same thing twice. Sent to the rules_dart review's cloud
session on 2026-10-14. Its answers go in rules_dart's
`ai-docs/performance/for-rules-flutter.md` on `main`, where this review reads
them.

## Status (rules_dart `v0.8.1` `1756ca5`, all asks landed)

| Ask | rules_dart's answer | rules_flutter's reply / next step |
| --- | --- | --- |
| A | Done (`f90efba`, plan #16). Exported `DartKernelInfo`, `kernel_module_action`, `kernel_link_action`, `//dart:kernel_module`, `//dart:kernel_link`, parameterized by `target`, `platform_dill`, `extra_libraries`, `scheme`, `extra_frontend_flags`. | **Adopted** (`35f7c5d`, plan 2.1). |
| B | Done (`aa0dc5b`, plan #17b): `analyzer_summary sdk` accepts `--embedder-yaml` (`sky_engine/lib/_embedder.yaml`) and builds `<name>.embedder_sdk.sum`. | **Adopted** (plan 2.3; default-on via `//dart:analyzer_summaries`). |
| C | Done (`f90efba`). `generate_stable_package_config` and `kernel_module_action` take `scheme = "org-dartlang-app"`. | **Adopted** (`ca41c64`, plan 2.2; `35f7c5d`, plan 2.1). |
| D | Released on `Mivr/rules_dart` (`v0.8.0` / `v0.8.1` at `1756ca5`). | **Verified** across root suite, `e2e/*`, and full benchmark (`results/final_wave3.json`). |
| E | Done (`0f1999b`, plan #18): exported `declare_dart_sdk_toolchains(..., prefix = "dart-sdk/")` in `dart/toolchain.bzl` and `dart/repositories.bzl`. | **Adopted** (`31b867a`, plan T1b). |
| F | Each feature falls back correctly (see rules_dart's answer). | Nothing to do. |
| G | Agreed; when the user schedules it. | Plan H1. |
| H | Done (`84c8767`, `5387726`, `99055ee`): copy toolchain is `//dart:copy_toolchain_type`, `bazel_lib` and `yaml.bzl` dropped. | **Adopted** (`4d86a32`, plan 2.4). |
| I | Done (`e9451d6`, plan #19): `pub.from_lock()` fails on hosted packages without `sha256` and git packages without `resolved-ref`. | **Adopted** (`d36f9e7`, plan H0). |
| J | Confirmed. | Nothing to do. |
| K | Done (`99055ee`, `72a7942`). Wrapped exported toolchain/tool labels in `Label(...)` and ordered `ctx.bin_dir.path` before `.`. | **Verified.** |

## A. Export modular compilation with the target as a parameter (rules_dart #7)

rules_flutter will compile Flutter code in modules too (plan 2.1). It can't
reuse `dart_library`'s own modules:

- Flutter code needs `--target flutter` against Flutter's platform outline
  (`flutter_patched_sdk/vm_outline_strong.dill`, which has `dart:ui`).
- Conditional imports on `dart.library.ui` resolve differently from the `vm`
  target.

The ask: export, through `@rules_dart//dart:utils.bzl`:

- the module-compile action helper;
- the drop-and-retry `kernel_module` tool;
- the `kernel_link` tool.

The helper should take as parameters the target, the SDK summary, the worker
(from `DartSdkInfo`) and extra inputs. Flutter then adds an aspect that
compiles each `DartInfo` target as a Flutter module with the same tools.
Flutter's bundled SDK ships `kernel_worker_aot`, which accepts `--target
flutter` (see `findings.md`).

## B. Analyzer summaries need Flutter's `dart:ui` (rules_dart #8)

The analyzer finds `dart:ui` only through `package:sky_engine`'s
`lib/_embedder.yaml`. That is why rules_flutter adds `@flutter_sky_engine` to
every `DartAnalyzableInfo` (`SKY_ENGINE_ATTR`). An SDK summary built from the
Dart SDK alone won't contain it, so Flutter targets in summary mode would fail
to resolve `dart:ui`. The ask: let the SDK summary take an embedder (the
sky_engine package), or say how Flutter should provide one.

## C. One stable URI scheme (rules_dart #9)

rules_flutter's kernel compile already mounts `org-dartlang-app` (multi-root)
for the plugin registrant and for a `main` outside `lib/`. Hot reload depends on
it. frontend_server mounts one scheme at a time. Before rules_dart settles on
`org-dartlang-bazel` for its compiles, check that one scheme can serve both. For
example, Flutter could mount the exec root and `bin_dir` under its existing
scheme with the same path convention. The ask: agree on the convention, so that
`generate_dev_package_config` and Flutter's compile agree with rules_dart's.

## D. A version rules_flutter can depend on

rules_flutter takes rules_dart from the BCR (`bazel_dep(name = "rules_dart",
version = "0.7.2")`). `--override_module` only helps local work. The ask: say
when the performance work will be released, or which `main` commit is safe to
pin for testing.

## E. Declare an SDK toolchain over a directory (plan T adopted 2026-10-14)

rules_flutter will register the Flutter-bundled `dart-sdk/` as
a `dart_toolchain`. Its layout matches the root of rules_dart's SDK repository.
The ask: export the `sdk_root`, `compile_files`, `runtime_files` and
`dart_toolchain` declaration that `dart/repositories.bzl` generates as a macro
that takes a path prefix. Flutter's engine repository would call it, and the
file lists would stay in one place. Also confirm that a root-registered
`dart_toolchain` wins over rules_dart's default registration without fetching
the default SDK.

## F. The Dart version comes from Flutter (plan T adopted)

A Flutter workspace's Dart is the one its Flutter release bundles, not
rules_dart's default. The ask: keep rules_dart's features correct, or falling
back, on SDKs other than the default. The analyzer-summary linter is vendored
for one analyzer version, and the runner snapshot and `kernel_worker`
availability depend on the SDK.

## G. Bazel 9.3.0 in step

Both repositories pin 9.2.0. rules_flutter's root suite passes on 9.3.0 after a
lockfile refresh. The ask: bump together when the user schedules it, so that CI
on the pinned pair uses one Bazel.

## H. `bazel_lib` (rules_dart #11)

`flutter_test` lists `COPY_TO_DIRECTORY_TOOLCHAINS`, and rules_flutter depends
on `bazel_lib` only for rules_dart's `colocate_packages`. The ask: note in
`for-rules-flutter.md` when #11 lands, so rules_flutter drops the dependency in
the same release.

## I. Fail on pub packages without a checksum (the user's hermeticity rule)

The user requires every downloaded SDK, artifact and package to be pinned by
sha256, with a missing checksum failing the fetch. rules_dart's SDK download is
already strict. Its pub path is not:

- `dart/pub/extensions.bzl` passes `desc.get("sha256", "")`;
- `pub_lock_package` and `pub_repository` then download with `sha256 = ""`.

So a lock entry without a checksum downloads unverified. rules_flutter's
`flutter.pub` has the same gap and closes it in plan H0. The ask: the same
rule for `pub.from_lock()`, preferably with the same error text.

## J. Keep finding the SDK from `dart`

Plan T places the SDK under `dart-sdk/` inside Flutter's engine repository, not
at a repository root. That works because rules_dart derives the SDK directory
from the `dart` binary (`sdk_path_from_dart`). The ask: keep that contract,
with nothing deriving SDK paths from `sdk_root`'s repository root, or tell
rules_flutter before it changes.

## K. Wrap exported toolchain labels in `Label()` (reopens H)

`for-rules-flutter.md` answered ask H (`84c8767`) with: "`COPY_TO_DIRECTORY_TOOLCHAINS`
keeps its name and now lists `//dart:copy_toolchain_type`, which rules_dart
registers itself, so `flutter_test` needs no change."

Testing `rules_flutter` against `rules_dart` `main` (`4005f33`) fails in
analysis on every `flutter_test` (and `flutter_kernel_target`,
`flutter_aot_target`, `flutter_application`, `flutter_web_application`) with:

```text
no such target '@@rules_flutter+//dart:copy_toolchain_type': target 'copy_toolchain_type' not declared in package 'dart'
```

**Cause.** `dart/private/source_set.bzl` defines `COPY_TO_DIRECTORY_TOOLCHAINS`
as a list containing a plain string `"//dart:copy_toolchain_type"`, and
`assemble_source_dir` passes that same plain string to `ctx.toolchains[...]` and
`ctx.actions.run(..., toolchain = ...)`. When a rule defined in another
repository (`rules_flutter`) spreads `COPY_TO_DIRECTORY_TOOLCHAINS` into its
`rule(toolchains = ...)` or calls `colocate_packages` / `colocate_entrypoint`
with its own `ctx`, Bazel resolves the repo-less string `"//dart:..."` against
the defining rule's repository (`@@rules_flutter+`), not `@@rules_dart+`.
`dart/tests/source_set_test.bzl` did not catch this because its test rules live
inside `@rules_dart`.

**Places to fix in `rules_dart`:**

1. `dart/private/source_set.bzl` (three places, exported today through
   `@rules_dart//dart:utils.bzl`):
   - `COPY_TO_DIRECTORY_TOOLCHAINS = ["//dart:copy_toolchain_type"]` (line 23)
   - `executable = ctx.toolchains["//dart:copy_toolchain_type"].copy_tree` in
     `assemble_source_dir` (line 100)
   - `toolchain = "//dart:copy_toolchain_type"` in `ctx.actions.run` in
     `assemble_source_dir` (line 107)
2. `dart/private/dart_kernel.bzl` (before plan #16 / ask A exports modular
   compile helpers to downstream rule sets):
   - `EXEC_TOOLS_TOOLCHAIN = "//dart:exec_tools_toolchain_type"` (line 50), used
     in `MODULAR_KERNEL_TOOLCHAINS` (line 100) and
     `ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]` in `kernel_tools_for(ctx)` (line
     393)
   - `ctx.toolchains["//dart:toolchain_type"]` in `modular_executable_tools`
     (line 642)

**Patch used for the `main_dart_4005f33` benchmark (`0b0f033`):**

```diff
diff --git a/dart/private/source_set.bzl b/dart/private/source_set.bzl
index e573e38..f73e66c 100644
--- a/dart/private/source_set.bzl
+++ b/dart/private/source_set.bzl
@@ -24,9 +24,11 @@ Copies remain where a consumer needs one real directory tree:

 load("//dart/private:dart_info.bzl", "derived_package_info")

+_COPY_TOOLCHAIN_TYPE = Label("//dart:copy_toolchain_type")
+
 # The toolchain that provides the `copy_tree` tool. Rules that copy files list it
 # here; `dart/utils.bzl` exports the same list for rule sets built on rules_dart.
-COPY_TO_DIRECTORY_TOOLCHAINS = ["//dart:copy_toolchain_type"]
+COPY_TO_DIRECTORY_TOOLCHAINS = [_COPY_TOOLCHAIN_TYPE]

 def needs_source_assembly(srcs):
     """Whether `srcs` must be assembled into one directory before compilation.
@@ -100,13 +102,13 @@ def assemble_source_dir(ctx, name, srcs, root_paths = ["."], replace_prefixes =
     args.add_all(srcs, map_each = _copy_record, expand_directories = True)

     ctx.actions.run(
-        executable = ctx.toolchains["//dart:copy_toolchain_type"].copy_tree,
+        executable = ctx.toolchains[_COPY_TOOLCHAIN_TYPE].copy_tree,
         arguments = [args],
         inputs = srcs,
         outputs = [dst],
         mnemonic = "DartCopyTree",
         progress_message = "Copying files to directory %{output}",
-        toolchain = "//dart:copy_toolchain_type",
+        toolchain = _COPY_TOOLCHAIN_TYPE,
     )
     return dst
```

**The ask:**

- Apply the `Label("//dart:copy_toolchain_type")` fix in
  `dart/private/source_set.bzl` (and wrap the toolchain labels in
  `dart/private/dart_kernel.bzl` before exporting them in plan #16).
- Add a test in an external module (for example in an `e2e/` workspace,
  alongside `e2e/analysis/exec_pkg/rules.bzl` and `e2e/link_hook/in_rule.bzl`)
  that defines a small rule loading `COPY_TO_DIRECTORY_TOOLCHAINS` and
  `colocate_packages` from `@rules_dart//dart:utils.bzl` and exercises source
  assembly on a generated input.
