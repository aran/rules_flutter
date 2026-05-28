/// HTTP server for DDC-compiled web modules during development.
///
/// Implements DWDS's [AssetReader] interface and integrates DWDS for
/// VM service protocol support (hot reload, hot restart, debugging).
///
/// Serves: flutter_bootstrap.js (with embedded flutter.js + build config),
/// main.dart.js (DDC bootstrap), DDC modules, dart_sdk.js, CanvasKit,
/// user web assets, and DWDS endpoints.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dwds/dwds.dart';
import 'package:package_config/package_config.dart' as pkg;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'toolchain_info.dart';
import 'web_bootstrap.dart';

/// Serves DDC-compiled modules and static assets for web dev mode.
///
/// Implements [AssetReader] so DWDS can resolve sources, source maps,
/// and metadata for debugging and hot reload.
class WebModuleServer implements AssetReader {
  final WebToolchainPaths webToolchain;

  /// The build output directory (e.g. `bazel-bin/app_wasm_web/`).
  final String buildOutputDir;

  /// The synthetic entrypoint filename (just `main.dart`, not a full path).
  final String entrypointFilename;

  /// Flutter engine revision (for build config in flutter_bootstrap.js).
  final String engineRevision;

  /// Workspace root (for dart source lookups by DWDS).
  final String? workspaceRoot;

  /// Path to package_config.json (for DWDS package URI resolution).
  final String? packageConfigPath;

  /// Cached parsed package config for source resolution.
  pkg.PackageConfig? _packageConfig;

  /// Compiled JS modules keyed by URL path.
  final Map<String, Uint8List> _modules = {};

  /// Source maps keyed by URL path (e.g. `foo.lib.js.map`).
  final Map<String, Uint8List> _sourcemaps = {};

  /// Module metadata keyed by URL path (e.g. `foo.lib.js.metadata`).
  final Map<String, Uint8List> _metadata = {};

  /// In-memory file storage for first-upload bootstrap files.
  /// These override build-output files and generated scripts.
  final Map<String, Uint8List> _files = {};

  /// Reloaded module descriptors for `reloaded_sources.json`.
  /// Each entry has `src`, `module`, and optionally `libraries`.
  List<Map<String, dynamic>>? _reloadedSources;

  /// Merged metadata string for DWDS MetadataProvider.
  /// Newline-separated JSON objects, one per module.
  String _mergedMetadata = '';

  /// Module digests: module name → hash.
  Map<String, String> _moduleDigests = {};

  /// Whether the first compile has completed. Used to skip populating
  /// reloaded_sources.json on initial compile (matching Flutter).
  bool _initialCompileDone = false;

  /// Cached flutter.js contents.
  String? _flutterJsContents;

  /// Cached DDC bootstrap scripts (generated once, served on every request).
  String? _ddcBootstrapJs;
  String? _ddcMainModuleJs;

  HttpServer? _server;

  /// DWDS instance for VM service protocol bridge.
  Dwds? _dwds;


  WebModuleServer({
    required this.webToolchain,
    required this.buildOutputDir,
    required this.entrypointFilename,
    required this.engineRevision,
    this.workspaceRoot,
    this.packageConfigPath,
  });

  /// The base URL of the running server.
  Uri? get uri => _server == null
      ? null
      : Uri.parse('http://localhost:${_server!.port}');

  /// Stream of connected apps from DWDS.
  Stream<AppConnection>? get connectedApps => _dwds?.connectedApps;

  /// Get a debug connection for an app (provides VM service).
  Future<DebugConnection> debugConnection(AppConnection app) =>
      _dwds!.debugConnection(app);

  /// Write a string to the in-memory file store.
  void writeFile(String path, String content) {
    _files[path] = Uint8List.fromList(utf8.encode(content));
  }

  /// Write bytes to the in-memory file store.
  void writeBytes(String path, Uint8List bytes) {
    _files[path] = bytes;
  }

  // ---- AssetReader implementation ----

  @override
  String get basePath => '';

  @override
  Future<String?> dartSourceContents(String serverPath) async {
    // Check in-memory files first.
    final bytes = _files[serverPath];
    if (bytes != null) return utf8.decode(bytes);
    // Read from workspace filesystem.
    if (workspaceRoot != null && serverPath.endsWith('.dart')) {
      final file = File(p.join(workspaceRoot!, serverPath));
      if (file.existsSync()) return file.readAsStringSync();
      // Try packages/ → package: resolution via package_config.
      if (serverPath.startsWith('packages/') && packageConfigPath != null) {
        try {
          _packageConfig ??=
              await pkg.loadPackageConfig(File(packageConfigPath!));
          final packagePath =
              serverPath.replaceFirst('packages/', 'package:');
          final resolved = _packageConfig!.resolve(Uri.parse(packagePath));
          if (resolved != null) {
            final source = File(resolved.toFilePath());
            if (source.existsSync()) return source.readAsStringSync();
          }
        } catch (_) {}
      }
    }
    return null;
  }

