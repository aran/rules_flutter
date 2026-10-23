"""Shared utilities for Flutter rules.

Package config generation, transitive source collection, and the shared
compilation pipeline (kernel → AOT → assets → FFI collection) used by
flutter_application, flutter_android_bundle, and flutter_ios_application.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_srcs", "derive_lib_root", "generate_dev_package_config", _COPY_TO_DIRECTORY_TOOLCHAINS = "COPY_TO_DIRECTORY_TOOLCHAINS")
load("//flutter:providers.bzl", "FlutterCompiledShadersInfo", "FlutterInfo", "FlutterNativeLibraryInfo", _resolve_exec_dart = "resolve_exec_dart", _resolve_exec_dart_vm = "resolve_exec_dart_vm", _resolve_flutter_sdk_info = "resolve_flutter_sdk_info")
load("//flutter/private:app_entrypoint.bzl", "APP_SCHEME", "app_main_location", "app_scheme_location", "app_scheme_sources", "compile_kernel_package_config", "resolve_kernel_entrypoint", "synthesize_app_package", "with_root")
load("//flutter/private:asset_keys.bzl", "bundle_asset_entries", "is_within_package", "relative_key")
load("//flutter/private:flutter_asset_bundle_action.bzl", "flutter_asset_bundle_action")
load("//flutter/private:flutter_compile.bzl", "flutter_kernel_compile_action")
load("//flutter/private:flutter_info.bzl", "dedup_plugins")
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "compile_flutter_modular_app_kernel",
    "flutter_modular_test_tools",
)
load("//flutter/private:flutter_library.bzl", "aggregate_pub_contributions", "build_pub_contributions", "resolve_font_subset_tools")
load("//flutter/private:flutter_shader_compile.bzl", "flutter_shader_compile_action")
load("//flutter/private:native_sources.bzl", "native_sources_aspect")
load("//flutter/private:plugin_registrant.bzl", "generate_dart_plugin_registrant", "generate_dev_plugin_registrants")
load("//flutter/private:validation.bzl", "validate_dart_defines")

COPY_TO_DIRECTORY_TOOLCHAINS = _COPY_TO_DIRECTORY_TOOLCHAINS
resolve_exec_dart = _resolve_exec_dart
resolve_exec_dart_vm = _resolve_exec_dart_vm
resolve_flutter_sdk_info = _resolve_flutter_sdk_info

def _web_ui_web_head_lines():
    """Imports, `bootstrapEngine` and handler stubs heading the `dart:ui_web` stub."""
    return [
        "// GENERATED — do not edit.",
        "// ignore_for_file: type=lint",
        "import 'dart:async';",
        "import 'dart:ui' as ui;",
        "",
        "Future<void> bootstrapEngine({",
        "  FutureOr<void> Function()? runApp,",
        "  FutureOr<void> Function()? registerPlugins,",
        "}) async {",
        "  await registerPlugins?.call();",
        "  await runApp?.call();",
        "}",
        "",
        "void setPluginHandler(ui.PlatformMessageCallback handler) {}",
        "",
        "typedef EventListener = dynamic Function(Object event);",
        "typedef PopStateListener = void Function(Object? state);",
        "",
    ]

def _web_shared_navigation_lines():
    """`PlatformLocation`/`BrowserPlatformLocation`/`UrlStrategy` stubs.

    Shared verbatim by the `dart:ui_web` and `flutter_web_plugins` stubs:
    both stand in for web-only navigation types when compiling against a
    platform without them.
    """
    return [
        "abstract interface class PlatformLocation {",
        "  void addPopStateListener(EventListener fn);",
        "  void removePopStateListener(EventListener fn);",
        "  String get pathname;",
        "  String get search;",
        "  String get hash;",
        "  Object? get state;",
        "  void pushState(Object? state, String title, String url);",
        "  void replaceState(Object? state, String title, String url);",
        "  void go(int count);",
        "  String? getBaseHref();",
        "}",
        "",
        "class BrowserPlatformLocation implements PlatformLocation {",
        "  const BrowserPlatformLocation();",
        "",
        "  @override",
        "  void addPopStateListener(EventListener fn) {}",
        "",
        "  @override",
        "  void removePopStateListener(EventListener fn) {}",
        "",
        "  @override",
        "  String get pathname => '';",
        "",
        "  @override",
        "  String get search => '';",
        "",
        "  @override",
        "  String get hash => '';",
        "",
        "  @override",
        "  Object? get state => null;",
        "",
        "  @override",
        "  void pushState(Object? state, String title, String url) {}",
        "",
        "  @override",
        "  void replaceState(Object? state, String title, String url) {}",
        "",
        "  @override",
        "  void go(int count) {}",
        "",
        "  @override",
        "  String? getBaseHref() => null;",
        "}",
        "",
        "abstract class UrlStrategy {",
        "  const UrlStrategy();",
        "",
        "  ui.VoidCallback addPopStateListener(PopStateListener fn) => () {};",
        "  String getPath() => '';",
        "  Object? getState() => null;",
        "  String prepareExternalUrl(String internalUrl) => '';",
        "  void pushState(Object? state, String title, String url) {}",
        "  void replaceState(Object? state, String title, String url) {}",
        "  Future<void> go(int count) async {}",
        "}",
        "",
    ]

def _web_ui_web_tail_lines():
    """The default `urlStrategy` and `HashUrlStrategy` closing the `dart:ui_web` stub."""
    return [
        "UrlStrategy? urlStrategy;",
        "",
        "class HashUrlStrategy extends UrlStrategy {",
        "  const HashUrlStrategy([",
        "    this._platformLocation = const BrowserPlatformLocation(),",
        "  ]);",
        "",
        "  final PlatformLocation _platformLocation;",
        "",
        "  @override",
        "  String getPath() => _platformLocation.hash;",
        "}",
        "",
    ]

def make_web_ui_web_stub_content():
    """Generate a VM-compatible stub for `dart:ui_web` used during icon tree-shaking kernel compilation.

    Provides the `dart:ui_web` entrypoints referenced by the web bootstrap
    wrapper (`bootstrapEngine`) and by the real `package:flutter_web_plugins`
    sources (`setPluginHandler` and the URL strategy / platform location types
    re-exported by `src/navigation/url_strategy.dart`) for compiles against a
    platform without `dart:ui_web`, which select it through the wrapper's
    conditional import.
    """
    return "\n".join(_web_ui_web_head_lines() + _web_shared_navigation_lines() + _web_ui_web_tail_lines())

def _web_plugins_base_import_lines():
    """The `library` and `dart:` imports heading the `flutter_web_plugins` stub."""
    return [
        "// GENERATED — do not edit.",
        "// ignore_for_file: type=lint",
        "library flutter_web_plugins;",
        "",
        "import 'dart:async';",
        "import 'dart:typed_data';",
        "import 'dart:ui' as ui;",
    ]

def _web_plugins_foundation_import_lines():
    """`package:flutter` imports when `flutter/services.dart` is present."""
    return [
        "",
        "import 'package:flutter/foundation.dart';",
        "import 'package:flutter/services.dart';",
    ]

def _web_plugins_local_channel_lines():
    """Local `BinaryMessenger`/`MethodCodec` stubs when `flutter/services.dart` is absent."""
    return [
        "",
        "typedef MessageHandler = Future<ByteData?> Function(ByteData? message);",
        "",
        "abstract class BinaryMessenger {",
        "  const BinaryMessenger();",
        "  Future<void> handlePlatformMessage(",
        "    String channel,",
        "    ByteData? data,",
        "    ui.PlatformMessageResponseCallback? callback,",
        "  );",
        "  Future<ByteData?>? send(String channel, ByteData? message);",
        "  void setMessageHandler(String channel, MessageHandler? handler);",
        "}",
        "",
        "class MethodCall {",
        "  const MethodCall(this.method, [this.arguments]);",
        "  final String method;",
        "  final dynamic arguments;",
        "}",
        "",
        "abstract class MethodCodec {",
        "  const MethodCodec();",
        "  ByteData? encodeMethodCall(MethodCall methodCall);",
        "  MethodCall decodeMethodCall(ByteData? methodCall);",
        "  dynamic decodeEnvelope(ByteData envelope);",
        "  ByteData encodeSuccessEnvelope(Object? result);",
        "  ByteData encodeErrorEnvelope({",
        "    required String code,",
        "    String? message,",
        "    Object? details,",
        "  });",
        "}",
        "",
        "class StandardMethodCodec implements MethodCodec {",
        "  const StandardMethodCodec();",
        "",
        "  @override",
        "  ByteData? encodeMethodCall(MethodCall methodCall) => null;",
        "",
        "  @override",
        "  MethodCall decodeMethodCall(ByteData? methodCall) => const MethodCall('');",
        "",
        "  @override",
        "  dynamic decodeEnvelope(ByteData envelope) => null;",
        "",
        "  @override",
        "  ByteData encodeSuccessEnvelope(Object? result) => ByteData(0);",
        "",
        "  @override",
        "  ByteData encodeErrorEnvelope({",
        "    required String code,",
        "    String? message,",
        "    Object? details,",
        "  }) => ByteData(0);",
        "}",
    ]

def _web_plugins_messenger_lines():
    """The `Registrar`/`PluginRegistry`/`PluginEventChannel` section of the plugins stub."""
    return [
        "",
        "class Registrar extends BinaryMessenger {",
        "  Registrar([BinaryMessenger? binaryMessenger]);",
        "",
        "  void registerMessageHandler() {}",
        "",
        "  @override",
        "  Future<void> handlePlatformMessage(",
        "    String channel,",
        "    ByteData? data,",
        "    ui.PlatformMessageResponseCallback? callback,",
        "  ) => handleFrameworkMessage(channel, data, callback);",
        "",
        "  Future<void> handleFrameworkMessage(",
        "    String channel,",
        "    ByteData? data,",
        "    ui.PlatformMessageResponseCallback? callback,",
        "  ) async {",
        "    callback?.call(null);",
        "  }",
        "",
        "  BinaryMessenger get messenger => this;",
        "",
        "  @override",
        "  Future<ByteData?> send(String channel, ByteData? message) async => null;",
        "",
        "  @override",
        "  void setMessageHandler(String channel, MessageHandler? handler) {}",
        "}",
        "",
        "class PluginRegistry extends Registrar {",
        "  PluginRegistry([BinaryMessenger? binaryMessenger]) : super(binaryMessenger);",
        "",
        "  Registrar registrarFor(Type key) => this;",
        "}",
        "",
        "final Registrar webPluginRegistrar = PluginRegistry();",
        "",
        "PluginRegistry get webPluginRegistry => webPluginRegistrar as PluginRegistry;",
        "",
        "BinaryMessenger get pluginBinaryMessenger => webPluginRegistrar;",
        "",
        "class PluginEventChannel<T> {",
        "  const PluginEventChannel(",
        "    this.name, [",
        "    this.codec = const StandardMethodCodec(),",
        "    this.binaryMessenger,",
        "  ]);",
        "",
        "  final String name;",
        "  final MethodCodec codec;",
        "  final BinaryMessenger? binaryMessenger;",
        "",
        "  set controller(StreamController<T> controller) {",
        "    setController(controller);",
        "  }",
        "",
        "  void setController(StreamController<T>? controller) {}",
        "}",
        "",
    ]

def _web_plugins_typedef_lines():
    """The navigation listener typedefs shared with the `dart:ui_web` stub header."""
    return [
        "typedef EventListener = dynamic Function(Object event);",
        "typedef PopStateListener = void Function(Object? state);",
        "",
    ]

def _web_plugins_strategy_tail_lines():
    """The `urlStrategy` accessors and path-strategy helpers closing the plugins stub."""
    return [
        "UrlStrategy? get urlStrategy => null;",
        "void setUrlStrategy(UrlStrategy? strategy) {}",
        "void usePathUrlStrategy() {}",
        "",
        "class HashUrlStrategy extends UrlStrategy {",
        "  const HashUrlStrategy([",
        "    this._platformLocation = const BrowserPlatformLocation(),",
        "  ]);",
        "",
        "  final PlatformLocation _platformLocation;",
        "",
        "  @override",
        "  String getPath() => _platformLocation.hash;",
        "}",
        "",
        "class PathUrlStrategy extends HashUrlStrategy {",
        "  PathUrlStrategy([",
        "    super.platformLocation,",
        "    this.includeHash = false,",
        "  ]);",
        "",
        "  final bool includeHash;",
        "}",
        "",
        "String extractPathname(String url) => ensureLeadingSlash(Uri.parse(url).path);",
        "String checkBaseHref(String? baseHref) => baseHref ?? '/';",
        "String ensureLeadingSlash(String path) => path.startsWith('/') ? path : '/$path';",
        "String stripTrailingSlash(String path) =>",
        "    path.endsWith('/') ? path.substring(0, path.length - 1) : path;",
        "",
    ]

def make_web_plugins_stub_content(has_flutter_services = False):
    """Generate a fallback `package:flutter_web_plugins/flutter_web_plugins.dart` for synthetic test targets without `@deps//:flutter_web_plugins`.

    Args:
        has_flutter_services: Whether `package:flutter/services.dart` is present
            in the target's `flutter` package sources.

    Returns:
        String of Dart source code.
    """
    header = _web_plugins_base_import_lines()
    if has_flutter_services:
        header += _web_plugins_foundation_import_lines()
    else:
        header += _web_plugins_local_channel_lines()
    return "\n".join(
        header + _web_plugins_messenger_lines() + _web_plugins_typedef_lines() +
        _web_shared_navigation_lines() + _web_plugins_strategy_tail_lines(),
    )

def make_web_wrapper_main_content(original_import, registrant_import = None, ui_web_stub_import = None):
    """Generate a web wrapper main.dart that uses ui_web.bootstrapEngine().

    Flutter web requires ui_web.bootstrapEngine() to properly initialize the
    engine (create the implicit view, set up the platform dispatcher, etc.)
    before calling the user's main(). Without this, runApp() fails with
    "The app requested a view, but the platform did not provide one."

    This matches the wrapper that `flutter build web` generates.

    Args:
        original_import: Import URI for the original main.
        registrant_import: Optional relative import path for the generated
            registrant file. If None, plugin registration is a no-op.
        ui_web_stub_import: Optional relative import path for a VM-compatible
            `dart:ui_web` stub, conditionally selected when `dart.library.ui_web`
            is absent (as in the `--target=flutter` icon tree-shaking kernel).

    Returns:
        String of Dart source code.
    """
    ui_web_import = (
        "import '%s' if (dart.library.ui_web) 'dart:ui_web' as ui_web;" % ui_web_stub_import if ui_web_stub_import else "import 'dart:ui_web' as ui_web;"
    )
    lines = [
        "// GENERATED — do not edit.",
        "// Flutter web bootstrap script.",
        "// ignore_for_file: type=lint",
        "",
        ui_web_import,
        "import 'dart:async';",
        "",
        "import '%s' as entrypoint;" % original_import,
    ]
    if registrant_import:
        lines.append("import '%s' as pluginRegistrant;" % registrant_import)
    lines.extend([
        "",
        "typedef _UnaryFunction = dynamic Function(List<String> args);",
        "typedef _NullaryFunction = dynamic Function();",
        "",
        "Future<void> main() async {",
        "  await ui_web.bootstrapEngine(",
        "    runApp: () {",
        "      if (entrypoint.main is _UnaryFunction) {",
        "        return (entrypoint.main as _UnaryFunction)(<String>[]);",
        "      }",
        "      return (entrypoint.main as _NullaryFunction)();",
        "    },",
    ])
    if registrant_import:
        lines.append("    registerPlugins: () {")
        lines.append("      pluginRegistrant.registerPlugins();")
        lines.append("    },")
    lines.extend([
        "  );",
        "}",
        "",
    ])
    return "\n".join(lines)

def check_unreplaced_hooks(label, deps):
    """Returns an error naming pub packages whose build hook nothing replaces.

    A pub package shipping `hook/build.dart` builds its native library at
    `pub get` time. Bazel cannot run that hook, so without a replacement the
    package's `@Native` bindings resolve to nothing: the manifest is simply
    missing an entry, and the failure surfaces at runtime as "couldn't resolve
    native function" with nothing pointing at the cause.

    Checked at the application rather than when the spoke repo is generated.
    `flutter.pub()` materialises the whole lock file, so failing at generation
    would fail over packages nothing depends on, and on platforms where the
    hook is irrelevant. Only a package an application actually reaches is a
    problem, and only here is the depending target known.

    rules_dart applies the same rule at `dart_binary` with its own copy. The
    two differ only in the remediation they suggest — a Flutter user fixes this
    through `flutter.pub()`, not `pub.from_lock()` — so this collapses into one
    shared helper once rules_dart exports one that takes the hint as an
    argument.

    Args:
      label: The consuming target's label, for the message.
      deps: The application's `deps`, each providing `DartInfo`.

    Returns:
      An error message string, or `None`.
    """
    packages = depset(
        transitive = [dep[DartInfo].transitive_packages for dep in deps],
    ).to_list()

    # Guarded for the same reason `bridge_dart_code_assets` guards
    # `code_assets`: `DartPackageInfo` is rules_dart's, and it deliberately
    # tolerates a record built against a rules_dart predating a field. Absent
    # is not "unknown" here — a producer with no such field could not have
    # recorded a hook — so it reads as "no hook". Unguarded, the read fails
    # analysis on records that are not even offenders.
    offenders = [
        pkg
        for pkg in packages
        if hasattr(pkg, "has_unreplaced_hook") and pkg.has_unreplaced_hook
    ]
    if not offenders:
        return None
    return (
        "%s depends on pub package(s) that build native code with a hook " +
        "Bazel cannot run:\n%s\n\n" +
        "Their `@Native` bindings will not resolve at runtime. Either:\n" +
        "  - add a `dart_code_asset` to the owning package's `code_assets` " +
        "(for a pub package, that means a `flutter.plugin_overlays` entry, " +
        "or a curated entry upstream in rules_dart), or\n" +
        "  - list the package in `flutter.pub(ignore_hooks = [...])` if its " +
        "native code is genuinely unused here."
    ) % (
        label,
        "\n".join([
            "  - %s (%s)" % (pkg.package_name, pkg.has_unreplaced_hook)
            for pkg in offenders
        ]),
    )

# Implicit attr for the build-time `@Tags` extractor (see
# `//flutter/private/tools:extract_library_tags`). The test isolate never
# parses annotations — `package:test`'s analyzer-backed loader does that for
# `flutter test`, but under `flutter_tester` only this action reads the
# entrypoint — so every test rule extracts the tags at build time and ships
# the JSON to the runner, which injects them as the root group's metadata.
LIBRARY_TAGS_TOOL_ATTR = attr.label(
    default = Label("//flutter/private/tools:extract_library_tags"),
    executable = True,
    cfg = "exec",
)

def extract_library_tags_action(ctx, main_file):
    """Extract the entrypoint's `@Tags` into a JSON file for the test runner.

    Only the entrypoint file is read. An imported file's own `@Tags` stays
    invisible, exactly as under `flutter test`: the test_core loader parses
    each suite file, and only the suite file's annotations become that suite's
    root metadata.

    Args:
        ctx: Rule context. Must declare `_library_tags_tool`
            (`LIBRARY_TAGS_TOOL_ATTR`).
        main_file: The test entrypoint source `File`.

    Returns:
        The `{"tags": [...]}` JSON `File`, to ship in runfiles and name from
        `FLUTTER_TEST_LIBRARY_TAGS`.
    """
    output = ctx.actions.declare_file(ctx.label.name + ".library_tags.json")
    ctx.actions.run(
        executable = ctx.executable._library_tags_tool,
        arguments = [main_file.path, output.path],
        inputs = [main_file],
        outputs = [output],
        mnemonic = "FlutterExtractLibraryTags",
        progress_message = "Extracting library tags %s" % ctx.label,
    )
    return output

def collect_native_libs(native_deps):
    """Collect shared libraries from native_deps for dart:ffi.

    Filters DefaultInfo files by extension (.so, .dylib, .dll).

    Args:
        native_deps: List of targets providing DefaultInfo with shared libs.

    Returns:
        List of shared library Files.
    """
    libs = []
    for dep in native_deps:
        for f in dep[DefaultInfo].files.to_list():
            if f.extension in ("so", "dylib", "dll"):
                libs.append(f)
    return libs

def resolve_dev_generated_sources(paths, candidates):
    """The Files behind `_dev_config.json`'s `generatedSourcePaths`.

    `_dev_config.json` sends the frontend_server to read these paths. Nothing
    asks for them by label, and being an action's *input* is not what makes bazel
    write a file to this machine — a cache hit (disk or remote) runs no action, so
    an input-only file is never materialized and the dev tool reports "the build
    declared files it did not write". Declaring them is what makes the paths true.

    Args:
        paths: The `generatedSourcePaths` going into the dev config.
        candidates: The Files the paths were derived from.

    Returns:
        The Files, in the order [paths] names them.
    """
    by_path = {f.path: f for f in candidates}
    missing = [p for p in paths if p not in by_path]
    if missing:
        fail(
            "dev config names generated sources with no File to declare: " +
            ", ".join(missing) +
            "\nThey would be written into _dev_config.json for the " +
            "frontend_server to read and never materialized by the build.",
        )
    return [by_path[p] for p in paths]

def collect_binding_contracts(native_deps):
    """Pair each `native_deps` entry's libraries with its declared binding contract.

    Only a `flutter_native_library` wrapper declares one. A bare shared library
    contributes a pair with an empty contract rather than being left out: "this
    library has nothing describing its bindings" is the state the dev tool has to
    be able to name, and a library missing from the map would read as a library
    that is not bundled.

    Args:
        native_deps: The `native_deps` targets, wrapped or bare.

    Returns:
        List of `struct(library = File, contract = tuple[File])`, one per shared
        library.
    """
    pairs = []
    for dep in native_deps:
        if FlutterNativeLibraryInfo in dep:
            info = dep[FlutterNativeLibraryInfo]
            contract = tuple(info.binding_contract.to_list())
            for lib in info.libraries.to_list():
                pairs.append(struct(library = lib, contract = contract))
        else:
            for f in dep[DefaultInfo].files.to_list():
                if f.extension in ("so", "dylib", "dll"):
                    pairs.append(struct(library = f, contract = ()))
    return pairs

def _kernel_source_inputs(ctx):
    """Collect the kernel compile's sources and synthesize the app package."""
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list()
    packages = collect_packages(ctx.attr.deps)

    # Register the app itself as a package so the frontend_server keys the
    # entrypoint as `package:<name>/main.dart` — the URI the dev tool's
    # incremental compiler uses (without this, hot-reload deltas keyed via
    # sandbox `file://` URIs can't be matched against the kernel's libraries).
    app_pkg_name = ctx.attr.package_name

    # The app's own library root, which is what `package:<name>/…` resolves
    # against. Derived from the label rather than assumed to be the workspace
    # root, so an app in a nested Bazel package registers a `rootUri` pointing
    # at its own directory; assuming `""` pointed every nested app's
    # `package:` URIs at whatever sits in the *workspace's* `lib/`.
    app_lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    packages = synthesize_app_package(
        ctx.label,
        packages,
        app_pkg_name,
        app_lib_root,
        ctx.attr.language_version,
    )

    # Include the app's own `main` so the synthesized package keyed as
    # `package:<name>/main.dart` (hot-reload URI parity) is co-located with
    # its lib/ siblings when any of them are generated.
    colocate_inputs = all_srcs + ([ctx.file.main] if ctx.file.main else [])
    return struct(
        all_srcs = all_srcs,
        packages = packages,
        app_pkg_name = app_pkg_name,
        app_lib_root = app_lib_root,
        colocate_inputs = colocate_inputs,
    )

