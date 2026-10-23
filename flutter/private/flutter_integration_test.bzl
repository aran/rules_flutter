"""Flutter integration test rule.

Compiles a Flutter application together with an in-app integration test
entrypoint (`package:integration_test` / `package:flutter_test` `WidgetTester`
code) for the target platform and runs it end-to-end under a platform runner.

For `platform = "web"`:
  1. Generates `<name>_bootstrap.dart` which initializes the live integration
     test binding (`IntegrationTestWidgetsFlutterBinding` when
     `package:integration_test` is in `deps`, or a built-in
     `LiveTestWidgetsFlutterBinding` subclass otherwise), connects back to the
     host runner over a WebSocket (`/__flutter_integration_ws__`), and drives
     the suite via `package:test_api/backend.dart` `RemoteListener`.
  2. Wraps `<name>_bootstrap.dart` in the standard Flutter web engine bootstrap
     (`ui_web.bootstrapEngine`) and compiles the whole app + test to JS/WASM
     with local CanvasKit/Skwasm and bundled `flutter_assets/`.
  3. Runs `flutter_integration_test_runner`, which serves the built web bundle
     over `http://127.0.0.1:<ephemeral>`, launches the hermetic pinned
     `chrome-headless-shell` binary with its pinned shared-library closure, and
     collects test results and any uncaught errors.

For `platform = "linux"`:
  1. Generates `<name>_linux_bootstrap.dart` which initializes the live
     integration test binding, connects back to the host runner over the
     WebSocket URL in `FLUTTER_INTEGRATION_TEST_HARNESS_URL`, and drives the
     suite via `RemoteListener`.
  2. Compiles the app + test to a kernel `.dill` (and in non-debug modes AOT
     `libapp.so`), compiles the C++ GTK runner + native C++ plugin registrant +
     Linux plugin C++ sources against the hermetic Chromium sysroot, and
     assembles the `<name>_linux` desktop bundle directory.
  3. Runs `flutter_integration_test_runner`, which starts the hermetic pinned
     `Xvfb` virtual display (`-displayfd`), launches the compiled Linux desktop
     application against that display and the pinned GTK3/Mesa/EGL/GLib runtime
     shared-library closure, and collects test results and any uncaught errors.

For `platform = "android"`:
  1. Generates `<name>_android_bootstrap.dart` which initializes the live
     integration test binding, connects back to the host runner over a localhost
     WebSocket forwarded into the emulator via `adb reverse`, and drives the
     suite via `RemoteListener`.
  2. Compiles the app + test to a kernel `.dill` (and in non-debug modes AOT
     `libapp.so`) for `android_x64`, generates `GeneratedPluginRegistrant.java`,
     compiles transitive Android plugin libraries, and packages a real signed
     Android APK via `android_binary`.
  3. Runs `flutter_integration_test_runner`, which boots the hermetic pinned
     Android emulator (`x86_64` API 35 `aosp_atd`) headless with KVM and
     SwiftShader, sets up `adb reverse`, installs and launches the APK, monitors
     for crashes/ANRs, and collects test results and any uncaught errors.
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//android:rules.bzl", "android_binary")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "MODULAR_KERNEL_TOOLCHAINS",
    "collect_packages",
    "collect_transitive_srcs",
    "dart_analyzable_info_with_package",
    "derive_lib_root",
    "runfiles_path",
)
load("@rules_java//java:java_import.bzl", "java_import")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load(
    "//flutter:android.bzl",
    "ANDROID_MIN_SDK_VERSION",
    "ANDROID_TARGET_SDK_VERSION",
    "flutter_android_bundle",
    "flutter_android_engine",
    "flutter_android_manifest_merge",
)
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_location",
    "app_scheme_location",
    "app_scheme_rel_path",
    "compile_kernel_package_config",
    "package_lib_prefix",
    "resolve_wrapper_main_import",
    "synthesize_app_package",
)
load(
    "//flutter/private:common.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "FLUTTER_APPLICATION_ATTRS",
    "FLUTTER_DEPS_DOC",
    "KERNEL_COMPILE_ATTRS",
    "LIBRARY_TAGS_TOOL_ATTR",
    "PLATFORM_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "collect_native_libs",
    "compute_desktop_bundle_copies",
    "declare_flutter_assets_dir",
    "extract_library_tags_action",
    "flutter_app_shader_aspect",
    "flutter_build_assets",
    "flutter_build_mode",
    "flutter_compile_shaders",
    "flutter_web_shader_aspect",
    "host_target_arch",
    "make_web_wrapper_main_content",
    "merge_dart_defines",
    "resolve_exec_dart_vm",
    "resolve_flutter_sdk_info",
)
load(
    "//flutter/private:flutter_android_registrant.bzl",
    "flutter_android_plugins_aggregator",
    "flutter_android_registrant",
)
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action")
load("//flutter/private:flutter_compile.bzl", "flutter_kernel_compile_action")
load("//flutter/private:flutter_info.bzl", "dedup_plugins")
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "MODULAR_KERNEL_ATTRS",
    "flutter_kernel_module_aspect",
)
load(
    "//flutter/private:flutter_linux_application.bzl",
    "compile_linux_runner",
    "linux_runner_defines",
)
load(
    "//flutter/private:flutter_native_assets.bzl",
    "bridge_dart_code_assets",
    "collect_bundled_code_asset_files",
    "write_native_assets_manifest",
)
load(
    "//flutter/private:flutter_web_compile.bzl",
    "flutter_dart2js_action",
    "flutter_dart2wasm_action",
    "make_dart2js_request",
    "make_dart2wasm_request",
    "web_build_mode",
    "web_compile_tool_inputs",
    "web_sdk_files_for_dart2js",
)
load("//flutter/private:native_sources.bzl", "native_sources_aspect")
load(
    "//flutter/private:plugin_registrant.bzl",
    "generate_dart_plugin_registrant",
    "generate_native_plugin_registrant",
    "generate_native_plugin_registrant_header",
)
load(
    "//flutter/private:validation.bzl",
    "escape_html",
    "validate_web_compiler_renderer",
    "web_renderer",
)

_INDEX_HTML_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
  <base href="$FLUTTER_BASE_HREF">
  <meta charset="UTF-8">
  <meta content="IE=Edge" http-equiv="X-UA-Compatible">
  <title>{title}</title>
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
"""

_BOOTSTRAP_JS_TEMPLATE = """\
{{flutter_build_config}}
{
  let script = document.createElement("script");
  script.src = "flutter.js";
  script.addEventListener("load", function() {
    _flutter.loader.load();
  });
  document.head.appendChild(script);
}
"""

_MANIFEST_JSON_TEMPLATE = """\
{{
    "name": "{name}",
    "short_name": "{name}",
    "start_url": ".",
    "display": "standalone",
    "background_color": "#0175C2",
    "theme_color": "#0175C2",
    "description": "A Flutter web integration test.",
    "orientation": "portrait-primary",
    "prefer_related_applications": false
}}
"""

_VERSION_JSON_TEMPLATE = """\
{{
    "app_name": "{app_name}",
    "version": "1.0.0",
    "build_number": "1",
    "package_name": "{app_name}"
}}
"""

def _build_config_js(engine_revision, builds):
    config = {
        "engineRevision": engine_revision,
        "builds": builds,
        "useLocalCanvasKit": True,
    }
    return """if (!window._flutter) {
  window._flutter = {};
}
_flutter.buildConfig = %s;
""" % json.encode(config)

def _wasm_build(renderer):
    return {
        "compileTarget": "dart2wasm",
        "renderer": renderer,
        "mainWasmPath": "main.dart.wasm",
        "jsSupportRuntimePath": "main.dart.mjs",
    }

_JS_BUILD = {
    "compileTarget": "dart2js",
    "renderer": "canvaskit",
    "mainJsPath": "main.dart.js",
}

def _exposes_package(deps, names):
    """True if any dep transitively exposes one of `names`."""
    for dep in deps:
        if DartInfo not in dep:
            continue
        for pkg in dep[DartInfo].transitive_packages.to_list():
            if pkg.package_name in names:
                return True
    return False

def _test_tag_env(ctx, env):
    """Forward `include_tags` / `exclude_tags` as the runner's tag env vars.

    Forwarded under `_ATTR` keys: a `--test_env=FLUTTER_TEST_TAGS=...` (or
    `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute,
    and it can only do that when the rule leaves those keys alone — Bazel lets
    a rule-set variable win over `--test_env` for the same key. Set only when
    the attribute names tags. Called before the `env` merge so a colliding
    `env` key is rejected like the rule's other keys.
    """
    if ctx.attr.include_tags:
        env["FLUTTER_TEST_TAGS_ATTR"] = ",".join(ctx.attr.include_tags)
    if ctx.attr.exclude_tags:
        env["FLUTTER_TEST_EXCLUDE_TAGS_ATTR"] = ",".join(ctx.attr.exclude_tags)

# Runner-contract tag keys the rule reserves for `--test_env` overrides (see
# `_test_tag_env`): an `env` entry for any of these is rejected in the
# implementations so the flag stays the one override channel.
_RESERVED_TAG_ENV_KEYS = [
    "FLUTTER_TEST_TAGS",
    "FLUTTER_TEST_EXCLUDE_TAGS",
    "FLUTTER_TEST_TAGS_ATTR",
    "FLUTTER_TEST_EXCLUDE_TAGS_ATTR",
    "FLUTTER_TEST_LIBRARY_TAGS",
]