  @override
  Future<String?> sourceMapContents(String serverPath) async {
    var path = serverPath;
    if (path.startsWith('/')) path = path.substring(1);
    // Source maps are looked up by their .js path (strip .map).
    if (path.endsWith('.map')) {
      final bytes = _sourcemaps[path];
      if (bytes != null) return utf8.decode(bytes);
    }
    return null;
  }

  @override
  Future<String?> metadataContents(String serverPath) async {
    final path =
        serverPath.startsWith('/') ? serverPath.substring(1) : serverPath;
    // DWDS MetadataProvider asks for `main_module.ddc_merged_metadata`.
    if (path == 'main_module.ddc_merged_metadata' &&
        _mergedMetadata.isNotEmpty) {
      return _mergedMetadata;
    }
    // Try exact path match in metadata store.
    final bytes = _metadata[path];
    if (bytes != null) return utf8.decode(bytes);
    return null;
  }

  @override
  Future<void> close() async {}

  // ---- Module management ----

  /// Parse DDC manifest and extract modules, source maps, and metadata.
  ///
  /// DDC frontend server writes incremental output to the same files,
  /// containing only changed modules. We merge into existing state so
  /// unchanged modules remain available.
  void updateModules(String dillPath) {
    final manifestFile = File('$dillPath.json');
    final sourcesFile = File('$dillPath.sources');
    final mapFile = File('$dillPath.map');
    final metadataFile = File('$dillPath.metadata');

    if (!manifestFile.existsSync() || !sourcesFile.existsSync()) return;

    final manifest =
        json.decode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final sourcesBytes = sourcesFile.readAsBytesSync();
    final mapBytes = mapFile.existsSync() ? mapFile.readAsBytesSync() : null;
    final metadataBytes =
        metadataFile.existsSync() ? metadataFile.readAsBytesSync() : null;

    // Merge into existing state — incremental compiles only contain changed
    // modules, and unchanged modules must remain available.
    final reloadedSources = <Map<String, dynamic>>[];
    final metadataLines = <String>[];
    final digests = <String, String>{..._moduleDigests};

    for (final entry in manifest.entries) {
      var modulePath = entry.key;
      if (modulePath.startsWith('/')) {
        modulePath = modulePath.substring(1);
      }
      final offsets = entry.value as Map<String, dynamic>;
      final moduleName = modulePath.replaceAll('.lib.js', '');

      // Code (JS source).
      final codeOffsets = (offsets['code'] as List).cast<int>();
      if (codeOffsets.length >= 2) {
        final start = codeOffsets[0];
        final end = codeOffsets[1];
        if (end <= sourcesBytes.length) {
          _modules[modulePath] =
              Uint8List.sublistView(sourcesBytes, start, end);

          final reloadEntry = <String, dynamic>{
            'src': '${uri ?? ''}/$modulePath',
            'module': moduleName,
            'libraries': <String>[],
          };
          reloadedSources.add(reloadEntry);
        }
      }

      // Source maps.
      if (mapBytes != null && offsets.containsKey('sourcemap')) {
        final mapOffsets = (offsets['sourcemap'] as List).cast<int>();
        if (mapOffsets.length >= 2) {
          final start = mapOffsets[0];
          final end = mapOffsets[1];
          if (end <= mapBytes.length) {
            _sourcemaps['$modulePath.map'] =
                Uint8List.sublistView(mapBytes, start, end);
          }
        }
      }

      // Metadata (for DWDS module resolution).
      if (metadataBytes != null && offsets.containsKey('metadata')) {
        final metaOffsets = (offsets['metadata'] as List).cast<int>();
        if (metaOffsets.length >= 2) {
          final start = metaOffsets[0];
          final end = metaOffsets[1];
          if (end <= metadataBytes.length) {
            final metaSlice =
                Uint8List.sublistView(metadataBytes, start, end);
            _metadata['$modulePath.metadata'] = metaSlice;
            final metaStr = utf8.decode(metaSlice);
            if (metaStr.isNotEmpty) {
              metadataLines.add(metaStr);
              // Extract libraries from metadata for reloaded_sources.
              try {
                final metaJson =
                    json.decode(metaStr) as Map<String, dynamic>;
                // Use metadata name for module field when available.
                final metaName = metaJson['name'] as String?;
                final idx = reloadedSources.length - 1;
                if (idx >= 0) {
                  if (metaName != null) {
                    reloadedSources[idx]['module'] = metaName;
                  }
                  final libs = metaJson['libraries'] as List?;
                  if (libs != null) {
                    final libraryUris = <String>[];
                    for (final lib in libs) {
                      final importUri =
                          (lib as Map<String, dynamic>)['importUri']
                              as String?;
                      if (importUri != null) libraryUris.add(importUri);
                    }
                    reloadedSources[idx]['libraries'] = libraryUris;
                  }
                }
              } catch (_) {}
            }
          }
        }
      }

      // Compute digest from code bytes for DWDS.
      if (_modules.containsKey(modulePath)) {
        digests[moduleName] = _modules[modulePath]!.length.toRadixString(16);
      }
    }

    // Only populate reloaded_sources.json after the first compile.
    // On initial load, it must be empty — DWDS's hot reload fetches it
    // and tries to reload every listed module. Matching Flutter's behavior.
    if (_initialCompileDone) {
      _reloadedSources = reloadedSources;
    } else {
      _initialCompileDone = true;
    }
    _mergedMetadata = metadataLines.join('\n');
    _moduleDigests = digests;
  }