def _kernel_dev_config(ctx, st, mode):
    """Write the debug-only dev package config; return the hot-reload metadata."""
    emit = mode == "debug"
    dev_package_config = None
    dev_filesystem_roots = []
    dev_filesystem_scheme = ""
    dev_generated_source_paths = []
    dev_generated_source_uris = []
    dev_generated_source_files = []
    dev_source_packages = []
    dev_app_sources = []
    main_location = app_main_location(st.app_pkg_name, st.app_lib_root, ctx.file.main) if ctx.file.main else None
    app_entrypoint_uri = main_location.uri if main_location else None
    if emit:
        dev_package_config = ctx.actions.declare_file(ctx.label.name + ".dev_package_config.json")
        dev_pc = generate_dev_package_config(st.packages, st.colocate_inputs, dev_package_config, scheme = APP_SCHEME)
        ctx.actions.write(dev_package_config, dev_pc.content)

        # A `main` with no `package:` URI is compiled under the app scheme,
        # and the dev loop's compiler has to mount the same root to name it
        # the same way.
        dev_filesystem_roots = with_root(dev_pc.filesystem_roots, main_location.root if main_location else None)
        dev_filesystem_scheme = dev_pc.scheme
        dev_app_sources = app_scheme_sources(st.app_pkg_name, st.app_lib_root, ctx.file.main, ctx.files.srcs) if ctx.file.main else []
        dev_generated_source_paths = dev_pc.generated_source_paths
        dev_generated_source_uris = dev_pc.generated_source_uris
        dev_source_packages = dev_pc.source_packages

        # Resolved from the same list the paths came from, so the two cannot
        # drift — see [resolve_dev_generated_sources] for why declaring them is
        # what makes the config's paths true.
        dev_generated_source_files = resolve_dev_generated_sources(
            dev_generated_source_paths,
            st.colocate_inputs,
        )
    return struct(
        emit = emit,
        package_config = dev_package_config,
        filesystem_roots = dev_filesystem_roots,
        filesystem_scheme = dev_filesystem_scheme,
        generated_source_paths = dev_generated_source_paths,
        generated_source_uris = dev_generated_source_uris,
        generated_source_files = dev_generated_source_files,
        source_packages = dev_source_packages,
        app_sources = dev_app_sources,
        entrypoint_uri = app_entrypoint_uri,
    )

