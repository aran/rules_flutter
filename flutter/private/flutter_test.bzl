"""Flutter test rules: `flutter_test_program` compiles, `flutter_test` declares a test.

`flutter_test_program` compiles a Flutter test entry point to a kernel `.dill`
(`FlutterTestProgramInfo`), and `flutter_program_test`
(`flutter_program_test.bzl`) runs a program under `flutter_tester`, the
headless Flutter engine. `flutter_test` is the macro that declares both. Tests interact with the test
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
     point, and all of it listed in a kernel list, which the runner joins into the
     one kernel flutter_tester loads when it starts it (in memory on Linux, a
     temporary file elsewhere), so no test stores a copy of its libraries.
     With `--@rules_dart//dart:kernel_list=false` the build joins them into
     one `.dill` instead. A test therefore recompiles only its own files, and a change to a shared
     library recompiles that library's module and those downstream of it once,
     not every test that reaches it. With
     `--@rules_dart//dart:modular_kernel=false` the test instead compiles its
     whole program from source, as `flutter_application` does.
  3. The runner binary spawns `flutter_tester` with the dill, hosts a localhost
     WebSocket harness, drives the `package:test` MultiChannel protocol, and
     reports per-test pass/fail.

Coverage: under `bazel coverage` the runner launches `flutter_tester` with
the VM service enabled, collects line coverage over it once the suite has run,
and converts it with rules_dart's `coverage_converter` into an LCOV tracefile
in `COVERAGE_DIR`, naming each file by its workspace path. Which files it
reports is Bazel's `--instrumentation_filter`, over the test's `srcs` and every
library it reaches; Bazel merges the tracefile with `_lcov_merger`.

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

load("@bazel_skylib//lib:structs.bzl", "structs")
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartKernelSdkInfo")
load("@rules_dart//dart:utils.bzl", "KERNEL_LIST_ATTR", "KERNEL_TOOL_ATTR", "MODULAR_KERNEL_ATTR", "PROGRAM_ASSETS_TOOLCHAINS", "TRACK_CREATION_LOCATIONS_ATTR", "collect_modules", "collect_packages", "collect_transitive_runfiles", "collect_transitive_srcs", "dart_entry_kernel_action", "dart_import_check_aspect", "dart_link_kernel_action", "executable_defines", "executable_defines_config", "import_check_output_groups", "kernel_list", "modular_kernel", "package_identity_attrs", "program_assets_attrs", "runfiles_path", "track_creation_locations")
load("//flutter:providers.bzl", "FlutterApplicationInputsInfo", "FlutterTestProgramInfo")
load("//flutter/private:app_entrypoint.bzl", "APP_SCHEME", "synthesize_app_package")
load("//flutter/private:application_libraries.bzl", "application_libraries", "application_libraries_aspect")
load(
    "//flutter/private:common.bzl",
    "FLUTTER_APPLICATION_ATTRS",
    "PLATFORM_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "declare_flutter_assets_dir",
    "detect_target_platform",
    "flag_dart_defines",
    "flavor_dart_defines",
    "flutter_build_assets",
    "flutter_compile_shaders",
    "flutter_program_inputs",
    "program_package",
)
load("//flutter/private:exec_groups.bzl", "FLUTTER_EXEC_TOOLS", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_compile.bzl", "flutter_kernel_compile")
load("//flutter/private:flutter_module.bzl", "flutter_module_aspect")
load("//flutter/private:flutter_native_assets.bzl", "CODE_ASSETS_DOC", "collect_bundled_code_asset_files", "resolve_native_assets", "write_native_assets_manifest")
load("//flutter/private:flutter_program_test.bzl", "add_user_env", "program_environment", "track_widget_creation", _flutter_test_rule = "flutter_test")
load("//flutter/private:plugin_registrant.bzl", "make_registrant_parts")
load("//flutter/private:plugin_resolution.bzl", "application_plugins")
load("//flutter/private:program_analysis.bzl", "program_analyzable_info", "program_sky_engine_attr")
load("//flutter/private:sdk_defines.bzl", "app_version_dart_defines")

# The target's Flutter SDK, whose `flutter_tester` runs the test.
_FLUTTER_TOOLCHAIN = "@rules_flutter//flutter:toolchain_type"

def make_bootstrap_content(test_relative_import, golden_comparator_import = None, test_config_import = None, plugin_registrant = None):
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
        test_config_import: Import URI for the suite's `flutter_test_config.dart`,
            or None. Its `testExecutable` is handed the suite's main and runs
            it, as `flutter test` runs it, after the golden comparator is
            installed so the config can replace it.
        plugin_registrant: The `make_registrant_parts` of the test's Dart
            plugins, or None for none. Declared in the bootstrap, the root
            library: with no library named by `flutter.dart_plugin_registrant`,
            the engine calls the root library's `_PluginRegistrant.register()`
            before `main`.

    Returns:
        Dart source string.
    """
    if test_config_import:
        config_import = "import '{}' as test_config;\n".format(test_config_import)
        returned_main = "() => test_config.testExecutable(_runTestMain)"
    else:
        config_import = ""
        returned_main = "_runTestMain"

    if golden_comparator_import:
        golden_import = "import '{}' as goldens;\n".format(golden_comparator_import)
        golden_install = "    goldens.installBazelGoldenFileComparator();\n"
    else:
        golden_import = ""
        golden_install = ""

    if plugin_registrant:
        registrant_imports = "".join([line + "\n" for line in plugin_registrant.imports])
        registrant_declaration = "\n" + plugin_registrant.declaration
    else:
        registrant_imports = ""
        registrant_declaration = ""

    return """// GENERATED by flutter_test — do not edit.
//
// Bootstraps a Flutter widget test under flutter_tester. Connects back to
// the bazel-side harness over WebSocket and drives the test via
// package:test_api/backend.dart RemoteListener — the same surface
// `flutter test` uses.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Service;
import 'dart:io';
import 'dart:isolate';

import 'package:test_api/backend.dart';

import '{test_import}' as test;
{golden_import}{config_import}{registrant_imports}{registrant_declaration}
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
{golden_install}    return {returned_main};
  }});

  // 127.0.0.1 and not `localhost`: deliberately the same address family the
  // harness binds. Read the record on `_Harness.bind` in
  // flutter/private/tools/flutter_test_runner.dart before changing either —
  // the two only make sense together, and changing this one alone is how a
  // dial reaches something other than the harness.
  //
  // The dial-back names the VM service when this run has one, for coverage:
  // flutter_tester's output goes straight to the target's log, so the harness
  // does not read the address from it. The VM finishes starting its service
  // before it runs `main`, so the address is known here or there is none.
  final vmService = (await Service.getInfo()).serverUri;
  final ws = await WebSocket.connect(
    vmService == null
        ? 'ws://127.0.0.1:$port'
        : 'ws://127.0.0.1:$port/'
            '?vm-service=${{Uri.encodeQueryComponent('$vmService')}}',
  );
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
        config_import = config_import,
        returned_main = returned_main,
        registrant_imports = registrant_imports,
        registrant_declaration = registrant_declaration,
    )

def _kernel_root_path(short_path):
    # Where a file sits under the kernel filesystem roots: another
    # repository's `../<repo>/…` is `external/<repo>/…` there.
    return "external/" + short_path[3:] if short_path.startswith("../") else short_path

def _app_source_uri(file):
    # A source's URI under the app scheme, which the whole-program compile
    # mounts the exec root and the output root under: the same wherever, and
    # in whichever configuration, the kernel is built.
    return "%s:///%s" % (APP_SCHEME, _kernel_root_path(file.short_path))

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

def _flutter_test_program_impl(ctx):
    # The flutter_tester that runs the test: the target's, as everything the
    # test runs is. The compiles are `portable`.
    runner_tools = ctx.toolchains[_FLUTTER_TOOLCHAIN].flutter_sdk_info

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
    target_arch = _target_arch(ctx)
    if runner_tools.flutter_tester == None:
        fail((
            "flutter_test_program {label}: Flutter ships no flutter_tester for " +
            "{os}, the target platform; build the test for a desktop " +
            "platform with `--platforms` or a platform transition."
        ).format(label = ctx.label, os = target_platform))

    # Bazel runs a test with its working directory at the runfiles root, which
    # is what the `runfiles` layout's relative library paths resolve against.
    # Windows has no such tree by default, only a manifest, so a test there
    # finds its libraries by name on PATH, as a `flutter_tester_binary` does.
    layout = "library_path" if target_platform == "windows" else "runfiles"
    program = _program(ctx, "flutter_test_program", runner_tools, target_platform, target_arch, layout)

    return [
        DefaultInfo(
            files = depset([program.info.kernel, program.info.assets], transitive = [program.info.kernels]),
            runfiles = program.info.runfiles,
        ),
        program.info,
        # What `bazel coverage` reports: the test's `srcs` (its package's
        # `lib/`) and every library it reaches, as `--instrumentation_filter`
        # selects them. The test's `main` is the test, as a `dart_test`'s is
        # under Bazel's default `--noinstrument_test_targets`.
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["deps", "application"],
            extensions = ["dart"],
        ),
    ] + program.providers

def _target_arch(ctx):
    """The target platform's CPU in Native Assets' naming, or "" if neither."""
    if ctx.target_platform_has_constraint(ctx.attr._arm64_constraint[platform_common.ConstraintValueInfo]):
        return "arm64"
    if ctx.target_platform_has_constraint(ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo]):
        return "x64"
    return ""

# What a test of an `application` takes from it besides its Dart program: the
# asset bundle's inputs, which the test's own attributes cannot add to, since
# the bundle keys every asset by the one package it is in.
_APPLICATION_BUNDLE_FIELDS = ["assets", "shaders", "shader_includes", "additional_licenses"]

# What a test of an `application` takes from it beyond the package it is
# compiled in, which `flutter_program_inputs` resolves from the application's
# declaration: the label the program is built for.
_APPLICATION_PACKAGE_FIELDS = ["label"]

def _test_inputs(ctx, kind):
    """The program the test compiles, as `flutter_program_inputs` describes one.

    Its own attributes', or, with `application`, the application's program
    with the test's `main`, `srcs`, `deps` and `code_assets` added: the test is
    compiled in the application's package, as `flutter test` compiles a test
    in the package it is in, so `package:<app>/…` resolves against the
    application's `lib/` and the application's libraries and assets are the
    test's. The application's own `main` stays a source, for the test to
    import, as in `flutter_application_variant`. The test's `defines`,
    `flavor` and compile settings are its own.
    """

    # A list, empty or of one: the attribute has a transition.
    application = getattr(ctx.attr, "application", [])
    application = application[0] if application else None

    # The application's package is the test's; a `package` the test names
    # too must be the same declaration, which `resolve_package_identity` checks.
    app = application[FlutterApplicationInputsInfo].inputs if application else None
    own = flutter_program_inputs(ctx, metadata = app.package if app else None)
    if application == None:
        if own.package == None:
            fail((
                "{kind} {label}: `package` is required: the " +
                "`dart_package_metadata` of the Dart package the test is " +
                "compiled in. Or name the `application` whose package it is."
            ).format(kind = kind, label = ctx.label))
        return own
    for field in _APPLICATION_BUNDLE_FIELDS:
        if getattr(own, field):
            fail((
                "{kind} {label}: `{field}` cannot be given with `application`: " +
                "the test bundles the application's, as it is compiled in the " +
                "application's package."
            ).format(kind = kind, label = ctx.label, field = field))

    # A library both name is one dependency: each is configured the same way.
    deps = {}
    for dep in own.deps + application_libraries(application):
        deps.setdefault(dep.label, dep)
    kept_main = [app.main] if app.main != None and app.main not in app.srcs else []
    return struct(**(structs.to_dict(own) | {
        field: getattr(app, field)
        for field in _APPLICATION_PACKAGE_FIELDS + _APPLICATION_BUNDLE_FIELDS
    } | {
        "srcs": app.srcs + kept_main + own.srcs,
        "staged_sources": app.staged_sources,
        "deps": deps.values(),
        "code_assets": own.code_assets + app.code_assets,
    }))

def _program(ctx, kind, runner_tools, target_os, target_arch, layout):
    """Compiles the target's suite into what flutter_tester runs, with its runfiles.

    Shared by `flutter_test` and `flutter_tester_binary`, which differ only in
    how the runner is started and where it runs.

    Args:
      ctx: The rule context.
      kind: The rule's name, for messages.
      runner_tools: The `FlutterSdkInfo` or `FlutterExecToolsInfo` whose
        `flutter_tester` runs the program.
      target_os: The target's OS, which `deps` and `code_assets` are built
        for; with `target_arch`, the ABI the native-assets manifest names.
      target_arch: The target's CPU.
      layout: The native-assets manifest layout (`write_native_assets_manifest`).

    Returns:
      `struct(info, providers)`: the `FlutterTestProgramInfo` of the compiled
      program, and the other providers both rules return.
    """

    # rules_dart's checks of the environment reserve no key; the keys the
    # Flutter build sets itself are refused here.
    flag_dart_defines(ctx)
    inputs = _test_inputs(ctx, kind)
    deps = inputs.deps
    if not _can_bootstrap(deps):
        fail((
            "{kind} target {name} must depend on package:flutter_test " +
            "(or at minimum package:test_api). Add `@<hub>//:flutter_test` " +
            "to deps so the generated bootstrap can import RemoteListener."
        ).format(kind = kind, name = ctx.label.name))

    # Same contract as `flutter_application`: a pub package that builds its
    # native code with a hook Bazel cannot run contributes no library, and the
    # manifest below would be quietly one entry short. A test is where that
    # matters most — it is where an unresolved `@Native` symbol gets debugged.
    hook_err = check_unreplaced_hooks(ctx.label, deps)
    if hook_err != None:
        fail(hook_err)

    # Code assets reach a test the same ways they reach an application: named
    # in `code_assets`, or owned by a package and lifted off the Dart package
    # graph. See `resolve_native_assets`.
    native_assets_list = resolve_native_assets(
        ctx,
        package = program_package(inputs),
        deps = deps,
        code_assets = [target[DartCodeAssetInfo] for target in inputs.code_assets],
    ).assets

    native_assets_manifest = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    write_native_assets_manifest(
        ctx = ctx,
        output_file = native_assets_manifest,
        native_assets = native_assets_list,
        target_os = target_os,
        target_arch = target_arch,
        # No bundle to resolve against: the libraries ship in runfiles, named
        # by their runfiles paths or found on the runner's library path.
        layout = layout,
    )
    bundled_code_assets = collect_bundled_code_asset_files(native_assets_list).to_list()

    # Under `library_path` the manifest names each library by its bundle
    # filename alone, and the runner puts one directory holding all of them on
    # the loader's search path. Bundle filenames are unique, as in an
    # application's bundle. `native_files` names each by its runfiles path:
    # a manifest-only runfiles lists files, so the runner finds the directory
    # through them, and can name any it cannot find.
    native_files = []
    if layout == "library_path":
        staged = []
        for asset in native_assets_list:
            if asset.link_mode != "dynamic_loading_bundle" or asset.file == None:
                continue
            link = ctx.actions.declare_file("%s.native/%s" % (ctx.label.name, asset.bundle_filename))
            ctx.actions.symlink(output = link, target_file = asset.file)
            staged.append(link)
            native_files.append(runfiles_path(link, ctx.workspace_name))
        bundled_code_assets = staged

    # The golden comparator, staged next to the generated bootstrap so the
    # bootstrap can import it by basename — the same arrangement
    # `flutter_application` uses for `dev_tool_support/agent.dart`. A symlink
    # rather than a copy: the file is a plain source, and staging it into this
    # rule's own output namespace is what makes the import a sibling lookup
    # instead of arithmetic over the exec root.
    #
    # Only for suites that actually carry `package:flutter_test`; see the two
    # predicates above. Both the staged file and the bootstrap's import of it
    # are behind that gate, so a `test_api`-only target compiles exactly the
    # bootstrap it compiled before.
    staged_comparator = None
    if _has_flutter_test(deps):
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
    modular = modular_kernel(ctx)

    # Per-target bootstrap. Imports the user's test by a path relative to the
    # bootstrap under the filesystem roots both compile modes mount, so the
    # import names no configuration.
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")
    to_root = "../" * _kernel_root_path(bootstrap.short_path).count("/")
    config = ctx.file.test_config

    # The Dart plugins of the platform flutter_tester runs on are registered
    # before the test's `main`, as `flutter test` registers them. Upstream
    # names its registrant library with `-Dflutter.dart_plugin_registrant`,
    # which `package:flutter` reads as a constant; here that define would be
    # the environment of every module the test reaches, so `package:flutter`
    # would compile once per test. The bootstrap declares the registrant
    # instead, in either kernel mode: the engine calls the root library's when
    # the define names none, and the bootstrap's imports are what keeps the
    # plugins' libraries in the linked program.
    # One Dart implementation of each federated plugin, as `flutter test`
    # chooses it, with the test's `deps` the direct dependencies.
    plugins = application_plugins(ctx.label, deps).dart
    ctx.actions.write(bootstrap, make_bootstrap_content(
        to_root + _kernel_root_path(ctx.file.main.short_path),
        golden_comparator_import = staged_comparator.basename if staged_comparator else None,
        test_config_import = to_root + _kernel_root_path(config.short_path) if config else None,
        plugin_registrant = make_registrant_parts(plugins, target_platform = target_os),
    ))

    # The files that are the user's own and in no package: the main, and the
    # `flutter_test_config.dart` that wraps it.
    entry_files = [ctx.file.main] + ([config] if config else [])

    # Register the test's own package so `package:<self>/foo` imports inside
    # test sources resolve.
    package_root = inputs.package_root
    packages = synthesize_app_package(
        ctx.label,
        collect_packages(deps),
        inputs.package_name,
        package_root,
        inputs.package,
    )

    own_srcs = list(inputs.srcs) + entry_files
    if staged_comparator:
        own_srcs.append(staged_comparator)
    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")

    # With `--@rules_dart//dart:kernel_list`, `kernel_dill` is a list of the
    # kernels the program is made of, and these are the files it names.
    listed_kernels = depset()
    as_kernel_list = modular and kernel_list(ctx)
    if modular:
        listed_kernels = _link_modules(ctx, deps, bootstrap, own_srcs, packages, native_assets_manifest, kernel_dill, as_kernel_list)
    else:
        _compile_whole_program(ctx, portable_tools(ctx), deps, bootstrap, own_srcs, packages, native_assets_manifest, kernel_dill)

    # Build a `flutter_assets/` tree for the test. Material widgets pull
    # `shaders/ink_sparkle.frag` at first paint, and pub-package fonts/assets
    # (e.g. MaterialIcons) need to land in the bundle for tests that resolve
    # them via `rootBundle`. Tests run on the host, so shaders compile against
    # the host platform resolved above.
    # The test runs on flutter_tester, not the host's embedder: its shaders
    # are compiled for it, as `flutter test` compiles them (SkSL for Skia,
    # Vulkan for Impeller).
    compiled_shaders = flutter_compile_shaders(ctx, portable_tools(ctx), "tester", deps, inputs)
    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_build_assets(
        ctx,
        portable_tools(ctx),
        flutter_assets,
        deps,
        "tester",
        compiled_shaders,
        is_debug = True,
        # flutter_tester resolves an `@Native` binding through the
        # `NativeAssetsManifest.json` of its assets directory, as `flutter test`
        # gives it one; the engine reads no manifest from the kernel.
        native_assets_manifest = native_assets_manifest,
        inputs = inputs,
    )

    runfiles = ctx.runfiles(
        # The bundled native-asset libraries ship here, at the runfiles-relative
        # paths the manifest names. `resolve_native_assets` re-declares each
        # library under this rule's name first, so what lands in runfiles is
        # the File the manifest points at rather than the `_solib_<arch>/`
        # original.
        files = [
            kernel_dill,
            runner_tools.flutter_tester,
            runner_tools.icu_data,
            flutter_assets,
            ctx.file.main,
        ] + ctx.files.data + bundled_code_assets,
        transitive_files = listed_kernels,
    )

    # Merge the runfiles of any `data` targets so cc_library / cc_binary
    # producers (e.g. shared dylibs that the test loads via dart:ffi) and
    # transitively-needed files come along. Mirrors the behavior of
    # rules_dart's dart_binary/dart_test and the standard cc_test/py_test
    # `data` semantics.
    for data_target in ctx.attr.data:
        runfiles = runfiles.merge(data_target[DefaultInfo].default_runfiles)

    # What the libraries the program reaches need at run time (a
    # `dart_library`'s or `flutter_library`'s `data`), as rules_dart's
    # `dart_test` carries it.
    runfiles = runfiles.merge(collect_transitive_runfiles(ctx, deps))

    info = FlutterTestProgramInfo(
        kernel = kernel_dill,
        kernel_list = bool(as_kernel_list),
        kernels = listed_kernels,
        assets = flutter_assets,
        tester = runner_tools.flutter_tester,
        icu_data = runner_tools.icu_data,
        # Used in package:test report output.
        display_path = ctx.file.main.short_path,
        source = ctx.file.main,
        packages = packages,
        native_assets_manifest = native_assets_manifest,
        native_files = native_files,
        enable_impeller = ctx.attr.enable_impeller,
        target_os = target_os,
        runfiles = runfiles,
    )
    return struct(info = info, providers = [
        # The test's own files and every library it reaches import only what
        # their `deps` provide, in either compile mode. The generated bootstrap
        # and golden comparator are the rule's, not the user's: their imports
        # are uses of `deps` (the bootstrap's of `flutter_test`, which a test
        # may reach only through a helper), and are not themselves checked.
        OutputGroupInfo(**import_check_output_groups(
            ctx,
            ctx.executable._kernel_tool,
            entry_files + inputs.srcs,
            # `synthesize_app_package` appends the test's own package last.
            packages[-1],
            deps,
            main = ctx.file.main,
            generated = [bootstrap] + ([staged_comparator] if staged_comparator else []),
        )),
        # What lets rules_dart's analysis check a `flutter_test`. The test's
        # `main` belongs to no package's `lib/`, so no `DartInfo` can name it
        # and it reaches the analyzer only through here. Deliberately not
        # offered as a `DartInfo`: `deps` requires one, and a test is not a
        # dependency. A test built in an application's package (`application`)
        # has the application's sources among its own.
        program_analyzable_info(ctx, inputs.package, package_root, deps, inputs.srcs + entry_files + inputs.staged_sources),
    ])

def _link_modules(ctx, deps, bootstrap, own_srcs, packages, native_assets_manifest, kernel_dill, kernel_list):
    """Compiles the test's own files against its deps' modules, and links them.

    Every library in `deps` arrives compiled, once per configuration, as a
    kernel module; only the test's own files are compiled here, against them,
    and the two are linked into the program flutter_tester runs: one joined
    kernel, or, as `kernel_list`, a list of the kernels that the runner joins
    when it starts flutter_tester, which takes a single file.

    Returns:
      A depset of the kernels `kernel_dill` lists, for the runfiles; empty for
      a joined kernel.
    """
    entry_dill = ctx.actions.declare_file(ctx.label.name + ".entry.dill")
    linked = dart_entry_kernel_action(
        ctx,
        sdk = ctx.attr._kernel_sdk[DartKernelSdkInfo],
        kernel_tool = ctx.executable._kernel_tool,
        main = bootstrap,
        srcs = own_srcs,
        packages = packages,
        modules = collect_modules(deps),
        # `synthesize_app_package` appends the test's own package last.
        own_package = packages[-1],
        output = entry_dill,
        native_assets_yaml = native_assets_manifest,
        track_creation_locations = track_creation_locations(ctx),
    )
    return dart_link_kernel_action(ctx, ctx.executable._kernel_tool, entry_dill, linked, kernel_dill, kernel_list = kernel_list)

def _compile_whole_program(ctx, tools, deps, bootstrap, own_srcs, packages, native_assets_manifest, kernel_dill):
    """Compiles the bootstrap and everything it reaches from source, as `flutter_application` does."""
    flutter_kernel_compile(
        ctx,
        tools,
        # The debug platform, as `flutter test` compiles.
        runtime = "debug",
        main = bootstrap,
        srcs = depset(own_srcs, transitive = [collect_transitive_srcs(deps)]),
        packages = packages,
        output = kernel_dill,
        # Under the app scheme, not the bootstrap's exec path: frontend_server
        # names a root given as a path by the sandbox it ran in, so the kernel
        # and every coverage report would carry a sandbox-specific `file://`
        # path to the test.
        entrypoint_uri = _app_source_uri(bootstrap),
        # The SDK's own describe it to the program, as a module's compile carries them.
        defines = executable_defines(ctx) + list(tools.sdk_defines),
        # Widgets know where they were built, as under `flutter test`: the
        # inspector and the "relevant error-causing widget" of a failure read
        # it. Set by `track_widget_creation`, as the modules' is.
        track_widget_creation = track_creation_locations(ctx),
        native_assets_manifest = native_assets_manifest,
    )

def _implied_defines(attrs):
    """What `flutter test` adds to the compile: the test's flavor and its version.

    The SDK's come with the kernel SDK the modules and the entrypoint are
    compiled against (`flutter_kernel_sdk_info`), so they follow the selected SDK.
    """
    return flavor_dart_defines(attrs.flavor) + app_version_dart_defines(
        attrs.build_name,
        attrs.build_number,
    )

# The environment the test and its `deps`' modules compile in: its `defines`,
# then the flavor's and the version's, then the extra_dart_defines flag. A
# `defines` entry that sets one of those keys too is refused. The SDK's own
# defines are the kernel SDK's.
_ENVIRONMENT = executable_defines_config(_implied_defines)

# flutter_test takes the compilation attrs plus the asset-bundle attrs.
# Material widgets implicitly require `shaders/ink_sparkle.frag` and the
# MaterialIcons font, so a flutter_assets/ tree is built and passed to
# flutter_tester via `--flutter-assets-dir`. Platform-runner-specific
# attrs (engines, plugin libs) are intentionally omitted — flutter_tester
# is a self-contained host engine.
_PROGRAM_ATTRS = {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in (
        "main",
        "srcs",
        "deps",
        "defines",
        "flavor",
        "build_name",
        "build_number",
        "_extra_dart_defines",
        # Asset-bundle inputs. Same surface as flutter_application — most
        # widget tests don't touch these, but Material widgets implicitly
        # require shader and font assets to render.
        "assets",
        "shaders",
        "shader_includes",
        "require_sksl_shaders",
        "_shader_compile_tool",
        "additional_licenses",
        "tree_shake_icons",
        "_asset_bundle_tool",
        "_notices_tool",
        "_engine_license",
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
_PROGRAM_ATTRS["data"] = attr.label_list(
    allow_files = True,
    doc = "Runtime data deps. Available in test runfiles. Use for " +
          "fixtures, goldens, and FFI dylibs. Golden PNGs must be listed " +
          "here or the comparator cannot see them.",
)

_PROGRAM_ATTRS["test_config"] = attr.label(
    doc = "The suite's `flutter_test_config.dart`: its " +
          "`testExecutable(FutureOr<void> Function() testMain)` runs the " +
          "suite, as under `flutter test`. `flutter_test` finds it itself, " +
          "the way `flutter test` does; name one here only when it is above " +
          "the BUILD file's package, where that search cannot see.",
    allow_single_file = [".dart"],
)

_PROGRAM_ATTRS["enable_impeller"] = attr.bool(
    doc = "Render with Impeller in flutter_tester, as `flutter test " +
          "--enable-impeller` does, instead of software Skia. A test that " +
          "draws an Impeller-only shader, or a golden meant to match an " +
          "Impeller device, needs it. Impeller needs a GPU where the test " +
          "runs (Metal on macOS, Vulkan on Linux); a host without one, such " +
          "as a typical remote worker, fails to start flutter_tester. A " +
          "test runs on a host matching its target; where that may be a " +
          "machine without a GPU, keep this one on one with " +
          "`exec_group_compatible_with = {\"test\": [...]}`.",
    default = False,
)

_PROGRAM_ATTRS.update(_ENVIRONMENT.attrs)

_PROGRAM_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_PROGRAM_ATTRS.update(program_assets_attrs())
_PROGRAM_ATTRS.update(KERNEL_TOOL_ATTR)
_PROGRAM_ATTRS.update(KERNEL_LIST_ATTR)
_PROGRAM_ATTRS.update(MODULAR_KERNEL_ATTR)
_PROGRAM_ATTRS.update(TRACK_CREATION_LOCATIONS_ATTR)

# Each library in `deps` is compiled into a kernel module by the aspect, and its
# imports checked by another, with the test's own `defines` (the transition) so a dependency's
# `bool.fromEnvironment` const agrees with the test's.
_PROGRAM_ATTRS["deps"] = attr.label_list(
    doc = "`dart_library` or `flutter_library` dependencies. List " +
          "`@rules_flutter//flutter:material_icons` to bundle " +
          "`MaterialIcons-Regular.otf` for Material widgets.",
    providers = [DartInfo],
    aspects = [flutter_module_aspect, dart_import_check_aspect],
    cfg = _ENVIRONMENT.cfg,
)

# The application a test may be compiled in. Built in the test's environment,
# as `deps` are, so the libraries of its program, which the aspect compiles to
# modules, are the ones the test's own compile and link agree with.
_PROGRAM_ATTRS["application"] = attr.label(
    doc = "A `flutter_application` (or `flutter_application_variant`) " +
          "whose package the test is compiled in, as `flutter test` compiles " +
          "a test in the package it is in: its `package`, sources, " +
          "`deps`, `code_assets` and assets are the test's, and `main`, " +
          "`srcs`, `deps` and `code_assets` add to them, so the test imports " +
          "the application's libraries as `package:<name>/…`. " +
          "`package` and the asset attributes are then the " +
          "application's and not given here. Its `defines` and `flavor` are " +
          "not taken: the test's own are.",
    providers = [FlutterApplicationInputsInfo],
    aspects = [application_libraries_aspect],
    cfg = _ENVIRONMENT.cfg,
)

_PROGRAM_ATTRS.update(package_identity_attrs(
    doc = "The `dart_package_metadata` of the Dart package the test is " +
          "compiled in (the Bazel stand-in for its `pubspec.yaml`), so " +
          "`package:<name>/…` resolves against `srcs` in that package's " +
          "`lib/`, and the test's files take its `language_version`. It is " +
          "`pubspec-metadata` in the BUILD file at the package root, its " +
          "directory, wherever the test's BUILD file is. " +
          "A test of a library *is* that library's package: name the " +
          "library's `dart_package_metadata`, and list the library's " +
          "sources in `srcs` or depend on it. Required, unless `application` " +
          "names the package.",
))

_PROGRAM_ATTRS["code_assets"] = attr.label_list(
    doc = CODE_ASSETS_DOC,
    providers = [DartCodeAssetInfo],
    cfg = _ENVIRONMENT.cfg,
)

# Built for the host the test's entry kernel compiles on: rules_dart compiles
# and links it in `portable`.
_PROGRAM_ATTRS["_kernel_sdk"] = attr.label(
    default = Label("//flutter/private:flutter_kernel_sdk"),
    providers = [DartKernelSdkInfo],
    cfg = config.exec(PORTABLE),
)

# The golden-file comparator the generated bootstrap installs. Implicit rather
# than something each target lists, because needing it is a property of running
# Flutter tests at all, not a choice any BUILD file makes — and because the
# alternative to installing one is Flutter's `TrivialComparator`, which reports
# every golden assertion as passing without comparing anything.
_PROGRAM_ATTRS["_golden_comparator_src"] = attr.label(
    doc = "Golden-file comparator staged into the generated bootstrap. " +
          "Compiled into the test only when its deps expose package:flutter_test.",
    default = Label("//flutter/private/goldens:comparator.dart"),
    allow_single_file = [".dart"],
)

_PROGRAM_ATTRS["_sky_engine"] = program_sky_engine_attr(_ENVIRONMENT.cfg)

flutter_test_program = rule(
    implementation = _flutter_test_program_impl,
    attrs = _PROGRAM_ATTRS,
    cfg = track_widget_creation,
    # The compiles are `portable`.
    toolchains = [_FLUTTER_TOOLCHAIN] + PROGRAM_ASSETS_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = ["cpp"],
    provides = [FlutterTestProgramInfo],
    doc = """Compiles a Flutter test into a program, and does not run it. Returns \