def make_web_integration_bootstrap_content(test_import, has_integration_test = False):
    """Generate the per-target web integration test bootstrap Dart source.

    The generated file is wrapped by `make_web_wrapper_main_content` so
    `ui_web.bootstrapEngine` initializes the Flutter web engine and implicit
    view before calling `main()` here.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        Dart source string.
    """
    if has_integration_test:
        binding_import = "import 'package:integration_test/integration_test.dart';\n"
        binding_decl = ""
        binding_init = "IntegrationTestWidgetsFlutterBinding.ensureInitialized();"
    else:
        binding_import = ""
        binding_decl = """
class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding {
  static _IntegrationTestBinding? _instance;

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  static _IntegrationTestBinding ensureInitialized() {
    if (_instance == null) {
      _IntegrationTestBinding();
    }
    return _instance!;
  }

  @override
  bool get overrideHttpClient => false;

  @override
  bool get registerTestTextInput => false;

  Size? _surfaceSize;

  @override
  Future<void> setSurfaceSize(Size? size) {
    return TestAsyncUtils.guard<void>(() async {
      assert(inTest);
      if (_surfaceSize == size) {
        return;
      }
      _surfaceSize = size;
      handleMetricsChanged();
    });
  }

  @override
  ViewConfiguration createViewConfigurationFor(RenderView renderView) {
    final FlutterView view = renderView.flutterView;
    final Size? surfaceSize =
        view == platformDispatcher.implicitView ? _surfaceSize : null;
    return TestViewConfiguration.fromView(
      size: surfaceSize ?? view.physicalSize / view.devicePixelRatio,
      view: view,
    );
  }

  @override
  void setLabel(String value) {}

  @override
  void reportExceptionNoticed(FlutterErrorDetails exception) {}
}
"""
        binding_init = "_IntegrationTestBinding.ensureInitialized();"

    return """// GENERATED by flutter_integration_test — do not edit.
// ignore_for_file: type=lint

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/backend.dart';
{binding_import}import '{test_import}' as test_entrypoint;

@JS('window')
external _JSWindow get _window;

extension type _JSWindow._(JSObject _) implements JSObject {{
  external _JSLocation get location;
  external void addEventListener(String type, JSFunction listener);
}}

extension type _JSLocation._(JSObject _) implements JSObject {{
  external String get host;
  external String get protocol;
}}

@JS('WebSocket')
extension type _JSWebSocket._(JSObject _) implements JSObject {{
  external factory _JSWebSocket(String url);
  external int get readyState;
  external void send(String data);
  external void close();
  external void addEventListener(String type, JSFunction listener);
}}

extension type _JSMessageEvent._(JSObject _) implements JSObject {{
  external JSAny? get data;
}}

extension type _JSErrorEvent._(JSObject _) implements JSObject {{
  external String? get message;
  external JSAny? get error;
}}

extension type _JSPromiseRejectionEvent._(JSObject _) implements JSObject {{
  external JSAny? get reason;
}}
{binding_decl}
bool _bindingInitialized = false;

bool _isBindingInTest() {{
  return _bindingInitialized && TestWidgetsFlutterBinding.instance.inTest;
}}

Future<void> _runTestMain() async {{
  debugPrint = debugPrintSynchronously;
  {binding_init}
  debugPrint = debugPrintSynchronously;
  reportTestException = (FlutterErrorDetails details, String testDescription) {{
    debugPrint = debugPrintSynchronously;
    FlutterError.dumpErrorToConsole(details, forceReport: true);
    final String additional = testDescription.isNotEmpty
        ? '\\nThe test description was: $testDescription'
        : '';
    registerException(
      TestFailure('${{details.exceptionAsString()}}$additional'),
      details.stack ?? StackTrace.current,
    );
  }};
  _bindingInitialized = true;
  await Future(test_entrypoint.main);
}}

Future<void> main() async {{
  final wsScheme = _window.location.protocol == 'https:' ? 'wss' : 'ws';
  final wsUrl = '$wsScheme://${{_window.location.host}}/__flutter_integration_ws__';
  final ws = _JSWebSocket(wsUrl);

  final openCompleter = Completer<void>();
  ws.addEventListener(
    'open',
    ((JSObject _) {{
      if (!openCompleter.isCompleted) {{
        openCompleter.complete();
      }}
    }}).toJS,
  );
  ws.addEventListener(
    'error',
    ((JSObject _) {{
      if (!openCompleter.isCompleted) {{
        openCompleter.completeError(
          StateError('Failed to connect to integration test harness at $wsUrl'),
        );
      }}
    }}).toJS,
  );
  if (ws.readyState == 1 && !openCompleter.isCompleted) {{
    openCompleter.complete();
  }}

  void sendToHarness(Object? payload) {{
    if (ws.readyState == 1) {{
      ws.send(json.encode(payload));
    }}
  }}

  void reportUncaughtError(Object error, StackTrace? stack) {{
    final effectiveStack = stack ?? StackTrace.current;
    sendToHarness(<String, Object?>{{
      'type': 'uncaughtError',
      'message': error.toString(),
      'stack': effectiveStack.toString(),
    }});
    if (_isBindingInTest()) {{
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: effectiveStack,
          library: 'flutter_integration_test',
          context: ErrorDescription('while running integration test'),
        ),
      );
    }}
  }}

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {{
    reportUncaughtError(error, stack);
    return true;
  }};

  final FlutterExceptionHandler? prevOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {{
    prevOnError?.call(details);
    if (!_isBindingInTest()) {{
      sendToHarness(<String, Object?>{{
        'type': 'uncaughtError',
        'message': details.exceptionAsString(),
        'stack': (details.stack ?? StackTrace.current).toString(),
      }});
    }}
  }};

  _window.addEventListener(
    'error',
    ((JSObject rawEvent) {{
      final event = _JSErrorEvent._(rawEvent);
      final msg =
          event.message ??
          event.error?.dartify()?.toString() ??
          'Uncaught window error';
      reportUncaughtError(msg, StackTrace.current);
    }}).toJS,
  );

  _window.addEventListener(
    'unhandledrejection',
    ((JSObject rawEvent) {{
      final event = _JSPromiseRejectionEvent._(rawEvent);
      final reason =
          event.reason?.dartify()?.toString() ?? 'Unhandled promise rejection';
      reportUncaughtError(reason, StackTrace.current);
    }}).toJS,
  );

  final testChannel = RemoteListener.start(() => _runTestMain);

  ws.addEventListener(
    'message',
    ((JSObject rawEvent) {{
      final event = _JSMessageEvent._(rawEvent);
      final data = event.data;
      if (data != null) {{
        final text = (data as JSString).toDart;
        testChannel.sink.add(json.decode(text));
      }}
    }}).toJS,
  );
  ws.addEventListener(
    'close',
    ((JSObject _) {{
      testChannel.sink.close();
    }}).toJS,
  );

  await openCompleter.future;
  await for (final dynamic message in testChannel.stream) {{
    sendToHarness(message);
  }}
}}
""".format(
        binding_import = binding_import,
        test_import = test_import,
        binding_decl = binding_decl,
        binding_init = binding_init,
    )

def make_linux_integration_bootstrap_content(test_import, has_integration_test = False):
    """Generate the per-target Linux desktop integration test bootstrap Dart source.

    Initializes the live integration test binding (`IntegrationTestWidgetsFlutterBinding`
    when `package:integration_test` is in `deps`, or a built-in
    `LiveTestWidgetsFlutterBinding` subclass otherwise), connects to the host
    runner over the WebSocket URL in `FLUTTER_INTEGRATION_TEST_HARNESS_URL`,
    forwards uncaught errors, and drives the suite via `RemoteListener`.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        Dart source string.
    """
    if has_integration_test:
        binding_import = "import 'package:integration_test/integration_test.dart';\n"
        binding_decl = ""
        binding_init = "IntegrationTestWidgetsFlutterBinding.ensureInitialized();"
    else:
        binding_import = ""
        binding_decl = """
class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding {
  static _IntegrationTestBinding? _instance;

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  static _IntegrationTestBinding ensureInitialized() {
    if (_instance == null) {
      _IntegrationTestBinding();
    }
    return _instance!;
  }

  @override
  bool get overrideHttpClient => false;

  @override
  bool get registerTestTextInput => false;

  Size? _surfaceSize;

  @override
  Future<void> setSurfaceSize(Size? size) {
    return TestAsyncUtils.guard<void>(() async {
      assert(inTest);
      if (_surfaceSize == size) {
        return;
      }
      _surfaceSize = size;
      handleMetricsChanged();
    });
  }

  @override
  ViewConfiguration createViewConfigurationFor(RenderView renderView) {
    final FlutterView view = renderView.flutterView;
    final Size? surfaceSize =
        view == platformDispatcher.implicitView ? _surfaceSize : null;
    return TestViewConfiguration.fromView(
      size: surfaceSize ?? view.physicalSize / view.devicePixelRatio,
      view: view,
    );
  }

  @override
  void setLabel(String value) {}

  @override
  void reportExceptionNoticed(FlutterErrorDetails exception) {}
}
"""
        binding_init = "_IntegrationTestBinding.ensureInitialized();"

    return """// GENERATED by flutter_integration_test — do not edit.
// ignore_for_file: type=lint

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/backend.dart';
{binding_import}import '{test_import}' as test_entrypoint;
{binding_decl}
bool _bindingInitialized = false;

bool _isBindingInTest() {{
  return _bindingInitialized && TestWidgetsFlutterBinding.instance.inTest;
}}

void _catchIsolateErrors(void Function(Object error, StackTrace? stack) onError) {{
  final errorPort = ReceivePort();
  Isolate.current.setErrorsFatal(false);
  Isolate.current.addErrorListener(errorPort.sendPort);
  errorPort.listen((dynamic message) {{
    final list = message as List;
    final error = IsolateSpawnException(list[0] as String);
    final stack = list[1] == null
        ? StackTrace.empty
        : StackTrace.fromString(list[1] as String);
    onError(error, stack);
    Zone.current.handleUncaughtError(error, stack);
  }});
}}

Future<void> _runTestMain() async {{
  debugPrint = debugPrintSynchronously;
  {binding_init}
  final PointerDataPacketCallback? prevOnPointerDataPacket =
      PlatformDispatcher.instance.onPointerDataPacket;
  if (prevOnPointerDataPacket != null) {{
    PlatformDispatcher.instance.onPointerDataPacket =
        (PointerDataPacket packet) {{
          final Iterable<RenderView> views =
              WidgetsBinding.instance.renderViews;
          if (views.isEmpty ||
              packet.data.any(
                (PointerData datum) => !views.any(
                  (RenderView r) => r.flutterView.viewId == datum.viewId,
                ),
              )) {{
            return;
          }}
          prevOnPointerDataPacket(packet);
        }};
  }}
  debugPrint = debugPrintSynchronously;
  reportTestException = (FlutterErrorDetails details, String testDescription) {{
    debugPrint = debugPrintSynchronously;
    FlutterError.dumpErrorToConsole(details, forceReport: true);
    final String additional = testDescription.isNotEmpty
        ? '\\nThe test description was: $testDescription'
        : '';
    registerException(
      TestFailure('${{details.exceptionAsString()}}$additional'),
      details.stack ?? StackTrace.current,
    );
  }};
  _bindingInitialized = true;
  await Future(test_entrypoint.main);
}}

Future<void> main() async {{
  final wsUrl = Platform.environment['FLUTTER_INTEGRATION_TEST_HARNESS_URL'];
  if (wsUrl == null || wsUrl.isEmpty) {{
    stderr.writeln(
      'flutter_integration_test bootstrap: '
      'FLUTTER_INTEGRATION_TEST_HARNESS_URL not set',
    );
    exit(64);
  }}

  final ws = await WebSocket.connect(wsUrl);

  void sendToHarness(Object? payload) {{
    if (ws.readyState == WebSocket.open) {{
      ws.add(json.encode(payload));
    }}
  }}

  void reportUncaughtError(Object error, StackTrace? stack) {{
    final effectiveStack = stack ?? StackTrace.current;
    sendToHarness(<String, Object?>{{
      'type': 'uncaughtError',
      'message': error.toString(),
      'stack': effectiveStack.toString(),
    }});
    if (_isBindingInTest()) {{
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: effectiveStack,
          library: 'flutter_integration_test',
          context: ErrorDescription('while running integration test'),
        ),
      );
    }}
  }}

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {{
    reportUncaughtError(error, stack);
    return true;
  }};

  final FlutterExceptionHandler? prevOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {{
    prevOnError?.call(details);
    if (!_isBindingInTest()) {{
      sendToHarness(<String, Object?>{{
        'type': 'uncaughtError',
        'message': details.exceptionAsString(),
        'stack': (details.stack ?? StackTrace.current).toString(),
      }});
    }}
  }};

  final testChannel = RemoteListener.start(() {{
    _catchIsolateErrors(reportUncaughtError);
    return _runTestMain;
  }});

  unawaited(
    ws
        .map<dynamic>((dynamic m) => json.decode(m as String))
        .pipe(testChannel.sink),
  );

  await for (final dynamic message in testChannel.stream) {{
    sendToHarness(message);
  }}
  try {{
    await ws.close();
  }} catch (_) {{}}
  exit(0);
}}
""".format(
        binding_import = binding_import,
        test_import = test_import,
        binding_decl = binding_decl,
        binding_init = binding_init,
    )