def _resolve_kernel_platform_dill(platform_dill, aot, mode, flutter_sdk_info):
    """Resolve the platform dill for a kernel compile, failing when absent."""
    if platform_dill != None:
        return platform_dill

    # Profile and debug compile against the non-product platform: the product
    # one has the VM service and the profiling hooks compiled out, and is not
    # fetched in `-c dbg`.
    if aot and mode == "release":
        platform_dill = flutter_sdk_info.platform_kernel_dill_product
        if platform_dill == None:
            fail(
                "Unresolved @rules_flutter//flutter:product_tools_toolchain_type " +
                "(@rules_flutter//flutter/private:product_tools_toolchain_type): " +
                "Flutter toolchain does not provide platform_kernel_dill_product, " +
                "which is required for release AOT kernel compilation. Register " +
                "the Flutter toolchains (e.g. `flutter.toolchain()` in MODULE.bazel " +
                "or `register_toolchains(\"@flutter_toolchains//:all\")`) or set " +
                "`platform_kernel_dill_product` on `flutter_toolchain`.",
            )
        return platform_dill
    platform_dill = flutter_sdk_info.platform_kernel_dill
    if platform_dill == None:
        fail(
            "Unresolved @rules_flutter//flutter:toolchain_type: " +
            "Flutter toolchain does not provide platform_kernel_dill. " +
            "Register a Flutter toolchain (e.g. `flutter.toolchain()` in " +
            "MODULE.bazel) or set `platform_kernel_dill` on `flutter_toolchain`.",
        )
    return platform_dill

def _stage_agent_extensions(ctx, aot, mode):
    """Stage the debug-agent sources next to the registrant in debug builds."""

    # AI-agent service-extension injection: in debug builds (non-AOT), if the
    # rule carries an `_agent_extensions_src` attr, stage the agent source next
    # to the generated registrant, which registers the extensions from the
    # engine's pre-main plugin-registrant hook. Release/AOT/profile builds skip
    # this entirely — profile mode is for performance investigation where added
    # instrumentation distorts measurements, so it must look the same as
    # release on the agent surface.
    agent_src_attr = getattr(ctx.attr, "_agent_extensions_src", None)
    inject_agent = (not aot) and mode == "debug" and agent_src_attr != None
    staged_agent = None
    staged_native_agent = None
    if inject_agent:
        staged_agent = ctx.actions.declare_file(ctx.label.name + ".agent_extensions.dart")
        ctx.actions.symlink(output = staged_agent, target_file = ctx.file._agent_extensions_src)

        # The native-only half (`dart:ffi`): loading a native hot patch. A
        # kernel compile is always native — web stages `agent.dart` alone, in
        # its own rule.
        staged_native_agent = ctx.actions.declare_file(ctx.label.name + ".native_agent_extensions.dart")
        ctx.actions.symlink(output = staged_native_agent, target_file = ctx.file._native_agent_extensions_src)
    return struct(agent = staged_agent, native_agent = staged_native_agent)

def _kernel_registrant(ctx, target_platform, agent, emit_dev_config):
    """Collect plugins and generate the registrant plus dev-loop registrants."""

    # Collect plugins from deps and generate the registrant. The registrant is
    # a side library (upstream _PluginRegistrant shape) the engine invokes
    # before main() on every root-isolate launch — including hot restart.
    all_dep_plugins = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
    plugins = dedup_plugins(all_dep_plugins)
    registrant = generate_dart_plugin_registrant(
        ctx,
        plugins,
        target_platform = target_platform,
        agent_import = agent.agent.basename if agent.agent else None,
        native_agent_import = agent.native_agent.basename if agent.native_agent else None,
    )
    registrant_location = app_scheme_location(registrant) if registrant else None

    # Dev-loop registrants, one per platform (debug only). The dev tool reads
    # these from a HOST-configuration build while the app can be running on a
    # different platform, so the host build emits every platform's filter and
    # the dev tool selects by the platform the running app reports. See
    # generate_dev_plugin_registrants.
    dev_plugin_registrants = {}
    if emit_dev_config:
        dev_plugin_registrants = generate_dev_plugin_registrants(
            ctx,
            plugins,
            agent_import = agent.agent.basename if agent.agent else None,
            native_agent_import = agent.native_agent.basename if agent.native_agent else None,
        )
    return struct(registrant = registrant, location = registrant_location, dev_registrants = dev_plugin_registrants)