`FlutterTestProgramInfo`, which `flutter_program_test` runs.

This is the compile half of `flutter_test`: from `main`, `srcs` and `deps` it \
generates the bootstrap that speaks the `package:test_api` `RemoteListener` \
protocol, installs the golden-file comparator, compiles the test's own files \
against its dependencies' kernel modules, and bundles the assets, shaders, \
code assets and Native Assets manifest the test needs. `flutter_test` is this \
rule and `flutter_program_test` over it. Use the two directly to run a program \
of your own compile with `flutter_program_test`, or to put a program between \
the two.

Its `deps`, native code assets included, and flutter_tester are built for the \
target platform. The compiles run in the `portable` group. `data`, \
goldens included, is part of the program's runfiles. Declare it `testonly`: \
`flutter_test` does.""",
)

# A `flutter_tester_binary` runs where it is started: under `bazel run`, here;
# as another action's tool, on that action's host, which builds it in its exec
# configuration. Either way its target platform is that host, so the `run`
# group asks for a host of the target's OS and CPU and takes flutter_tester
# from it.
_RUN = "run"
_RUN_HOST_TOOLCHAIN = "//flutter:run_host_toolchain_type"

def _flutter_tester_binary_impl(ctx):
    runner_tools = ctx.exec_groups[_RUN].toolchains[FLUTTER_EXEC_TOOLS].flutter_exec_tools_info

    # The program may be started from any working directory, as a build
    # action starts its tools from the exec root, so its libraries are found
    # on the loader's path rather than relative to the runfiles root.
    #
    # The `run` group's host has the target's OS and CPU, so the native
    # libraries built for the target are the ones it loads.
    target_os = detect_target_platform(
        ctx.target_platform_has_constraint(ctx.attr._ios_constraint[platform_common.ConstraintValueInfo]),
        ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]),
        ctx.target_platform_has_constraint(ctx.attr._linux_constraint[platform_common.ConstraintValueInfo]),
        ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo]),
        ctx.target_platform_has_constraint(ctx.attr._android_constraint[platform_common.ConstraintValueInfo]),
    )
    program = _program(ctx, "flutter_tester_binary", runner_tools, target_os, _target_arch(ctx), "library_path")
    env = program_environment(program.info, ctx.workspace_name)
    add_user_env(ctx, "flutter_tester_binary", env)

    # The executable is the prebuilt runner under the binary's name, as for
    # `flutter_test`, so it runs on every host and starts no shell. A build
    # action that runs it as a tool never applies a run environment, so the
    # settings a test gets from `RunEnvironmentInfo` travel in runfiles
    # instead, as `<name>.launch.json` at the root of the binary's own tree.
    # The runner finds that tree beside its own path: a RUNFILES_DIR inherited
    # from a caller names the caller's.
    tool = ctx.attr._tool
    ext = ".exe" if runner_tools.host_os == "windows" else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    launch = ctx.actions.declare_file(ctx.label.name + ".launch.json")
    ctx.actions.write(launch, json.encode(env))
    return [
        DefaultInfo(
            executable = executable,
            runfiles = program.info.runfiles.merge_all([
                ctx.runfiles(root_symlinks = {ctx.label.name + ".launch.json": launch}),
                tool[DefaultInfo].default_runfiles,
            ]),
        ),
        program.info,
    ] + program.providers