def make_android_integration_bootstrap_content(test_import, has_integration_test = False):
    """Generate the per-target Android integration test bootstrap Dart source.

    Initializes the live integration test binding (`IntegrationTestWidgetsFlutterBinding`
    when `package:integration_test` is in `deps`, or a built-in
    `LiveTestWidgetsFlutterBinding` subclass otherwise), connects to the host
    runner over a localhost WebSocket forwarded via `adb reverse` (accepting
    the harness URL via `dart_entrypoint_args`, `FLUTTER_INTEGRATION_TEST_HARNESS_URL`,
    or the default `ws://127.0.0.1:38427/__flutter_integration_ws__`),
    forwards uncaught errors, and drives the suite via `RemoteListener`.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        Dart source string.
    """
    if has_integration_test:
        binding_import = "import 'package:integration_test/integration_test.dart';\n"
        binding_decl = ""
        binding_init = "IntegrationTestWidgetsFlutterBinding.ensureInitialized();"
    else:
        binding_import = ""
        binding_decl = """
class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding {
  static _IntegrationTestBinding? _instance;

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  static _IntegrationTestBinding ensureInitialized() {
    if (_instance == null) {
      _IntegrationTestBinding();
    }
    return _instance!;
  }

  @override
  bool get overrideHttpClient => false;

  @override
  bool get registerTestTextInput => false;

  Size? _surfaceSize;

  @override
  Future<void> setSurfaceSize(Size? size) {
    return TestAsyncUtils.guard<void>(() async {
      assert(inTest);
      if (_surfaceSize == size) {
        return;
      }
      _surfaceSize = size;
      handleMetricsChanged();
    });
  }

  @override
  ViewConfiguration createViewConfigurationFor(RenderView renderView) {
    final FlutterView view = renderView.flutterView;
    final Size? surfaceSize =
        view == platformDispatcher.implicitView ? _surfaceSize : null;
    return TestViewConfiguration.fromView(
      size: surfaceSize ?? view.physicalSize / view.devicePixelRatio,
      view: view,
    );
  }

  @override
  void setLabel(String value) {}

  @override
  void reportExceptionNoticed(FlutterErrorDetails exception) {}
}
"""
        binding_init = "_IntegrationTestBinding.ensureInitialized();"

    return """// GENERATED by flutter_integration_test — do not edit.
// ignore_for_file: type=lint

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/backend.dart';
{binding_import}import '{test_import}' as test_entrypoint;
{binding_decl}
bool _bindingInitialized = false;

bool _isBindingInTest() {{
  return _bindingInitialized && TestWidgetsFlutterBinding.instance.inTest;
}}

void _catchIsolateErrors(void Function(Object error, StackTrace? stack) onError) {{
  final errorPort = ReceivePort();
  Isolate.current.setErrorsFatal(false);
  Isolate.current.addErrorListener(errorPort.sendPort);
  errorPort.listen((dynamic message) {{
    final list = message as List;
    final error = IsolateSpawnException(list[0] as String);
    final stack = list[1] == null
        ? StackTrace.empty
        : StackTrace.fromString(list[1] as String);
    onError(error, stack);
    Zone.current.handleUncaughtError(error, stack);
  }});
}}

Future<void> _runTestMain() async {{
  debugPrint = debugPrintSynchronously;
  {binding_init}
  final PointerDataPacketCallback? prevOnPointerDataPacket =
      PlatformDispatcher.instance.onPointerDataPacket;
  if (prevOnPointerDataPacket != null) {{
    PlatformDispatcher.instance.onPointerDataPacket =
        (PointerDataPacket packet) {{
          final Iterable<RenderView> views =
              WidgetsBinding.instance.renderViews;
          if (views.isEmpty ||
              packet.data.any(
                (PointerData datum) => !views.any(
                  (RenderView r) => r.flutterView.viewId == datum.viewId,
                ),
              )) {{
            return;
          }}
          prevOnPointerDataPacket(packet);
        }};
  }}
  debugPrint = debugPrintSynchronously;
  reportTestException = (FlutterErrorDetails details, String testDescription) {{
    debugPrint = debugPrintSynchronously;
    FlutterError.dumpErrorToConsole(details, forceReport: true);
    final String additional = testDescription.isNotEmpty
        ? '\\nThe test description was: $testDescription'
        : '';
    registerException(
      TestFailure('${{details.exceptionAsString()}}$additional'),
      details.stack ?? StackTrace.current,
    );
  }};
  _bindingInitialized = true;
  await Future(test_entrypoint.main);
}}

Future<void> main([List<String> args = const <String>[]]) async {{
  String? wsUrl;
  for (final String arg in args) {{
    if (arg.startsWith('ws://') || arg.startsWith('wss://')) {{
      wsUrl = arg;
      break;
    }}
    if (arg.startsWith('--harness-url=')) {{
      wsUrl = arg.substring('--harness-url='.length);
      break;
    }}
  }}
  wsUrl ??= Platform.environment['FLUTTER_INTEGRATION_TEST_HARNESS_URL'];
  if (wsUrl == null || wsUrl.isEmpty) {{
    wsUrl = 'ws://127.0.0.1:38427/__flutter_integration_ws__';
  }}

  WebSocket? connectedWs;
  Object? lastConnectError;
  for (var attempt = 0; attempt < 30; attempt++) {{
    try {{
      connectedWs = await WebSocket.connect(wsUrl);
      break;
    }} catch (e) {{
      lastConnectError = e;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }}
  }}
  if (connectedWs == null) {{
    stderr.writeln(
      'flutter_integration_test bootstrap: failed to connect to $wsUrl: '
      '$lastConnectError',
    );
    exit(64);
  }}
  final ws = connectedWs;

  void sendToHarness(Object? payload) {{
    if (ws.readyState == WebSocket.open) {{
      ws.add(json.encode(payload));
    }}
  }}

  void reportUncaughtError(Object error, StackTrace? stack) {{
    final effectiveStack = stack ?? StackTrace.current;
    sendToHarness(<String, Object?>{{
      'type': 'uncaughtError',
      'message': error.toString(),
      'stack': effectiveStack.toString(),
    }});
    if (_isBindingInTest()) {{
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: effectiveStack,
          library: 'flutter_integration_test',
          context: ErrorDescription('while running integration test'),
        ),
      );
    }}
  }}

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {{
    reportUncaughtError(error, stack);
    return true;
  }};

  final FlutterExceptionHandler? prevOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {{
    prevOnError?.call(details);
    if (!_isBindingInTest()) {{
      sendToHarness(<String, Object?>{{
        'type': 'uncaughtError',
        'message': details.exceptionAsString(),
        'stack': (details.stack ?? StackTrace.current).toString(),
      }});
    }}
  }};

  final testChannel = RemoteListener.start(() {{
    _catchIsolateErrors(reportUncaughtError);
    return _runTestMain;
  }});

  unawaited(
    ws
        .map<dynamic>((dynamic m) => json.decode(m as String))
        .pipe(testChannel.sink),
  );

  await for (final dynamic message in testChannel.stream) {{
    sendToHarness(message);
  }}
  try {{
    await ws.close();
  }} catch (_) {{}}
  exit(0);
}}
""".format(
        binding_import = binding_import,
        test_import = test_import,
        binding_decl = binding_decl,
        binding_init = binding_init,
    )

def _resolve_main_and_srcs(ctx):
    """Resolve the integration test entrypoint File and additional source Files."""
    if ctx.file.main != None:
        main_file = ctx.file.main
        extra_srcs = [
            f
            for f in (ctx.files.srcs + ctx.files.app_srcs)
            if f != main_file
        ]
        return main_file, extra_srcs

    if len(ctx.files.srcs) == 1:
        main_file = ctx.files.srcs[0]
        extra_srcs = [f for f in ctx.files.app_srcs if f != main_file]
        return main_file, extra_srcs

    test_candidates = [
        f
        for f in ctx.files.srcs
        if f.short_path.endswith("_test.dart")
    ]
    if len(test_candidates) == 1:
        main_file = test_candidates[0]
        extra_srcs = [
            f
            for f in (ctx.files.srcs + ctx.files.app_srcs)
            if f != main_file
        ]
        return main_file, extra_srcs

    fail(
        "%s: specify `main` (or pass a single test file in `srcs`)." % ctx.label,
    )

def _build_analyzable_and_coverage_infos(ctx, package_name, lib_root, main_file, extra_srcs):
    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs", "app_srcs", "main"],
        dependency_attributes = ["deps"],
    )

    prefix = package_lib_prefix(lib_root)
    in_pkg_srcs = []
    non_pkg_srcs = []
    for f in [main_file] + extra_srcs:
        if f.short_path.startswith(prefix):
            in_pkg_srcs.append(f)
        else:
            non_pkg_srcs.append(f)

    analyzable_info = dart_analyzable_info_with_package(
        label = ctx.label,
        package_name = package_name,
        lib_root = lib_root,
        deps = ctx.attr.deps + [ctx.attr._sky_engine],
        srcs = non_pkg_srcs,
        package_srcs = in_pkg_srcs,
        language_version = ctx.attr.language_version,
    )
    return instrumented_files_info, analyzable_info

def _web_sdk_file_list(ctx):
    """All files the web SDK target carries (renderer/template lookup)."""
    return ctx.attr._web_sdk.files.to_list() if ctx.attr._web_sdk else []