def _kernel_compile_flags(ctx, track_widget_creation, mode, aot, assets_dir, platform_build_args, target_platform):
    """Merge frontend flags and defines for a kernel compile."""

    # Collect extra frontend_server flags from build flag attrs.
    extra_frontend_flags = []
    if track_widget_creation:
        extra_frontend_flags.append("--track-widget-creation")

    # Merge defines with mode-specific Dart VM flags. user_defines (attr +
    # extra_dart_defines flag, no mode keys) is surfaced in the return struct
    # so dev-config writers can replay it on the dev tool's frontend_server.
    user_defines = merge_dart_defines(ctx)
    all_defines = list(user_defines)
    if mode == "profile":
        all_defines.append("dart.vm.profile=true")
    elif aot:
        all_defines.append("dart.vm.product=true")

    # A debug app describes its own build to itself. `ext.rules_flutter.buildInfo`
    # hands this straight back to the dev tool, which needs it because
    # `flutter_bazel attach` starts from nothing but a VM service URL: it has no
    # `-d` device, no knowledge of the configuration, and no way to ask the user
    # for flags they never typed. Debug only — profile mode must look like
    # release on the agent surface, and there is no dev loop to serve in AOT.
    #
    # Deliberately NOT added to `user_defines`: that list is replayed by the dev
    # tool's own frontend_server, which runs against the host-configured dev
    # build. Replaying this one would have the app start reporting the dev
    # pipeline's configuration as its launch truth. The dev tool re-injects the
    # value it read from the running app instead.
    if assets_dir != None and not aot and mode == "debug":
        all_defines.append("rules_flutter.build_info=" + json.encode({
            "label": str(ctx.label),
            "compilationMode": ctx.var["COMPILATION_MODE"],
            "platformBuildArgs": platform_build_args,
            "dartDefines": user_defines,
            "assetsDir": assets_dir.path,
            # The platform this kernel was compiled for. The dev tool's own
            # build runs in the host configuration, so only the app can say
            # which platform-filtered plugin registrant its reloads need.
            "targetPlatform": target_platform,
        }))
    return struct(extra_frontend = extra_frontend_flags, user_defines = user_defines, all_defines = all_defines)

def _use_modular_kernel(mode, aot, frontend_server_target, registrant, staged_agent, native_assets_manifest, recorded_uses, extra_frontend_flags, all_defines):
    return (
        not aot and mode != "profile" and
        frontend_server_target == "flutter" and
        not registrant and not staged_agent and
        not native_assets_manifest and not recorded_uses and
        not extra_frontend_flags and not all_defines
    )

def _modular_tools_or_none(ctx, flutter_sdk_info, packages):
    """The modular kernel tools, or None when the target needs a whole-program compile."""
    own_files = [ctx.file.main] + [f for f in ctx.files.srcs if f != ctx.file.main]
    return flutter_modular_test_tools(
        ctx,
        flutter_sdk_info,
        own_files,
        packages,
        [],
    )

def _compile_modular_kernel(ctx, app_lib_root, packages, kernel_dill, platform_dill, modular_tools):
    compile_flutter_modular_app_kernel(
        ctx,
        modular_tools,
        app_lib_root,
        packages,
        kernel_dill,
        platform_dill,
    )

def _compile_full_kernel(ctx, flutter_sdk_info, kernel_dill, platform_dill, st, agent, reg, flags, opts):
    pc = compile_kernel_package_config(
        ctx,
        st.packages,
        st.colocate_inputs,
        roots = {st.app_pkg_name: True} if st.app_pkg_name else None,
    )
    config_file = pc.config_file
    all_srcs = pc.srcs
    if reg.registrant:
        all_srcs = all_srcs + [reg.registrant]
    if agent.agent:
        all_srcs = all_srcs + [agent.agent, agent.native_agent]

    # Resolve the kernel entrypoint: the user's main, keyed by its package:
    # URI for hot-reload parity with the dev tool.
    entrypoint_info = resolve_kernel_entrypoint(ctx, st.app_pkg_name, st.app_lib_root)
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        kernel_filter_tool = ctx.executable._kernel_filter_tool,
        frontend_server = flutter_sdk_info.frontend_server,
        platform_dill = platform_dill,
        main = entrypoint_info.file,
        entrypoint_uri = entrypoint_info.uri,
        srcs = all_srcs,
        package_config = config_file,
        output = kernel_dill,
        aot = opts.aot,
        defines = flags.all_defines,
        target = opts.frontend_server_target,
        extra_flags = flags.extra_frontend,
        native_assets_manifest = opts.native_assets_manifest,
        dart_plugin_registrant_uri = reg.location.uri if reg.location else None,
        recorded_uses = opts.recorded_uses,
    )
    return config_file

def _run_kernel_compile(ctx, flutter_sdk_info, kernel_dill, platform_dill, st, agent, reg, flags, opts):
    if _use_modular_kernel(
        opts.mode,
        opts.aot,
        opts.frontend_server_target,
        reg.registrant,
        agent.agent,
        opts.native_assets_manifest,
        opts.recorded_uses,
        flags.extra_frontend,
        flags.all_defines,
    ):
        modular_tools = _modular_tools_or_none(ctx, flutter_sdk_info, st.packages)
        if modular_tools != None:
            _compile_modular_kernel(ctx, st.app_lib_root, st.packages, kernel_dill, platform_dill, modular_tools)
            return None
    return _compile_full_kernel(ctx, flutter_sdk_info, kernel_dill, platform_dill, st, agent, reg, flags, opts)

def flutter_compile_kernel(ctx, flutter_sdk_info, aot = None, platform_dill = None, target_platform = None, frontend_server_target = "flutter", native_assets_manifest = None, track_widget_creation = False, assets_dir = None, platform_build_args = [], recorded_uses = None):
    """Run the shared kernel compilation step.

    Collects sources, generates package_config.json, and invokes
    flutter_kernel_compile_action. If deps contain plugins with
    dartPluginClass (or the debug agent is injected), generates a
    registrant library the engine invokes before main() on every
    root-isolate launch — including hot restart.

    If aot and platform_dill are not specified, they follow the build mode
    (`flutter_build_mode`): debug → debug dill + JIT, profile → debug
    (non-product) dill + AOT, release → product dill + AOT.

    Args:
        ctx: Rule context (must have main, srcs, deps, defines attrs).
        flutter_sdk_info: FlutterSdkInfo from the toolchain.
        aot: If set, override AOT mode. Otherwise determined by compilation mode.
        platform_dill: If set, override platform dill. Otherwise determined by compilation mode.
        target_platform: Optional platform string (e.g. "web", "linux", "android").
            When set, only plugins with dartPluginClass on that platform are registered.
        frontend_server_target: Frontend server --target flag ("flutter" or "dartdevc" for web).
        native_assets_manifest: Optional File pointing at the
            `native_assets.json` manifest (the JSON shape the
            frontend_server reads via `--native-assets`). Always passed
            through when set; the manifest's contents may be empty.
        track_widget_creation: Whether to pass `--track-widget-creation` to
            the frontend server. Passed rather than read off `ctx.attr`,
            because the rules calling this do not share one attribute set —
            `flutter_kernel_target` has no such attr — and a rule that has no
            opinion should say `False` rather than be probed for one.
        assets_dir: The declared `flutter_assets/` tree artifact, from
            `declare_flutter_assets_dir`. Supplying it is what makes a debug
            build carry `rules_flutter.build_info`; the rules with no asset
            bundle of their own (`flutter_kernel_target`,
            `flutter_aot_target`) leave it None and emit no define, because
            an app with no assets tree has nothing for the dev tool to watch.
        platform_build_args: Flags from `launch_build_args`, recorded in
            `build_info` so an attaching dev tool can reproduce this
            configuration. Only meaningful alongside `assets_dir`.
        recorded_uses: Optional declared File for the compiler's recorded
            `@RecordUse` uses, the input of package link hooks. Pass it for
            AOT compiles only.

    Returns:
        struct with kernel_dill (File) and package_config (File).
    """
    st = _kernel_source_inputs(ctx)

    # Dev hot-reload metadata (debug only): a *second* package_config that, for a
    # source-assembled app package, points its `rootUri` at the live source tree
    # + generated bazel-out roots via a filesystem scheme — instead of the frozen
    # assembled `.pkgsrcs` dir the build package_config uses. This is what lets
    # the dev tool's frontend_server pick up live edits AND find generated parts.
    # Computed from the PRE-colocation `packages`/`colocate_inputs` so `lib_root`
    # and `File.is_source` are still intact. See rules_dart
    # `generate_dev_package_config`.
    mode = flutter_build_mode(ctx)
    dev = _kernel_dev_config(ctx, st, mode)

    if aot == None:
        aot = mode != "debug"
    platform_dill = _resolve_kernel_platform_dill(platform_dill, aot, mode, flutter_sdk_info)
    agent = _stage_agent_extensions(ctx, aot, mode)
    reg = _kernel_registrant(ctx, target_platform, agent, dev.emit)
    flags = _kernel_compile_flags(ctx, track_widget_creation, mode, aot, assets_dir, platform_build_args, target_platform)

    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    config_file = _run_kernel_compile(
        ctx,
        flutter_sdk_info,
        kernel_dill,
        platform_dill,
        st,
        agent,
        reg,
        flags,
        struct(
            mode = mode,
            aot = aot,
            frontend_server_target = frontend_server_target,
            native_assets_manifest = native_assets_manifest,
            recorded_uses = recorded_uses,
        ),
    )
    return struct(
        kernel_dill = kernel_dill,
        package_config = config_file,
        # Dev-loop plugin registrants, keyed by platform (empty outside
        # debug). The dev tool replays the entry matching the running app's
        # platform on its resident frontend_server so the engine hook keeps
        # firing — with the right plugin set — after hot restart.
        dev_plugin_registrants = reg.dev_registrants,
        # Merged user defines (attr + flag), without the mode-specific
        # dart.vm.* keys — the dev tool replays these on its own compiler.
        dart_defines = flags.user_defines,
        # Hot-reload dev metadata (None/empty outside debug). Consumed by the
        # rule impl to emit `_dev_config.json` for the dev tool.
        app_entrypoint_uri = dev.entrypoint_uri,
        dev_package_config = dev.package_config,
        dev_filesystem_roots = dev.filesystem_roots,
        dev_filesystem_scheme = dev.filesystem_scheme,
        dev_generated_source_paths = dev.generated_source_paths,
        dev_generated_source_uris = dev.generated_source_uris,
        dev_generated_source_files = dev.generated_source_files,
        dev_source_packages = dev.source_packages,
        dev_app_sources = dev.app_sources,
    )

def collect_sdk_shader_srcs(deps):
    """Collect shader source files from transitive FlutterInfo deps.

    These are raw .frag/.glsl files (e.g. Flutter SDK material shaders)
    that need to be compiled per-platform before inclusion in the asset bundle.

    Args:
        deps: List of targets, some of which may provide FlutterInfo.

    Returns:
        List of shader source Files.
    """
    transitive_depsets = [
        dep[FlutterInfo].shader_srcs
        for dep in deps
        if FlutterInfo in dep
    ]
    if transitive_depsets:
        return depset(transitive = transitive_depsets).to_list()
    return []

