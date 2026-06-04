/// Reusable harness for dev tool e2e tests.
///
/// Spawns the dev tool as a subprocess and provides helpers for
/// interacting with it via stdin/stdout/stderr and the machine protocol.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Parsed HTTP control channel info from machine protocol output.
class HttpControlInfo {
  final Uri uri;
  final String token;
  HttpControlInfo({required this.uri, required this.token});
}

/// Resolves the absolute path to the dev tool entrypoint.
///
/// Assumes tests are run from the `tools/dev_tool/` directory.
String get devToolBin {
  return p.join(Directory.current.path, 'bin', 'flutter_bazel.dart');
}

/// Resolves the absolute path to an e2e workspace.
String e2eWorkspace(String name) {
  return p.normalize(p.join(Directory.current.path, '..', '..', 'e2e', name));
}

/// Resolves the absolute path to the bazel-built dev_tool binary.
///
/// Tests that need bundled tools shipped as Bazel runfiles (e.g. the macOS
/// screenshot helper) must launch through this binary rather than
/// `dart run`, since `dart run` provides no runfiles context. Throws a
/// [StateError] when the binary isn't present — callers should
/// `bazel build //tools/dev_tool:flutter_bazel` first.
String get bazelBuiltDevTool {
  final repoRoot =
      p.normalize(p.join(Directory.current.path, '..', '..'));
  final path =
      p.join(repoRoot, 'bazel-bin', 'tools', 'dev_tool', 'flutter_bazel');
  if (!File(path).existsSync()) {
    throw StateError(
      'Bazel-built dev_tool not found at $path. '
      'Run: bazel build //tools/dev_tool:flutter_bazel',
    );
  }
  return path;
}

/// A running dev tool process with helpers for machine protocol interaction.
class DevToolProcess {
  final Process process;
  final List<Map<String, dynamic>> events = [];
  final List<String> stderrLines = [];
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController.broadcast();
  final StreamController<String> _stderrController =
      StreamController.broadcast();
  late final StreamSubscription _stdoutSub;
  late final StreamSubscription _stderrSub;

  DevToolProcess(this.process) {
    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      // Machine protocol wraps each message in [...].
      if (line.startsWith('[{') && line.endsWith('}]')) {
        try {
          final list = json.decode(line) as List;
          for (final item in list) {
            final msg = item as Map<String, dynamic>;
            events.add(msg);
            _eventController.add(msg);
          }
        } catch (_) {
          // Not JSON — skip.
        }
      }
    });
    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stderrLines.add(line);
      _stderrController.add(line);
    });
  }

  /// Send a machine protocol command and wait for the response.
  Future<Map<String, dynamic>> sendCommand(
    int id,
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final request = <String, dynamic>{
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    process.stdin.writeln(json.encode(request));

    // Wait for a response with matching id.
    return _eventController.stream
        .where((msg) => msg['id'] == id)
        .first
        .timeout(const Duration(seconds: 60));
  }

  /// Wait for an event with the given name.
  Future<Map<String, dynamic>> waitForEvent(
    String eventName, {
    Duration timeout = const Duration(seconds: 120),
  }) {
    // Check already-received events first.
    for (final e in events) {
      if (e['event'] == eventName) return Future.value(e);
    }
    return _eventController.stream
        .where((msg) => msg['event'] == eventName)
        .first
        .timeout(timeout);
  }

  /// Extract the HTTP control channel info from structured JSON stderr lines.
  ///
  /// Parses the `http_control_channel` structured log entry emitted by the
  /// dev tool when `LOG_FORMAT=json`.
  HttpControlInfo? get httpControl {
    for (final line in stderrLines) {
      try {
        final obj = json.decode(line) as Map<String, dynamic>;
        if (obj['message'] == 'http_control_channel') {
          return HttpControlInfo(
            uri: Uri.parse(obj['uri'] as String),
            token: obj['token'] as String,
          );
        }
      } catch (_) {
        // Not JSON — skip.
      }
    }
    return null;
  }

  /// Wait for the HTTP control channel to be available.
  Future<HttpControlInfo> waitForHttpControl({
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final existing = httpControl;
    if (existing != null) return existing;
    await _stderrController.stream
        .where((line) {
          try {
            final obj = json.decode(line) as Map<String, dynamic>;
            return obj['message'] == 'http_control_channel';
          } catch (_) {
            return false;
          }
        })
        .first
        .timeout(timeout);
    return httpControl!;
  }

  /// Take a screenshot via the HTTP control channel.
  ///
  /// Tries the `flutter` endpoint (VM service `_flutter.screenshot`) first,
  /// which works without display access. Falls back to `native` (CDP/screencapture)
  /// if the flutter endpoint fails (e.g. web sessions with no VM service).
  Future<List<int>> httpScreenshot(String appId) async {
    final info = httpControl;
    if (info == null) throw StateError('HTTP control channel not available');
    // Try flutter endpoint first (works without display access).
    try {
      return await _httpScreenshotEndpoint(info, appId, 'flutter');
    } catch (_) {
      // Fall back to native endpoint (CDP for web, screencapture for macOS).
      return _httpScreenshotEndpoint(info, appId, 'native');
    }
  }

  Future<List<int>> _httpScreenshotEndpoint(
    HttpControlInfo info,
    String appId,
    String type,
  ) async {
    final client = HttpClient();
    try {
      final url = info.uri.replace(
        path: '/sessions/$appId/screenshot/$type',
        query: 'token=${info.token}',
      );
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != 200) {
        final body = await utf8.decoder.bind(response).join();
        throw StateError('Screenshot failed (${response.statusCode}): $body');
      }
      final chunks = <List<int>>[];
      await response.forEach(chunks.add);
      return chunks.expand((c) => c).toList();
    } finally {
      client.close();
    }
  }

  /// Take a screenshot and save to a file. Returns the file path.
  Future<String> httpScreenshotToFile(String appId, String outputPath) async {
    final bytes = await httpScreenshot(appId);
    await File(outputPath).writeAsBytes(bytes);
    return outputPath;
  }

  /// Hit the `native` screenshot endpoint directly, optionally selecting a
  /// window by exact title via `?window=<encoded>`. Distinct from
  /// [httpScreenshot] which tries `flutter` first and falls back to `native`.
  Future<List<int>> httpNativeScreenshot(
    String appId, {
    String? window,
  }) async {
    final info = httpControl;
    if (info == null) throw StateError('HTTP control channel not available');
    final client = HttpClient();
    try {
      final query = {
        'token': info.token,
        if (window != null) 'window': window,
      };
      final url = info.uri.replace(
        path: '/sessions/$appId/screenshot/native',
        queryParameters: query,
      );
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != 200) {
        final body = await utf8.decoder.bind(response).join();
        throw StateError(
            'Native screenshot failed (${response.statusCode}): $body');
      }
      final chunks = <List<int>>[];
      await response.forEach(chunks.add);
      return chunks.expand((c) => c).toList();
    } finally {
      client.close();
    }
  }

  /// Extract appId from app.start events.
  String? get appId {
    for (final e in events) {
      if (e['event'] == 'app.start') {
        return e['params']?['appId'] as String?;
      }
    }
    return null;
  }

  /// Send a command via the HTTP control channel and return the JSON response.
  Future<Map<String, dynamic>> httpCommand(
    String method,
    Map<String, dynamic> params,
  ) async {
    final info = httpControl;
    if (info == null) throw StateError('HTTP control channel not available');
    final client = HttpClient();
    try {
      final url = info.uri.replace(
        path: '/command',
        query: 'token=${info.token}',
      );
      final request = await client.postUrl(url);
      request.headers.contentType = ContentType.json;
      request.write(json.encode({'method': method, 'params': params}));
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      return json.decode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// Kill the process and clean up.
  Future<void> dispose() async {
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
    await _eventController.close();
    await _stderrController.close();
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -9;
      },
    );
  }
}