def _flutter_integration_test_impl(ctx):
    if ctx.attr.platform != "web":
        fail(
            "%s: flutter_integration_test does not yet support platform = %r " % (
                ctx.label,
                ctx.attr.platform,
            ) + "(supported: \"web\", \"linux\", \"android\").",
        )

    if not _exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    main_file, extra_srcs = _resolve_main_and_srcs(ctx)

    renderer = web_renderer(ctx.attr.compiler, ctx.attr.renderer)
    validate_web_compiler_renderer(ctx.attr.compiler, renderer)

    flutter_sdk_info = resolve_flutter_sdk_info(ctx)
    user_defines = merge_dart_defines(ctx)
    mode = web_build_mode(ctx)
    is_debug = mode == "debug"

    package_name = ctx.attr.package_name or ctx.label.name
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # Collect sources and synthesize the package config.
    all_srcs = list(extra_srcs) + collect_transitive_srcs(ctx.attr.deps).to_list()
    packages = collect_packages(ctx.attr.deps)
    packages = synthesize_app_package(
        ctx.label,
        packages,
        package_name,
        lib_root,
        ctx.attr.language_version,
    )

    pc = compile_kernel_package_config(
        ctx,
        packages,
        all_srcs + [main_file],
        roots = {package_name: True} if package_name else None,
    )
    config_file = pc.config_file
    all_srcs = pc.srcs

    # Step 1a: Generate the test bootstrap `<name>_bootstrap.dart`.
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")
    bootstrap_rel = app_scheme_rel_path(bootstrap)
    bootstrap_depth = len(bootstrap_rel.split("/")) - 1
    test_import = resolve_wrapper_main_import(
        package_name,
        lib_root,
        main_file.short_path,
        app_scheme_rel_path(main_file),
        bootstrap_depth,
    )
    has_integration_test = _exposes_package(ctx.attr.deps, ["integration_test"])
    ctx.actions.write(
        bootstrap,
        make_web_integration_bootstrap_content(
            test_import = test_import,
            has_integration_test = has_integration_test,
        ),
    )

    # Step 1b: Wrap `<name>_bootstrap.dart` with `ui_web.bootstrapEngine()` so
    # the Flutter web engine creates its implicit view before running the test.
    all_dep_plugins = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
    plugins = dedup_plugins(all_dep_plugins)
    registrant = generate_dart_plugin_registrant(ctx, plugins, target_platform = "web")

    wrapper = ctx.actions.declare_file(ctx.label.name + "_wrapper_main.dart")
    wrapper_content = make_web_wrapper_main_content(
        bootstrap.basename,
        registrant.basename if registrant else None,
    )
    ctx.actions.write(wrapper, wrapper_content)
    entrypoint = wrapper
    extra_wrapper_srcs = [main_file, bootstrap, wrapper]
    if registrant:
        extra_wrapper_srcs.append(registrant)
    all_srcs = all_srcs + extra_wrapper_srcs

    # Step 2: Compile to JS or WASM. The request struct is gathered once here
    # and each compiler builds its own request from it (see
    # `flutter_web_compile.bzl`).
    compile = struct(
        dart = flutter_sdk_info.dart,
        flutter_sdk_info = flutter_sdk_info,
        dart2wasm_platform_dill = ctx.file._dart2wasm_platform_dill,
        dart2js_platform_dill = ctx.file._dart2js_platform_dill,
        web_sdk_files = web_sdk_files_for_dart2js(ctx.attr._web_sdk),
        main_dart = entrypoint,
        srcs = all_srcs,
        package_config = config_file,
        mode = mode,
        defines = user_defines,
        renderer = renderer,
        stage_salt = "",
        web_compile_tool = ctx.executable._web_template_tool,
        web_compile_inputs = web_compile_tool_inputs(flutter_sdk_info.dart_vm_files),
        web_guard_tool = ctx.executable._web_guard_tool,
        enable_experiments = ctx.attr.enable_experiments,
    )
    compile_outputs = []
    compile_copies = []
    dart2js_dirs = []

    if ctx.attr.compiler == "dart2wasm":
        output_wasm = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm")
        output_mjs = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.mjs")
        output_wasm_map = None
        if ctx.attr.source_maps:
            output_wasm_map = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm.map")
        flutter_dart2wasm_action(ctx, make_dart2wasm_request(
            compile,
            struct(
                optimization_level = ctx.attr.optimization_level_wasm,
                minify = ctx.attr.minify_wasm,
                strip_wasm = ctx.attr.strip_wasm,
            ),
            output_wasm,
            output_mjs,
            output_wasm_map,
        ))
        compile_outputs = [output_wasm, output_mjs]
        compile_copies = [
            {"src": output_wasm.path, "dst": "main.dart.wasm"},
            {"src": output_mjs.path, "dst": "main.dart.mjs"},
        ]
        if output_wasm_map != None:
            compile_outputs.append(output_wasm_map)
            compile_copies.append({"src": output_wasm_map.path, "dst": "main.dart.wasm.map"})
        builds = [_wasm_build(renderer)]
    else:
        output_js_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js")
        flutter_dart2js_action(ctx, make_dart2js_request(
            compile,
            struct(
                optimization_level = ctx.attr.optimization_level_js,
                minify = ctx.attr.minify_js,
                native_null_assertions = ctx.attr.native_null_assertions,
                frequency_based_minification = ctx.attr.frequency_based_minification,
                dump_info = False,
                source_maps = ctx.attr.source_maps,
            ),
            renderer,
            output_js_dir,
        ))
        dart2js_dirs = [output_js_dir]
        builds = [_JS_BUILD]

    # Step 3: Compile shaders + bundle assets.
    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, "web")
    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_build_assets(
        ctx,
        flutter_sdk_info,
        flutter_assets,
        compiled_shaders,
        target_platform = "web",
        kernel_dill = None,
        is_debug = is_debug,
    )

    # Step 4: Generate web templates (index.html, flutter_bootstrap.js, manifest.json, version.json).
    safe_title = escape_html(ctx.label.name)
    index_template = ctx.actions.declare_file(ctx.label.name + "_index_template.html")
    ctx.actions.write(index_template, _INDEX_HTML_TEMPLATE.format(title = safe_title))

    bootstrap_template = ctx.actions.declare_file(ctx.label.name + "_bootstrap_template.js")
    ctx.actions.write(bootstrap_template, _BOOTSTRAP_JS_TEMPLATE)

    manifest_json = ctx.actions.declare_file(ctx.label.name + "_manifest.json")
    ctx.actions.write(manifest_json, _MANIFEST_JSON_TEMPLATE.format(name = safe_title))

    version_json = ctx.actions.declare_file(ctx.label.name + "_version.json")
    ctx.actions.write(version_json, _VERSION_JSON_TEMPLATE.format(app_name = package_name))

    flutter_js_file = None
    renderer_files = []
    for f in _web_sdk_file_list(ctx):
        if f.path.endswith("/flutter_js/flutter.js"):
            flutter_js_file = f
        if "/web-sdk/canvaskit/" in f.path:
            renderer_files.append(f)

    index_html = ctx.actions.declare_file(ctx.label.name + "_index.html")
    bootstrap_js = ctx.actions.declare_file(ctx.label.name + "_flutter_bootstrap.js")

    build_config = _build_config_js(flutter_sdk_info.engine_revision, builds)
    shared_builtins = {
        "flutter_build_config": {"value": build_config},
        "flutter_service_worker_version": {"value": "null"},
    }
    template_inputs = [index_template, bootstrap_template]
    if flutter_js_file:
        shared_builtins["flutter_js"] = {"file": flutter_js_file.path}
        template_inputs.append(flutter_js_file)

    index_builtins = dict(shared_builtins)
    index_builtins["flutter_bootstrap_js"] = {"from_output": 0}

    template_config = {
        "web_defines": {},
        "keep_placeholders": [],
        "files": [
            {
                "template": bootstrap_template.path,
                "output": bootstrap_js.path,
                "label": "flutter_bootstrap.js",
                "base_href": "",
                "static_assets_url": None,
                "dev_loop_guard": False,
                "manages_service_worker": False,
                "check_constructs": True,
                "builtins": shared_builtins,
            },
            {
                "template": index_template.path,
                "output": index_html.path,
                "label": "index.html",
                "base_href": "/",
                "static_assets_url": "/",
                "dev_loop_guard": False,
                "manages_service_worker": False,
                "check_constructs": True,
                "builtins": index_builtins,
            },
        ],
    }
    template_config_file = ctx.actions.declare_file(ctx.label.name + "_web_template_config.json")
    ctx.actions.write(template_config_file, json.encode(template_config))

    ctx.actions.run(
        executable = flutter_sdk_info.dart,
        arguments = [
            ctx.executable._web_template_tool.path,
            "--config",
            template_config_file.path,
        ],
        inputs = depset(
            direct = template_inputs + [template_config_file, ctx.executable._web_template_tool],
            transitive = [flutter_sdk_info.dart_vm_files],
        ),
        outputs = [index_html, bootstrap_js],
        mnemonic = "FlutterWebTemplate",
        progress_message = "Substituting web templates for %s" % ctx.label,
    )

    # Step 5: Assemble web bundle directory.
    output_dir = ctx.actions.declare_directory(ctx.label.name + "_web")
    copies = list(compile_copies)
    copies.extend([
        {"src": index_html.path, "dst": "index.html"},
        {"src": bootstrap_js.path, "dst": "flutter_bootstrap.js"},
        {"src": manifest_json.path, "dst": "manifest.json"},
        {"src": version_json.path, "dst": "version.json"},
    ])
    engine_inputs = []
    if flutter_js_file:
        copies.append({"src": flutter_js_file.path, "dst": "flutter.js"})
        engine_inputs.append(flutter_js_file)
    for f in renderer_files:
        idx = f.path.find("/web-sdk/canvaskit/")
        if idx >= 0:
            rel = "canvaskit/" + f.path[idx + len("/web-sdk/canvaskit/"):]
            copies.append({"src": f.path, "dst": rel})
            engine_inputs.append(f)

    copy_dirs = [{"src": flutter_assets.path, "dst": "assets"}]
    for d in dart2js_dirs:
        copy_dirs.append({
            "src": d.path,
            "dst": ".",
            "exclude": ["*.deps", "*.info.json"],
        })

    bundle_config = {
        "output_dir": output_dir.path,
        "copies": copies,
        "copy_dirs": copy_dirs,
        "extracts": [],
    }
    bundle_config_file = ctx.actions.declare_file(ctx.label.name + "_web_bundle_config.json")
    ctx.actions.write(bundle_config_file, json.encode(bundle_config))

    exec_dart, dart_vm_files = resolve_exec_dart_vm(ctx, flutter_sdk_info)
    all_bundle_inputs = (
        compile_outputs +
        dart2js_dirs +
        engine_inputs +
        [flutter_assets, index_html, bootstrap_js, manifest_json, version_json, bundle_config_file]
    )
    ctx.actions.run(
        executable = exec_dart,
        arguments = [
            ctx.executable._bundle_tool.path,
            "--config",
            bundle_config_file.path,
        ],
        inputs = depset(
            direct = all_bundle_inputs + [ctx.executable._bundle_tool],
            transitive = [dart_vm_files],
        ),
        outputs = [output_dir],
        mnemonic = "FlutterWebBundle",
        progress_message = "Bundling Flutter web integration test %s" % ctx.label,
    )

    # Step 6: Symlink the runner executable and wire test environment + runfiles.
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

    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": ctx.attr.platform,
        "FLUTTER_INTEGRATION_TEST_WEB_DIR": runfiles_path(output_dir, workspace_name),
        "FLUTTER_INTEGRATION_TEST_BROWSER": runfiles_path(ctx.file._chrome_headless_shell, workspace_name),
        "FLUTTER_INTEGRATION_TEST_FONTCONFIG": runfiles_path(ctx.file._chrome_fontconfig, workspace_name),
        "FLUTTER_INTEGRATION_TEST_ROBOTO_FONT": runfiles_path(ctx.file._roboto_font, workspace_name),
        "FLUTTER_INTEGRATION_TEST_PATH": main_file.short_path,
        "FLUTTER_INTEGRATION_TEST_DECLARED_ENV": json.encode(ctx.attr.env),
    }
    _test_tag_env(ctx, env)

    # The entrypoint's own `@Tags`, extracted at build time (see
    # `extract_library_tags_action`): the runner injects them as the root
    # group's metadata, so they inherit down to every test in the suite.
    library_tags = extract_library_tags_action(ctx, main_file)
    env["FLUTTER_TEST_LIBRARY_TAGS"] = runfiles_path(library_tags, workspace_name)
    for key, value in ctx.attr.env.items():
        if key in env or key in _RESERVED_TAG_ENV_KEYS:
            fail((
                "flutter_integration_test {name}: env key {key} is set by the " +
                "rule itself and cannot be overridden."
            ).format(name = ctx.label.name, key = key))
        env[key] = value

    env_info = testing.TestEnvironment(env)

    runtime_files = [
        output_dir,
        ctx.file._chrome_headless_shell,
        ctx.file._chrome_fontconfig,
        ctx.file._roboto_font,
        library_tags,
    ] + ctx.attr._chrome_all_files.files.to_list()
    tool_runfiles = tool[DefaultInfo].default_runfiles
    runfiles = ctx.runfiles(
        files = runtime_files + ctx.files.data,
    )
    runfiles = runfiles.merge(tool_runfiles)
    for data_target in ctx.attr.data:
        runfiles = runfiles.merge(data_target[DefaultInfo].default_runfiles)

    instrumented_files_info, analyzable_info = _build_analyzable_and_coverage_infos(
        ctx,
        package_name,
        lib_root,
        main_file,
        extra_srcs,
    )

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
        env_info,
        instrumented_files_info,
        analyzable_info,
    ]