def _shader_jobs(ctx):
    """Every shader this target bundles, as struct(bundle_path, file, includes).

    The target's own shaders are keyed like its assets: relative to the
    listing target's package directory, which is where
    `FragmentProgram.fromAsset` looks for them. SDK shaders go under
    "shaders/<basename>" (Flutter's convention), and a package's under
    "packages/<pkg>/<path>" (bare "<path>" when it has no package name). A
    shader outside the listing target's package fails here rather than
    guessing a key, and two shaders claiming one bundle path fail here: one
    would otherwise overwrite the other.
    """
    jobs = []
    user_includes = tuple(getattr(ctx.files, "shader_includes", []))
    for shader in ctx.files.shaders:
        if not is_within_package(ctx.label.workspace_root, ctx.label.package, shader.short_path):
            fail("%s: shader %s is outside the target's package; move it into a flutter_library with a package_name and depend on it instead." % (ctx.label, shader.short_path))
        jobs.append(struct(
            bundle_path = relative_key(ctx.label.workspace_root, ctx.label.package, shader.short_path),
            file = shader,
            includes = user_includes,
        ))
    for entry in collect_sdk_shader_srcs(ctx.attr.deps):
        shader = entry.file if hasattr(entry, "file") else entry
        includes = entry.includes if hasattr(entry, "includes") else ()
        jobs.append(struct(bundle_path = "shaders/" + shader.basename, file = shader, includes = includes))
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            for entry in dep[FlutterInfo].pub_shaders.to_list():
                prefix = "packages/{}/".format(entry.package_name) if entry.package_name else ""
                jobs.append(struct(
                    bundle_path = prefix + entry.shader_path,
                    file = entry.file,
                    includes = entry.includes,
                ))

    # One package can reach a target along several paths; the same file at
    # the same bundle path is one shader.
    by_path = {}
    for job in jobs:
        seen = by_path.get(job.bundle_path)
        if seen == None:
            by_path[job.bundle_path] = job
        elif seen.file != job.file:
            fail("%s: two shaders are bundled at %s: %s and %s." % (
                ctx.label,
                job.bundle_path,
                seen.file.short_path,
                job.file.short_path,
            ))
        elif job.includes and tuple(job.includes) != tuple(seen.includes):
            by_path[job.bundle_path] = struct(
                bundle_path = seen.bundle_path,
                file = seen.file,
                includes = tuple(depset(list(seen.includes) + list(job.includes)).to_list()),
            )
    return by_path.values()

def shader_sources(ctx):
    """The workspace files behind each bundled shader, for the dev tool.

    `{bundle path: [workspace-relative path]}`: the shader and what it may
    `#include`, where those are source files of this workspace. A shader from
    another repository maps to an empty list; it is still a shader, which is
    what the dev tool needs to know to make the app reload it.
    """
    return {
        job.bundle_path: [
            f.short_path
            for f in [job.file] + list(job.includes)
            if f.is_source and not f.short_path.startswith("../")
        ]
        for job in _shader_jobs(ctx)
    }

def _collect_dep_compiled_shaders(ctx, target_platform, compiled):
    """Fold dep `FlutterCompiledShadersInfo` entries for the platform into `compiled`.

    Returns the `require_sksl` flag: when true every shader is (re)compiled
    locally, so dep entries are skipped.
    """
    require_sksl = getattr(ctx.attr, "require_sksl_shaders", False)
    if not require_sksl:
        for dep in getattr(ctx.attr, "deps", []):
            if type(dep) == "Target" and FlutterCompiledShadersInfo in dep:
                for entry in dep[FlutterCompiledShadersInfo].compiled_shaders.to_list():
                    if getattr(entry, "target_platform", None) != target_platform:
                        continue
                    seen = compiled.get(entry.bundle_path)
                    if seen == None:
                        compiled[entry.bundle_path] = entry.file
                    elif seen != entry.file:
                        fail("%s: two shaders are bundled at %s: %s and %s." % (
                            ctx.label,
                            entry.bundle_path,
                            seen.short_path,
                            entry.file.short_path,
                        ))
    return require_sksl

def _compile_missing_shaders(ctx, flutter_sdk_info, target_platform, require_sksl, compiled):
    """Compile each `_shader_jobs` entry missing from `compiled`, in place."""
    for job in _shader_jobs(ctx):
        if job.bundle_path not in compiled:
            # Named by the bundle path, which is unique, so no two outputs meet.
            out_path = job.bundle_path.replace("../", "_external/")
            output = ctx.actions.declare_file("_shaders_%s/%s/%s.iplr" % (target_platform, ctx.label.name, out_path))
            flutter_shader_compile_action(
                ctx = ctx,
                impellerc = flutter_sdk_info.impellerc,
                shader_lib = flutter_sdk_info.shader_lib,
                shader = job.file,
                output = output,
                target_platform = target_platform,
                is_web = target_platform == "web",
                includes = job.includes,
                # What compiles a shader whose SkSL stage fails without it.
                compile_tool = ctx.executable._shader_compile_tool,
                require_sksl = require_sksl,
            )
            compiled[job.bundle_path] = output

def flutter_compile_shaders(ctx, flutter_sdk_info, target_platform):
    """Compile every shader this target bundles for the target platform.

    The shaders are the target's own (`shaders`), the SDK's (collected from
    FlutterInfo.shader_srcs) and its packages' (FlutterInfo.pub_shaders); see
    `_shader_jobs` for where each is bundled.

    Shaders from dependencies are compiled once per platform via the shader
    aspect on the owning target and collected from FlutterCompiledShadersInfo.
    Any shader not supplied by deps (including the target's own `shaders` attr)
    is compiled here. If `require_sksl_shaders` is True, all shaders are
    compiled here with `require_sksl = True`.

    Args:
        ctx: Rule context (must have shaders attr and deps attr).
        flutter_sdk_info: FlutterSdkInfo from the toolchain.
        target_platform: Target platform string ("ios", "macos", "android", "linux", "windows", "web").

    Returns:
        Dict mapping bundle destination path → compiled File. Pass to
        extra_asset_copies in flutter_asset_bundle_action.
    """
    if not flutter_sdk_info or not flutter_sdk_info.impellerc:
        return {}

    compiled = {}
    require_sksl = _collect_dep_compiled_shaders(ctx, target_platform, compiled)
    _compile_missing_shaders(ctx, flutter_sdk_info, target_platform, require_sksl, compiled)
    return compiled

def declare_flutter_assets_dir(ctx):
    """Declare the `flutter_assets/` tree artifact for this target.

    Split out from `flutter_build_assets` so a rule can name the directory
    before it compiles the kernel: an application bakes this path into
    `rules_flutter.build_info.assetsDir`, and the dev tool matches the app's
    reported value against the tree it watches and rebuilds. Every rule that
    bundles assets uses this one helper so the name is stated in a single
    place rather than re-spelled at each call site.

    Args:
        ctx: Rule context.

    Returns:
        The declared directory (tree artifact) File.
    """
    return ctx.actions.declare_directory(ctx.label.name + "_flutter_assets")

def flutter_build_assets(ctx, flutter_sdk_info, output_dir, compiled_shaders = {}, *, target_platform, kernel_dill = None, kernel_dills = [], tree_shake_key = "", is_debug = False, data_assets = None):
    """Run the shared asset bundling step.

    Walks `FlutterInfo.pub_fonts` / `pub_assets` from deps to bundle
    pub-package contributions (fonts/assets — shaders are pre-compiled by
    `flutter_compile_shaders` and arrive via `compiled_shaders`).

    Args:
        ctx: Rule context (must have assets, deps, license_files, tree_shake_icons attrs and _asset_bundle_tool).
        flutter_sdk_info: FlutterSdkInfo from the toolchain.
        output_dir: The tree artifact to bundle into, from
            `declare_flutter_assets_dir`. Passed in rather than declared here
            so an application can bake the path into its `build_info` before
            the kernel compile that this action depends on.
        compiled_shaders: Dict mapping bundle dest path → compiled shader File.
        target_platform: The bundle's platform (`android`, `ios`, `macos`,
            `linux`, `windows`, `web`, or `tester` for test bundles).
            Required and keyword-only, so a new bundle call site cannot
            silently inherit the wrong filter: pub assets carrying
            `platforms` / `flavors` conditions bundle only where
            flutter_tools would bundle them.
        kernel_dill: The compiled kernel .dill File (needed for icon tree shaking).
        kernel_dills: Optional list of compiled kernel .dill Files when a bundle
            ships multiple programs with distinct defines (e.g. WASM + JS fallback).
        tree_shake_key: Optional configuration fingerprint for the shipped
            programs whose icons are tree-shaken.
        is_debug: Whether this is a debug build (icon tree shaking is skipped in debug).
        data_assets: Optional depset[FlutterDataAssetInfo]. Each entry is
            placed at `flutter_assets/packages/<package>/<name>` and listed in
            the asset manifest under that key, as flutter_tools bundles a
            hook's data asset.

    Returns:
        The flutter_assets/ tree artifact File.
    """
    all_entries = bundle_asset_entries(ctx.label, ctx.files.assets, ctx.attr.deps)

    # Walk pub-package font/asset contributions from FlutterInfo.
    # MaterialIcons is no longer special-cased here — apps depend on
    # `@rules_flutter//flutter:material_icons` to get it via this same path.
    fonts, pub_extra_asset_copies = aggregate_pub_contributions(
        ctx.attr.deps,
        target_platform,
    )
    extra_asset_copies = dict(compiled_shaders)
    extra_asset_copies.update(pub_extra_asset_copies)

    # Drop each DataAsset at flutter_assets/packages/<pkg>/<name>, the key
    # flutter_tools gives a hook's data asset and the one `rootBundle` loads
    # it by. The bundle action keys extra_asset_copies on a destination path
    # relative to the assets/ root.
    if data_assets != None:
        for entry in data_assets.to_list():
            dst = "packages/{pkg}/{name}".format(pkg = entry.package, name = entry.name)
            if dst in extra_asset_copies:
                fail("%s: data asset %s collides with another asset bundled at %s." % (ctx.label, entry.file.short_path, dst))
            extra_asset_copies[dst] = entry.file

    license_files = ctx.files.license_files

    const_finder, font_subset = resolve_font_subset_tools(flutter_sdk_info) if fonts else (None, None)
    all_kernel_dills = list(kernel_dills) if kernel_dills else ([kernel_dill] if kernel_dill != None else [])

    if ctx.attr.tree_shake_icons and bool(fonts) and not is_debug and bool(all_kernel_dills) and (const_finder == None or font_subset == None):
        fail(
            "%s: icon tree shaking is enabled (`tree_shake_icons = True`) and the target bundles fonts, " % ctx.label +
            "but `const_finder` or `font_subset` (`font-subset`) is not available in the Flutter toolchain " +
            "(`@rules_flutter//flutter:font_subset_toolchain_type`) for the execution platform.",
        )

    # Icon tree shaking: enabled only in non-debug mode with tree_shake_icons=True
    # when the dependency graph actually contributes at least one font family.
    tree_shake_icons = (
        ctx.attr.tree_shake_icons and
        bool(fonts) and
        not is_debug and
        bool(all_kernel_dills) and
        const_finder != None and
        font_subset != None
    )

    # `const_finder.dart.snapshot` is a kernel snapshot built by the Flutter
    # engine's bundled Dart SDK and analyzes `kernel_dill` compiled by Flutter's
    # `frontend_server`, so it must run on `flutter_sdk_info.dart` paired with
    # `flutter_sdk_info.dart_vm_files` rather than `@rules_dart`'s exec-tools SDK.
    return flutter_asset_bundle_action(
        ctx = ctx,
        dart = flutter_sdk_info.dart if tree_shake_icons else None,
        flutter_sdk_files = flutter_sdk_info.dart_vm_files if tree_shake_icons else None,
        assets = all_entries,
        fonts = fonts,
        license_files = license_files,
        output_dir = output_dir,
        const_finder = const_finder if tree_shake_icons else None,
        font_subset = font_subset if tree_shake_icons else None,
        kernel_dill = all_kernel_dills[0] if tree_shake_icons else None,
        kernel_dills = all_kernel_dills if tree_shake_icons else [],
        tree_shake_key = tree_shake_key if tree_shake_icons else "",
        extra_asset_copies = extra_asset_copies,
    )

