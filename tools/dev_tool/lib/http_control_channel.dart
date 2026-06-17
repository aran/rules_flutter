/// HTTP control channel for the dev tool.
///
/// Runs an HTTP server on the IPv6 loopback (`::1`) with an auto-assigned
/// port. All endpoints require a `?token=<token>` query parameter for auth.
/// This allows external tools (like Claude Code) to send commands from
/// isolated shell sessions via simple `curl` POSTs.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'command_runner.dart';
import 'session.dart';

/// HTTP server that exposes the dev tool's command dispatch and screenshot
/// endpoints to external clients.
class HttpControlChannel {
  final CommandRunner _commandRunner;
  final DeviceSession? Function(String appId) _findSession;
  final String _token;
  HttpServer? _server;

  HttpControlChannel({
    required CommandRunner commandRunner,
    required DeviceSession? Function(String appId) findSession,
    String? token,
  })  : _commandRunner = commandRunner,
        _findSession = findSession,
        _token = token ?? _generateToken();

  static String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// The auth token required for all requests.
  String get token => _token;

  /// The bound server URI (available after [start]).
  Uri get uri {
    final server = _server;
    if (server == null) throw StateError('Server not started');
    return Uri.parse('http://[::1]:${server.port}');
  }

  /// Start the HTTP server on `::1` with an auto-assigned port.
  Future<void> start() async {
    _server = await HttpServer.bind(
      InternetAddress('::1', type: InternetAddressType.IPv6),
      0,
    );
    _server!.listen(_handleRequest);
  }

  /// Stop the HTTP server.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    // Reject HTTP upgrade attempts (e.g. HTTP/2 cleartext "h2c"). Dart's
    // HttpServer is HTTP/1.1 only and, when an `Upgrade` header is present,
    // silently discards the request body — which turns a POST /command into a
    // mysterious hang/empty-reply. Fail loudly and early with guidance instead.
    final upgrade = request.headers.value(HttpHeaders.upgradeHeader);
    if (upgrade != null) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({
        'error': 'HTTP upgrade ($upgrade) is not supported; this endpoint is '
            'HTTP/1.1 only. Retry with plain HTTP/1.1 (curl: --http1.1).'
      }));
      await request.response.close();
      return;
    }

    // Auth check.
    final requestToken = request.uri.queryParameters['token'];
    if (requestToken != _token) {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': 'Invalid or missing token'}));
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    try {
      if (request.method == 'POST' && path == '/command') {
        await _handleCommand(request);
      } else if (request.method == 'GET' &&
          _sessionScreenshotMatch(path) != null) {
        final match = _sessionScreenshotMatch(path)!;
        if (match.type == 'flutter') {
          await _handleFlutterScreenshot(request, match.appId);
        } else {
          await _handleNativeScreenshot(request, match.appId);
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.headers.contentType = ContentType.json;
        request.response.write(json.encode({'error': 'Not found'}));
        await request.response.close();
      }
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': e.toString()}));
      await request.response.close();
    }
  }

  Future<void> _handleCommand(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    Map<String, dynamic> parsed;
    try {
      parsed = json.decode(body) as Map<String, dynamic>;
    } catch (e) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': 'Invalid JSON: $e'}));
      await request.response.close();
      return;
    }

    final method = parsed['method'] as String?;
    if (method == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': 'Missing "method" field'}));
      await request.response.close();
      return;
    }

    final params = (parsed['params'] as Map<String, dynamic>?) ?? {};

    try {
      final result = await _commandRunner.run(method, params);
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'result': result}));
    } on ArgumentError catch (e) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': e.message}));
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': e.toString()}));
    }
    await request.response.close();
  }

  Future<void> _handleFlutterScreenshot(
      HttpRequest request, String appId) async {
    final session = _findSession(appId);
    if (session == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': 'Unknown appId: $appId'}));
      await request.response.close();
      return;
    }

    if (session.vmClient == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      request.response.headers.contentType = ContentType.json;
      request.response
          .write(json.encode({'error': 'No VM service for $appId'}));
      await request.response.close();
      return;
    }

    final bytes = await session.vmClient!.screenshotBytes();
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('image', 'png');
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _handleNativeScreenshot(
      HttpRequest request, String appId) async {
    final session = _findSession(appId);
    if (session == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': 'Unknown appId: $appId'}));
      await request.response.close();
      return;
    }

    // `?window=<title>` narrows the capture to a single window on devices
    // that support multi-window selection (currently macOS, exact title
    // match). Devices that ignore it composite or capture however they do
    // by default.
    final window = request.uri.queryParameters['window'];

    final tmpFile = File(
        '${Directory.systemTemp.path}/flutter_bazel_screenshot_${DateTime.now().millisecondsSinceEpoch}.png');
    try {
      // Pass vmClient: null to force the platform-native capture path
      // (bundled macOS helper, adb screencap, etc.) instead of
      // _flutter.screenshot.
      await session.device
          .screenshot(session.appInstance, tmpFile.path, window: window);
      final bytes = await tmpFile.readAsBytes();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(bytes);
      await request.response.close();
    } finally {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
    }
  }

  /// Parse `/sessions/{appId}/screenshot/{type}` from a path.
  _ScreenshotMatch? _sessionScreenshotMatch(String path) {
    final match =
        RegExp(r'^/sessions/([^/]+)/screenshot/(flutter|native)$')
            .firstMatch(path);
    if (match == null) return null;
    return _ScreenshotMatch(
      appId: Uri.decodeComponent(match.group(1)!),
      type: match.group(2)!,
    );
  }
}

class _ScreenshotMatch {
  final String appId;
  final String type;
  _ScreenshotMatch({required this.appId, required this.type});
}
