/// JavaScript and Dart bootstrap generators for DDC web dev mode.
///
/// Ported from Flutter's `packages/flutter_tools/lib/src/web/bootstrap.dart`
/// and `packages/flutter_tools/lib/src/web/file_generators/main_dart.dart`.
/// These generate the exact same files that `flutter run -d chrome` produces.
import 'dart:io' show Platform;

/// Generate the synthetic main.dart wrapper that initializes the Flutter engine.
///
/// This wraps the user's entrypoint with `ui_web.bootstrapEngine()` which:
/// 1. Loads CanvasKit/renderer
/// 2. Creates the implicit view
/// 3. Then calls the user's main()
///
/// If [pluginRegistrantEntrypoint] is provided, imports it and calls
/// `registerPlugins()` before running the app — matching Flutter's
/// `generateMainDartFile()` from `main_dart.dart`.
String generateSyntheticMainDart({
  required String appEntrypoint,
  String? pluginRegistrantEntrypoint,
}) {
  final pluginImport = pluginRegistrantEntrypoint != null
      ? "import '$pluginRegistrantEntrypoint' as pluginRegistrant;"
      : '';
  final registerPluginsCallback = pluginRegistrantEntrypoint != null
      ? '''
    registerPlugins: () {
      pluginRegistrant.registerPlugins();
    },'''
      : '';

  return '''
// Flutter web bootstrap script.
// Generated file. Do not edit.

// ignore_for_file: type=lint

import 'dart:ui_web' as ui_web;
import 'dart:async';

import '$appEntrypoint' as entrypoint;
$pluginImport

typedef _UnaryFunction = dynamic Function(List<String> args);
typedef _NullaryFunction = dynamic Function();

Future<void> main() async {
  await ui_web.bootstrapEngine(
    runApp: () {
      if (entrypoint.main is _UnaryFunction) {
        return (entrypoint.main as _UnaryFunction)(<String>[]);
      }
      return (entrypoint.main as _NullaryFunction)();
    },
$registerPluginsCallback
  );
}
''';
}

/// Generate the `flutter_bootstrap.js` script.
///
/// Embeds `flutter.js` inline and sets up `_flutter.buildConfig` with DDC
/// compilation target, then calls `_flutter.loader.load()` to initialize
/// the engine and load `main.dart.js`.
///
/// Matches Flutter's `_serveFlutterBootstrapJs()` + `_buildConfigString`.
String generateFlutterBootstrapJs({
  required String flutterJsContents,
  required String engineRevision,
}) {
  return '''
$flutterJsContents

if (!window._flutter) {
  window._flutter = {};
}
_flutter.buildConfig = ${_buildConfigJson(engineRevision)};

_flutter.loader.load();
''';
}

String _buildConfigJson(String engineRevision) {
  // Match Flutter's exact build config structure for DDC dev mode.
  // useLocalCanvasKit: true tells flutter.js to load CanvasKit from the
  // relative path "canvaskit/" instead of gstatic.com CDN. This matches
  // Flutter's dev server behavior — faster loads, no external dependency.
  return '{"engineRevision":"$engineRevision","builds":[{"compileTarget":"dartdevc","renderer":"canvaskit","mainJsPath":"main.dart.js"}],"useLocalCanvasKit":true}';
}

// ---- DDC Bootstrap Scripts (served as JS to the browser) ----

/// Used to load prerequisite scripts such as ddc_module_loader.js
const _simpleLoaderScript = r'''
window.$dartCreateScript = (function() {
  const scripts = Array.from(document.getElementsByTagName("script"));
  let nonce;
  scripts.some(
      script => (nonce = script.nonce || script.getAttribute("nonce")));
  if (nonce) {
    return function() {
      const script = document.createElement("script");
      script.nonce = nonce;
      return script;
    };
  } else {
    return function() {
      return document.createElement("script");
    };
  }
})();

const forceLoadModule = function (relativeUrl, root) {
  const actualRoot = root ?? _currentDirectory;
  return new Promise(function(resolve, reject) {
    const script = self.$dartCreateScript();
    let policy = {
      createScriptURL: function(src) {return src;}
    };
    if (self.trustedTypes && self.trustedTypes.createPolicy) {
      policy = self.trustedTypes.createPolicy('dartDdcModuleUrl', policy);
    }
    script.onload = resolve;
    script.onerror = reject;
    script.src = policy.createScriptURL(actualRoot + relativeUrl);
    document.head.appendChild(script);
  });
};
''';