def _flutter_linux_integration_test_impl(ctx):
    if ctx.attr.platform != "linux":
        fail(
            "%s: _flutter_linux_integration_test requires platform = 'linux', got %r." % (
                ctx.label,
                ctx.attr.platform,
            ),
        )

    if not _exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    hook_err = check_unreplaced_hooks(ctx.label, ctx.attr.deps)
    if hook_err != None:
        fail(hook_err)

    main_file, extra_srcs = _resolve_main_and_srcs(ctx)
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)

    mode = "profile" if ctx.attr.profile else flutter_build_mode(ctx)
    is_debug = mode == "debug"
    aot = not is_debug
    strip = ctx.var["COMPILATION_MODE"] == "opt"

    if not is_debug and flutter_sdk_info.target_os in ("linux", "macos", "windows"):
        fail(
            "AOT cross-compilation between desktop platforms is not supported. " +
            "Build on a Linux host, or use debug mode (-c dbg).",
        )
    if not is_debug and not flutter_sdk_info.gen_snapshot:
        fail(
            "No target-compatible AOT gen_snapshot toolchain is registered for " +
            "this host and target platform.",
        )
    if flutter_sdk_info.engine_library == None:
        fail(
            "No Linux engine library available in the Flutter toolchain. " +
            "Run Linux integration tests on a Linux host.",
        )

    package_name = ctx.attr.package_name or ctx.label.name
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # Aggregate Native Assets and Data Assets from transitive deps.
    transitive_native_asset_depsets = []
    transitive_data_asset_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo not in dep:
            continue
        info = dep[FlutterInfo]
        transitive_native_asset_depsets.append(info.native_assets)
        transitive_data_asset_depsets.append(info.data_assets)
    transitive_native_assets = depset(transitive = transitive_native_asset_depsets)
    transitive_data_assets = depset(transitive = transitive_data_asset_depsets)

    native_assets_list = transitive_native_assets.to_list()
    declared_ids = {asset.asset_id: True for asset in native_assets_list}
    native_assets_list = native_assets_list + [
        asset
        for asset in bridge_dart_code_assets(ctx, ctx.attr.deps)
        if asset.asset_id not in declared_ids
    ]

    target_arch = host_target_arch(ctx, flutter_sdk_info)
    native_assets_manifest = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    write_native_assets_manifest(
        ctx = ctx,
        output_file = native_assets_manifest,
        native_assets = native_assets_list,
        target_os = "linux",
        target_arch = target_arch,
    )
    bundled_code_assets = collect_bundled_code_asset_files(native_assets_list)

    # Step 1: Generate `<name>_linux_bootstrap.dart` and compile kernel `.dill`.
    packages = collect_packages(ctx.attr.deps)
    packages = synthesize_app_package(
        ctx.label,
        packages,
        package_name,
        lib_root,
        ctx.attr.language_version,
    )

    bootstrap = ctx.actions.declare_file(ctx.label.name + "_linux_bootstrap.dart")
    main_location = app_main_location(package_name, lib_root, main_file)
    has_integration_test = _exposes_package(ctx.attr.deps, ["integration_test"])
    ctx.actions.write(
        bootstrap,
        make_linux_integration_bootstrap_content(
            test_import = main_location.uri,
            has_integration_test = has_integration_test,
        ),
    )

    all_dep_plugins = []
    linux_plugin_lib_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
            linux_plugin_lib_depsets.append(dep[FlutterInfo].linux_plugin_libraries)
    plugins = dedup_plugins(all_dep_plugins)
    linux_plugin_libraries = depset(transitive = linux_plugin_lib_depsets)

    registrant = generate_dart_plugin_registrant(
        ctx,
        plugins,
        target_platform = "linux",
    )
    registrant_location = app_scheme_location(registrant) if registrant else None
    bootstrap_location = app_scheme_location(bootstrap)

    all_srcs = (
        list(extra_srcs) +
        collect_transitive_srcs(ctx.attr.deps).to_list() +
        [main_file, bootstrap] +
        ([registrant] if registrant else [])
    )
    pc = compile_kernel_package_config(
        ctx,
        packages,
        all_srcs,
        roots = {package_name: True} if package_name else None,
    )

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
    else:
        platform_dill = flutter_sdk_info.platform_kernel_dill
        if platform_dill == None:
            fail(
                "Unresolved @rules_flutter//flutter:toolchain_type: " +
                "Flutter toolchain does not provide platform_kernel_dill. " +
                "Register a Flutter toolchain (e.g. `flutter.toolchain()` in " +
                "MODULE.bazel) or set `platform_kernel_dill` on `flutter_toolchain`.",
            )

    user_defines = merge_dart_defines(ctx)
    all_defines = list(user_defines)
    if mode == "profile":
        all_defines.append("dart.vm.profile=true")
    elif aot:
        all_defines.append("dart.vm.product=true")

    extra_frontend_flags = []
    if ctx.attr.track_widget_creation:
        extra_frontend_flags.append("--track-widget-creation")

    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        kernel_filter_tool = ctx.executable._kernel_filter_tool,
        frontend_server = flutter_sdk_info.frontend_server,
        platform_dill = platform_dill,
        main = bootstrap,
        entrypoint_uri = bootstrap_location.uri,
        srcs = pc.srcs,
        package_config = pc.config_file,
        output = kernel_dill,
        aot = aot,
        defines = all_defines,
        target = "flutter",
        extra_flags = extra_frontend_flags,
        native_assets_manifest = native_assets_manifest,
        dart_plugin_registrant_uri = registrant_location.uri if registrant_location else None,
    )

    # Step 2: AOT compile when not in debug mode.
    aot_output = None
    if not is_debug:
        aot_output = ctx.actions.declare_file(ctx.label.name + ".so")
        flutter_aot_elf_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            kernel_dill = kernel_dill,
            output = aot_output,
            strip = strip,
        )

    # Step 3: Compile shaders + bundle assets.
    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, "linux")
    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_build_assets(
        ctx,
        flutter_sdk_info,
        flutter_assets,
        compiled_shaders,
        target_platform = "linux",
        kernel_dill = kernel_dill,
        is_debug = is_debug,
        data_assets = transitive_data_assets,
    )

    # Step 4: Generate native C++ plugin registrant and compile GTK runner binary.
    native_registrant_cc = generate_native_plugin_registrant(ctx, plugins, "linux")
    native_registrant_h = generate_native_plugin_registrant_header(ctx, "linux")

    plugin_srcs = []
    plugin_hdrs = []
    plugin_include_dirs = []
    for entry in linux_plugin_libraries.to_list():
        plugin_srcs.extend(entry.srcs.to_list())
        plugin_hdrs.extend(entry.hdrs.to_list())
        plugin_include_dirs.extend(entry.include_dirs.to_list())

    engine_files = flutter_sdk_info.engine_library.files.to_list()
    runner_binary = compile_linux_runner(
        ctx,
        runner_srcs = [ctx.file._linux_runner_source],
        runner_hdrs = [],
        engine_files = engine_files,
        defines = linux_runner_defines(ctx.attr.gtk_app_id, ctx.attr.window_title),
        registrant_srcs = [native_registrant_cc],
        registrant_hdrs = [native_registrant_h],
        linux_sysroot = flutter_sdk_info.linux_sysroot,
        target_arch = flutter_sdk_info.target_arch,
        plugin_srcs = plugin_srcs,
        plugin_hdrs = plugin_hdrs,
        plugin_include_dirs = plugin_include_dirs,
    )

    # Step 5: Assemble Linux desktop bundle directory.
    native_libs = collect_native_libs(ctx.attr.native_deps)
    transitive_native_depsets = [
        dep[FlutterInfo].transitive_native_libs
        for dep in ctx.attr.deps
        if FlutterInfo in dep
    ]
    if transitive_native_depsets:
        native_libs.extend(depset(transitive = transitive_native_depsets).to_list())
    native_libs.extend(bundled_code_assets.to_list())

    bundle_dir = ctx.actions.declare_directory(ctx.label.name + "_linux")
    binary_name = ctx.label.name
    copies = compute_desktop_bundle_copies(
        is_debug = is_debug,
        kernel_dill_path = kernel_dill.path if is_debug else None,
        aot_output_path = aot_output.path if aot_output else None,
        aot_dst = "lib/libapp.so",
        icu_data_path = flutter_sdk_info.icu_data.path,
        engine_basenames = [(f.path, f.basename) for f in engine_files],
        native_basenames = [(lib.path, lib.basename) for lib in native_libs],
    )
    copies.append({"src": runner_binary.path, "dst": binary_name})

    bundle_config = {
        "output_dir": bundle_dir.path,
        "copies": copies,
        "copy_dirs": [
            {"src": flutter_assets.path, "dst": "data/flutter_assets"},
        ],
    }
    bundle_config_file = ctx.actions.declare_file(ctx.label.name + "_linux_bundle_config.json")
    ctx.actions.write(bundle_config_file, json.encode(bundle_config))

    extra_bundle_inputs = [kernel_dill] if is_debug else [aot_output]
    all_bundle_inputs = (
        [bundle_config_file, flutter_assets, flutter_sdk_info.icu_data, runner_binary] +
        extra_bundle_inputs +
        native_libs +
        engine_files
    )
    exec_dart, dart_vm_files = resolve_exec_dart_vm(ctx, flutter_sdk_info)
    ctx.actions.run(
        executable = exec_dart,
        arguments = [
            ctx.executable._bundle_tool.path,
            "--config",
            bundle_config_file.path,
        ],
        inputs = depset(
            direct = all_bundle_inputs + [ctx.executable._bundle_tool],
            transitive = [dart_vm_files],
        ),
        outputs = [bundle_dir],
        mnemonic = "FlutterLinuxBundle",
        progress_message = "Bundling Flutter Linux integration test %s" % ctx.label,
    )

    # Step 6: Symlink the runner executable and wire test environment + runfiles.
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

    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": "linux",
        "FLUTTER_INTEGRATION_TEST_LINUX_BUNDLE": runfiles_path(bundle_dir, workspace_name),
        "FLUTTER_INTEGRATION_TEST_LINUX_BINARY": binary_name,
        "FLUTTER_INTEGRATION_TEST_XVFB": runfiles_path(ctx.file._linux_xvfb, workspace_name),
        "FLUTTER_INTEGRATION_TEST_XKBCOMP": runfiles_path(ctx.file._linux_xkbcomp, workspace_name),
        "FLUTTER_INTEGRATION_TEST_FONTCONFIG": runfiles_path(ctx.file._linux_fontconfig, workspace_name),
        "FLUTTER_INTEGRATION_TEST_PATH": main_file.short_path,
        "FLUTTER_INTEGRATION_TEST_DECLARED_ENV": json.encode(ctx.attr.env),
    }
    _test_tag_env(ctx, env)

    # The entrypoint's own `@Tags`, extracted at build time (see
    # `extract_library_tags_action`): the runner injects them as the root
    # group's metadata, so they inherit down to every test in the suite.
    library_tags = extract_library_tags_action(ctx, main_file)
    env["FLUTTER_TEST_LIBRARY_TAGS"] = runfiles_path(library_tags, workspace_name)
    for key, value in ctx.attr.env.items():
        if key in env or key in _RESERVED_TAG_ENV_KEYS:
            fail((
                "flutter_integration_test {name}: env key {key} is set by the " +
                "rule itself and cannot be overridden."
            ).format(name = ctx.label.name, key = key))
        env[key] = value

    env_info = testing.TestEnvironment(env)

    runtime_files = [
        bundle_dir,
        ctx.file._linux_xvfb,
        ctx.file._linux_xkbcomp,
        ctx.file._linux_fontconfig,
        library_tags,
    ] + ctx.attr._linux_runtime_all_files.files.to_list()
    tool_runfiles = tool[DefaultInfo].default_runfiles
    runfiles = ctx.runfiles(
        files = runtime_files + ctx.files.data,
    )
    runfiles = runfiles.merge(tool_runfiles)
    for data_target in ctx.attr.data:
        runfiles = runfiles.merge(data_target[DefaultInfo].default_runfiles)

    instrumented_files_info, analyzable_info = _build_analyzable_and_coverage_infos(
        ctx,
        package_name,
        lib_root,
        main_file,
        extra_srcs,
    )

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
        env_info,
        instrumented_files_info,
        analyzable_info,
    ]

