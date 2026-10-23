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
  2. The user's test + bootstrap are compiled together to a kernel `.dill` via
     the standard frontend_server (debug platform dill, `--enable-asserts`).
  3. The runner binary spawns `flutter_tester` with the dill, hosts a localhost
     WebSocket harness, drives the `package:test` MultiChannel protocol, and
     reports per-test pass/fail.

Coverage: when `bazel coverage` sets `COVERAGE_OUTPUT_FILE`, the runner
launches `flutter_tester` with the VM service enabled and collects source
reports via JSON-RPC, writing LCOV.

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

load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "MODULAR_KERNEL_ATTRS",
    "MODULAR_KERNEL_TOOLCHAINS",
    "collect_packages",
    "collect_transitive_srcs",
    "dart_analyzable_info_with_package",
    "derive_lib_root",
)
load("//flutter:providers.bzl", "FlutterInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_location",
    "app_scheme_location",
    "compile_kernel_package_config",
    "synthesize_app_package",
)
load(
    "//flutter/private:common.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "FLUTTER_APPLICATION_ATTRS",
    "FLUTTER_DEPS_DOC",
    "LIBRARY_TAGS_TOOL_ATTR",
    "PLATFORM_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "declare_flutter_assets_dir",
    "detect_target_platform",
    "extract_library_tags_action",
    "flutter_build_assets",
    "flutter_compile_shaders",
    "flutter_tester_shader_aspect",
    "host_target_arch",
    "merge_dart_defines",
)
load("//flutter/private:flutter_compile.bzl", "flutter_kernel_compile_action")
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "compile_flutter_modular_test_kernel",
    "flutter_kernel_module_aspect",
    "flutter_modular_test_tools",
)
load("//flutter/private:flutter_native_assets.bzl", "bridge_dart_code_assets", "collect_bundled_code_asset_files", "write_native_assets_manifest")
load(
    "//flutter/private:flutter_test_common.bzl",
    _can_bootstrap = "can_bootstrap",
    _flutter_test_bootstrap_action = "flutter_test_bootstrap_action",
    _flutter_test_runner = "flutter_test_runner",
    _make_bootstrap_content = "make_bootstrap_content",
)

