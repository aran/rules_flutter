"""Flutter test runner rule.

Compiles a Flutter test entry point to a kernel `.dill` and runs it under
`flutter_tester`, the headless Flutter engine. Tests interact with the test
runner via the same `package:test_api/backend.dart` `RemoteListener`
protocol that `flutter test` uses, so widget tests that initialize
`TestWidgetsFlutterBinding` (every `testWidgets`, every golden, the live
binding) work.

Wire-up:
  1. Bazel writes a per-target bootstrap `<name>_bootstrap.dart` that imports
     the user's test as `test`, then calls `RemoteListener.start(() => test.main)`
     and pipes the resulting StreamChannel over a WebSocket to the runner. When
     the suite carries `package:flutter_test`, the same callback installs the
     golden-file comparator, exactly where `flutter test` installs its own —
     see `flutter/private/goldens/comparator.dart`.
  2. Each library in `deps` is compiled once per configuration into a kernel
     module (`flutter_module_aspect`, rules_dart's per-library compile over the
     debug Flutter platform), with the test's `defines`. The test's own files
     are compiled against those modules, the bootstrap compiled as the entry
     point, and all of it linked into the one `.dill` flutter_tester loads.
     A test therefore recompiles only its own files, and a change to a shared
     library recompiles that library's module and those downstream of it once,
     not every test that reaches it. With
     `--@rules_dart//dart:modular_kernel=false` the test instead compiles its
     whole program from source, as `flutter_application` does.
  3. The runner binary spawns `flutter_tester` with the dill, hosts a localhost
     WebSocket harness, drives the `package:test` MultiChannel protocol, and
     reports per-test pass/fail.

Coverage: when `bazel coverage` sets `COVERAGE_OUTPUT_FILE`, the runner
launches `flutter_tester` with the VM service enabled and collects source
reports via JSON-RPC, writing LCOV for the test's own package and sources.

Usage:
    flutter_test(
        name = "widget_test",
        main = "test/widget_test.dart",
        deps = [
            "@deps//:flutter",
            "@deps//:flutter_test",
            "//:my_app_lib",
        ],
    )

The user's `deps` must transitively expose `package:flutter_test` (and
therefore `package:test_api`) so the generated bootstrap compiles.

Golden files: `matchesGoldenFile('goldens/x.png')` reads
`<dir of the test's main>/goldens/x.png` out of runfiles, so every golden has
to be a declared input — list them in `data`. Regenerate with
`bazel run //<pkg>:<target> -- --update-goldens`, which writes back to the
source tree; the same flag under `bazel test` is refused, because a test action
cannot write there.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo", "DartKernelSdkInfo")
load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "KERNEL_TOOL_ATTR", "collect_modules", "collect_packages", "collect_transitive_srcs", "dart_analyzable_info_with_package", "dart_entry_kernel_action", "dart_import_check_aspect", "dart_link_kernel_action", "derive_lib_root", "import_check_validation", "module_defines_transition", "runfiles_path")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:app_entrypoint.bzl", "APP_SCHEME", "compile_package_config", "synthesize_app_package")
load(
    "//flutter/private:common.bzl",
    "FLUTTER_APPLICATION_ATTRS",
    "PLATFORM_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "declare_flutter_assets_dir",
    "detect_target_platform",
    "flutter_build_assets",
    "flutter_compile_shaders",
    "host_target_arch",
    "merge_dart_defines",
)
load("//flutter/private:flutter_compile.bzl", "flutter_kernel_compile_action")
load("//flutter/private:flutter_module.bzl", "flutter_module_aspect")
load("//flutter/private:flutter_native_assets.bzl", "bridge_dart_code_assets", "collect_bundled_code_asset_files", "write_native_assets_manifest")

def make_bootstrap_content(test_relative_import, golden_comparator_import = None):
    """Generate the per-test bootstrap Dart source.

    The bootstrap is the kernel entry point flutter_tester loads. It calls
    `RemoteListener.start(() => test.main)` to register the user's tests with
    `package:test_api`, then opens a WebSocket back to the harness on
    `FLUTTER_TEST_HARNESS_PORT` and forwards the resulting channel as
    JSON-encoded `[id, data]` tuples (the `package:stream_channel`
    MultiChannel framing the test harness already speaks).

    The golden block is emitted at the same point `flutter test` emits its own
    — inside the `RemoteListener.start` callback, before the user's `main` is
    returned — and, like upstream's, only when the suite actually depends on
    `package:flutter_test`. Upstream guards it with `if (flutterTestDep)` for
    the same reason this takes an import that may be None: a suite carrying
    only `package:test_api` has no `goldenFileComparator` to assign to, and an
    unconditional import would fail its kernel compile over a feature it
    cannot use.

    Args:
        test_relative_import: Path-style import URI from the bootstrap file
            to the user's test source (e.g. `../../e2e/foo/test/widget_test.dart`).
        golden_comparator_import: Import URI for the staged golden comparator,
            or None to emit no golden block (a `test_api`-only suite).

    Returns:
        Dart source string.
    """
    if golden_comparator_import:
        golden_import = "import '{}' as goldens;\n".format(golden_comparator_import)
        golden_install = "    goldens.installBazelGoldenFileComparator();\n"
    else:
        golden_import = ""
        golden_install = ""

    return """// GENERATED by flutter_test — do not edit.