_BINARY_ATTRS = {
    k: v
    for k, v in _PROGRAM_ATTRS.items()
}

_BINARY_ATTRS["env"] = attr.string_dict(
    doc = "Extra environment variables for the program. Values are " +
          "literal — no Make-variable or $(location) expansion. The " +
          "FLUTTER_TEST_* keys the rule sets itself cannot be overridden.",
)

_BINARY_ATTRS["test_config"] = attr.label(
    doc = "A `flutter_test_config.dart` whose " +
          "`testExecutable(FutureOr<void> Function() testMain)` runs the " +
          "program, as it runs a suite under `flutter test`. Unlike " +
          "`flutter_test`'s, it is not searched for: a binary runs through " +
          "one only when it names it.",
    allow_single_file = [".dart"],
)

_BINARY_ATTRS["_tool"] = attr.label(
    default = Label("//flutter/private/tools:flutter_test_runner"),
    cfg = config.exec(_RUN),
)

flutter_tester_binary = rule(
    implementation = _flutter_tester_binary_impl,
    attrs = _BINARY_ATTRS,
    cfg = track_widget_creation,
    executable = True,
    toolchains = PROGRAM_ASSETS_TOOLCHAINS,
    fragments = ["cpp"],
    exec_groups = PORTABLE_EXEC_GROUPS | {
        _RUN: exec_group(toolchains = [FLUTTER_EXEC_TOOLS, _RUN_HOST_TOOLCHAIN]),
    },
    doc = """Compiles a program as `flutter_test` compiles a test, and runs it \
under flutter_tester, the headless Flutter engine, as an ordinary executable: \
with `bazel run`, or as the tool of a build action, so outputs made with it \
need not be `testonly`.

The program is written as a test suite, because flutter_tester draws frames \
through `package:flutter_test`'s binding: its work is the bodies of its \
`testWidgets` and `test` calls. It exits 0 when every one passes and non-zero \
when one fails, as `flutter_test` reports a suite. Arguments are not passed to \
the program; the environment is, and the program runs in the working directory \
it was started in, Native Assets included, so a build action can hand it paths \
under the exec root. `enable_impeller` renders with Impeller, which needs the \
host's GPU: an action running one should not be sent to a remote executor.

Build it for the host it runs on: `bazel run` does, and a rule that runs it in \
an action takes it as an executable attribute with `cfg = "exec"`, as a \
`genrule` takes its `tools`.""",
)