  /// Write the `reloaded_sources.json` file to in-memory storage.
  void writeReloadedSources(List<Map<String, dynamic>> sources) {
    _reloadedSources = sources;
  }

  // ---- DWDS initialization ----

  /// Initialize DWDS for VM service protocol support.
  ///
  /// Must be called before [start] or after [start] with [chromeConnection]
  /// callback that will lazily connect to Chrome when DWDS needs it.
  Future<void> initDwds({
    required ConnectionProvider chromeConnection,
    Uri? serverUri,
  }) async {
    // Build the package URI mapper for DWDS module resolution.
    PackageUriMapper? mapper;
    if (packageConfigPath != null) {
      try {
        final config =
            await pkg.loadPackageConfig(File(packageConfigPath!));
        mapper = PackageUriMapper(config);
      } catch (e) {
        // Can't create mapper — DWDS will have limited functionality.
        stderr.writeln('Warning: Could not load package config for DWDS: $e');
      }
    }

    if (mapper == null) {
      stderr.writeln('Warning: No PackageUriMapper available — '
          'DWDS integration disabled.');
      return;
    }

    final strategyProvider = FrontendServerDdcLibraryBundleStrategyProvider(
      ReloadConfiguration.none,
      this, // AssetReader
      mapper,
      () async => _moduleDigests,
      BuildSettings(
        appEntrypoint: Uri.parse('org-dartlang-app:/$entrypointFilename'),
        canaryFeatures: true,
      ),
      packageConfigPath: packageConfigPath,
      reloadedSourcesUri: serverUri != null
          ? serverUri.replace(path: '/reloaded_sources.json')
          : Uri.parse('/reloaded_sources.json'),
    );

    _dwds = await Dwds.start(
      assetReader: this,
      buildResults: const Stream.empty(),
      chromeConnection: chromeConnection,
      toolConfiguration: ToolConfiguration(
        loadStrategy: strategyProvider.strategy,
        debugSettings: DebugSettings(
          enableDebugExtension: true,
        ),
        appMetadata: AppMetadata(hostname: 'localhost'),
      ),
    );

    // Swap the active handler to include DWDS middleware.
    // Match Flutter's web_asset_server.dart:387-393 composition:
    // DWDS middleware wraps only our asset handler (not DWDS's own handler).
    // Cascade tries DWDS handler first, then our wrapped asset handler.
    final wrappedAssetHandler = const shelf.Pipeline()
        .addMiddleware(_dwds!.middleware)
        .addHandler(_shelfHandler);
    _activeHandler = shelf.Cascade()
        .add(_dwds!.handler)
        .add(wrappedAssetHandler)
        .handler;

  }

  // ---- HTTP server ----

  /// The current request handler — swapped when DWDS is initialized.
  late shelf.Handler _activeHandler = _shelfHandler;

  /// Start the HTTP server.
  ///
  /// Call [initDwds] after this to integrate DWDS middleware —
  /// the handler is swapped in-place without restarting the server.
  Future<Uri> start() async {
    // Use an indirection so we can swap the handler after DWDS init.
    final pipeline = const shelf.Pipeline()
        .addMiddleware(_corsMiddleware)
        .addHandler((request) => _activeHandler(request));

    _server = await shelf_io.serve(pipeline, 'localhost', 0);
    return uri!;
  }

  /// Stop the HTTP server and DWDS.
  Future<void> stop() async {
    await _dwds?.stop();
    _dwds = null;
    await _server?.close();
    _server = null;
  }