/// Generate the DDC library bundle bootstrap script (`main.dart.js`).
///
/// Matches Flutter's `generateDDCLibraryBundleBootstrapScript()`.
/// The scripts array contains only `dart_sdk.js` and `main_module.bootstrap.js`.
/// App modules are loaded in the second stage by `main_module.bootstrap.js`.
String generateDDCBootstrapScript({
  required String entrypoint,
  String ddcModuleLoaderUrl = 'ddc_module_loader.js',
  String mapperUrl = 'stack_trace_mapper.js',
}) {
  final isWindows = Platform.isWindows;

  return '''
const _currentDirectory = (function () {
  const _url = document.currentScript.src;
  const lastSlash = _url.lastIndexOf('/');
  if (lastSlash == -1) return _url;
  const currentDirectory = _url.substring(0, lastSlash + 1);
  return currentDirectory;
})();

$_simpleLoaderScript

(function() {
  let appName = "org-dartlang-app:/$entrypoint";

  let prerequisiteScripts = [
    {
      "src": "$ddcModuleLoaderUrl",
      "id": "ddc_module_loader \x00"
    },
    {
      "src": "$mapperUrl",
      "id": "dart_stack_trace_mapper \x00"
    }
  ];

  let prerequisiteLoads = [];
  for (let i = 0; i < prerequisiteScripts.length; i++) {
    prerequisiteLoads.push(forceLoadModule(prerequisiteScripts[i].src));
  }
  Promise.all(prerequisiteLoads).then((_) => afterPrerequisiteLogic());

  const _currentScript = document.currentScript;

  let policy = {
    createScriptURL: function(src) {return src;}
  };
  if (self.trustedTypes && self.trustedTypes.createPolicy) {
    policy = self.trustedTypes.createPolicy('dartDdcModuleUrl', policy);
  }

  const afterPrerequisiteLogic = function() {
    window.\$dartLoader.rootDirectories.push(_currentDirectory);
    let scripts = [
      {"src": "dart_sdk.js", "id": "dart_sdk"},
      {"src": "main_module.bootstrap.js", "id": "data-main"}
    ];

    let loadConfig = new window.\$dartLoader.LoadConfiguration();
    loadConfig.isWindows = $isWindows;
    loadConfig.bootstrapScript = scripts[scripts.length - 1];

    loadConfig.loadScriptFn = function(loader) {
      loader.addScriptsToQueue(scripts, null);
      loader.loadEnqueuedModules();
    }
    loadConfig.ddcEventForLoadStart = /* LOAD_ALL_MODULES_START */ 1;
    loadConfig.ddcEventForLoadedOk = /* LOAD_ALL_MODULES_END_OK */ 2;
    loadConfig.ddcEventForLoadedError = /* LOAD_ALL_MODULES_END_ERROR */ 3;

    let loader = new window.\$dartLoader.DDCLoader(loadConfig);

    prerequisiteScripts.forEach(script => loader.registerScript(script));

    window.\$dartLoader.loadConfig = loadConfig;
    window.\$dartLoader.loader = loader;

    loader.nextAttempt();

    if (window.\$dartStackTraceUtility &&
        !window.\$dartStackTraceUtility.ready) {
      window.\$dartStackTraceUtility.ready = true;
      window.\$dartStackTraceUtility.setSourceMapProvider(function(url) {
        const baseUrl = window.location.protocol + '//' + window.location.host;
        url = url.replace(baseUrl + '/', '');
        if (url == 'dart_sdk.js') {
          return dartDevEmbedder.debugger.getSourceMap('dart_sdk');
        }
        url = url.replace(".lib.js", "");
        return dartDevEmbedder.debugger.getSourceMap(url);
      });
    }

    let currentUri = _currentScript.src;
    let reloadedSources = _currentDirectory + 'reloaded_sources.json';

    if (!window.\$dartReloadModifiedModules) {
      window.\$dartReloadModifiedModules = (function(appName, callback) {
        const xhttp = new XMLHttpRequest();
        xhttp.withCredentials = true;
        xhttp.onreadystatechange = function() {
          if (this.readyState == 4 && this.status == 200 || this.status == 304) {
            const scripts = JSON.parse(this.responseText);
            let numToLoad = 0;
            let numLoaded = 0;
            for (let i = 0; i < scripts.length; i++) {
              const script = scripts[i];
              const module = script.module;
              if (module == null) continue;
              const src = script.src;
              const oldSrc = window.\$dartLoader.moduleIdToUrl.get(module);

              window.\$dartLoader.urlToModuleId.delete(oldSrc);
              window.\$dartLoader.moduleIdToUrl.set(module, src);
              window.\$dartLoader.urlToModuleId.set(src, module);

              numToLoad++;

              let el = document.getElementById(module);
              if (el) el.remove();
              el = window.\$dartCreateScript();
              el.src = policy.createScriptURL(src);
              el.async = false;
              el.defer = true;
              el.id = module;
              el.onload = function() {
                numLoaded++;
                if (numToLoad == numLoaded) callback();
              };
              document.head.appendChild(el);
            }
            if (numToLoad == 0) callback();
          }
        };
        xhttp.open("GET", reloadedSources, true);
        xhttp.send();
      });
    }
  };
})();
''';
}