def compute_desktop_bundle_copies(is_debug, kernel_dill_path, aot_output_path, aot_dst, icu_data_path, engine_basenames, native_basenames, engine_dst_prefix = "lib/", native_dst_prefix = "lib/"):
    """Compute the file-copy list for a desktop Flutter bundle.

    Builds the list of {"src": ..., "dst": ...} dicts that the Dart bundler
    tool uses to assemble a Linux or Windows application directory.

    Args:
        is_debug: Whether this is a debug build.
        kernel_dill_path: Source path to kernel .dill file (used in debug mode), or None.
        aot_output_path: Source path to AOT output (used in release mode), or None.
        aot_dst: Destination path for AOT output (e.g. "lib/libapp.so" or "app.so").
        icu_data_path: Source path to icudtl.dat.
        engine_basenames: List of (src_path, basename) tuples for engine files.
        native_basenames: List of (src_path, basename) tuples for native FFI libs.
        engine_dst_prefix: Destination prefix for engine files (default "lib/").
        native_dst_prefix: Destination prefix for native FFI / Native
            Assets `dynamic_loading_bundle` libs. Linux uses `lib/`
            (next to libapp.so); Windows uses `""` so DLLs land next to
            the runner `.exe` where Windows' dynamic loader picks them
            up via the standard search order.

    Returns:
        List of {"src": ..., "dst": ...} dicts.
    """
    copies = [{"src": icu_data_path, "dst": "data/icudtl.dat"}]

    if is_debug and kernel_dill_path:
        # The Flutter engine's embedder looks for kernel_blob.bin inside the
        # assets directory (settings.assets_path / "kernel_blob.bin").
        copies.append({"src": kernel_dill_path, "dst": "data/flutter_assets/kernel_blob.bin"})
    elif aot_output_path:
        copies.append({"src": aot_output_path, "dst": aot_dst})

    for src_path, basename in engine_basenames:
        copies.append({"src": src_path, "dst": engine_dst_prefix + basename})

    for src_path, basename in native_basenames:
        copies.append({"src": src_path, "dst": native_dst_prefix + basename})

    return copies

def compute_android_jni_path(target_name, abi, basename):
    """Compute the JNI symlink path for an Android native library.

    Scoped by [target_name] because `ctx.actions.declare_file` resolves
    package-relative: two Android bundles in one package would otherwise both
    declare `jni/<abi>/libapp.so` and collide. That is not hypothetical — the
    Tier 1 `flutter_android_app` macro generates a bundle internally, so a
    package holding two apps (or an app plus an explicit Tier 2 bundle) hits
    it, and `bazel build //...` fails with conflicting actions. Bazel only
    tolerates the duplicate while both symlinks happen to point at the *same*
    source file, which masks the bug until the two apps differ.

    Mirrors the same scoping already applied to the mobile-install assets
    directory in `flutter_android_application.bzl`.

    Args:
        target_name: Name of the declaring target (`ctx.label.name`).
        abi: Android ABI string (e.g. "arm64-v8a").
        basename: Filename within the ABI directory.

    Returns:
        Path string like "my_app_jni/arm64-v8a/libapp.so".
    """
    return "{}_jni/{}/{}".format(target_name, abi, basename)

# Android ABIs with AOT cross-compilation support. Single source of truth
# mapping each ABI to the Bazel platform Android rules transition to and the
# ELF e_machine value native libraries packaged for that ABI must carry.
ANDROID_ABIS = {
    "arm64-v8a": struct(
        platform = Label("//flutter/platforms:android_arm64"),
        elf_machine = 183,  # EM_AARCH64
    ),
    "x86_64": struct(
        platform = Label("//flutter/platforms:android_x64"),
        elf_machine = 62,  # EM_X86_64
    ),
}

def android_platform_for_abi(abi):
    """The Bazel platform label Android rules build for, given an ABI.

    Args:
        abi: Android ABI string ("arm64-v8a" or "x86_64").

    Returns:
        A Label for the platform under //flutter/platforms.
    """
    if abi not in ANDROID_ABIS:
        fail("Unsupported Android ABI '{}'. Supported: {}.".format(
            abi,
            ", ".join(ANDROID_ABIS.keys()),
        ))
    return ANDROID_ABIS[abi].platform

def android_elf_machine_for_abi(abi):
    """The ELF e_machine value native libraries must have for an ABI.

    Args:
        abi: Android ABI string ("arm64-v8a" or "x86_64").

    Returns:
        The e_machine value as an int (e.g. 183 for EM_AARCH64).
    """
    if abi not in ANDROID_ABIS:
        fail("Unsupported Android ABI '{}'. Supported: {}.".format(
            abi,
            ", ".join(ANDROID_ABIS.keys()),
        ))
    return ANDROID_ABIS[abi].elf_machine

def host_target_arch(ctx, flutter_sdk_info):
    """Best-effort target architecture string for Native Assets.

    The toolchain's `target_arch` is set on cross-compilation toolchains
    but empty for native builds. For native builds we infer from
    `bin_dir` path. Returns one of `arm64`, `x64`, `arm`, or "" if
    unknown. The empty string causes the Native Assets manifest to omit
    the target section, which is still valid for the engine.

    Args:
      ctx: Rule context — used only for `ctx.bin_dir`.
      flutter_sdk_info: `FlutterSdkInfo` from the toolchain. Carries the
        `target_arch` field, which when set wins over the heuristic.

    Returns:
      A lowercase architecture string (`arm64`, `x64`, `arm`) or "" when
      neither the toolchain nor the bin_dir hint at a known arch.
    """
    if flutter_sdk_info.target_arch:
        return flutter_sdk_info.target_arch

    # Heuristic: parse the bazel-out output dir for cpu hints. The bin_dir
    # path looks like `bazel-out/<cpu>-<mode>/bin`. Match the same `cpu`
    # values rules_flutter assumes elsewhere. Windows cpu names put the
    # arch first (`x64_windows`, `arm64_windows`), so match those before
    # the suffix-style patterns.
    bin_dir = ctx.bin_dir.path
    if "arm64_windows" in bin_dir:
        return "arm64"
    if "x64_windows" in bin_dir:
        return "x64"
    if "darwin_arm64" in bin_dir or "_arm64" in bin_dir:
        return "arm64"
    if "darwin_x86_64" in bin_dir or "_x86_64" in bin_dir or "_amd64" in bin_dir or "k8" in bin_dir:
        return "x64"
    if "darwin_x64" in bin_dir or "_x64" in bin_dir:
        return "x64"
    if "armv7" in bin_dir or "arm-" in bin_dir:
        return "arm"
    return ""

def detect_target_platform(is_ios, is_macos, is_linux, is_windows, is_android):
    """Detect the Flutter target platform from constraint booleans.

    Args:
        is_ios: True if target platform is iOS.
        is_macos: True if target platform is macOS.
        is_linux: True if target platform is Linux.
        is_windows: True if target platform is Windows.
        is_android: True if target platform is Android.

    Returns:
        Platform string: "ios", "macos", "linux", "windows", or "android".
        Fails if no platform matches.
    """
    if is_ios:
        return "ios"
    elif is_macos:
        return "macos"
    elif is_linux:
        return "linux"
    elif is_windows:
        return "windows"
    elif is_android:
        return "android"
    else:
        fail(
            "No supported Flutter target platform detected. " +
            "Supported platforms: android, ios, macos, linux, windows. " +
            "Use --platforms= to set the target platform.",
        )

# Shared platform constraint attrs used by rules that need to check target platform.
PLATFORM_CONSTRAINT_ATTRS = {
    "_macos_constraint": attr.label(
        default = "@platforms//os:macos",
    ),
    "_ios_constraint": attr.label(
        default = "@platforms//os:ios",
    ),
    "_linux_constraint": attr.label(
        default = "@platforms//os:linux",
    ),
    "_windows_constraint": attr.label(
        default = "@platforms//os:windows",
    ),
    "_android_constraint": attr.label(
        default = "@platforms//os:android",
    ),
    # CPU alongside OS, because Android's ABI selects a whole platform label
    # in `launch_build_args`. Read from the resolved platform rather than
    # parsed out of `ctx.bin_dir` the way `host_target_arch` still does — a
    # value the dev tool builds against has to be right or absent, not
    # guessed.
    "_arm64_constraint": attr.label(
        default = "@platforms//cpu:arm64",
    ),
    "_x86_64_constraint": attr.label(
        default = "@platforms//cpu:x86_64",
    ),
}