# Re-exported from `//flutter/private:flutter_test_common.bzl`, which holds the
# bootstrap implementation both test rules share. Kept under this name so
# existing loads of `make_bootstrap_content` from this module keep working.
make_bootstrap_content = _make_bootstrap_content

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

    # Per-target bootstrap. Imports the user's test via its `package:` URI when
    # `main` sits under `<lib_root>/lib/` and via `org-dartlang-app:///<stable_path>`
    # otherwise. Written by the shared helper, which also stages the golden
    # comparator next to it (a symlink, as `flutter_application` stages
    # `agent_extensions/agent.dart`) exactly when the suite carries
    # `package:flutter_test`.
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")
    test_import = app_main_location(ctx.attr.package_name, lib_root, ctx.file.main).uri
    staged_comparator = _flutter_test_bootstrap_action(ctx, test_import, bootstrap)

    packages = collect_packages(ctx.attr.deps)

    # Register the test's own package (when declared) so `package:<self>/foo`
    # imports inside test sources resolve across the multi-root `org-dartlang-app:///`
    # scheme without copying sources.
    packages = synthesize_app_package(
        ctx.label,
        packages,
        ctx.attr.package_name,
        lib_root,
        ctx.attr.language_version,
    )

    # Compile bootstrap+test to kernel modularly when eligible, falling back
    # to whole-program compilation otherwise (e.g. per-test defines or code assets).
    # Both paths compile against the debug platform dill with assertions enabled
    # (`--enable-asserts` on `frontend_server`, and `AssertStatement` /
    # `AssertInitializer` preservation in `.flutter.kmod` / `.flutter_entry.kmod`
    # under `flutter_tester --enable-checked-mode`).
    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    own_files = [ctx.file.main] + [f for f in ctx.files.srcs if f != ctx.file.main]
    modular_tools = flutter_modular_test_tools(
        ctx,
        flutter_sdk_info,
        own_files,
        packages,
        native_assets_list,
    )
    base_dill = None
    if modular_tools != None:
        base_dill = compile_flutter_modular_test_kernel(
            ctx,
            flutter_sdk_info,
            modular_tools,
            bootstrap,
            staged_comparator,
            lib_root,
            packages,
            kernel_dill,
        )
    else:
        all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list() + [ctx.file.main, bootstrap]
        if staged_comparator:
            all_srcs.append(staged_comparator)
        pc = compile_kernel_package_config(
            ctx,
            packages,
            all_srcs,
            roots = {ctx.attr.package_name: True} if ctx.attr.package_name else None,
        )
        flutter_kernel_compile_action(
            ctx = ctx,
            dartaotruntime = flutter_sdk_info.dartaotruntime,
            kernel_filter_tool = ctx.executable._kernel_filter_tool,
            frontend_server = flutter_sdk_info.frontend_server,
            platform_dill = flutter_sdk_info.platform_kernel_dill,
            main = bootstrap,
            entrypoint_uri = app_scheme_location(bootstrap).uri,
            srcs = pc.srcs,
            package_config = pc.config_file,
            output = kernel_dill,
            aot = False,
            defines = merge_dart_defines(ctx),
            target = "flutter",
            native_assets_manifest = native_assets_manifest,
        )

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
        target_platform = "tester",
        kernel_dill = kernel_dill,
        is_debug = True,
    )

    # The entrypoint's own `@Tags`, extracted at build time (see
    # `extract_library_tags_action`): the runner injects them as the root
    # group's metadata, so they inherit down to every test in the suite.
    library_tags = extract_library_tags_action(ctx, ctx.file.main)

    # The test run itself: the executable symlink, the `FLUTTER_TEST_*` env and
    # the runfiles, all from the implementation `flutter_prebuilt_test`
    # shares — one runner contract, no copy of it.
    runner = _flutter_test_runner(
        ctx,
        dill = kernel_dill,
        base_dill = base_dill,
        assets_dir = flutter_assets,
        library_tags = library_tags,
        test_path = ctx.file.main.short_path,
        enable_impeller = ctx.attr.enable_impeller,
        include_tags = ctx.attr.include_tags,
        exclude_tags = ctx.attr.exclude_tags,
        user_env = ctx.attr.env,
        data = ctx.attr.data,
        # The bundled native-asset libraries ship here, at the runfiles-relative
        # paths the manifest names. Both arms re-declare the library into an
        # output namespace of their own first — `flutter_native_asset` under
        # its `bundle_filename`, `bridge_dart_code_assets` under this rule's —
        # so what lands in runfiles is the File the manifest points at rather
        # than the `_solib_<arch>/` original.
        extra_files = bundled_code_assets.to_list(),
    )
    executable = runner.executable
    runfiles = runner.runfiles
    env_info = runner.env

    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs", "main"],
        dependency_attributes = ["deps"],
    )

    generated_dart_srcs = [
        f
        for f in ctx.files.srcs
        if f.extension == "dart" and not f.is_source
    ]

    return [
        DefaultInfo(
            executable = executable,
            files = depset([executable] + generated_dart_srcs),
            runfiles = runfiles,
        ),
        env_info,
        instrumented_files_info,
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
        # The test's own build products, for `flutter_prebuilt_test` to run
        # without compiling: `test_kernel` is exactly the test `.dill`,
        # `test_base_kernel` the base dill it links against at run time
        # (empty when the kernel was compiled whole-program),
        # `test_assets` its `flutter_assets/` tree, and `test_library_tags`
        # the entrypoint's `@Tags` as a `{"tags": [...]}` JSON file, for
        # `flutter_prebuilt_test`'s `library_tags`. A `filegroup` with
        # `output_group` on one of these feeds the matching
        # `flutter_prebuilt_test` attr.
        OutputGroupInfo(
            test_kernel = depset([kernel_dill]),
            test_base_kernel = depset([base_dill]) if base_dill != None else depset(),
            test_assets = depset([flutter_assets]),
            test_library_tags = depset([library_tags]),
        ),
    ]

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
        "_incremental_kernel",
        "_incr_worker_tool",
        "license_files",
        "tree_shake_icons",
        "_asset_bundle_tool",
    )
}
_TEST_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_tester_shader_aspect, flutter_kernel_module_aspect],
)

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
# The `FLUTTER_TEST_*` keys the runner reads are its start-up contract;
# supplying one in `env` is rejected in the implementation rather than
# silently honoured or silently dropped. Tag selection is the exception with
# its own channel: a `--test_env=FLUTTER_TEST_TAGS=...` (or
# `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute.
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
          "FLUTTER_TEST_* keys the runner reads cannot be set here; " +
          "override tag selection at run time with " +
          "--test_env=FLUTTER_TEST_TAGS=... instead.",
)

# Tag selection, as `flutter test --tags` / `--exclude-tags` resolve it.
# Named `include_tags` / `exclude_tags` rather than `tags` because Bazel's
# own `tags` attribute means something else. A `--test_env=FLUTTER_TEST_TAGS=...`
# (or `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute.
#
# Library-level `@Tags` on the entrypoint need no attribute: they are extracted
# at build time and always honoured (see `extract_library_tags_action`).
_TEST_ATTRS["include_tags"] = attr.string_list(
    doc = "Run only tests matching every one of these `package:test` tag " +
          "selectors (library, group or test level), as `flutter test " +
          "--tags` intersects them. Each entry is a boolean selector " +
          "(`a && b`, `a || b`, `!a`, parentheses); several entries, or " +
          "comma-separated values in one entry, all have to match. A test " +
          "matching an `exclude_tags` selector never runs. An attribute " +
          "selection that matches no test fails the target, so a tag name " +
          "nobody carries is a typo, not an empty pass.",
)
_TEST_ATTRS["exclude_tags"] = attr.string_list(
    doc = "Skip tests matching any of these `package:test` tag selectors " +
          "(library, group or test level), as `flutter test " +
          "--exclude-tags` unions them. Wins over `include_tags`.",
)
_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_TEST_ATTRS.update(MODULAR_KERNEL_ATTRS)
_TEST_ATTRS["_library_tags_tool"] = LIBRARY_TAGS_TOOL_ATTR
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
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter widget test, then runs it under flutter_tester " +
          "via the package:test_api RemoteListener protocol.",
)