/// Generate the main module wrapper script (`main_module.bootstrap.js`).
///
/// Matches Flutter's `generateDDCLibraryBundleMainModule()`.
/// Contains the `$onLoadEndCallback` with `dartDevEmbedder.runMain()`.
/// DWDS handles module loading — no scripts array or loadScriptFn needed.
String generateDDCMainModuleScript({
  required String entrypoint,
  bool nativeNullAssertions = true,
}) {
  return '''
/* ENTRYPOINT_EXTENTION_MARKER */

(function() {
  const appName = "org-dartlang-app:/$entrypoint";

  dartDevEmbedder.debugger.registerDevtoolsFormatter();

  const onLoadEndSrc = 'on_load_end_bootstrap.js';
  window.\$dartLoader.loadConfig.bootstrapScript = {
    src: onLoadEndSrc,
    id: onLoadEndSrc,
  };
  window.\$dartLoader.loadConfig.tryLoadBootstrapScript = true;

  window.\$onLoadEndCallback = function() {
    const child = {};
    child.main = function() {
      const sdkOptions = {
        nativeNonNullAsserts: $nativeNullAssertions,
      };
      dartDevEmbedder.runMain(appName, sdkOptions);
    }
    /* MAIN_EXTENSION_MARKER */
    child.main();
  }
})();
''';
}

/// Generate the on-load-end callback script (`on_load_end_bootstrap.js`).
///
/// Matches Flutter's `generateDDCLibraryBundleOnLoadEndBootstrap()`.
String generateOnLoadEndScript() {
  return r'window.$onLoadEndCallback();';
}

/// Generate the `flutter_bootstrap.js` for WASM mode.
///
/// Uses `dart2wasm` compile target and the specified renderer.
String generateWasmFlutterBootstrapJs({
  required String flutterJsContents,
  required String engineRevision,
  String renderer = 'skwasm',
}) {
  final config = '{"engineRevision":"$engineRevision","builds":'
      '[{"compileTarget":"dart2wasm","renderer":"$renderer",'
      '"mainWasmPath":"main.dart.wasm","jsSupportRuntimePath":"main.dart.mjs"}]}';
  return '''
$flutterJsContents

if (!window._flutter) {
  window._flutter = {};
}
_flutter.buildConfig = $config;

_flutter.loader.load();
''';
}

/// CSS loading indicator shown while DDC modules are loading.
///
/// Matches Flutter's loading progress bar style.
const loadingIndicatorCss = '''
.flutter-loader {
  width: 100%;
  height: 8px;
  position: fixed;
  top: 0;
  left: 0;
  z-index: 10000;
  background-color: #e0e0e0;
}
.flutter-loader .indeterminate {
  position: relative;
  width: 100%;
  height: 100%;
}
.flutter-loader .indeterminate .bar {
  position: absolute;
  height: 100%;
  background-color: #1a73e8;
  animation: flutter-loading 2.1s cubic-bezier(0.65, 0.815, 0.735, 0.395) infinite;
}
@keyframes flutter-loading {
  0% { left: -35%; right: 100%; }
  60% { left: 100%; right: -90%; }
  100% { left: 100%; right: -90%; }
}
''';