# What the test target takes of the attributes `flutter_test` is given: the
# ones only a run has. Everything else is for the compile, except what both take.
_RUN_ATTRS = [
    "args",
    "env",
    "exclude_tags",
    "flaky",
    "include_tags",
    "local",
    "shard_count",
    "size",
    "timeout",
]

# What both targets take: `data` is the program's runfiles and the test's own
# (where `args` can name it), and the rest place the pair alike. The program is
# as visible as the test, so that it can be built, analyzed and depended on
# wherever the test can.
_SHARED_ATTRS = [
    "compatible_with",
    "data",
    "deprecation",
    "exec_compatible_with",
    "exec_properties",
    "features",
    "restricted_to",
    "tags",
    "target_compatible_with",
    "visibility",
]

def flutter_test(name, **kwargs):
    """Compiles a Flutter widget test, then runs it under flutter_tester.

    Tier 1 of the test rules: declares a `flutter_test_program` named
    `<name>.program` that compiles the test, and the
    test `<name>` that runs it, whose kind is `flutter_test`. Every attribute
    of either rule, and of a Bazel test, can be given here: the compile's
    (`main`, `srcs`, `deps`, `package`, `application`, `defines`,
    `flavor`, `assets`, `enable_impeller`, `test_config`, ...) go to the
    program, the run's (`include_tags`, `exclude_tags`, `env`, `size`,
    `timeout`, `shard_count`, `args`, ...) to the test, and `data`, `tags`,
    `visibility` and the platform constraints to both.

    Args:
        name: Test name.
        **kwargs: The attributes of `flutter_test_program` and
            `flutter_program_test`, and the common ones of a test.
    """
    program = {"testonly": True}
    test = {"program": ":" + name + ".program"}
    for key, value in kwargs.items():
        if key in _RUN_ATTRS:
            test[key] = value
        elif key in _SHARED_ATTRS:
            test[key] = value
            program[key] = value
        elif key == "exec_group_compatible_with":
            # A group is the test's, or the compile's.
            for group, constraints in value.items():
                target = test if group == "test" else program
                target.setdefault(key, {})[group] = constraints
        elif key != "testonly":
            program[key] = value
    flutter_test_program(name = name + ".program", **program)
    _flutter_test_rule(name = name, **test)