def _flutter_android_integration_app_impl(ctx):
    if not _exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    hook_err = check_unreplaced_hooks(ctx.label, ctx.attr.deps)
    if hook_err != None:
        fail(hook_err)

    main_file, extra_srcs = _resolve_main_and_srcs(ctx)
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)

    mode = "profile" if ctx.attr.profile else flutter_build_mode(ctx)
    is_debug = mode == "debug"
    aot = not is_debug
    strip = ctx.var["COMPILATION_MODE"] == "opt"

    if not is_debug and not flutter_sdk_info.gen_snapshot:
        fail(
            "No target-compatible AOT gen_snapshot toolchain is registered for " +
            "this host and Android target platform.",
        )

    package_name = ctx.attr.package_name or ctx.label.name
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    transitive_native_asset_depsets = []
    transitive_data_asset_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo not in dep:
            continue
        info = dep[FlutterInfo]
        transitive_native_asset_depsets.append(info.native_assets)
        transitive_data_asset_depsets.append(info.data_assets)
    transitive_native_assets = depset(transitive = transitive_native_asset_depsets)
    transitive_data_assets = depset(transitive = transitive_data_asset_depsets)

    native_assets_list = transitive_native_assets.to_list()
    declared_ids = {asset.asset_id: True for asset in native_assets_list}
    native_assets_list = native_assets_list + [
        asset
        for asset in bridge_dart_code_assets(ctx, ctx.attr.deps)
        if asset.asset_id not in declared_ids
    ]

    target_arch = host_target_arch(ctx, flutter_sdk_info)
    native_assets_manifest = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    write_native_assets_manifest(
        ctx = ctx,
        output_file = native_assets_manifest,
        native_assets = native_assets_list,
        target_os = "android",
        target_arch = target_arch,
    )
    bundled_code_assets = collect_bundled_code_asset_files(native_assets_list)

    packages = collect_packages(ctx.attr.deps)
    packages = synthesize_app_package(
        ctx.label,
        packages,
        package_name,
        lib_root,
        ctx.attr.language_version,
    )

    bootstrap = ctx.actions.declare_file(ctx.label.name + "_android_bootstrap.dart")
    main_location = app_main_location(package_name, lib_root, main_file)
    has_integration_test = _exposes_package(ctx.attr.deps, ["integration_test"])
    ctx.actions.write(
        bootstrap,
        make_android_integration_bootstrap_content(
            test_import = main_location.uri,
            has_integration_test = has_integration_test,
        ),
    )

    all_dep_plugins = []
    apple_plugin_lib_depsets = []
    android_plugin_lib_depsets = []
    linux_plugin_lib_depsets = []
    windows_plugin_lib_depsets = []
    apple_privacy_manifest_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
            apple_plugin_lib_depsets.append(dep[FlutterInfo].apple_plugin_libraries)
            android_plugin_lib_depsets.append(dep[FlutterInfo].android_plugin_libraries)
            linux_plugin_lib_depsets.append(dep[FlutterInfo].linux_plugin_libraries)
            windows_plugin_lib_depsets.append(dep[FlutterInfo].windows_plugin_libraries)
            apple_privacy_manifest_depsets.append(dep[FlutterInfo].apple_privacy_manifests)
    plugins = dedup_plugins(all_dep_plugins)
    apple_plugin_libraries = depset(transitive = apple_plugin_lib_depsets)
    android_plugin_libraries = depset(transitive = android_plugin_lib_depsets)
    linux_plugin_libraries = depset(transitive = linux_plugin_lib_depsets)
    windows_plugin_libraries = depset(transitive = windows_plugin_lib_depsets)
    apple_privacy_manifests = depset(transitive = apple_privacy_manifest_depsets)

    registrant = generate_dart_plugin_registrant(
        ctx,
        plugins,
        target_platform = "android",
    )
    registrant_location = app_scheme_location(registrant) if registrant else None
    bootstrap_location = app_scheme_location(bootstrap)

    all_srcs = (
        list(extra_srcs) +
        collect_transitive_srcs(ctx.attr.deps).to_list() +
        [main_file, bootstrap] +
        ([registrant] if registrant else [])
    )
    pc = compile_kernel_package_config(
        ctx,
        packages,
        all_srcs,
        roots = {package_name: True} if package_name else None,
    )

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
    else:
        platform_dill = flutter_sdk_info.platform_kernel_dill
        if platform_dill == None:
            fail(
                "Unresolved @rules_flutter//flutter:toolchain_type: " +
                "Flutter toolchain does not provide platform_kernel_dill. " +
                "Register a Flutter toolchain (e.g. `flutter.toolchain()` in " +
                "MODULE.bazel) or set `platform_kernel_dill` on `flutter_toolchain`.",
            )

    user_defines = merge_dart_defines(ctx)
    all_defines = list(user_defines)
    if mode == "profile":
        all_defines.append("dart.vm.profile=true")
    elif aot:
        all_defines.append("dart.vm.product=true")

    extra_frontend_flags = []
    if ctx.attr.track_widget_creation:
        extra_frontend_flags.append("--track-widget-creation")

    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        kernel_filter_tool = ctx.executable._kernel_filter_tool,
        frontend_server = flutter_sdk_info.frontend_server,
        platform_dill = platform_dill,
        main = bootstrap,
        entrypoint_uri = bootstrap_location.uri,
        srcs = pc.srcs,
        package_config = pc.config_file,
        output = kernel_dill,
        aot = aot,
        defines = all_defines,
        target = "flutter",
        extra_flags = extra_frontend_flags,
        native_assets_manifest = native_assets_manifest,
        dart_plugin_registrant_uri = registrant_location.uri if registrant_location else None,
    )

    aot_output = None
    if not is_debug:
        aot_output = ctx.actions.declare_file(ctx.label.name + ".so")
        flutter_aot_elf_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            kernel_dill = kernel_dill,
            output = aot_output,
            strip = strip,
        )

    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, "android")
    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_build_assets(
        ctx,
        flutter_sdk_info,
        flutter_assets,
        compiled_shaders,
        target_platform = "android",
        kernel_dill = kernel_dill,
        is_debug = is_debug,
        data_assets = transitive_data_assets,
    )

    native_libs = collect_native_libs(ctx.attr.native_deps)
    transitive_native_depsets = [
        dep[FlutterInfo].transitive_native_libs
        for dep in ctx.attr.deps
        if FlutterInfo in dep
    ]
    if transitive_native_depsets:
        native_libs.extend(depset(transitive = transitive_native_depsets).to_list())

    default_files = [
        flutter_assets,
        pc.config_file,
        native_assets_manifest,
    ] + native_libs + bundled_code_assets.to_list()
    if aot_output:
        default_files.append(aot_output)
    if is_debug:
        default_files.append(kernel_dill)

    return [
        DefaultInfo(files = depset(default_files)),
        FlutterApplicationInfo(
            aot_output = aot_output,
            kernel_dill = kernel_dill if is_debug else None,
            flutter_assets = flutter_assets,
            icu_data = flutter_sdk_info.icu_data,
            native_libs = native_libs,
            is_debug = is_debug,
            package_config = pc.config_file,
            native_assets_manifest = native_assets_manifest,
            bundled_code_assets = bundled_code_assets,
            bundled_data_assets = transitive_data_assets,
            apple_privacy_manifests = apple_privacy_manifests,
            plugins = plugins,
            apple_plugin_libraries = apple_plugin_libraries,
            android_plugin_libraries = android_plugin_libraries,
            linux_plugin_libraries = linux_plugin_libraries,
            windows_plugin_libraries = windows_plugin_libraries,
        ),
    ]

def _flutter_android_integration_test_impl(ctx):
    if ctx.attr.platform != "android":
        fail(
            "%s: _flutter_android_integration_test requires platform = 'android', got %r." % (
                ctx.label,
                ctx.attr.platform,
            ),
        )

    if not _exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    main_file, extra_srcs = _resolve_main_and_srcs(ctx)
    package_name = ctx.attr.package_name or ctx.label.name
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    apk_files = [
        f
        for f in ctx.files.apk
        if f.path.endswith(".apk") and not f.path.endswith("_unsigned.apk")
    ]
    if not apk_files:
        fail(
            "flutter_integration_test %s: expected a signed .apk from %s, got %s" % (
                ctx.label.name,
                ctx.attr.apk.label,
                [f.short_path for f in ctx.files.apk],
            ),
        )
    apk_file = apk_files[0]

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

    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": "android",
        "FLUTTER_INTEGRATION_TEST_ANDROID_APK": runfiles_path(apk_file, workspace_name),
        "FLUTTER_INTEGRATION_TEST_ANDROID_PACKAGE": ctx.attr.android_package,
        "FLUTTER_INTEGRATION_TEST_ANDROID_EMULATOR": runfiles_path(ctx.file._android_emulator, workspace_name),
        "FLUTTER_INTEGRATION_TEST_ANDROID_ADB": runfiles_path(ctx.file._android_adb, workspace_name),
        "FLUTTER_INTEGRATION_TEST_PATH": main_file.short_path,
        "FLUTTER_INTEGRATION_TEST_DECLARED_ENV": json.encode(ctx.attr.env),
    }
    _test_tag_env(ctx, env)

    # The entrypoint's own `@Tags`, extracted at build time (see
    # `extract_library_tags_action`): the runner injects them as the root
    # group's metadata, so they inherit down to every test in the suite.
    library_tags = extract_library_tags_action(ctx, main_file)
    env["FLUTTER_TEST_LIBRARY_TAGS"] = runfiles_path(library_tags, workspace_name)
    for key, value in ctx.attr.env.items():
        if key in env or key in _RESERVED_TAG_ENV_KEYS:
            fail((
                "flutter_integration_test {name}: env key {key} is set by the " +
                "rule itself and cannot be overridden."
            ).format(name = ctx.label.name, key = key))
        env[key] = value

    env_info = testing.TestEnvironment(env)

    runtime_files = [
        apk_file,
        ctx.file._android_emulator,
        ctx.file._android_adb,
        library_tags,
    ] + ctx.attr._android_runtime_all_files.files.to_list()
    tool_runfiles = tool[DefaultInfo].default_runfiles
    runfiles = ctx.runfiles(
        files = runtime_files + ctx.files.data,
    )
    runfiles = runfiles.merge(tool_runfiles)
    for data_target in ctx.attr.data:
        runfiles = runfiles.merge(data_target[DefaultInfo].default_runfiles)

    instrumented_files_info, analyzable_info = _build_analyzable_and_coverage_infos(
        ctx,
        package_name,
        lib_root,
        main_file,
        extra_srcs,
    )

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
        env_info,
        instrumented_files_info,
        analyzable_info,
    ]