# Target compatibility constraint for targets that only run on a host OS
# (Linux, macOS, Windows) and must be skipped when `--platforms` targets a
# mobile/device OS such as Android or iOS.
HOST_COMPATIBLE = select({
    Label("@platforms//os:linux"): [],
    Label("@platforms//os:macos"): [],
    Label("@platforms//os:windows"): [],
    "//conditions:default": [Label("@platforms//:incompatible")],
})

def launch_build_args(target_platform, is_simulator, is_arm64, is_x86_64):
    """The bazel flags the *launch target's* build needs to produce this app.

    MIRRORS `Device.buildArgs` in `tools/dev_tool/lib/device.dart`. The dev
    tool normally gets these from the `-d` device the user named — but
    `flutter_bazel attach` has no `-d`, and even on `run` these flags come
    from the device rather than from anything the user typed, so they are not
    something an attaching process can ask the user to repeat. The app
    therefore carries them, and the dev tool replays them when it builds and
    queries the wrapper. Keep the two lists in step; a drift shows up as the
    dev tool's `assetsDir` mismatch, loudly, rather than as a silent rebuild
    into a tree the app never reads.

    These are NOT flags that would reproduce this configuration on a bare
    build of the `flutter_application` itself. That is not expressible: the
    Apple and Android wrappers reach this target through split transitions
    whose output directories (`…-ST-<hash>`) no command line can name. These
    are the flags for the *wrapper*, which is what the dev tool builds.

    Takes booleans rather than `ctx` for the same reason
    `detect_target_platform` does: the interesting part is the mapping, and a
    mapping only a configured target can call is a mapping nothing can test.

    Args:
        target_platform: Platform string from `detect_target_platform`.
        is_simulator: True when the Apple target environment is the simulator.
            Resolved by the caller through `apple_support`, which is where
            that question is answerable; ignored off Apple.
        is_arm64: True when the target platform has the arm64 CPU constraint.
        is_x86_64: True when it has the x86_64 CPU constraint.

    Returns:
        list[str] of bazel flags. Empty on desktop.
    """
    if target_platform == "ios":
        # `Device.buildArgs` hardcodes arm64 on both sides — a 32-bit or x86
        # simulator is not a target rules_flutter builds for.
        return ["--ios_multi_cpus=sim_arm64"] if is_simulator else ["--ios_multi_cpus=arm64"]

    if target_platform == "android":
        if is_arm64:
            abi = "arm64"
        elif is_x86_64:
            abi = "x64"
        else:
            fail(
                "flutter_application: the Android target platform has neither an arm64 nor " +
                "an x86_64 CPU constraint, so the `--platforms` flag a dev-loop rebuild " +
                "needs cannot be named. rules_flutter ships android_arm64 and android_x64 " +
                "under @rules_flutter//flutter/platforms.",
            )
        return ["--platforms=@rules_flutter//flutter/platforms:android_" + abi]

    # Desktop needs no flag: the app is already built in the top-level
    # configuration. `Device.buildArgs` emits `--platforms=` only when
    # cross-building, and that case is out of reach here anyway — the dev tool
    # reads the app's own bazel-out paths, so it has to be on the machine that
    # built it. Emitting the flag regardless would move a dev-loop rebuild to a
    # different output directory than the one the running app came from.
    return []

AGENT_EXTENSIONS_ATTR = {
    "_agent_extensions_src": attr.label(
        doc = "AI-agent service-extension source. Registered from the generated plugin registrant in debug builds; ignored in AOT/release.",
        default = Label("//flutter/private/agent_extensions:agent.dart"),
        allow_single_file = [".dart"],
    ),
    "_native_agent_extensions_src": attr.label(
        doc = "The native-only agent extensions (`dart:ffi`): loading a `flutter_native_library.hot_patch`. Staged beside `_agent_extensions_src` in native debug builds; never on web.",
        default = Label("//flutter/private/agent_extensions:native_patch.dart"),
        allow_single_file = [".dart"],
    ),
}

BUILD_MODE_ATTR = {
    "_profile_flag": attr.label(
        doc = "The //flutter:profile build setting. Read through `flutter_build_mode`.",
        default = Label("//flutter:profile"),
    ),
}

def flutter_build_mode(ctx):
    """Flutter's build mode for this configuration: "debug", "profile" or "release".

    `-c dbg` is debug and any other `-c` is release, unless
    `--@rules_flutter//flutter:profile` asks for profile, which needs `-c opt`:
    the engine and gen_snapshot selects match profile only there, and a
    profile Dart snapshot on any other engine does not start.

    Args:
        ctx: Rule context carrying `BUILD_MODE_ATTR`.

    Returns:
        "debug", "profile" or "release".
    """
    compilation_mode = ctx.var["COMPILATION_MODE"]
    if ctx.attr._profile_flag[BuildSettingInfo].value:
        if compilation_mode != "opt":
            fail(
                "--@rules_flutter//flutter:profile builds Flutter's profile mode, " +
                "which is optimized AOT code and needs -c opt (this build is -c " +
                compilation_mode + "). Add -c opt, or drop the flag.",
            )
        return "profile"
    return "debug" if compilation_mode == "dbg" else "release"

EXTRA_DART_DEFINES_ATTR = {
    "_extra_dart_defines": attr.label(
        doc = "The //flutter:extra_dart_defines build setting, appended after the target's own `defines`.",
        default = Label("//flutter:extra_dart_defines"),
    ),
}

def merge_dart_defines(ctx):
    """Merge a target's `defines` attr with the extra_dart_defines flag.

    Flag values come after attr values, so on a duplicated key the command
    line wins (the compilers take the last -D). The flag validates its own
    value in its rule impl; only the attr is validated here.

    Args:
        ctx: Rule context with `defines` and `_extra_dart_defines` attrs.

    Returns:
        The merged list of KEY=VALUE define strings.
    """
    validate_dart_defines(ctx.attr.defines, "defines attribute of %s" % ctx.label)
    return list(ctx.attr.defines) + list(ctx.attr._extra_dart_defines[BuildSettingInfo].value)

# The attrs `flutter_compile_kernel` reads off its caller's `ctx`. Every rule
# that calls it spreads this bundle wholesale rather than naming the members,
# because naming them is what let the contract break: `flutter_compile_kernel`
# reaches into `ctx.attr.language_version` on whatever context it is handed,
# and the two callers that built a narrowed attr surface — `flutter_aot_target`
# cherry-picking from `FLUTTER_APPLICATION_ATTRS`, `flutter_kernel_target`
# hand-rolling a near-copy that had already drifted — simply did not have it.
# One failed at analysis, the other silently; a caller that spreads the bundle
# can omit nothing.
#
# Per-rule inputs stay out. `track_widget_creation` and `assets_dir`
# are function parameters of `flutter_compile_kernel` for the reason its
# docstring gives — the callers genuinely disagree about whether they have one
# — and `_agent_extensions_src` is declared by the rules that inject the agent,
# not by every kernel compile.
KERNEL_COMPILE_ATTRS = {
    "_kernel_filter_tool": attr.label(
        default = Label("//flutter/private/tools:kernel_filter"),
        executable = True,
        cfg = "exec",
    ),
    "_incremental_kernel": attr.label(
        default = Label("//flutter:incremental_kernel"),
        doc = "Opt-in incremental kernel worker flag (a BuildSettingInfo).",
    ),
    "_incr_worker_tool": attr.label(
        default = Label("//flutter/private/tools:incr_fkc_worker"),
        executable = True,
        cfg = "exec",
        doc = "Persistent incremental kernel compile worker tool.",
    ),
    "_web_guard_tool": attr.label(
        default = Label("//flutter/private/tools:web_guard"),
        executable = True,
        cfg = "exec",
    ),
    "main": attr.label(
        doc = "The main .dart entry point.",
        mandatory = True,
        allow_single_file = [".dart"],
    ),
    "package_name": attr.string(
        doc = "Dart package name (same value as `pubspec.yaml`'s `name:`). " +
              "Required: keys the kernel's libraries under stable `package:` URIs " +
              "(hot-reload parity with the dev tool), anchors codegen sibling " +
              "co-location, and resolves `package:<self>/...` imports. There is " +
              "no signal in the Bazel graph that can determine this reliably, " +
              "so it must be declared explicitly.\n\n" +
              "A target declared beside the library it covers — a " +
              "`flutter_test` in the same directory as its `flutter_library`, " +
              "the layout pub uses — *is* that package rather than a consumer " +
              "of it: give it the library's `package_name` and list the " +
              "library's sources in `srcs`, instead of depending on the " +
              "sibling target. Two Dart packages cannot share a directory, so " +
              "a dependency declaring a different package name at this " +
              "target's own root is refused.",
        mandatory = True,
    ),
    "language_version": attr.string(
        doc = "Dart language version for the app's own package, in " +
              "`<major>.<minor>` form — the same value pub derives from this " +
              "package's `environment.sdk` lower bound and writes into " +
              "`package_config.json` (`sdk: ^3.12.0` → `\"3.12\"`). " +
              "Optional, and it lives here for the same reason `package_name` " +
              "does: it is stated in `pubspec.yaml`, which the analysis phase " +
              "cannot read.\n\n" +
              "Left unset, the app's entry carries no `languageVersion`, and " +
              "`package_config.json` reads that as the *current* SDK's — so " +
              "the build accepts newer syntax than the app's own pubspec " +
              "permits, and applies newer semantics to code written against " +
              "an older version. That is a divergence from `flutter build`, " +
              "not a neutral default. Set it to match your pubspec if the two " +
              "differ. Same attribute, same meaning, as on `flutter_library` " +
              "and `flutter_plugin`.",
    ),
    "srcs": attr.label_list(
        doc = "Additional Dart source files.",
        allow_files = [".dart"],
    ),
    "deps": attr.label_list(
        doc = "`dart_library` or `flutter_library` dependencies. A rule that " +
              "builds an asset bundle needs `@rules_flutter//flutter:material_icons` " +
              "listed here to bundle `MaterialIcons-Regular.otf` into " +
              "`flutter_assets/` for Material widgets; the rules that emit only " +
              "a kernel or an AOT artifact have no bundle for it to reach.",
        providers = [DartInfo],
    ),
    "defines": attr.string_list(
        doc = "Dart environment defines (-D flags).",
    ),
} | EXTRA_DART_DEFINES_ATTR | BUILD_MODE_ATTR

def _aspect_target_platform(ctx, fixed_platform):
    """The platform string the shader aspect compiles for."""
    if fixed_platform != None:
        return fixed_platform
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
    return detect_target_platform(is_ios, is_macos, is_linux, is_windows, is_android)