//
// Bootstraps a Flutter widget test under flutter_tester. Connects back to
// the bazel-side harness over WebSocket and drives the test via
// package:test_api/backend.dart RemoteListener — the same surface
// `flutter test` uses.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test_api/backend.dart';

import '{test_import}' as test;
{golden_import}
void _catchIsolateErrors() {{
  final errorPort = ReceivePort();
  Isolate.current.setErrorsFatal(false);
  Isolate.current.addErrorListener(errorPort.sendPort);
  errorPort.listen((dynamic message) {{
    final list = message as List;
    final error = IsolateSpawnException(list[0] as String);
    final stack = list[1] == null
        ? StackTrace.empty
        : StackTrace.fromString(list[1] as String);
    Zone.current.handleUncaughtError(error, stack);
  }});
}}

Future<void> _runTestMain() async {{
  await Future(test.main);
}}

Future<void> main() async {{
  final portStr = Platform.environment['FLUTTER_TEST_HARNESS_PORT'];
  if (portStr == null || portStr.isEmpty) {{
    stderr.writeln('flutter_test bootstrap: FLUTTER_TEST_HARNESS_PORT not set');
    exit(64);
  }}
  final port = int.parse(portStr);

  final testChannel = RemoteListener.start(() {{
    _catchIsolateErrors();
{golden_install}    return _runTestMain;
  }});

  // 127.0.0.1 and not `localhost`: deliberately the same address family the
  // harness binds. Read the record on `_Harness.bind` in
  // flutter/private/tools/flutter_test_runner.dart before changing either —
  // the two only make sense together, and changing this one alone is how a
  // dial reaches something other than the harness.
  final ws = await WebSocket.connect('ws://127.0.0.1:$port');
  // Forward harness → testChannel. `pipe` completes when the WebSocket
  // closes; we don't need to await it because the harness side closes the
  // socket once the suite is done.
  unawaited(ws.map<dynamic>((dynamic m) => json.decode(m as String))
      .pipe(testChannel.sink));
  // Forward testChannel events → harness. `addStream` completes when the
  // testChannel's stream is done — that happens after the harness sends
  // a close message and RemoteListener closes the inner controller. At
  // that point we exit the isolate explicitly so flutter_tester shuts
  // down without waiting for the engine to drain its event loop.
  await ws.addStream(testChannel.stream.map<String>((dynamic m) => json.encode(m)));
  exit(0);
}}
""".format(
        test_import = test_relative_import,
        golden_import = golden_import,
        golden_install = golden_install,
    )

def _kernel_root_path(short_path):
    # Where a file sits under the kernel filesystem roots: another
    # repository's `../<repo>/…` is `external/<repo>/…` there.
    return "external/" + short_path[3:] if short_path.startswith("../") else short_path

# The schemes each compile mode names a test's own non-`package:` sources by:
# the per-library link reads them through rules_dart's kernel roots, and the
# whole-program compile mounts the exec root under the app scheme. Both are the
# same wherever the kernel is built.
_MODULAR_SCHEME = "org-dartlang-root"

def _own_source_uri(file, modular):
    if modular:
        return "%s:///%s" % (_MODULAR_SCHEME, _kernel_root_path(file.short_path))
    return "%s:///%s" % (APP_SCHEME, file.path)

def _exposes_package(deps, names):
    """True if any dep transitively exposes one of `names`."""
    for dep in deps:
        if DartInfo not in dep:
            continue
        for pkg in dep[DartInfo].transitive_packages.to_list():
            if pkg.package_name in names:
                return True
    return False

# Two predicates, deliberately not one.
#
# `_can_bootstrap` is what the rule requires at all: the bootstrap imports
# `package:test_api/backend.dart` for `RemoteListener`, and `package:flutter_test`
# re-exports it, so either package satisfies the compile.
#
# `_has_flutter_test` is narrower and gates only the golden block, which needs
# `goldenFileComparator` and `autoUpdateGoldenFiles` — both `flutter_test`'s.
# Collapsing the two would make a `test_api`-only target (a documented,
# supported configuration) fail its kernel compile on an import it never asked
# for. Upstream draws the same line with its `if (flutterTestDep)` guard.
def _can_bootstrap(deps):
    return _exposes_package(deps, ["flutter_test", "test_api"])

def _has_flutter_test(deps):
    return _exposes_package(deps, ["flutter_test"])

def _flutter_test_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    if not flutter_sdk_info.flutter_tester:
        fail(
            "flutter_test requires the active Flutter toolchain to provide a " +
            "flutter_tester binary; the resolved toolchain has none. This is " +
            "typically the case for cross-compile-only configurations — " +
            "build the test target with the host platform.",
        )

    if not _can_bootstrap(ctx.attr.deps):
        fail((
            "flutter_test target {name} must depend on package:flutter_test " +
            "(or at minimum package:test_api). Add `@<hub>//:flutter_test` " +
            "to deps so the generated bootstrap can import RemoteListener."
        ).format(name = ctx.label.name))

    # Same contract as `flutter_application`: a pub package that builds its
    # native code with a hook Bazel cannot run contributes no library, and the
    # manifest below would be quietly one entry short. A test is where that
    # matters most — it is where an unresolved `@Native` symbol gets debugged.
    hook_err = check_unreplaced_hooks(ctx.label, ctx.attr.deps)
    if hook_err != None:
        fail(hook_err)

    # Tests always run on the host, but the platform still has to be resolved
    # before the kernel compile: the frontend_server reads the native-assets
    # manifest at compile time, and the manifest is keyed by `<os>_<arch>`.
    is_macos = ctx.target_platform_has_constraint(
        ctx.attr._macos_constraint[platform_common.ConstraintValueInfo],
    )
    is_ios = ctx.target_platform_has_constraint(
        ctx.attr._ios_constraint[platform_common.ConstraintValueInfo],
    )
    is_linux = ctx.target_platform_has_constraint(
        ctx.attr._linux_constraint[platform_common.ConstraintValueInfo],
    )
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    is_android = ctx.target_platform_has_constraint(
        ctx.attr._android_constraint[platform_common.ConstraintValueInfo],
    )
    target_platform = detect_target_platform(is_ios, is_macos, is_linux, is_windows, is_android)

    # Native Assets reach a test the same two ways they reach an application:
    # declared with `flutter_native_asset` and propagated on `FlutterInfo`, or
    # owned by a pub package and lifted off the Dart package graph. Deliberate
    # declarations win on a shared id, as in `flutter_application`.
    native_assets_list = depset(transitive = [
        dep[FlutterInfo].native_assets
        for dep in ctx.attr.deps
        if FlutterInfo in dep
    ]).to_list()
    declared_ids = {asset.asset_id: True for asset in native_assets_list}
    native_assets_list = native_assets_list + [
        asset
        for asset in bridge_dart_code_assets(ctx, ctx.attr.deps)
        if asset.asset_id not in declared_ids
    ]

    native_assets_manifest = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    write_native_assets_manifest(
        ctx = ctx,
        output_file = native_assets_manifest,
        native_assets = native_assets_list,
        target_os = target_platform,
        target_arch = host_target_arch(ctx, flutter_sdk_info),
        # No bundle to resolve against — the libraries ship in runfiles.
        layout = "runfiles",
    )
    bundled_code_assets = collect_bundled_code_asset_files(native_assets_list)

    # The golden comparator, staged next to the generated bootstrap so the
    # bootstrap can import it by basename — the same arrangement
    # `flutter_application` uses for `agent_extensions/agent.dart`. A symlink
    # rather than a copy: the file is a plain source, and staging it into this
    # rule's own output namespace is what makes the import a sibling lookup
    # instead of arithmetic over the exec root.
    #
    # Only for suites that actually carry `package:flutter_test`; see the two
    # predicates above. Both the staged file and the bootstrap's import of it
    # are behind that gate, so a `test_api`-only target compiles exactly the
    # bootstrap it compiled before.
    staged_comparator = None
    if _has_flutter_test(ctx.attr.deps):
        staged_comparator = ctx.actions.declare_file(
            ctx.label.name + ".golden_comparator.dart",
        )
        ctx.actions.symlink(
            output = staged_comparator,
            target_file = ctx.file._golden_comparator_src,
        )

    # `--@rules_dart//dart:modular_kernel=false` turns per-library compilation
    # off build-wide; the aspect then compiles nothing, and the test compiles
    # its whole program from source.
    modular = ctx.attr._modular_kernel[BuildSettingInfo].value

    # Per-target bootstrap. Imports the user's test by a path relative to the
    # bootstrap: under the kernel filesystem roots when modular, through the
    # exec root otherwise.
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")
    if modular:
        test_import = "../" * _kernel_root_path(bootstrap.short_path).count("/") + _kernel_root_path(ctx.file.main.short_path)
    else:
        test_import = "../" * len(bootstrap.dirname.split("/")) + ctx.file.main.path
    ctx.actions.write(bootstrap, make_bootstrap_content(
        test_import,
        golden_comparator_import = staged_comparator.basename if staged_comparator else None,
    ))

    # Register the test's own package so `package:<self>/foo` imports inside
    # test sources resolve.
    packages = synthesize_app_package(
        ctx.label,
        collect_packages(ctx.attr.deps),
        ctx.attr.package_name,
        derive_lib_root(ctx.label.workspace_root, ctx.label.package),
        ctx.attr.language_version,
    )

    own_srcs = list(ctx.files.srcs) + [ctx.file.main]
    if staged_comparator:
        own_srcs.append(staged_comparator)
    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    if modular:
        _link_modules(ctx, bootstrap, own_srcs, packages, native_assets_manifest, kernel_dill)
    else:
        _compile_whole_program(ctx, flutter_sdk_info, bootstrap, own_srcs, packages, native_assets_manifest, kernel_dill)

    # Build a `flutter_assets/` tree for the test. Material widgets pull
    # `shaders/ink_sparkle.frag` at first paint, and pub-package fonts/assets
    # (e.g. MaterialIcons) need to land in the bundle for tests that resolve
    # them via `rootBundle`. Tests run on the host, so shaders compile against
    # the host platform resolved above.
    # The test runs on flutter_tester, not the host's embedder: its shaders
    # are compiled for it, as `flutter test` compiles them (SkSL for Skia,
    # Vulkan for Impeller).
    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, "tester")
    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_build_assets(
        ctx,
        flutter_sdk_info,
        flutter_assets,
        compiled_shaders,
        kernel_dill = kernel_dill,
        is_debug = True,
    )

    # Symlink the prebuilt runner as the test executable.
    tool = ctx.attr._tool
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    ext = ".exe" if is_windows else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    # Runfiles-relative paths the runner reads from env at start-up.
    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_TEST_TESTER": runfiles_path(flutter_sdk_info.flutter_tester, workspace_name),
        "FLUTTER_TEST_ICU": runfiles_path(flutter_sdk_info.icu_data, workspace_name),
        "FLUTTER_TEST_DILL": runfiles_path(kernel_dill, workspace_name),
        "FLUTTER_TEST_ASSETS": runfiles_path(flutter_assets, workspace_name),
        # Display path for the suite. Used in package:test report output.
        "FLUTTER_TEST_PATH": ctx.file.main.short_path,
        "FLUTTER_TEST_IMPELLER": "1" if ctx.attr.enable_impeller else "",
        # What a coverage run reports, one URI prefix a line: the test's own
        # package and its own sources, as `flutter test --coverage` reports its
        # package by default. The rule's generated bootstrap and comparator
        # are not the user's code.
        "FLUTTER_TEST_COVERAGE_LIBRARIES": "\n".join(
            ["package:%s/" % ctx.attr.package_name] +
            [_own_source_uri(f, modular) for f in [ctx.file.main] + ctx.files.srcs],
        ),
    }

    # User-supplied variables, merged last but never over the rule's own keys:
    # those are the runner's start-up contract, and a test that quietly
    # replaced one would fail far from the cause.
    for key, value in ctx.attr.env.items():
        if key in env:
            fail((
                "flutter_test {name}: env key {key} is set by the rule itself " +
                "and cannot be overridden."
            ).format(name = ctx.label.name, key = key))
        env[key] = value

    env_info = testing.TestEnvironment(env)

    runtime_files = [
        kernel_dill,
        flutter_sdk_info.flutter_tester,
        flutter_sdk_info.icu_data,
        flutter_assets,
    ]
    tool_runfiles = tool[DefaultInfo].default_runfiles
    runfiles = ctx.runfiles(
        # The bundled native-asset libraries ship here, at the runfiles-relative
        # paths the manifest names. Both arms re-declare the library into an
        # output namespace of their own first — `flutter_native_asset` under
        # its `bundle_filename`, `bridge_dart_code_assets` under this rule's —
        # so what lands in runfiles is the File the manifest points at rather
        # than the `_solib_<arch>/` original.
        files = runtime_files + ctx.files.data + bundled_code_assets.to_list(),
        transitive_files = flutter_sdk_info.tool_files,
    )
    runfiles = runfiles.merge(tool_runfiles)

    # Merge the runfiles of any `data` targets so cc_library / cc_binary
    # producers (e.g. shared dylibs that the test loads via dart:ffi) and
    # transitively-needed files come along. Mirrors the behavior of
    # rules_dart's dart_binary/dart_test and the standard cc_test/py_test
    # `data` semantics.
    for data_target in ctx.attr.data:
        runfiles = runfiles.merge(data_target[DefaultInfo].default_runfiles)

    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs", "main"],
        dependency_attributes = ["deps"],
    )

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
        env_info,
        instrumented_files_info,
        # The test's own files and every library it reaches import only what
        # their `deps` provide, in either compile mode. The generated bootstrap
        # and golden comparator are the rule's, not the user's, and are not
        # checked.
        OutputGroupInfo(_validation = import_check_validation(
            ctx,
            ctx.executable._kernel_tool,
            [ctx.file.main] + ctx.files.srcs,
            # `synthesize_app_package` appends the test's own package last.
            packages[-1],
            ctx.attr.deps,
        )),
        # What lets rules_dart's analysis check a `flutter_test`. The test's
        # `main` belongs to no package's `lib/`, so no
        # `DartInfo` can name it and it reaches the analyzer only through here.
        # Deliberately not offered as a `DartInfo`: `deps` requires one, and a
        # test is not a dependency.
        #
        # Built by `dart_analyzable_info_with_package` rather than
        # `dart_analyzable_info`, because a `flutter_test` is not package-less
        # the way a `dart_test` is: it declares `package_name`, and its `srcs`
        # are that package's `lib/`. The compile path already says so —
        # `synthesize_app_package` registers the same root record so
        # `package:<self>/…` imports resolve — and the package-less closure the
        # other constructor nests instead reports every such import as
        # `uri_does_not_exist`, blaming a line that is correct.
        #
        # Hence the source split: `srcs` is the `main` outside any `lib/`, and
        # `package_srcs` the `lib/` files reachable as `package:<self>/…`.
        #
        # `lib_root` comes from `derive_lib_root`, the same call the compile
        # path above now passes to `synthesize_app_package`. The two used to
        # disagree — synthesis hardcoded `""` — which is how a sub-package
        # target could analyze clean and compile against the *workspace
        # root's* `lib/`. One derivation, so they cannot drift again.
        #
        # `_sky_engine` joins the analyzer's closure and nothing else.
        # Compilation gets `dart:ui` from the patched SDK the toolchain
        # supplies; the analyzer resolves it only by following the
        # package_config to `package:sky_engine`'s `lib/_embedder.yaml`, so
        # analysis genuinely needs an entry compilation does not.
        dart_analyzable_info_with_package(
            label = ctx.label,
            package_name = ctx.attr.package_name,
            lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package),
            deps = ctx.attr.deps + [ctx.attr._sky_engine],
            srcs = [ctx.file.main],
            package_srcs = ctx.files.srcs,
            # The same version the compile path above states. Analysis reading
            # a different one than the compiler is the divergence this attr
            # exists to close, reappearing one layer down.
            language_version = ctx.attr.language_version,
        ),
    ]

def _link_modules(ctx, bootstrap, own_srcs, packages, native_assets_manifest, kernel_dill):
    """Compiles the test's own files against its deps' modules, and links them.

    Every library in `deps` arrives compiled, once per configuration, as a
    kernel module; only the test's own files are compiled here, against them,
    and the two are linked into the program flutter_tester runs.
    """
    entry_dill = ctx.actions.declare_file(ctx.label.name + ".entry.dill")
    linked = dart_entry_kernel_action(
        ctx,
        sdk = ctx.attr._kernel_sdk[DartKernelSdkInfo],
        kernel_tool = ctx.executable._kernel_tool,
        main = bootstrap,
        srcs = own_srcs,
        packages = packages,
        modules = collect_modules(ctx.attr.deps),
        # `synthesize_app_package` appends the test's own package last.
        own_package = packages[-1],
        output = entry_dill,
        defines = merge_dart_defines(ctx),
        native_assets_yaml = native_assets_manifest,
    )
    dart_link_kernel_action(ctx, ctx.executable._kernel_tool, entry_dill, linked, kernel_dill)

def _compile_whole_program(ctx, flutter_sdk_info, bootstrap, own_srcs, packages, native_assets_manifest, kernel_dill):
    """Compiles the bootstrap and everything it reaches from source, as `flutter_application` does.

    Packages whose hand-written and generated sources straddle the source tree
    and `bazel-out` are co-located first, so `part` directives and a package's
    single `rootUri` resolve.
    """
    all_srcs = collect_transitive_srcs(ctx.attr.deps).to_list() + own_srcs + [bootstrap]
    pc = compile_package_config(ctx, packages, all_srcs)
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        dart = flutter_sdk_info.dart,
        kernel_filter_tool = ctx.file._kernel_filter_tool,
        flutter_sdk_files = flutter_sdk_info.tool_files,
        frontend_server = flutter_sdk_info.frontend_server,
        # The debug platform: asserts on, as `flutter test` compiles.
        platform_dill = flutter_sdk_info.platform_kernel_dill,
        main = bootstrap,
        # Under the app scheme, not the bootstrap's exec path: frontend_server
        # names a root given as a path by the sandbox it ran in, so the kernel
        # and every coverage report would carry a sandbox-specific `file://`
        # path to the test.
        entrypoint_uri = _own_source_uri(bootstrap, modular = False),
        filesystem_roots = [""],
        srcs = pc.srcs,
        package_config = pc.config_file,
        output = kernel_dill,
        aot = False,
        defines = merge_dart_defines(ctx),
        target = "flutter",
        native_assets_manifest = native_assets_manifest,
    )

# flutter_test takes the compilation attrs plus the asset-bundle attrs.
# Material widgets implicitly require `shaders/ink_sparkle.frag` and the
# MaterialIcons font, so a flutter_assets/ tree is built and passed to
# flutter_tester via `--flutter-assets-dir`. Platform-runner-specific
# attrs (engines, plugin libs) are intentionally omitted — flutter_tester
# is a self-contained host engine.
_TEST_ATTRS = {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in (
        "main",
        "srcs",
        "deps",
        "defines",
        "language_version",
        "_extra_dart_defines",
        "package_name",
        # Asset-bundle inputs. Same surface as flutter_application — most
        # widget tests don't touch these, but Material widgets implicitly
        # require shader and font assets to render.
        "assets",
        "shaders",
        "shader_includes",
        "require_sksl_shaders",
        "_shader_compile_tool",
        "_kernel_filter_tool",
        "license_files",
        "tree_shake_icons",
        "_asset_bundle_tool",
    )
}

# Standard `data` attr — files made available at test runtime via
# runfiles. Tests resolve them through `package:runfiles` /
# `Runfiles.create()`. Used for fixtures, golden images, and
# (importantly) FFI shared libraries the test loads via `dart:ffi`.
# Without this, a test that calls into a `cc_library`-produced dylib
# fails at `DynamicLibrary.open` with "file not found", and the
# failure surfaces silently from worker isolates as a hung
# `_opened.future` on the main isolate.
#
# Goldens in particular are *only* reachable through here. The comparator reads
# them from the test's directory in runfiles, so a PNG that exists in the source
# tree but is not a declared input fails as "non-existent file" rather than
# being read behind Bazel's back — which is what keeps a cached pass honest.
# The usual spelling is `data = glob(["test/goldens/**"])`.
_TEST_ATTRS["data"] = attr.label_list(
    allow_files = True,
    doc = "Runtime data deps. Available in test runfiles. Use for " +
          "fixtures, goldens, and FFI dylibs. Golden PNGs must be listed " +
          "here or the comparator cannot see them.",
)

# Standard `env` attr — extra variables for the test process.
#
# Values are used **literally**: there is no `$(location)` or Make-variable
# expansion, so a path here has to be one the test itself can resolve (through
# runfiles, or relative to its working directory). Half-expanding would be
# worse than not expanding, because the unexpanded form still looks like a
# path.
#
# The five `FLUTTER_TEST_*` keys the rule sets are the runner's start-up
# contract; supplying one is rejected in the implementation rather than
# silently honoured or silently dropped.
_TEST_ATTRS["enable_impeller"] = attr.bool(
    doc = "Render with Impeller in flutter_tester, as `flutter test " +
          "--enable-impeller` does, instead of software Skia. A test that " +
          "draws an Impeller-only shader, or a golden meant to match an " +
          "Impeller device, needs it.",
    default = False,
)

_TEST_ATTRS["env"] = attr.string_dict(
    doc = "Extra environment variables for the test process. Values are " +
          "literal — no Make-variable or $(location) expansion. The " +
          "FLUTTER_TEST_* keys the rule sets itself cannot be overridden.",
)
_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_TEST_ATTRS.update(KERNEL_TOOL_ATTR)

# Each library in `deps` is compiled into a kernel module by the aspect, and its
# imports checked by another, with the test's own `defines` (the transition) so a dependency's
# `bool.fromEnvironment` const agrees with the test's.
_TEST_ATTRS["deps"] = attr.label_list(
    doc = "`dart_library` or `flutter_library` dependencies. List " +
          "`@rules_flutter//flutter:material_icons` to bundle " +
          "`MaterialIcons-Regular.otf` for Material widgets.",
    providers = [DartInfo],
    aspects = [flutter_module_aspect, dart_import_check_aspect],
    cfg = module_defines_transition,
)
_TEST_ATTRS["_modular_kernel"] = attr.label(
    default = Label("@rules_dart//dart:modular_kernel"),
    providers = [BuildSettingInfo],
)
_TEST_ATTRS["_kernel_sdk"] = attr.label(
    default = Label("//flutter/private:flutter_kernel_sdk"),
    providers = [DartKernelSdkInfo],
)
_TEST_ATTRS["_tool"] = attr.label(
    default = Label("//flutter/private/tools:flutter_test_runner"),
    cfg = "exec",
)

# The golden-file comparator the generated bootstrap installs. Implicit rather
# than something each target lists, because needing it is a property of running
# Flutter tests at all, not a choice any BUILD file makes — and because the
# alternative to installing one is Flutter's `TrivialComparator`, which reports
# every golden assertion as passing without comparing anything.
_TEST_ATTRS["_golden_comparator_src"] = attr.label(
    doc = "Golden-file comparator staged into the generated bootstrap. " +
          "Compiled into the test only when its deps expose package:flutter_test.",
    default = Label("//flutter/private/goldens:comparator.dart"),
    allow_single_file = [".dart"],
)

# Analysis-only. `package:sky_engine`'s `lib/_embedder.yaml` is the whole of how
# the analyzer resolves `dart:ui`; without it every Flutter import in a widget
# test fails to resolve. It is an implicit attr rather than something each
# `flutter_test` lists, because needing it is a property of analyzing Flutter
# Dart, not a choice any BUILD file makes — and it reaches only
# `dart_analyzable_info`, so no compile action's inputs change.
_TEST_ATTRS["_sky_engine"] = attr.label(
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

flutter_test = rule(
    implementation = _flutter_test_impl,
    attrs = _TEST_ATTRS,
    test = True,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles a Flutter widget test, then runs it under flutter_tester " +
          "via the package:test_api RemoteListener protocol.",
)