_WEB_RELEVANT_KEYS = (
    "assets",
    "shaders",
    "shader_includes",
    "require_sksl_shaders",
    "_shader_compile_tool",
    "tree_shake_icons",
    "license_files",
    "track_widget_creation",
    "_asset_bundle_tool",
)

_COMMON_INTEGRATION_TEST_ATTRS = KERNEL_COMPILE_ATTRS | {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in _WEB_RELEVANT_KEYS
}
_COMMON_INTEGRATION_TEST_ATTRS["main"] = attr.label(
    doc = "The integration test .dart entry point. Optional when `srcs` " +
          "contains a single `.dart` file.",
    allow_single_file = [".dart"],
)
_COMMON_INTEGRATION_TEST_ATTRS["package_name"] = attr.string(
    doc = "Dart package name (from pubspec.yaml). Defaults to target name.",
)
_COMMON_INTEGRATION_TEST_ATTRS["app_srcs"] = attr.label_list(
    doc = "Dart source files for the application under test (e.g. `[\"lib/main.dart\"]`).",
    allow_files = [".dart"],
)
_COMMON_INTEGRATION_TEST_ATTRS["tree_shake_icons"] = attr.bool(
    doc = "Whether to tree-shake icon fonts in non-debug builds.",
    default = False,
)
_COMMON_INTEGRATION_TEST_ATTRS["platform"] = attr.string(
    doc = "Target platform to run the integration test on ('web', 'linux', or 'android').",
    default = "web",
    values = ["web", "linux", "android"],
)
_COMMON_INTEGRATION_TEST_ATTRS["profile"] = attr.bool(
    doc = "Whether to compile in profile mode.",
    default = False,
)
_COMMON_INTEGRATION_TEST_ATTRS["data"] = attr.label_list(
    allow_files = True,
    doc = "Runtime data files made available in test runfiles.",
)
_COMMON_INTEGRATION_TEST_ATTRS["env"] = attr.string_dict(
    doc = "Extra environment variables for the test runner process.",
)

# Tag selection, as `flutter test --tags` / `--exclude-tags` resolve it.
# Named `include_tags` / `exclude_tags` rather than `tags` because Bazel's
# own `tags` attribute means something else. A `--test_env=FLUTTER_TEST_TAGS=...`
# (or `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute.
#
# Library-level `@Tags` on the entrypoint need no attribute: they are extracted
# at build time and always honoured (see `extract_library_tags_action`).
_COMMON_INTEGRATION_TEST_ATTRS["include_tags"] = attr.string_list(
    doc = "Run only tests matching every one of these `package:test` tag " +
          "selectors (library, group or test level), as `flutter test " +
          "--tags` intersects them. Each entry is a boolean selector " +
          "(`a && b`, `a || b`, `!a`, parentheses); several entries, or " +
          "comma-separated values in one entry, all have to match. A test " +
          "matching an `exclude_tags` selector never runs. An attribute " +
          "selection that matches no test fails the target.",
)
_COMMON_INTEGRATION_TEST_ATTRS["exclude_tags"] = attr.string_list(
    doc = "Skip tests matching any of these `package:test` tag selectors " +
          "(library, group or test level), as `flutter test " +
          "--exclude-tags` unions them. Wins over `include_tags`.",
)
_COMMON_INTEGRATION_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_COMMON_INTEGRATION_TEST_ATTRS.update(MODULAR_KERNEL_ATTRS)
_COMMON_INTEGRATION_TEST_ATTRS["_tool"] = attr.label(
    default = Label("//flutter/private/tools:flutter_integration_test_runner"),
    executable = True,
    cfg = "exec",
)
_COMMON_INTEGRATION_TEST_ATTRS["_library_tags_tool"] = LIBRARY_TAGS_TOOL_ATTR
_COMMON_INTEGRATION_TEST_ATTRS["_bundle_tool"] = attr.label(
    default = Label("//flutter/private/tools:bundle_app"),
    executable = True,
    cfg = "exec",
)
_COMMON_INTEGRATION_TEST_ATTRS["_sky_engine"] = attr.label(
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

_INTEGRATION_TEST_ATTRS = dict(_COMMON_INTEGRATION_TEST_ATTRS)
_INTEGRATION_TEST_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_web_shader_aspect, flutter_kernel_module_aspect],
)
_INTEGRATION_TEST_ATTRS["compiler"] = attr.string(
    doc = "Web compiler: 'dart2js' (default) or 'dart2wasm'.",
    default = "dart2js",
    values = ["dart2js", "dart2wasm"],
)
_INTEGRATION_TEST_ATTRS["renderer"] = attr.string(
    doc = "Web renderer: 'canvaskit' or 'skwasm'. Defaults to matching `compiler`.",
    default = "",
    values = ["", "canvaskit", "skwasm"],
)
_INTEGRATION_TEST_ATTRS["optimization_level_js"] = attr.string(
    doc = "The `-O` level for dart2js compilation.",
    default = "1",
    values = ["auto", "0", "1", "2", "3", "4"],
)
_INTEGRATION_TEST_ATTRS["optimization_level_wasm"] = attr.string(
    doc = "The `-O` level for dart2wasm compilation.",
    default = "0",
    values = ["auto", "0", "1", "2", "3", "4"],
)
_INTEGRATION_TEST_ATTRS["minify_js"] = attr.string(
    doc = "Whether dart2js minifies identifiers.",
    default = "false",
    values = ["auto", "true", "false"],
)
_INTEGRATION_TEST_ATTRS["minify_wasm"] = attr.string(
    doc = "Whether dart2wasm minifies runtime type names.",
    default = "false",
    values = ["auto", "true", "false"],
)
_INTEGRATION_TEST_ATTRS["strip_wasm"] = attr.bool(
    doc = "Whether to strip static symbol names from WASM output.",
    default = False,
)
_INTEGRATION_TEST_ATTRS["native_null_assertions"] = attr.bool(
    doc = "Whether to check JS interop nullability at runtime.",
    default = True,
)
_INTEGRATION_TEST_ATTRS["frequency_based_minification"] = attr.bool(
    doc = "Whether dart2js uses frequency-based minification.",
    default = True,
)
_INTEGRATION_TEST_ATTRS["enable_experiments"] = attr.string_list(
    doc = "Dart language experiments to enable.",
)
_INTEGRATION_TEST_ATTRS["source_maps"] = attr.bool(
    doc = "Whether to generate source maps.",
    default = False,
)
_INTEGRATION_TEST_ATTRS["_chrome_headless_shell"] = attr.label(
    default = Label("@flutter_chrome_headless_shell//:browser/chrome-headless-shell"),
    allow_single_file = True,
)
_INTEGRATION_TEST_ATTRS["_chrome_fontconfig"] = attr.label(
    default = Label("@flutter_chrome_headless_shell//:fonts/fonts.conf"),
    allow_single_file = True,
)
_INTEGRATION_TEST_ATTRS["_chrome_all_files"] = attr.label(
    default = Label("@flutter_chrome_headless_shell//:all_files"),
)
_INTEGRATION_TEST_ATTRS["_roboto_font"] = attr.label(
    default = Label("@flutter_material_fonts//:material-fonts/Roboto-Regular.ttf"),
    allow_single_file = True,
)
_INTEGRATION_TEST_ATTRS["_dart2wasm_platform_dill"] = attr.label(
    default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2wasm_platform.dill"),
    allow_single_file = True,
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_dart2js_platform_dill"] = attr.label(
    default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2js_platform.dill"),
    allow_single_file = True,
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_web_sdk"] = attr.label(
    default = Label("@flutter_web_sdk//:web_sdk"),
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_web_template_tool"] = attr.label(
    default = Label("//flutter/private/tools:web_template"),
    executable = True,
    cfg = "exec",
)

_LINUX_INTEGRATION_TEST_ATTRS = dict(_COMMON_INTEGRATION_TEST_ATTRS)
_LINUX_INTEGRATION_TEST_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_app_shader_aspect, flutter_kernel_module_aspect],
)
_LINUX_INTEGRATION_TEST_ATTRS["native_deps"] = attr.label_list(
    doc = "Native shared library targets (cc_library) for dart:ffi bundled into lib/.",
    aspects = [native_sources_aspect],
)
_LINUX_INTEGRATION_TEST_ATTRS["gtk_app_id"] = attr.string(
    doc = "GTK application identifier for the Linux test runner.",
    default = "com.example.flutter_integration_test",
)
_LINUX_INTEGRATION_TEST_ATTRS["window_title"] = attr.string(
    doc = "Window title for the Linux test runner.",
    default = "Flutter Integration Test",
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_runner_source"] = attr.label(
    default = Label("//flutter/private/runners:linux_runner.cc"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_cc_toolchain"] = attr.label(
    default = "@bazel_tools//tools/cpp:current_cc_toolchain",
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_xvfb"] = attr.label(
    default = Label("@flutter_linux_headless_runtime//:sysroot/usr/bin/Xvfb"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_xkbcomp"] = attr.label(
    default = Label("@flutter_linux_headless_runtime//:sysroot/usr/bin/xkbcomp"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_fontconfig"] = attr.label(
    default = Label("@flutter_linux_headless_runtime//:fonts/fonts.conf"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_runtime_all_files"] = attr.label(
    default = Label("@flutter_linux_headless_runtime//:all_files"),
)

_ANDROID_INTEGRATION_APP_ATTRS = KERNEL_COMPILE_ATTRS | {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in _WEB_RELEVANT_KEYS
}
_ANDROID_INTEGRATION_APP_ATTRS["main"] = _COMMON_INTEGRATION_TEST_ATTRS["main"]
_ANDROID_INTEGRATION_APP_ATTRS["package_name"] = _COMMON_INTEGRATION_TEST_ATTRS["package_name"]
_ANDROID_INTEGRATION_APP_ATTRS["app_srcs"] = _COMMON_INTEGRATION_TEST_ATTRS["app_srcs"]
_ANDROID_INTEGRATION_APP_ATTRS["tree_shake_icons"] = _COMMON_INTEGRATION_TEST_ATTRS["tree_shake_icons"]
_ANDROID_INTEGRATION_APP_ATTRS["profile"] = _COMMON_INTEGRATION_TEST_ATTRS["profile"]
_ANDROID_INTEGRATION_APP_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_app_shader_aspect, flutter_kernel_module_aspect],
)
_ANDROID_INTEGRATION_APP_ATTRS["native_deps"] = attr.label_list(
    doc = "Native shared library targets (cc_library) for dart:ffi bundled into lib/.",
    aspects = [native_sources_aspect],
)
_ANDROID_INTEGRATION_APP_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_ANDROID_INTEGRATION_APP_ATTRS.update(MODULAR_KERNEL_ATTRS)

_ANDROID_INTEGRATION_TEST_ATTRS = {
    "apk": attr.label(
        mandatory = True,
        allow_files = True,
        doc = "The compiled Android APK target.",
    ),
    "android_package": attr.string(
        mandatory = True,
        doc = "Android application ID (e.g. 'com.example.app_test').",
    ),
    "srcs": KERNEL_COMPILE_ATTRS["srcs"],
    "main": _COMMON_INTEGRATION_TEST_ATTRS["main"],
    "app_srcs": _COMMON_INTEGRATION_TEST_ATTRS["app_srcs"],
    "package_name": _COMMON_INTEGRATION_TEST_ATTRS["package_name"],
    "language_version": KERNEL_COMPILE_ATTRS["language_version"],
    "deps": attr.label_list(
        doc = FLUTTER_DEPS_DOC,
        providers = [DartInfo],
    ),
    "platform": _COMMON_INTEGRATION_TEST_ATTRS["platform"],
    "data": _COMMON_INTEGRATION_TEST_ATTRS["data"],
    "env": _COMMON_INTEGRATION_TEST_ATTRS["env"],
    "include_tags": _COMMON_INTEGRATION_TEST_ATTRS["include_tags"],
    "exclude_tags": _COMMON_INTEGRATION_TEST_ATTRS["exclude_tags"],
    "_tool": _COMMON_INTEGRATION_TEST_ATTRS["_tool"],
    "_library_tags_tool": _COMMON_INTEGRATION_TEST_ATTRS["_library_tags_tool"],
    "_sky_engine": _COMMON_INTEGRATION_TEST_ATTRS["_sky_engine"],
    "_android_emulator": attr.label(
        default = Label("@flutter_android_headless_runtime//:sdk/emulator/emulator"),
        allow_single_file = True,
    ),
    "_android_adb": attr.label(
        default = Label("@flutter_android_headless_runtime//:sdk/platform-tools/adb"),
        allow_single_file = True,
    ),
    "_android_runtime_all_files": attr.label(
        default = Label("@flutter_android_headless_runtime//:all_files"),
    ),
}
_ANDROID_INTEGRATION_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)

_flutter_integration_test = rule(
    implementation = _flutter_integration_test_impl,
    attrs = _INTEGRATION_TEST_ATTRS,
    test = True,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:product_tools_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:font_subset_toolchain_type",
            mandatory = False,
        ),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter app with an in-app integration test and runs it on the web platform.",
)