/// Start the dev tool in machine mode and return a [DevToolProcess].
///
/// Sets `LOG_FORMAT=json` so the harness can parse structured log entries
/// from stderr (e.g. HTTP control channel info).
Future<DevToolProcess> startDevTool({
  required String workspace,
  required String target,
  required String device,
  List<String> extraArgs = const [],
  bool useBazelBuiltBinary = false,
  bool watch = false,
}) async {
  final commonArgs = [
    'run',
    '-t',
    target,
    '-d',
    device,
    '--machine',
    '--no-devtools',
    // Machine mode defaults the filesystem watcher OFF; opt back in to exercise
    // watch-driven (terminal-style) reloads.
    if (watch) '--watch',
    ...extraArgs,
  ];
  final process = useBazelBuiltBinary
      ? await Process.start(
          bazelBuiltDevTool,
          commonArgs,
          workingDirectory: workspace,
          environment: {...Platform.environment, 'LOG_FORMAT': 'json'},
        )
      : await Process.start(
          'dart',
          ['run', devToolBin, ...commonArgs],
          workingDirectory: workspace,
          environment: {...Platform.environment, 'LOG_FORMAT': 'json'},
        );
  return DevToolProcess(process);
}

/// Resolve `adb` the same way the dev tool itself does: $ANDROID_HOME
/// → macOS default → PATH. Inlined to keep the harness independent of
/// the dev tool's internal device library.
String _resolveAdb() {
  final androidHome = Platform.environment['ANDROID_HOME'];
  if (androidHome != null) {
    final adb = p.join(androidHome, 'platform-tools', 'adb');
    if (File(adb).existsSync()) return adb;
  }
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home != null) {
      final adb = p.join(
        home,
        'Library',
        'Android',
        'sdk',
        'platform-tools',
        'adb',
      );
      if (File(adb).existsSync()) return adb;
    }
  }
  return 'adb';
}

/// Returns true when `adb devices` lists at least one entry in the
/// `device` state — i.e. an authorized emulator or USB-connected
/// physical device.
///
/// Mirrors what `flutter_bazel run -d android` does internally: pick
/// whatever `adb devices` exposes; the test does not start or stop
/// emulators, that's the user's pre-step (per docs/TESTING.md
/// § Plugin verification matrix).
bool hasAndroidDevice() => firstAndroidSerial() != null;

/// Returns the serial of the first `adb devices` entry in the `device`
/// state, or null when none is authorized. The dev_tool's `-d` flag
/// takes an Android serial (not the generic `'android'` token), so the
/// e2e test passes the result of this through.
String? firstAndroidSerial() {
  try {
    final result = Process.runSync(_resolveAdb(), ['devices']);
    if (result.exitCode != 0) return null;
    final lines = (result.stdout as String).split('\n');
    for (final raw in lines.skip(1)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      // Format: `<serial>\t<state>`. We accept only `device`; `unauthorized`
      // / `offline` / `recovery` etc. fail the test loudly on launch
      // rather than skipping silently.
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts[1] == 'device') return parts[0];
    }
    return null;
  } catch (_) {
    return null;
  }
}