  String _getFlutterJs() {
    _flutterJsContents ??=
        File(p.join(buildOutputDir, 'flutter.js')).readAsStringSync();
    return _flutterJsContents!;
  }

  /// Shelf middleware that adds CORS headers for WASM SharedArrayBuffer.
  static shelf.Middleware get _corsMiddleware {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) async {
        final response = await innerHandler(request);
        return response.change(headers: {
          'Cross-Origin-Opener-Policy': 'same-origin',
          'Cross-Origin-Embedder-Policy': 'require-corp',
        });
      };
    };
  }

  /// Shelf handler for all asset requests.
  Future<shelf.Response> _shelfHandler(shelf.Request request) async {
    final path =
        request.url.path.isEmpty ? 'index.html' : request.url.path;

    try {
      // 1. In-memory files (first-upload bootstrap files override everything).
      if (_files.containsKey(path)) {
        return shelf.Response.ok(
          _files[path]!,
          headers: {'content-type': _mimeType(path)},
        );
      }

      // 2. flutter_bootstrap.js — embeds flutter.js + build config.
      if (path == 'flutter_bootstrap.js') {
        return shelf.Response.ok(
          generateFlutterBootstrapJs(
            flutterJsContents: _getFlutterJs(),
            engineRevision: engineRevision,
          ),
          headers: {'content-type': 'application/javascript'},
        );
      }

      // 3. DDC modules from memory.
      if (_modules.containsKey(path)) {
        return shelf.Response.ok(
          _modules[path]!,
          headers: {'content-type': 'application/javascript'},
        );
      }

      // Source maps from memory.
      if (_sourcemaps.containsKey(path)) {
        return shelf.Response.ok(
          _sourcemaps[path]!,
          headers: {'content-type': 'application/json'},
        );
      }

      // 4. reloaded_sources.json for hot reload/restart.
      if (path == 'reloaded_sources.json') {
        return shelf.Response.ok(
          json.encode(_reloadedSources ?? []),
          headers: {'content-type': 'application/json'},
        );
      }

      // 5. Generated DDC bootstrap scripts (cached — inputs never change).
      if (path == 'main.dart.js') {
        _ddcBootstrapJs ??=
            generateDDCBootstrapScript(entrypoint: entrypointFilename);
        return shelf.Response.ok(
          _ddcBootstrapJs,
          headers: {'content-type': 'application/javascript'},
        );
      }
      if (path == 'main_module.bootstrap.js') {
        _ddcMainModuleJs ??=
            generateDDCMainModuleScript(entrypoint: entrypointFilename);
        return shelf.Response.ok(
          _ddcMainModuleJs,
          headers: {'content-type': 'application/javascript'},
        );
      }
      if (path == 'on_load_end_bootstrap.js') {
        return shelf.Response.ok(
          generateOnLoadEndScript(),
          headers: {'content-type': 'application/javascript'},
        );
      }

      // 6. dart_sdk.js from DDC build outputs.
      if (path == 'dart_sdk.js') {
        return _serveFile(webToolchain.dartSdkJs);
      }
      if (path == 'dart_sdk.js.map') {
        final mapPath = '${webToolchain.dartSdkJs}.map';
        if (File(mapPath).existsSync()) {
          return _serveFile(mapPath);
        }
      }

      // 7. DDC module loader + stack trace mapper from DDC build outputs.
      if (path == 'ddc_module_loader.js') {
        return _serveFile(webToolchain.ddcModuleLoaderJs);
      }
      if (path == 'stack_trace_mapper.js') {
        return _serveFile(webToolchain.stackTraceMapperJs);
      }

      // 8. Metadata files for DWDS.
      if (_metadata.containsKey(path)) {
        return shelf.Response.ok(
          _metadata[path]!,
          headers: {'content-type': 'application/json'},
        );
      }

      // 9. Static files from build output directory.
      return _serveFile(p.join(buildOutputDir, path));
    } catch (e) {
      return shelf.Response.internalServerError(body: 'Error: $e');
    }
  }

  shelf.Response _serveFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      return shelf.Response.notFound('File not found: $filePath');
    }
    return shelf.Response.ok(
      file.openRead(),
      headers: {'content-type': _mimeType(filePath)},
    );
  }

  static String _mimeType(String path) {
    final ext = p.extension(path).replaceFirst('.', '');
    return switch (ext) {
      'html' => 'text/html',
      'js' || 'mjs' => 'application/javascript',
      'wasm' => 'application/wasm',
      'json' => 'application/json',
      'css' => 'text/css',
      'png' => 'image/png',
      'ico' => 'image/x-icon',
      'map' => 'application/json',
      _ => 'application/octet-stream',
    };
  }
}