def _aspect_direct_jobs(ctx, shader_includes):
    """The uncompiled shader jobs owned directly by the aspect's target."""
    direct_jobs = []

    # 1. Direct shaders from `shaders` attribute (e.g. on @flutter_sdk//:flutter or a flutter_library)
    if hasattr(ctx.rule.files, "shaders"):
        for shader in ctx.rule.files.shaders:
            direct_jobs.append(struct(
                bundle_path = "shaders/" + shader.basename,
                file = shader,
                includes = shader_includes,
            ))

    # 2. Direct shaders from `pkg_shaders` attribute (e.g. on flutter_library / flutter_plugin)
    if hasattr(ctx.rule.attr, "pkg_shaders") and ctx.rule.attr.pkg_shaders:
        pkg_name = getattr(ctx.rule.attr, "package_name", "") if hasattr(ctx.rule.attr, "package_name") else ""
        _, _, pub_shaders = build_pub_contributions(
            package_name = pkg_name,
            fonts_json = "",
            font_files_dict = {},
            pkg_assets_dict = {},
            pkg_shaders_dict = ctx.rule.attr.pkg_shaders,
            shader_includes = shader_includes,
        )
        for entry in pub_shaders:
            prefix = "packages/{}/".format(entry.package_name) if entry.package_name else ""
            direct_jobs.append(struct(
                bundle_path = prefix + entry.shader_path,
                file = entry.file,
                includes = entry.includes,
            ))
    return direct_jobs

def _compile_aspect_direct_jobs(ctx, flutter_sdk_info, target_platform, direct_jobs):
    """Compile the aspect target's own shaders, deduplicated by bundle path."""
    direct_compiled = []
    if direct_jobs and flutter_sdk_info and flutter_sdk_info.impellerc:
        by_path = {}
        for job in direct_jobs:
            seen = by_path.get(job.bundle_path)
            if seen == None:
                by_path[job.bundle_path] = job
            elif seen.file != job.file:
                fail("%s: two shaders are bundled at %s: %s and %s." % (
                    ctx.label,
                    job.bundle_path,
                    seen.file.short_path,
                    job.file.short_path,
                ))
            elif job.includes and tuple(job.includes) != tuple(seen.includes):
                by_path[job.bundle_path] = struct(
                    bundle_path = seen.bundle_path,
                    file = seen.file,
                    includes = tuple(depset(list(seen.includes) + list(job.includes)).to_list()),
                )

        for job in by_path.values():
            out_path = job.bundle_path.replace("../", "_external/")
            output = ctx.actions.declare_file("_shaders_%s/%s/%s.iplr" % (target_platform, ctx.label.name, out_path))
            flutter_shader_compile_action(
                ctx = ctx,
                impellerc = flutter_sdk_info.impellerc,
                shader_lib = flutter_sdk_info.shader_lib,
                shader = job.file,
                output = output,
                target_platform = target_platform,
                is_web = target_platform == "web",
                includes = job.includes,
                compile_tool = ctx.executable._shader_compile_tool,
                require_sksl = False,
            )
            direct_compiled.append(struct(
                bundle_path = job.bundle_path,
                file = output,
                target_platform = target_platform,
            ))
    return direct_compiled

def _aspect_transitive_shaders(ctx):
    """The dep `compiled_shaders` sets propagated through the aspect."""
    transitive = []
    if hasattr(ctx.rule.attr, "deps"):
        deps = ctx.rule.attr.deps
        for dep in (deps if type(deps) == "list" else [deps]):
            if type(dep) == "Target" and FlutterCompiledShadersInfo in dep:
                transitive.append(dep[FlutterCompiledShadersInfo].compiled_shaders)
    return transitive

def _shader_aspect_impl(ctx, fixed_platform):
    target_platform = _aspect_target_platform(ctx, fixed_platform)
    shader_includes = tuple(getattr(ctx.rule.files, "shader_includes", [])) if hasattr(ctx.rule.files, "shader_includes") else ()
    direct_jobs = _aspect_direct_jobs(ctx, shader_includes)
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"] if "@rules_flutter//flutter:toolchain_type" in ctx.toolchains else None
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info if flutter_toolchain else None
    direct_compiled = _compile_aspect_direct_jobs(ctx, flutter_sdk_info, target_platform, direct_jobs)
    transitive = _aspect_transitive_shaders(ctx)
    return [
        FlutterCompiledShadersInfo(
            compiled_shaders = depset(direct = direct_compiled, transitive = transitive),
        ),
    ]

def _tester_shader_aspect_impl(_target, ctx):
    return _shader_aspect_impl(ctx, "tester")

def _web_shader_aspect_impl(_target, ctx):
    return _shader_aspect_impl(ctx, "web")

def _app_shader_aspect_impl(_target, ctx):
    return _shader_aspect_impl(ctx, None)

_SHADER_ASPECT_BASE_ATTRS = {
    "_shader_compile_tool": attr.label(
        default = Label("//flutter/private/tools:compile_shader"),
        executable = True,
        cfg = "exec",
    ),
}

_SHADER_ASPECT_TOOLCHAINS = [
    "@rules_flutter//flutter:toolchain_type",
    config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
]

flutter_tester_shader_aspect = aspect(
    implementation = _tester_shader_aspect_impl,
    attr_aspects = ["deps"],
    attrs = _SHADER_ASPECT_BASE_ATTRS,
    toolchains = _SHADER_ASPECT_TOOLCHAINS,
    doc = "Compiles transitive shaders for the flutter_tester platform on the owning targets.",
)

flutter_web_shader_aspect = aspect(
    implementation = _web_shader_aspect_impl,
    attr_aspects = ["deps"],
    attrs = _SHADER_ASPECT_BASE_ATTRS,
    toolchains = _SHADER_ASPECT_TOOLCHAINS,
    doc = "Compiles transitive shaders for the web platform on the owning targets.",
)

flutter_app_shader_aspect = aspect(
    implementation = _app_shader_aspect_impl,
    attr_aspects = ["deps"],
    attrs = _SHADER_ASPECT_BASE_ATTRS | PLATFORM_CONSTRAINT_ATTRS,
    toolchains = _SHADER_ASPECT_TOOLCHAINS,
    doc = "Compiles transitive shaders for the target application platform on the owning targets.",
)

FLUTTER_DEPS_DOC = (
    "`dart_library` or `flutter_library` dependencies. A rule that " +
    "builds an asset bundle needs `@rules_flutter//flutter:material_icons` " +
    "listed here to bundle `MaterialIcons-Regular.otf` into " +
    "`flutter_assets/` for Material widgets; the rules that emit only " +
    "a kernel or an AOT artifact have no bundle for it to reach."
)

# Shared attrs for all flutter application rules.
FLUTTER_APPLICATION_ATTRS = KERNEL_COMPILE_ATTRS | {
    "deps": attr.label_list(
        doc = FLUTTER_DEPS_DOC,
        providers = [DartInfo],
        aspects = [flutter_app_shader_aspect],
    ),
    "assets": attr.label_list(
        doc = "Asset files to include in the bundle.",
        allow_files = True,
    ),
    "native_deps": attr.label_list(
        doc = "cc_library targets providing shared libraries for dart:ffi.",
        aspects = [native_sources_aspect],
    ),
    "obfuscate": attr.bool(
        doc = "If True, obfuscate Dart symbols in the AOT output. Pair with split_debug_info to produce a symbol map for deobfuscation.",
        default = False,
    ),
    "split_debug_info": attr.bool(
        doc = "If True, extract debug info from the AOT output into a separate file. Produces a .symbols output alongside the AOT binary.",
        default = False,
    ),
    "extra_gen_snapshot_options": attr.string_list(
        doc = "Additional flags passed directly to gen_snapshot (AOT compiler).",
    ),
    "track_widget_creation": attr.bool(
        doc = "If True, track widget creation locations for the DevTools widget inspector. Adds overhead; typically used only in debug/profile builds.",
        default = False,
    ),
    "shaders": attr.label_list(
        doc = "Fragment shader files (.frag) to compile with impellerc. Compiled shaders are included in the asset bundle.",
        allow_files = [".frag", ".glsl"],
    ),
    "shader_includes": attr.label_list(
        doc = "Files the `shaders` may `#include`. A shader compiles in a " +
              "sandbox holding only its declared inputs, so an include not " +
              "listed here is not found.",
        allow_files = True,
    ),
    "require_sksl_shaders": attr.bool(
        doc = "Fail the build when a shader cannot be compiled for Skia " +
              "(SkSL). By default such a shader is compiled for Impeller " +
              "alone with a warning, as `flutter build` does, and fails to " +
              "load only where the app renders with Skia. Set this for an " +
              "app that renders with Skia. Web builds always need SkSL.",
        default = False,
    ),
    "_shader_compile_tool": attr.label(
        default = Label("//flutter/private/tools:compile_shader"),
        executable = True,
        cfg = "exec",
    ),
    "link_hook_assets": attr.string_list(
        doc = "Data assets the packages' link hooks emit, each " +
              "`package:<package>/<name>`. In a release or profile build " +
              "the compiler records the uses of `@RecordUse` classes " +
              "(`--recorded-uses`), each listed package's `hook/link.dart` " +
              "runs over them, and the assets it emits are bundled at " +
              "`packages/<package>/<name>`, loadable with `rootBundle`. " +
              "A hook that emits an asset not listed, skips one that is, or " +
              "reports an error fails the build with its own message. Every " +
              "package with a link hook in `deps` runs, so list the assets " +
              "of each. Debug builds run no hook and bundle none: load what " +
              "the hook would index on demand there. Empty runs no hook.",
    ),
    "tree_shake_icons": attr.bool(
        doc = "If True, tree-shake icon fonts to only include used glyphs. " +
              "Requires all IconData instances to be const. Only applies to release builds.",
        default = True,
    ),
    "license_files": attr.label_list(
        doc = "License/NOTICE files to include in NOTICES.Z. Typically LICENSE files from dependencies.",
        allow_files = True,
    ),
    "min_os_version": attr.string(
        doc = "Minimum OS deployment target for Apple platforms (iOS/macOS). " +
              "Passed to gen_snapshot as --macho-min-os-version. " +
              "Platform-specific bundle rules set appropriate defaults.",
    ),
    "_asset_bundle_tool": attr.label(
        default = Label("//flutter/private/tools:generate_asset_manifest"),
        executable = True,
        cfg = "exec",
    ),
} | AGENT_EXTENSIONS_ATTR