_flutter_linux_integration_test = rule(
    implementation = _flutter_linux_integration_test_impl,
    attrs = _LINUX_INTEGRATION_TEST_ATTRS,
    fragments = ["cpp"],
    test = True,
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:product_tools_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:aot_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:desktop_engine_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:font_subset_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_dart//dart:exec_tools_toolchain_type",
            mandatory = False,
        ),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter Linux desktop app with an in-app integration test and runs it headlessly under Xvfb.",
)

_flutter_android_integration_app = rule(
    implementation = _flutter_android_integration_app_impl,
    attrs = _ANDROID_INTEGRATION_APP_ATTRS,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:product_tools_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:aot_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:font_subset_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_dart//dart:exec_tools_toolchain_type",
            mandatory = False,
        ),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter Android application with an in-app integration test bootstrap.",
)

_flutter_android_integration_test = rule(
    implementation = _flutter_android_integration_test_impl,
    attrs = _ANDROID_INTEGRATION_TEST_ATTRS,
    test = True,
    doc = "Runs a compiled Flutter Android integration test APK inside a hermetic, pinned headless Android emulator.",
)

def _sanitize_android_package_segment(raw):
    """Sanitizes a string into a valid Java package identifier segment."""
    chars = []
    for c in raw.elems():
        if c.isalnum() or c == "_":
            chars.append(c.lower())
        else:
            chars.append("_")
    segment = "".join(chars)
    if not segment or segment[0].isdigit():
        segment = "app_" + segment
    return segment

def _make_android_integration_manifest_lines(package_name, app_name):
    """Generates AndroidManifest.xml lines for an Android integration test APK."""
    return [
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
        "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"",
        "    package=\"%s\">" % package_name,
        "    <uses-permission android:name=\"android.permission.INTERNET\"/>",
        "    <uses-sdk android:minSdkVersion=\"%s\" android:targetSdkVersion=\"%s\"/>" % (
            ANDROID_MIN_SDK_VERSION,
            ANDROID_TARGET_SDK_VERSION,
        ),
        "",
        "    <application",
        "        android:label=\"%s\"" % app_name,
        "        android:name=\"android.app.Application\"",
        "        android:hardwareAccelerated=\"true\">",
        "        <activity",
        "            android:name=\"io.flutter.embedding.android.FlutterActivity\"",
        "            android:exported=\"true\"",
        "            android:launchMode=\"singleTop\"",
        "            android:configChanges=\"orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode\"",
        "            android:hardwareAccelerated=\"true\"",
        "            android:windowSoftInputMode=\"adjustResize\"",
        "            android:theme=\"@android:style/Theme.Light.NoTitleBar\">",
        "            <intent-filter>",
        "                <action android:name=\"android.intent.action.MAIN\"/>",
        "                <category android:name=\"android.intent.category.LAUNCHER\"/>",
        "            </intent-filter>",
        "            <meta-data",
        "                android:name=\"io.flutter.embedding.android.NormalTheme\"",
        "                android:resource=\"@android:style/Theme.Light.NoTitleBar\"/>",
        "        </activity>",
        "",
        "        <meta-data",
        "            android:name=\"io.flutter.embedding.android.EnableImpeller\"",
        "            android:value=\"false\"/>",
        "        <meta-data",
        "            android:name=\"flutterEmbedding\"",
        "            android:value=\"2\"/>",
        "    </application>",
        "</manifest>",
        "",
    ]

_ANDROID_APP_KWARG_KEYS = (
    "srcs",
    "main",
    "app_srcs",
    "assets",
    "shaders",
    "shader_includes",
    "require_sksl_shaders",
    "tree_shake_icons",
    "license_files",
    "track_widget_creation",
    "profile",
    "language_version",
    "defines",
    "native_deps",
)

def flutter_integration_test(
        name,
        package_name = "",
        deps = [],
        app_deps = [],
        app = None,
        platform = "web",
        android_package = "",
        android_deps = [],
        pub_hub_name = None,
        **kwargs):
    """Builds and runs an end-to-end Flutter integration test on a real platform.

    Compiles the application and the integration test (`WidgetTester` code) into
    a real platform bundle and drives it via the platform runner. On `web`, the
    built web bundle is served from `127.0.0.1` and executed inside a hermetic,
    pinned `chrome-headless-shell` browser. On `linux`, the built GTK desktop
    bundle is executed inside a hermetic, pinned `Xvfb` virtual display with
    pinned GTK3 and Mesa software OpenGL/EGL libraries. On `android`, the built
    Android APK is installed and executed inside a hermetic, pinned headless
    Android `x86_64` emulator accelerated with KVM.

    Args:
        name: Target name.
        package_name: Dart package name (from `pubspec.yaml`). Defaults to `name`.
        deps: Dependencies (`dart_library` / `flutter_library`) for the test and app.
        app_deps: Optional additional dependencies for the app, merged with `deps`.
        app: Optional library target for the app under test, merged with `deps`.
        platform: Target platform (`"web"`, `"linux"`, or `"android"`, defaults to `"web"`).
        android_package: Optional Android application ID when `platform = "android"`.
            Defaults to `"com.example.<package_name>"`.
        android_deps: Optional additional Android library targets (`kt_android_library`,
            `android_library`, `flutter_android_plugin_library`) when `platform = "android"`.
            Workspace plugins that set `android_libs` on `flutter_plugin` are
            collected automatically from `deps`.
        pub_hub_name: Optional `flutter.pub` hub name (e.g. `"deps"`) whose
            `@<pub_hub_name>//android:all_android_plugin_libs` aggregator should
            be linked when `platform = "android"`.
        **kwargs: Additional attributes forwarded to the rule (`main`, `srcs`,
            `app_srcs`, `assets`, `shaders`, `compiler`, `renderer`,
            `native_deps`, `defines`, `data`, `env`, etc.).
    """
    merged_deps = list(deps)
    for extra in list(app_deps) + ([app] if app != None else []):
        if extra not in merged_deps:
            merged_deps.append(extra)

    resolved_package_name = package_name or name

    if platform == "android":
        resolved_android_package = android_package or (
            "com.example.%s" % _sanitize_android_package_segment(resolved_package_name)
        )
        helper_tags = ["manual"]
        app_kwargs = {}
        for k in _ANDROID_APP_KWARG_KEYS:
            if k in kwargs:
                app_kwargs[k] = kwargs[k]

        _flutter_android_integration_app(
            name = "__%s_app" % name,
            package_name = resolved_package_name,
            deps = merged_deps,
            tags = helper_tags,
            visibility = ["//visibility:private"],
            **app_kwargs
        )

        flutter_android_bundle(
            name = "__%s_bundle" % name,
            application = ":__%s_app" % name,
            android_abi = "x86_64",
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        native.filegroup(
            name = "__%s_native_libs_jar" % name,
            srcs = [":__%s_bundle" % name],
            output_group = "native_libs_jar",
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        java_import(
            name = "__%s_native_libs" % name,
            jars = [":__%s_native_libs_jar" % name],
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        flutter_android_engine(
            name = "__%s_engine" % name,
            android_abi = "x64",
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        native.filegroup(
            name = "__%s_flutter_assets" % name,
            srcs = [":__%s_bundle" % name],
            output_group = "mobile_install",
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        flutter_android_registrant(
            name = "__%s_registrant_src" % name,
            application = ":__%s_app" % name,
            android_abi = "x86_64",
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        flutter_android_plugins_aggregator(
            name = "__%s_android_plugins" % name,
            application = ":__%s_app" % name,
            android_abi = "x86_64",
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        registrant_deps = [
            ":__%s_engine" % name,
            ":__%s_android_plugins" % name,
        ]
        if pub_hub_name:
            registrant_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)
        registrant_deps = registrant_deps + list(android_deps)

        kt_android_library(
            name = "__%s_registrant" % name,
            srcs = [":__%s_registrant_src" % name],
            custom_package = "io.flutter.plugins",
            deps = registrant_deps,
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        binary_deps = [
            ":__%s_native_libs" % name,
            ":__%s_engine" % name,
            ":__%s_registrant" % name,
            ":__%s_android_plugins" % name,
        ]
        if pub_hub_name:
            binary_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)
        binary_deps = binary_deps + list(android_deps)

        write_file(
            name = "__%s_base_manifest" % name,
            out = "__%s_base_manifest/AndroidManifest.xml" % name,
            content = _make_android_integration_manifest_lines(
                resolved_android_package,
                name,
            ),
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        flutter_android_manifest_merge(
            name = "__%s_manifest" % name,
            base = ":__%s_base_manifest" % name,
            libraries = binary_deps,
            placeholders = ["applicationId", "minSdkVersion", "targetSdkVersion"],
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        android_binary(
            name = "__%s_apk" % name,
            manifest = ":__%s_manifest" % name,
            manifest_values = {
                "applicationId": resolved_android_package,
                "minSdkVersion": ANDROID_MIN_SDK_VERSION,
                "targetSdkVersion": ANDROID_TARGET_SDK_VERSION,
            },
            assets = [":__%s_flutter_assets" % name],
            assets_dir = "assets",
            deps = binary_deps,
            tags = helper_tags,
            visibility = ["//visibility:private"],
        )

        test_kwargs = {
            k: v
            for k, v in kwargs.items()
            if k not in _ANDROID_APP_KWARG_KEYS or k in ("srcs", "main", "app_srcs", "language_version")
        }

        _flutter_android_integration_test(
            name = name,
            apk = ":__%s_apk" % name,
            android_package = resolved_android_package,
            package_name = resolved_package_name,
            deps = merged_deps,
            platform = platform,
            **test_kwargs
        )
    elif platform == "linux":
        _flutter_linux_integration_test(
            name = name,
            package_name = resolved_package_name,
            deps = merged_deps,
            platform = platform,
            **kwargs
        )
    else:
        _flutter_integration_test(
            name = name,
            package_name = resolved_package_name,
            deps = merged_deps,
            platform = platform,
            **kwargs
        )
