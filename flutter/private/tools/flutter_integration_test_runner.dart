/// Bazel-side driver for `flutter_integration_test`.
///
/// Launches a built Flutter application on the target platform (starting with
/// `web`, designed so `linux` and `android` share the harness), hosts a
/// localhost WebSocket + HTTP server, and drives the in-app `RemoteListener`
/// suite compiled into the application entrypoint.
///
/// Fails (exits non-zero) on:
/// - any test expectation failure (printing test name, expected, and actual),
/// - any uncaught Dart/Flutter/JS error,
/// - browser or target process crash / unexpected exit,
/// - dial-back or per-test timeout,
/// - zero executed cases (no test passed or failed): a run that executes
///   nothing is a broken harness, not a pass.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'bazel_test_protocol.dart';

/// WebSocket upgrade path the in-app bootstrap dials on the harness server.
const String integrationWebSocketPath = '/__flutter_integration_ws__';

void main(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln(
      'flutter_integration_test runner: unrecognised arguments: '
      '${args.join(" ")}',
    );
    exit(64);
  }

  final r = Runfiles.create();
  final platform =
      Platform.environment['FLUTTER_INTEGRATION_TEST_PLATFORM'] ?? 'web';
  final testPath =
      Platform.environment['FLUTTER_INTEGRATION_TEST_PATH'] ??
      'integration_test.dart';

  final TestSelection selection;
  try {
    selection = TestSelection.fromEnvironment(Platform.environment);
  } on FormatException catch (e) {
    stderr.writeln('flutter_integration_test runner: ${e.message}');
    exit(64);
  }
  // The suite's library-level `@Tags`, extracted at build time: sent in the
  // handshake below so the test isolate's root group carries them, as
  // `test_core` sends `parseMetadata`'s result.
  final Set<String> libraryTags;
  try {
    libraryTags = readLibraryTags(Platform.environment, r.rlocation);
  } on FormatException catch (e) {
    stderr.writeln('flutter_integration_test runner: ${e.message}');
    exit(64);
  }

  final shardStatus = Platform.environment['TEST_SHARD_STATUS_FILE'];
  if (shardStatus != null) {
    File(shardStatus).writeAsStringSync('');
  }

  final PlatformLauncher launcher;
  try {
    launcher = createPlatformLauncher(platform, Platform.environment, r);
  } on FormatException catch (e) {
    stderr.writeln('flutter_integration_test runner: ${e.message}');
    exit(64);
  }

  exitCode = await runIntegrationSuite(
    launcher: launcher,
    testPath: testPath,
    selection: selection,
    libraryTags: libraryTags,
    xmlOutput: Platform.environment['XML_OUTPUT_FILE'],
    bazelTestTimeout: Platform.environment['TEST_TIMEOUT'],
  );
}

/// Creates the [PlatformLauncher] for [platform] from environment variables.
PlatformLauncher createPlatformLauncher(
  String platform,
  Map<String, String> env,
  Runfiles r,
) {
  switch (platform) {
    case 'web':
      return _webLauncherFromEnv(env, r);
    case 'linux':
      return _linuxLauncherFromEnv(env, r);
    case 'android':
      return _androidLauncherFromEnv(env, r);
    default:
      throw FormatException(
        'Unsupported integration test platform "$platform". '
        'Supported platforms: web, linux, android.',
      );
  }
}

/// Builds the web launcher: the built bundle served over localhost HTTP to
/// the pinned `chrome-headless-shell`.
WebPlatformLauncher _webLauncherFromEnv(Map<String, String> env, Runfiles r) {
  final webDirKey = env['FLUTTER_INTEGRATION_TEST_WEB_DIR'];
  final browserKey = env['FLUTTER_INTEGRATION_TEST_BROWSER'];
  final fontconfigKey = env['FLUTTER_INTEGRATION_TEST_FONTCONFIG'];
  if (webDirKey == null || webDirKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_WEB_DIR must be set for platform="web".',
    );
  }
  if (browserKey == null || browserKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_BROWSER must be set for platform="web".',
    );
  }
  final webDir = r.rlocation(webDirKey);
  final browserBinary = r.rlocation(browserKey);
  final fontconfigFile = (fontconfigKey == null || fontconfigKey.isEmpty)
      ? null
      : r.rlocation(fontconfigKey);
  final robotoKey = env['FLUTTER_INTEGRATION_TEST_ROBOTO_FONT'];
  final robotoFont = (robotoKey == null || robotoKey.isEmpty)
      ? null
      : r.rlocation(robotoKey);
  return WebPlatformLauncher(
    webDir: webDir,
    browserBinary: browserBinary,
    fontconfigFile: fontconfigFile,
    robotoFontFile: robotoFont,
    baseTempDir: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
  );
}

/// Builds the Linux launcher: the desktop bundle under a hermetic `Xvfb`.
LinuxPlatformLauncher _linuxLauncherFromEnv(
  Map<String, String> env,
  Runfiles r,
) {
  final bundleDirKey = env['FLUTTER_INTEGRATION_TEST_LINUX_BUNDLE'];
  final binaryName = env['FLUTTER_INTEGRATION_TEST_LINUX_BINARY'];
  final xvfbKey = env['FLUTTER_INTEGRATION_TEST_XVFB'];
  final xkbcompKey = env['FLUTTER_INTEGRATION_TEST_XKBCOMP'];
  final fontconfigKey = env['FLUTTER_INTEGRATION_TEST_FONTCONFIG'];
  if (bundleDirKey == null || bundleDirKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_LINUX_BUNDLE must be set for platform="linux".',
    );
  }
  if (binaryName == null || binaryName.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_LINUX_BINARY must be set for platform="linux".',
    );
  }
  if (xvfbKey == null || xvfbKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_XVFB must be set for platform="linux".',
    );
  }
  if (xkbcompKey == null || xkbcompKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_XKBCOMP must be set for platform="linux".',
    );
  }
  final bundleDir = r.rlocation(bundleDirKey);
  final xvfbBinary = r.rlocation(xvfbKey);
  final xkbcompBinary = r.rlocation(xkbcompKey);
  final fontconfigFile = (fontconfigKey == null || fontconfigKey.isEmpty)
      ? null
      : r.rlocation(fontconfigKey);
  return LinuxPlatformLauncher(
    bundleDir: bundleDir,
    binaryName: binaryName,
    xvfbBinary: xvfbBinary,
    xkbcompBinary: xkbcompBinary,
    fontconfigFile: fontconfigFile,
    baseTempDir: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
  );
}

/// Builds the Android launcher: the APK on a hermetic emulator via `adb`.
AndroidPlatformLauncher _androidLauncherFromEnv(
  Map<String, String> env,
  Runfiles r,
) {
  final apkKey = env['FLUTTER_INTEGRATION_TEST_ANDROID_APK'];
  final packageName = env['FLUTTER_INTEGRATION_TEST_ANDROID_PACKAGE'];
  final emulatorKey = env['FLUTTER_INTEGRATION_TEST_ANDROID_EMULATOR'];
  final adbKey = env['FLUTTER_INTEGRATION_TEST_ANDROID_ADB'];
  if (apkKey == null || apkKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_ANDROID_APK must be set for platform="android".',
    );
  }
  if (packageName == null || packageName.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_ANDROID_PACKAGE must be set for platform="android".',
    );
  }
  if (emulatorKey == null || emulatorKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_ANDROID_EMULATOR must be set for platform="android".',
    );
  }
  if (adbKey == null || adbKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_ANDROID_ADB must be set for platform="android".',
    );
  }
  final apkPath = r.rlocation(apkKey);
  final emulatorBinary = r.rlocation(emulatorKey);
  final adbBinary = r.rlocation(adbKey);
  final kvmPath = env['FLUTTER_INTEGRATION_TEST_KVM_PATH'] ?? '/dev/kvm';
  return AndroidPlatformLauncher(
    apkPath: apkPath,
    packageName: packageName,
    emulatorBinary: emulatorBinary,
    adbBinary: adbBinary,
    baseTempDir: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
    kvmPath: kvmPath,
  );
}

/// Decodes the JSON-encoded declared environment forwarded by
/// `flutter_integration_test.bzl` (`FLUTTER_INTEGRATION_TEST_DECLARED_ENV`).
/// Decodes the JSON map stored in a `*_DECLARED_ENV` launcher variable.
///
/// Public, like [buildChromeArguments], because the test reaches it
/// directly. A missing variable or a malformed payload decodes to an empty
/// map: a build that received no usable declared environment falls back to
/// inherited-environment-only resolution, and a missing variable surfaces
/// later as a concrete lookup error instead.
Map<String, String> decodeDeclaredEnv(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <String, String>{};
  try {
    final decoded = json.decode(raw);
    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }
  } on FormatException {
    // Corrupted declared environment behaves like none at all.
  }
  return const <String, String>{};
}

/// Per-test timeout ceiling inside Bazel's outer `TEST_TIMEOUT`.
Duration testCeiling(String? bazelTestTimeout) {
  final seconds = int.tryParse(bazelTestTimeout ?? '');
  if (seconds == null || seconds <= 0) return const Duration(minutes: 5);
  final margin = seconds ~/ 20;
  return Duration(seconds: seconds - (margin < 10 ? 10 : margin));
}

/// Suite default timeout serialized as `package:test_api` `Metadata` expects.
Object suiteTimeout(String? bazelTestTimeout) {
  final seconds = int.tryParse(bazelTestTimeout ?? '');
  if (seconds == null || seconds <= 0) return 'none';
  return {
    'duration': Duration(seconds: seconds).inMicroseconds,
    'scaleFactor': null,
  };
}

/// Best-effort synchronous filesystem cleanup.
///
/// Swallows only [FileSystemException]: a file that vanished between the
/// `existsSync` check and the deletion is a race with the platform, not a
/// failure of the run. Anything else is a bug in the cleanup itself and
/// propagates.
///
/// Public, like [buildChromeArguments], because the test reaches it directly.
void cleanupQuietly(void Function() action) {
  try {
    action();
  } on FileSystemException catch (_) {
    // Best-effort cleanup only; anything else propagates by design.
  }
}

/// Best-effort asynchronous teardown step.
///
/// Swallows only the races a closing resource reports — [IOException] when
/// the peer went away first, [StateError] when the close already happened —
/// so a bug in teardown itself still surfaces instead of masking the run's
/// real result from a `finally` block.
///
/// Public, like [buildChromeArguments], because the test reaches it directly.
Future<void> teardownQuietly(Future<void> Function() step) async {
  try {
    await step();
  } on IOException catch (_) {
    // Best-effort teardown only; anything else propagates by design.
  } on StateError catch (_) {
    // Best-effort teardown only; anything else propagates by design.
  }
}

/// Builds the command-line flags passed to the hermetic `chrome-headless-shell`.
List<String> buildChromeArguments({
  required String url,
  required String userDataDir,
}) {
  return <String>[
    '--headless',
    '--no-sandbox',
    '--disable-dev-shm-usage',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-extensions',
    '--disable-sync',
    '--disable-translate',
    '--metrics-recording-only',
    '--mute-audio',
    '--window-size=800,600',
    '--user-data-dir=$userDataDir',
    url,
  ];
}

/// Builds the hermetic environment for `chrome-headless-shell`.
///
/// Clears `PATH` so no host browser or binary on `PATH` can ever be invoked,
/// and sets `LD_LIBRARY_PATH` exclusively to the pinned runtime library
/// directories in runfiles.
Map<String, String> buildChromeEnvironment({
  required String browserBinary,
  required String scratchDir,
  String? fontconfigFile,
  Map<String, String>? env,
  Map<String, String>? environment,
  Map<String, String>? declaredEnv,
  Map<String, String>? userEnv,
  Map<String, String>? extraEnv,
  Map<String, String>? extraEnvironment,
  Map<String, String>? forwardedEnv,
  Map<String, String>? userEnvironment,
  String? tz,
  String? timeZone,
  String? timezone,
  String? timeZoneName,
  String? timeZoneId,
  String? tzName,
}) {
  final browserFile = File(browserBinary);
  final browserDir = browserFile.parent.path;
  final repoRoot = browserFile.parent.parent.path;
  final libDirs = <String>[
    browserDir,
    '$repoRoot/sysroot/usr/lib/x86_64-linux-gnu',
    '$repoRoot/sysroot/lib/x86_64-linux-gnu',
  ];

  final resolvedEnv =
      env ??
      environment ??
      declaredEnv ??
      userEnv ??
      extraEnv ??
      extraEnvironment ??
      forwardedEnv ??
      userEnvironment;
  final resolvedTz =
      tz ?? timeZone ?? timezone ?? timeZoneName ?? timeZoneId ?? tzName;
  final mergedDeclared = resolvedEnv ?? const <String, String>{};
  final tzValue = mergedDeclared['TZ'] ?? resolvedTz ?? 'UTC';

  final result = <String, String>{
    'PATH': '',
    'LD_LIBRARY_PATH': libDirs.join(':'),
    'HOME': scratchDir,
    'TMPDIR': scratchDir,
    'XDG_CONFIG_HOME': '$scratchDir/.config',
    'XDG_CACHE_HOME': '$scratchDir/.cache',
    'TZ': tzValue,
    if (fontconfigFile != null) ...{
      'FONTCONFIG_FILE': fontconfigFile,
      'FONTCONFIG_PATH': File(fontconfigFile).parent.path,
    },
  };
  result.addAll(mergedDeclared);
  result.putIfAbsent('TZ', () => resolvedTz ?? 'UTC');
  return result;
}

/// Builds the command-line arguments passed to the hermetic `Xvfb` binary.
///
/// Uses `-displayfd 1` so `Xvfb` picks a free display number and writes
/// `<display>\n` to stdout once the X server is listening for connections.
List<String> buildXvfbArguments({required String xkbDir}) {
  return <String>[
    '-displayfd',
    '1',
    '-screen',
    '0',
    '1024x768x24',
    '-nolisten',
    'tcp',
    '-noreset',
    '-xkbdir',
    xkbDir,
  ];
}

/// Builds the hermetic environment for `Xvfb`.
///
/// Restricts `PATH` to the pinned sysroot `usr/bin` (so `xkbcomp` resolves
/// exclusively from the pinned package archive) and `LD_LIBRARY_PATH` to the
/// pinned sysroot library directories.
Map<String, String> buildXvfbEnvironment({
  required String sysrootDir,
  required String scratchDir,
}) {
  final libDirs = <String>[
    '$sysrootDir/usr/lib/x86_64-linux-gnu',
    '$sysrootDir/lib/x86_64-linux-gnu',
  ];
  return <String, String>{
    'PATH': '$sysrootDir/usr/bin',
    'LD_LIBRARY_PATH': libDirs.join(':'),
    'HOME': scratchDir,
    'TMPDIR': scratchDir,
    'XKB_BINDIR': '$sysrootDir/usr/bin',
  };
}

/// Builds the hermetic environment for the compiled Flutter Linux desktop app.
///
/// Directs GTK3, GDK, GLib, Fontconfig, libglvnd, and Mesa (`llvmpipe`
/// `swrast_dri.so`) to the pinned sysroot in runfiles and the `Xvfb` display.
Map<String, String> buildLinuxAppEnvironment({
  required String bundleDir,
  required String sysrootDir,
  required String scratchDir,
  required String display,
  required String harnessUrl,
  String? fontconfigFile,
  Map<String, String>? env,
  Map<String, String>? environment,
  Map<String, String>? declaredEnv,
  Map<String, String>? userEnv,
  Map<String, String>? extraEnv,
  Map<String, String>? extraEnvironment,
  Map<String, String>? forwardedEnv,
  Map<String, String>? userEnvironment,
  String? tz,
  String? timeZone,
  String? timezone,
  String? timeZoneName,
  String? timeZoneId,
  String? tzName,
}) {
  final libDirs = <String>[
    '$bundleDir/lib',
    '$sysrootDir/usr/lib/x86_64-linux-gnu',
    '$sysrootDir/lib/x86_64-linux-gnu',
  ];
  final driDir = '$sysrootDir/usr/lib/x86_64-linux-gnu/dri';

  final resolvedEnv =
      env ??
      environment ??
      declaredEnv ??
      userEnv ??
      extraEnv ??
      extraEnvironment ??
      forwardedEnv ??
      userEnvironment;
  final resolvedTz =
      tz ?? timeZone ?? timezone ?? timeZoneName ?? timeZoneId ?? tzName;
  final mergedDeclared = resolvedEnv ?? const <String, String>{};
  final tzValue = mergedDeclared['TZ'] ?? resolvedTz ?? 'UTC';

  final result = <String, String>{
    'PATH': '$sysrootDir/usr/bin',
    'LD_LIBRARY_PATH': libDirs.join(':'),
    'DISPLAY': display,
    'GDK_BACKEND': 'x11',
    'LIBGL_ALWAYS_SOFTWARE': '1',
    'GALLIUM_DRIVER': 'llvmpipe',
    'LIBGL_DRIVERS_PATH': driDir,
    'GBM_DRIVERS_PATH': driDir,
    '__EGL_VENDOR_LIBRARY_DIRS': '$sysrootDir/usr/share/glvnd/egl_vendor.d',
    'XLOCALEDIR': '$sysrootDir/usr/share/X11/locale',
    'XKB_CONFIG_ROOT': '$sysrootDir/usr/share/X11/xkb',
    'GIO_MODULE_DIR': '$scratchDir/empty-gio-modules',
    'GTK_PATH': '$scratchDir/empty-gtk-path',
    'NO_AT_BRIDGE': '1',
    'GSETTINGS_BACKEND': 'memory',
    'HOME': scratchDir,
    'TMPDIR': scratchDir,
    'XDG_CONFIG_HOME': '$scratchDir/.config',
    'XDG_CACHE_HOME': '$scratchDir/.cache',
    'XDG_RUNTIME_DIR': '$scratchDir/xdg-runtime',
    'FLUTTER_INTEGRATION_TEST_HARNESS_URL': harnessUrl,
    'TZ': tzValue,
    if (fontconfigFile != null) ...{
      'FONTCONFIG_FILE': fontconfigFile,
      'FONTCONFIG_PATH': File(fontconfigFile).parent.path,
    },
  };
  result.addAll(mergedDeclared);
  result.putIfAbsent('TZ', () => resolvedTz ?? 'UTC');
  return result;
}

/// Copies the pinned `Xvfb` binary into [scratchDir] and clears its compiled-in
/// `XkbBinDirectory` (`"/usr/bin"`) so `Xvfb` invokes `xkbcomp` via `PATH`
/// (`<sysroot>/usr/bin/xkbcomp`) instead of `/usr/bin/xkbcomp`.
String prepareHermeticXvfbBinary({
  required String sourceXvfbBinary,
  required String scratchDir,
}) {
  final binDir = Directory('$scratchDir/bin')..createSync(recursive: true);
  final destPath = '${binDir.path}/Xvfb';
  File(sourceXvfbBinary).copySync(destPath);

  final bytes = File(destPath).readAsBytesSync();
  // In Xorg's xkbInit.c, XkbBinDirectory is initialized to "/usr/bin"
  // immediately adjacent to XkbBaseDirectory ("/usr/share/X11/xkb"). Clearing
  // "/usr/bin" to an empty C string causes XkbDDXCompileKeymapByNames to omit
  // the directory prefix and resolve `xkbcomp` from PATH.
  const usrBin = <int>[0x2f, 0x75, 0x73, 0x72, 0x2f, 0x62, 0x69, 0x6e, 0x00];
  const xkbShare = <int>[
    0x2f, 0x75, 0x73, 0x72, 0x2f, 0x73, 0x68, 0x61, 0x72, 0x65, // /usr/share
    0x2f, 0x58, 0x31, 0x31, 0x2f, 0x78, 0x6b, 0x62, 0x00, // /X11/xkb\0
  ];
  final xkbIdx = _indexOfBytes(bytes, xkbShare);
  if (xkbIdx >= usrBin.length) {
    final searchStart = xkbIdx - 32 < 0 ? 0 : xkbIdx - 32;
    final usrBinIdx = _indexOfBytes(
      bytes,
      usrBin,
      start: searchStart,
      end: xkbIdx,
    );
    if (usrBinIdx >= 0) {
      final raf = File(destPath).openSync(mode: FileMode.writeOnlyAppend);
      try {
        raf.setPositionSync(usrBinIdx);
        raf.writeFromSync(const <int>[0, 0, 0, 0, 0, 0, 0, 0]);
      } finally {
        raf.closeSync();
      }
    }
  }
  return destPath;
}

int _indexOfBytes(
  List<int> haystack,
  List<int> needle, {
  int start = 0,
  int? end,
}) {
  final limit = (end ?? haystack.length) - needle.length;
  outer:
  for (var i = start; i <= limit; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Abstraction over how a target platform starts the compiled app and serves
/// any platform-specific HTTP endpoints on the harness [HttpServer].
abstract class PlatformLauncher {
  /// Platform identifier (`'web'`, `'linux'`, `'android'`).
  String get platformName;

  /// Runtime identifier for `package:test_api` `SuitePlatform`.
  String get suiteRuntime;

  /// Compiler identifier for `package:test_api` `SuitePlatform`.
  String get suiteCompiler;

  /// Handles a non-WebSocket HTTP request arriving on the harness server.
  Future<void> handleHttpRequest(HttpRequest request);

  /// Starts the target process against a harness listening on [harnessPort].
  Future<Process> startTarget(int harnessPort);

  /// Cleans up any temporary directories created for the target process.
  Future<void> dispose();
}

/// Launches the built Flutter web bundle in the pinned `chrome-headless-shell`
/// and serves the bundle over localhost HTTP.
class WebPlatformLauncher implements PlatformLauncher {
  WebPlatformLauncher({
    required this.webDir,
    required this.browserBinary,
    required this.baseTempDir,
    this.fontconfigFile,
    this.robotoFontFile,
  });

  final String webDir;
  final String browserBinary;
  final String baseTempDir;
  final String? fontconfigFile;
  final String? robotoFontFile;

  Directory? _scratchDir;

  @override
  String get platformName => 'web';

  @override
  String get suiteRuntime => 'chrome';

  @override
  String get suiteCompiler => 'dart2js';

  @override
  Future<Process> startTarget(int harnessPort) async {
    if (!File(browserBinary).existsSync()) {
      throw StateError(
        'Pinned chrome-headless-shell binary not found at "$browserBinary".',
      );
    }
    if (!Directory(webDir).existsSync()) {
      throw StateError('Built web bundle directory not found at "$webDir".');
    }

    final scratch = Directory(
      '$baseTempDir/chrome_integration_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    _scratchDir = scratch;
    final userDataDir = Directory('${scratch.path}/profile')
      ..createSync(recursive: true);
    Directory('${scratch.path}/.config').createSync(recursive: true);
    Directory('${scratch.path}/.cache').createSync(recursive: true);
    Directory('${scratch.path}/fontconfig-cache').createSync(recursive: true);

    final url = 'http://127.0.0.1:$harnessPort/';
    final args = buildChromeArguments(
      url: url,
      userDataDir: userDataDir.path,
    );
    final declaredEnv = decodeDeclaredEnv(
      Platform.environment['FLUTTER_INTEGRATION_TEST_DECLARED_ENV'],
    );
    final tz = Platform.environment['TZ'];
    final env = buildChromeEnvironment(
      browserBinary: browserBinary,
      scratchDir: scratch.path,
      fontconfigFile: fontconfigFile,
      env: declaredEnv,
      tz: tz,
    );

    return Process.start(
      browserBinary,
      args,
      environment: env,
      includeParentEnvironment: false,
    );
  }

  @override
  Future<void> handleHttpRequest(HttpRequest request) async {
    await serveWebBundleRequest(
      request,
      webDir: webDir,
      robotoFontFile: robotoFontFile,
    );
  }

  @override
  Future<void> dispose() async {
    final dir = _scratchDir;
    _scratchDir = null;
    if (dir != null && dir.existsSync()) {
      cleanupQuietly(() => dir.deleteSync(recursive: true));
    }
  }
}

/// Launches the built Flutter Linux desktop bundle inside a hermetic, pinned
/// `Xvfb` virtual display using the pinned GTK3 and Mesa software OpenGL/EGL
/// runtime libraries.
class LinuxPlatformLauncher implements PlatformLauncher {
  LinuxPlatformLauncher({
    required this.bundleDir,
    required this.binaryName,
    required this.xvfbBinary,
    required this.xkbcompBinary,
    required this.baseTempDir,
    this.fontconfigFile,
  });

  final String bundleDir;
  final String binaryName;
  final String xvfbBinary;
  final String xkbcompBinary;
  final String baseTempDir;
  final String? fontconfigFile;

  Directory? _scratchDir;
  Process? _xvfbProcess;
  String? _displayNumber;

  @override
  String get platformName => 'linux';

  @override
  String get suiteRuntime => 'vm';

  @override
  String get suiteCompiler => 'kernel';

  /// Creates the scratch tree for a Linux run: config, cache, runtime and
  /// fontconfig homes plus the empty GTK/GIO override directories.
  Directory _prepareLinuxScratch() {
    final scratch = Directory(
      '$baseTempDir/linux_integration_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    _scratchDir = scratch;
    Directory('${scratch.path}/.config').createSync(recursive: true);
    Directory('${scratch.path}/.cache').createSync(recursive: true);
    Directory('${scratch.path}/xdg-runtime').createSync(recursive: true);
    Directory('${scratch.path}/fontconfig-cache').createSync(recursive: true);
    Directory('${scratch.path}/empty-gio-modules').createSync(recursive: true);
    Directory('${scratch.path}/empty-gtk-path').createSync(recursive: true);
    return scratch;
  }

  /// Points fontconfig at the sysroot's fonts when it ships any, falling
  /// back to the pinned `fonts.conf`.
  String? _writeScratchFontsConf(Directory scratch, String sysrootDir) {
    final sysrootFontsDir = Directory('$sysrootDir/usr/share/fonts');
    if (!sysrootFontsDir.existsSync()) return fontconfigFile;
    final localFontsConf = File('${scratch.path}/fonts.conf');
    localFontsConf.writeAsStringSync('''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>${sysrootFontsDir.path}</dir>
  <cachedir>${scratch.path}/fontconfig-cache</cachedir>
</fontconfig>
''');
    return localFontsConf.path;
  }

  /// Starts the patched `Xvfb` and waits for its `-displayfd` number.
  Future<String> _bootXvfb(
    String patchedXvfb,
    List<String> xvfbArgs,
    Map<String, String> xvfbEnv,
  ) async {
    final xvfb = await Process.start(
      patchedXvfb,
      xvfbArgs,
      environment: xvfbEnv,
      includeParentEnvironment: false,
    );
    _xvfbProcess = xvfb;

    final xvfbStderr = <String>[];
    xvfb.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((
      line,
    ) {
      if (xvfbStderr.length < 50) {
        xvfbStderr.add(line);
      }
    });

    final displayCompleter = Completer<String>();
    final stdoutSub = xvfb.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty && !displayCompleter.isCompleted) {
              displayCompleter.complete(trimmed);
            }
          },
          onDone: () {
            if (!displayCompleter.isCompleted) {
              displayCompleter.completeError(
                StateError(
                  'Xvfb exited before reporting a display number on -displayfd:\n'
                  '${xvfbStderr.join("\n")}',
                ),
              );
            }
          },
        );

    try {
      return await displayCompleter.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException(
          'Timed out waiting for Xvfb to report a display number:\n'
          '${xvfbStderr.join("\n")}',
        ),
      );
    } finally {
      await stdoutSub.cancel();
    }
  }

  @override
  Future<Process> startTarget(int harnessPort) async {
    if (!File(xvfbBinary).existsSync()) {
      throw StateError('Pinned Xvfb binary not found at "$xvfbBinary".');
    }
    if (!File(xkbcompBinary).existsSync()) {
      throw StateError('Pinned xkbcomp binary not found at "$xkbcompBinary".');
    }
    if (!Directory(bundleDir).existsSync()) {
      throw StateError(
        'Built Linux bundle directory not found at "$bundleDir".',
      );
    }
    final appBinary = '$bundleDir/$binaryName';
    if (!File(appBinary).existsSync()) {
      throw StateError(
        'Built Linux application binary not found at "$appBinary".',
      );
    }

    // xvfbBinary is at <repoRoot>/sysroot/usr/bin/Xvfb.
    final sysrootDir = File(xvfbBinary).parent.parent.parent.path;

    final scratch = _prepareLinuxScratch();
    final effectiveFontconfig = _writeScratchFontsConf(scratch, sysrootDir);

    final patchedXvfb = prepareHermeticXvfbBinary(
      sourceXvfbBinary: xvfbBinary,
      scratchDir: scratch.path,
    );
    final xvfbArgs = buildXvfbArguments(
      xkbDir: '$sysrootDir/usr/share/X11/xkb',
    );
    final xvfbEnv = buildXvfbEnvironment(
      sysrootDir: sysrootDir,
      scratchDir: scratch.path,
    );

    final displayNumber = await _bootXvfb(patchedXvfb, xvfbArgs, xvfbEnv);
    _displayNumber = displayNumber;

    final harnessUrl = 'ws://127.0.0.1:$harnessPort$integrationWebSocketPath';
    final declaredEnv = decodeDeclaredEnv(
      Platform.environment['FLUTTER_INTEGRATION_TEST_DECLARED_ENV'],
    );
    final tz = Platform.environment['TZ'];
    final appEnv = buildLinuxAppEnvironment(
      bundleDir: bundleDir,
      sysrootDir: sysrootDir,
      scratchDir: scratch.path,
      display: ':$displayNumber',
      harnessUrl: harnessUrl,
      fontconfigFile: effectiveFontconfig,
      env: declaredEnv,
      tz: tz,
    );

    return Process.start(
      appBinary,
      const <String>[],
      workingDirectory: bundleDir,
      environment: appEnv,
      includeParentEnvironment: false,
    );
  }

  @override
  Future<void> handleHttpRequest(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  @override
  Future<void> dispose() async {
    final xvfb = _xvfbProcess;
    _xvfbProcess = null;
    if (xvfb != null) {
      xvfb.kill(ProcessSignal.sigkill);
      await teardownQuietly(
        () => xvfb.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () => 0,
        ),
      );
    }

    final display = _displayNumber;
    _displayNumber = null;
    if (display != null) {
      cleanupQuietly(() {
        final lockFile = File('/tmp/.X$display-lock');
        if (lockFile.existsSync()) lockFile.deleteSync();
      });
      cleanupQuietly(() {
        final sockFile = File('/tmp/.X11-unix/X$display');
        if (sockFile.existsSync()) sockFile.deleteSync();
      });
    }

    final dir = _scratchDir;
    _scratchDir = null;
    if (dir != null && dir.existsSync()) {
      cleanupQuietly(() => dir.deleteSync(recursive: true));
    }
  }
}

/// Verifies that [kvmPath] (normally `/dev/kvm`) exists and is both readable
/// and writable by the current process.
///
/// Throws a [StateError] with an actionable message when `/dev/kvm` is missing
/// or inaccessible so the test fails immediately rather than hanging or
/// silently skipping.
void verifyKvmAvailable(String kvmPath) {
  RandomAccessFile? reader;
  RandomAccessFile? writer;
  try {
    reader = File(kvmPath).openSync(mode: FileMode.read);
    writer = File(kvmPath).openSync(mode: FileMode.writeOnlyAppend);
  } on FileSystemException catch (e) {
    final osCode = e.osError?.errorCode;
    if (osCode == 2) {
      throw StateError(
        'KVM device not found at "$kvmPath". Android integration tests '
        'require hardware virtualization (/dev/kvm). Enable KVM on the host '
        '(e.g. `KERNEL=="kvm", GROUP="kvm", MODE="0666", '
        'OPTIONS+="static_node=kvm"` in `/etc/udev/rules.d/99-kvm4all.rules`).',
      );
    }
    throw StateError(
      'KVM device "$kvmPath" is not readable and writable '
      '(${e.osError?.message ?? e.message}). Ensure the current user has '
      'read/write permission to "$kvmPath" (e.g. `MODE="0666"` in '
      '`/etc/udev/rules.d/99-kvm4all.rules` or membership in the `kvm` group).',
    );
  } finally {
    cleanupQuietly(() => reader?.closeSync());
    cleanupQuietly(() => writer?.closeSync());
  }
}

/// Builds the hermetic environment for the pinned Android `emulator` and `adb`
/// binaries.
///
/// Restricts `PATH` exclusively to the pinned `platform-tools` and `emulator`
/// directories and `LD_LIBRARY_PATH` to the pinned emulator and Debian sysroot
/// library directories so no host SDK, emulator, adb, or non-glibc shared
/// library is ever loaded.
Map<String, String> buildAndroidRuntimeEnvironment({
  required String sdkRoot,
  required String sysrootDir,
  required String scratchDir,
  required String avdHomeDir,
  required int adbServerPort,
  Map<String, String>? env,
  Map<String, String>? environment,
  Map<String, String>? declaredEnv,
  Map<String, String>? userEnv,
  Map<String, String>? extraEnv,
  Map<String, String>? extraEnvironment,
  Map<String, String>? forwardedEnv,
  Map<String, String>? userEnvironment,
  String? tz,
  String? timeZone,
  String? timezone,
  String? timeZoneName,
  String? timeZoneId,
  String? tzName,
}) {
  final libDirs = <String>[
    '$sdkRoot/emulator/lib64',
    '$sdkRoot/emulator/lib64/gles_swiftshader',
    '$sysrootDir/usr/lib/x86_64-linux-gnu',
    '$sysrootDir/lib/x86_64-linux-gnu',
  ];

  final resolvedEnv =
      env ??
      environment ??
      declaredEnv ??
      userEnv ??
      extraEnv ??
      extraEnvironment ??
      forwardedEnv ??
      userEnvironment;
  final resolvedTz =
      tz ?? timeZone ?? timezone ?? timeZoneName ?? timeZoneId ?? tzName;
  final mergedDeclared = resolvedEnv ?? const <String, String>{};
  final tzValue = mergedDeclared['TZ'] ?? resolvedTz ?? 'UTC';

  final result = <String, String>{
    'PATH': '$sdkRoot/platform-tools:$sdkRoot/emulator',
    'LD_LIBRARY_PATH': libDirs.join(':'),
    'HOME': scratchDir,
    'TMPDIR': scratchDir,
    'USER': 'android',
    'LOGNAME': 'android',
    'ANDROID_SDK_ROOT': sdkRoot,
    'ANDROID_HOME': sdkRoot,
    'ANDROID_AVD_HOME': avdHomeDir,
    'ANDROID_EMULATOR_HOME': '$scratchDir/.android',
    'ANDROID_USER_HOME': '$scratchDir/.android',
    'ANDROID_ADB_SERVER_PORT': '$adbServerPort',
    'ADB_VENDOR_KEYS': '$scratchDir/.android',
    'XDG_CONFIG_HOME': '$scratchDir/.config',
    'XDG_CACHE_HOME': '$scratchDir/.cache',
    'XDG_RUNTIME_DIR': '$scratchDir/xdg-runtime',
    'TZ': tzValue,
  };
  result.addAll(mergedDeclared);
  result.putIfAbsent('TZ', () => resolvedTz ?? 'UTC');
  return result;
}

/// Generates the top-level `<avdName>.ini` file pointing the emulator at
/// [avdDir].
String buildAndroidAvdIniContent({
  required String avdDir,
  String avdName = 'test',
  int apiLevel = 35,
}) {
  return 'avd.ini.encoding=UTF-8\n'
      'path=$avdDir\n'
      'path.rel=avd/$avdName.avd\n'
      'target=android-$apiLevel\n';
}

/// Generates the `config.ini` for a fresh, headless `aosp_atd` `x86_64` AVD.
String buildAndroidAvdConfigContent({
  String avdName = 'test',
  int apiLevel = 35,
}) {
  return 'AvdId=$avdName\n'
      'PlayStore.enabled=false\n'
      'abi.type=x86_64\n'
      'avd.ini.displayname=$avdName\n'
      'avd.ini.encoding=UTF-8\n'
      'disk.dataPartition.size=4096M\n'
      'fastboot.chosenSnapshotFile=\n'
      'fastboot.forceChosenSnapshotBoot=no\n'
      'fastboot.forceColdBoot=yes\n'
      'fastboot.forceFastBoot=no\n'
      'hw.accelerometer=yes\n'
      'hw.arc=false\n'
      'hw.audioInput=no\n'
      'hw.audioOutput=no\n'
      'hw.battery=yes\n'
      'hw.camera.back=none\n'
      'hw.camera.front=none\n'
      'hw.cpu.arch=x86_64\n'
      'hw.cpu.ncore=4\n'
      'hw.dPad=no\n'
      'hw.gps=no\n'
      'hw.gpu.enabled=yes\n'
      'hw.gpu.mode=swiftshader_indirect\n'
      'hw.initialOrientation=Portrait\n'
      'hw.keyboard=yes\n'
      'hw.lcd.density=160\n'
      'hw.lcd.height=800\n'
      'hw.lcd.width=480\n'
      'hw.mainKeys=no\n'
      'hw.ramSize=2048\n'
      'hw.sdCard=no\n'
      'hw.sensors.orientation=yes\n'
      'hw.sensors.proximity=yes\n'
      'hw.trackBall=no\n'
      'image.sysdir.1=system-images/android-$apiLevel/aosp_atd/x86_64/\n'
      'runtime.network.latency=none\n'
      'runtime.network.speed=full\n'
      'showDeviceFrame=no\n'
      'tag.display=AOSP ATD\n'
      'tag.id=aosp_atd\n'
      'vm.heapSize=256\n';
}

/// Builds the command-line flags passed to the hermetic Android `emulator`.
List<String> buildAndroidEmulatorArguments({
  required String avdName,
  required int consolePort,
  required int adbPort,
}) {
  return <String>[
    '-avd',
    avdName,
    '-no-window',
    '-no-audio',
    '-no-boot-anim',
    '-no-snapshot',
    '-no-snapshot-save',
    '-no-snapshot-load',
    '-wipe-data',
    '-gpu',
    'swiftshader_indirect',
    '-accel',
    'on',
    '-ports',
    '$consolePort,$adbPort',
    '-no-metrics',
  ];
}

/// Allocates a free `(consolePort, adbPort)` pair in `adb`'s local transport
/// discovery range (`5554..5680`) and an ephemeral `adbServerPort`.
Future<({int adbServerPort, int consolePort, int adbPort})>
allocateAndroidEmulatorPorts() async {
  final adbServerSocket = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final adbServerPort = adbServerSocket.port;
  await adbServerSocket.close();

  const minConsolePort = 5554;
  const maxPairs = 64;
  final startOffset = pid % maxPairs;
  for (var i = 0; i < maxPairs; i++) {
    final idx = (startOffset + i) % maxPairs;
    final candidateConsole = minConsolePort + idx * 2;
    final candidateAdb = candidateConsole + 1;
    if (candidateConsole == adbServerPort || candidateAdb == adbServerPort) {
      continue;
    }
    ServerSocket? s1;
    ServerSocket? s2;
    try {
      s1 = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        candidateConsole,
      );
      s2 = await ServerSocket.bind(InternetAddress.loopbackIPv4, candidateAdb);
      await s1.close();
      await s2.close();
      return (
        adbServerPort: adbServerPort,
        consolePort: candidateConsole,
        adbPort: candidateAdb,
      );
    } on SocketException {
      // A half-bound probe pair must not leak sockets into the next attempt.
      await teardownQuietly(() async => await s1?.close());
      await teardownQuietly(() async => await s2?.close());
    }
  }
  throw StateError(
    'Could not find a free (consolePort, adbPort) pair in 5554..5681 for the '
    'Android emulator.',
  );
}

/// Boots a hermetic, pinned headless Android `x86_64` emulator accelerated with
/// KVM, installs the built integration test APK, forwards the harness WebSocket
/// port via `adb reverse`, and launches `FlutterActivity`.
class AndroidPlatformLauncher implements PlatformLauncher {
  AndroidPlatformLauncher({
    required this.apkPath,
    required this.packageName,
    required this.emulatorBinary,
    required this.adbBinary,
    required this.baseTempDir,
    this.kvmPath = '/dev/kvm',
    this.bootTimeout = const Duration(seconds: 120),
  });

  final String apkPath;
  final String packageName;
  final String emulatorBinary;
  final String adbBinary;
  final String baseTempDir;
  final String kvmPath;
  final Duration bootTimeout;

  Directory? _scratchDir;
  Process? _emulatorProcess;
  Process? _logcatProcess;
  Timer? _watchdogTimer;
  Map<String, String>? _runtimeEnv;
  bool _disposing = false;
  int? _emulatorExitCode;

  @override
  String get platformName => 'android';

  @override
  String get suiteRuntime => 'vm';

  @override
  String get suiteCompiler => 'kernel';

  /// Creates the scratch tree and a fresh headless AVD for one run.
  ({Directory scratch, Directory avdHomeDir}) _prepareAndroidScratch() {
    final scratch = Directory(
      '$baseTempDir/android_integration_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    _scratchDir = scratch;

    final avdHomeDir = Directory('${scratch.path}/.android/avd')
      ..createSync(recursive: true);
    final avdDir = Directory('${avdHomeDir.path}/test.avd')
      ..createSync(recursive: true);
    Directory('${scratch.path}/.config').createSync(recursive: true);
    Directory('${scratch.path}/.cache').createSync(recursive: true);
    Directory('${scratch.path}/xdg-runtime').createSync(recursive: true);

    File('${avdHomeDir.path}/test.ini').writeAsStringSync(
      buildAndroidAvdIniContent(avdDir: avdDir.path),
    );
    File('${avdDir.path}/config.ini').writeAsStringSync(
      buildAndroidAvdConfigContent(),
    );
    return (scratch: scratch, avdHomeDir: avdHomeDir);
  }

  /// Starts the hermetic `adb` server on the allocated port.
  Future<void> _startAdbServer(
    Map<String, String> runtimeEnv,
    int adbServerPort,
  ) async {
    final startServerResult = await Process.run(
      adbBinary,
      const <String>['start-server'],
      environment: runtimeEnv,
      includeParentEnvironment: false,
    );
    if (startServerResult.exitCode != 0) {
      throw StateError(
        'Failed to start hermetic adb server on port $adbServerPort:\n'
        '${startServerResult.stdout}\n${startServerResult.stderr}',
      );
    }
  }

  /// Launches the emulator, records its logs, and watches for a premature
  /// exit so the boot wait can report it instead of timing out.
  Future<Process> _launchEmulator(
    List<String> emulatorArgs,
    String scratchPath,
    Map<String, String> runtimeEnv,
    List<String> emulatorLogs,
  ) async {
    final emulator = await Process.start(
      emulatorBinary,
      emulatorArgs,
      workingDirectory: scratchPath,
      environment: runtimeEnv,
      includeParentEnvironment: false,
    );
    _emulatorProcess = emulator;

    void recordEmulatorLine(String prefix, String line) {
      if (emulatorLogs.length < 150) {
        emulatorLogs.add('[$prefix] $line');
      }
    }

    emulator.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => recordEmulatorLine('emu-out', l));
    emulator.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => recordEmulatorLine('emu-err', l));

    unawaited(
      emulator.exitCode.then((code) {
        _emulatorExitCode = code;
        if (!_disposing) {
          _logcatProcess?.kill(ProcessSignal.sigkill);
        }
      }),
    );
    return emulator;
  }

  /// Waits for `sys.boot_completed`, failing fast when the emulator already
  /// exited instead of sitting out the whole boot timeout.
  Future<void> _waitForEmulatorBoot(
    String serial,
    List<String> emulatorLogs,
    DateTime bootDeadline,
  ) async {
    var booted = false;
    while (DateTime.now().isBefore(bootDeadline)) {
      if (_emulatorExitCode != null) {
        throw StateError(
          'Android emulator exited prematurely with code $_emulatorExitCode '
          'before completing boot:\n${emulatorLogs.join("\n")}',
        );
      }
      final propResult = await _runAdb(
        serial,
        const <String>['shell', 'getprop', 'sys.boot_completed'],
      );
      if (propResult.exitCode == 0 && '${propResult.stdout}'.trim() == '1') {
        booted = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!booted) {
      throw TimeoutException(
        'Timed out after ${bootTimeout.inSeconds}s waiting for Android '
        'emulator ($serial) to finish booting:\n${emulatorLogs.join("\n")}',
      );
    }
  }

  /// Forwards the harness port into the emulator over `adb reverse`, so the
  /// app can dial `ws://127.0.0.1:<harnessPort>/…` (and the fallback 38427).
  Future<void> _forwardHarnessPorts(String serial, int harnessPort) async {
    for (final remotePort in <int>{harnessPort, 38427}) {
      final rev = await _runAdb(
        serial,
        <String>['reverse', 'tcp:$remotePort', 'tcp:$harnessPort'],
      );
      if (rev.exitCode != 0) {
        throw StateError(
          'adb reverse tcp:$remotePort tcp:$harnessPort failed on $serial:\n'
          '${rev.stdout}\n${rev.stderr}',
        );
      }
    }
  }

  /// Installs the built integration test APK on the booted emulator.
  Future<void> _installApk(String serial) async {
    final installResult = await _runAdb(
      serial,
      <String>['install', '-r', apkPath],
      timeout: const Duration(seconds: 90),
    );
    if (installResult.exitCode != 0) {
      throw StateError(
        'adb install -r "$apkPath" failed on $serial '
        '(exit ${installResult.exitCode}):\n'
        '${installResult.stdout}\n${installResult.stderr}',
      );
    }
  }

  /// Aligns the device timezone with the test's TZ so the app observes it.
  Future<void> _configureDeviceTimezone(String serial) async {
    final deviceTz = Platform.environment['TZ'] ?? 'UTC';
    await _runAdb(serial, <String>[
      'shell',
      'settings',
      'put',
      'global',
      'time_zone',
      deviceTz,
    ]);
    await _runAdb(serial, <String>[
      'shell',
      'setprop',
      'persist.sys.timezone',
      deviceTz,
    ]);
  }

  /// Launches the app's `FlutterActivity` with the harness URL as its
  /// entrypoint args. Returns the harness URL the app dials.
  Future<String> _startFlutterActivity(String serial, int harnessPort) async {
    final harnessUrl = 'ws://127.0.0.1:$harnessPort$integrationWebSocketPath';
    final startResult = await _runAdb(
      serial,
      <String>[
        'shell',
        'am',
        'start',
        '-W',
        '-n',
        '$packageName/io.flutter.embedding.android.FlutterActivity',
        '--esal',
        'dart_entrypoint_args',
        harnessUrl,
      ],
      timeout: const Duration(seconds: 45),
    );
    final startOutput = '${startResult.stdout}\n${startResult.stderr}';
    if (startResult.exitCode != 0 ||
        startOutput.contains('Error:') ||
        startOutput.contains('Exception')) {
      throw StateError(
        'Failed to start FlutterActivity for $packageName on $serial:\n'
        '$startOutput',
      );
    }
    return harnessUrl;
  }

  /// Tails the app's logcat and arms the crash watchdog. The returned
  /// process stands in for the target: when it dies, the run ends.
  Future<Process> _startLogcat(
    String serial,
    Map<String, String> runtimeEnv,
  ) async {
    final logcat = await Process.start(
      adbBinary,
      <String>[
        '-s',
        serial,
        'logcat',
        '-v',
        'time',
        'flutter:V',
        'DartVM:V',
        'AndroidRuntime:E',
        'ActivityManager:W',
        'DEBUG:V',
        'libc:F',
        '*:S',
      ],
      environment: runtimeEnv,
      includeParentEnvironment: false,
    );
    _logcatProcess = logcat;

    _startWatchdog(serial);
    return logcat;
  }

  @override
  Future<Process> startTarget(int harnessPort) async {
    verifyKvmAvailable(kvmPath);

    if (!File(emulatorBinary).existsSync()) {
      throw StateError(
        'Pinned Android emulator binary not found at "$emulatorBinary".',
      );
    }
    if (!File(adbBinary).existsSync()) {
      throw StateError('Pinned Android adb binary not found at "$adbBinary".');
    }
    if (!File(apkPath).existsSync()) {
      throw StateError('Built Android APK not found at "$apkPath".');
    }

    // emulatorBinary is at <repoRoot>/sdk/emulator/emulator.
    final sdkRoot = File(emulatorBinary).parent.parent.path;
    final repoRoot = Directory(sdkRoot).parent.path;
    final sysrootDir = '$repoRoot/sysroot';

    final prepared = _prepareAndroidScratch();
    final scratch = prepared.scratch;

    final ports = await allocateAndroidEmulatorPorts();
    final declaredEnv = decodeDeclaredEnv(
      Platform.environment['FLUTTER_INTEGRATION_TEST_DECLARED_ENV'],
    );
    final tz = Platform.environment['TZ'];
    final runtimeEnv = buildAndroidRuntimeEnvironment(
      sdkRoot: sdkRoot,
      sysrootDir: sysrootDir,
      scratchDir: scratch.path,
      avdHomeDir: prepared.avdHomeDir.path,
      adbServerPort: ports.adbServerPort,
      env: declaredEnv,
      tz: tz,
    );
    _runtimeEnv = runtimeEnv;

    await _startAdbServer(runtimeEnv, ports.adbServerPort);

    final emulatorArgs = buildAndroidEmulatorArguments(
      avdName: 'test',
      consolePort: ports.consolePort,
      adbPort: ports.adbPort,
    );
    final emulatorLogs = <String>[];
    await _launchEmulator(
      emulatorArgs,
      scratch.path,
      runtimeEnv,
      emulatorLogs,
    );

    final serial = 'emulator-${ports.consolePort}';
    final bootDeadline = DateTime.now().add(bootTimeout);
    await _waitForEmulatorBoot(serial, emulatorLogs, bootDeadline);

    await _forwardHarnessPorts(serial, harnessPort);
    await _installApk(serial);
    await _configureDeviceTimezone(serial);

    // Clear logcat buffers prior to launching the activity.
    await _runAdb(serial, const <String>['logcat', '-b', 'all', '-c']);

    await _startFlutterActivity(serial, harnessPort);
    return _startLogcat(serial, runtimeEnv);
  }

  void _startWatchdog(String serial) {
    var checkInFlight = false;
    var sawRunningPid = false;
    final launchedAt = DateTime.now();

    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_disposing || checkInFlight) return;
      checkInFlight = true;
      try {
        final crashResult = await _runAdb(
          serial,
          const <String>['logcat', '-b', 'crash', '-d'],
          timeout: const Duration(seconds: 5),
        );
        final crashOut = '${crashResult.stdout}'.trim();
        if (crashOut.isNotEmpty &&
            (crashOut.contains(packageName) ||
                crashOut.contains('FATAL EXCEPTION') ||
                crashOut.contains('Build fingerprint:'))) {
          stderr.writeln(
            'flutter_integration_test: Android crash detected for '
            '$packageName:\n$crashOut',
          );
          _logcatProcess?.kill(ProcessSignal.sigkill);
          return;
        }

        final pidResult = await _runAdb(
          serial,
          <String>['shell', 'pidof', packageName],
          timeout: const Duration(seconds: 5),
        );
        final pidOut = '${pidResult.stdout}'.trim();
        if (pidResult.exitCode == 0 && pidOut.isNotEmpty) {
          sawRunningPid = true;
        } else if (sawRunningPid ||
            DateTime.now().difference(launchedAt) >
                const Duration(seconds: 10)) {
          if (!_disposing) {
            _logcatProcess?.kill(ProcessSignal.sigkill);
          }
        }
      } on IOException {
        // Ignore transient adb errors during teardown.
      } on StateError {
        // Ignore races with dispose() clearing the runtime environment.
      } finally {
        checkInFlight = false;
      }
    });
  }

  Future<ProcessResult> _runAdb(
    String serial,
    List<String> args, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final env = _runtimeEnv;
    if (env == null) {
      throw StateError('Android runtime environment not initialized.');
    }
    final proc = await Process.start(
      adbBinary,
      <String>['-s', serial, ...args],
      environment: env,
      includeParentEnvironment: false,
    );
    final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
    final stderrFuture = proc.stderr.transform(utf8.decoder).join();
    final exitCode = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    return ProcessResult(
      proc.pid,
      exitCode,
      await stdoutFuture,
      await stderrFuture,
    );
  }

  @override
  Future<void> handleHttpRequest(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  @override
  Future<void> dispose() async {
    _disposing = true;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    final logcat = _logcatProcess;
    _logcatProcess = null;
    if (logcat != null) {
      logcat.kill(ProcessSignal.sigkill);
      await teardownQuietly(
        () => logcat.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () => 0,
        ),
      );
    }

    final emulator = _emulatorProcess;
    _emulatorProcess = null;
    if (emulator != null) {
      emulator.kill(ProcessSignal.sigkill);
      await teardownQuietly(
        () => emulator.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => 0,
        ),
      );
    }

    final env = _runtimeEnv;
    _runtimeEnv = null;
    if (env != null && File(adbBinary).existsSync()) {
      // Best-effort: a stuck daemon only costs the next run seconds of
      // `adb start-server`; a teardown failure here must never mask the
      // integration result the `finally` block is unwinding.
      await teardownQuietly(() async {
        final killProc = await Process.start(
          adbBinary,
          const <String>['kill-server'],
          environment: env,
          includeParentEnvironment: false,
        );
        await killProc.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            killProc.kill(ProcessSignal.sigkill);
            return 0;
          },
        );
      });
    }

    final dir = _scratchDir;
    _scratchDir = null;
    if (dir != null && dir.existsSync()) {
      cleanupQuietly(() => dir.deleteSync(recursive: true));
    }
  }
}

/// Serves a single static file request from [webDir].
///
/// Injects a local `Roboto` fallback entry into `assets/FontManifest.json` when
/// [robotoFontFile] is provided and the app's manifest does not already define
/// `Roboto`, so CanvasKit and Skwasm never attempt to fetch Roboto from
/// `fonts.gstatic.com` inside the network-isolated Bazel test sandbox.
Future<void> serveWebBundleRequest(
  HttpRequest request, {
  required String webDir,
  String? robotoFontFile,
}) async {
  final response = request.response;
  try {
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    final relPath = _bundleRelativePath(request);
    if (relPath == null) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }

    if (await _serveFontManifest(request, webDir, robotoFontFile)) return;

    var file = File('$webDir/$relPath');
    if (!file.existsSync() &&
        relPath == 'assets/fonts/Roboto-Regular.ttf' &&
        robotoFontFile != null) {
      file = File(robotoFontFile);
    }

    if (!file.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    await _serveBundleFile(request, file, relPath);
  } on FileSystemException {
    // The bundle file vanished or became unreadable mid-serve.
    await serveInternalError(response);
  } on FormatException {
    // A corrupted FontManifest.json fails the request, not the server.
    await serveInternalError(response);
  } catch (e) {
    // Containment for anything unexpected: answer 500 and keep serving so
    // one bad request cannot wedge the whole integration run.
    stderr.writeln('flutter_integration_test: web bundle serve failed: $e');
    await serveInternalError(response);
  }
}

/// Answers [response] with a 500, swallowing the races of answering a
/// response the failed write already closed: the original failure is the one
/// that matters.
///
/// Public, like [buildChromeArguments], because the test reaches it directly.
Future<void> serveInternalError(HttpResponse response) async {
  try {
    response.statusCode = HttpStatus.internalServerError;
    await response.close();
  } on StateError {
    // The failed write already answered or closed the response.
  }
}

/// Normalizes the request path to a bundle-relative path, or null when it
/// tries to escape the bundle.
String? _bundleRelativePath(HttpRequest request) {
  var relPath = Uri.decodeComponent(request.uri.path);
  if (relPath == '/' || relPath.isEmpty) {
    return 'index.html';
  }
  if (relPath.startsWith('/')) {
    relPath = relPath.substring(1);
  }
  final segments = relPath.split('/');
  if (segments.contains('..') || segments.contains('.')) {
    return null;
  }
  return relPath;
}

/// Serves `assets/FontManifest.json` with the local Roboto fallback injected,
/// when the app needs one. Returns whether the request was answered.
Future<bool> _serveFontManifest(
  HttpRequest request,
  String webDir,
  String? robotoFontFile,
) async {
  final relPath = _bundleRelativePath(request);
  final response = request.response;
  if (relPath != 'assets/FontManifest.json' ||
      robotoFontFile == null ||
      !File(robotoFontFile).existsSync()) {
    return false;
  }
  final manifestFile = File('$webDir/assets/FontManifest.json');
  List<dynamic> families = <dynamic>[];
  if (manifestFile.existsSync()) {
    final decoded = json.decode(manifestFile.readAsStringSync());
    if (decoded is List) {
      families = List<dynamic>.from(decoded);
    }
  }
  final hasRoboto = families.any(
    (entry) => entry is Map && entry['family'] == 'Roboto',
  );
  if (!hasRoboto) {
    families.add(<String, Object>{
      'family': 'Roboto',
      'fonts': <Map<String, String>>[
        <String, String>{'asset': 'fonts/Roboto-Regular.ttf'},
      ],
    });
  }
  final body = utf8.encode(json.encode(families));
  response.statusCode = HttpStatus.ok;
  response.headers.set(
    HttpHeaders.contentTypeHeader,
    'application/json; charset=utf-8',
  );
  response.headers.contentLength = body.length;
  if (request.method != 'HEAD') {
    response.add(body);
  }
  await response.close();
  return true;
}

/// Serves one bundle file with its MIME type and no caching.
Future<void> _serveBundleFile(
  HttpRequest request,
  File file,
  String relPath,
) async {
  final response = request.response;
  final bytes = file.readAsBytesSync();
  response.statusCode = HttpStatus.ok;
  response.headers.set(
    HttpHeaders.contentTypeHeader,
    contentTypeForPath(relPath),
  );
  response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
  response.headers.contentLength = bytes.length;
  if (request.method != 'HEAD') {
    response.add(bytes);
  }
  await response.close();
}

/// MIME type for a served bundle asset path.
String contentTypeForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.html')) return 'text/html; charset=utf-8';
  if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
    return 'application/javascript; charset=utf-8';
  }
  if (lower.endsWith('.wasm')) return 'application/wasm';
  if (lower.endsWith('.json')) return 'application/json; charset=utf-8';
  if (lower.endsWith('.css')) return 'text/css; charset=utf-8';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  if (lower.endsWith('.ttf')) return 'font/ttf';
  if (lower.endsWith('.otf')) return 'font/otf';
  if (lower.endsWith('.woff2')) return 'font/woff2';
  return 'application/octet-stream';
}

/// Runs the integration test suite end-to-end using [launcher].
Future<int> runIntegrationSuite({
  required PlatformLauncher launcher,
  required String testPath,
  required TestSelection selection,
  Set<String> libraryTags = const {},
  required String? xmlOutput,
  required String? bazelTestTimeout,
  Duration dialBackBound = const Duration(seconds: 45),
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final harness = _IntegrationHarness(
    server: server,
    launcher: launcher,
    dialBackBound: dialBackBound,
  );
  try {
    return await harness.run(
      testPath: testPath,
      selection: selection,
      libraryTags: libraryTags,
      xmlOutput: xmlOutput,
      bazelTestTimeout: bazelTestTimeout,
    );
  } finally {
    await harness.dispose();
  }
}

class _IntegrationHarness {
  _IntegrationHarness({
    required HttpServer server,
    required PlatformLauncher launcher,
    required Duration dialBackBound,
  }) : _server = server,
       _launcher = launcher,
       _dialBackBound = dialBackBound;

  final HttpServer _server;
  final PlatformLauncher _launcher;
  final Duration _dialBackBound;

  Process? _process;
  WebSocket? _ws;
  bool _socketClosed = false;
  StreamSubscription<HttpRequest>? _httpSub;
  final Completer<WebSocket> _wsConnected = Completer<WebSocket>();

  final Map<int, void Function(Object?)> _inbound = {};
  final Map<int, Completer<void>> _pendingTests = {};
  int _nextId = 1;

  ({int outputId, int inputId}) _allocChannel() {
    final out = _nextId;
    final inp = _nextId + 1;
    _nextId += 2;
    return (outputId: out, inputId: inp);
  }

  void _send(int outputId, Object? data) {
    if (_socketClosed || _ws == null) return;
    _ws!.add(json.encode([outputId, data]));
  }

  Future<void> dispose() async {
    await teardownQuietly(() async => await _ws?.close());
    await teardownQuietly(() async => await _httpSub?.cancel());
    _process?.kill(ProcessSignal.sigkill);
    await teardownQuietly(() => _server.close(force: true));
    await _launcher.dispose();
  }

  /// Serves the harness HTTP endpoint: upgrades the bootstrap's dial-back
  /// to a WebSocket, and defers every other request to the launcher.
  void _serveHttp() {
    _httpSub = _server.listen((HttpRequest request) async {
      if (request.uri.path == integrationWebSocketPath &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        await _upgradeDialBack(request);
        return;
      }
      await _launcher.handleHttpRequest(request);
    });
  }

  /// Adopts the bootstrap's dial-back socket, keeping the first and
  /// refusing any later one.
  Future<void> _upgradeDialBack(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      if (!_wsConnected.isCompleted) {
        _wsConnected.complete(socket);
      } else {
        await socket.close();
      }
    } catch (e) {
      if (!_wsConnected.isCompleted) {
        _wsConnected.completeError(e);
      }
    }
  }

  /// Starts the target and tails its output into [processLogs].
  ///
  /// Returns the run's exit code when the target never started, or null
  /// once it is running.
  Future<int?> _launchTarget(List<String> processLogs) async {
    void recordProcessLine(String streamName, String line) {
      if (processLogs.length < 200) {
        processLogs.add('[$streamName] $line');
      }
    }

    try {
      _process = await _launcher.startTarget(_server.port);
    } catch (e) {
      stderr.writeln(
        'flutter_integration_test: failed to start ${_launcher.platformName} '
        'target: $e',
      );
      return 1;
    }

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => recordProcessLine('stdout', line));
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => recordProcessLine('stderr', line));
    return null;
  }

  /// Waits for the target's dial-back and adopts the suite socket.
  ///
  /// Returns the run's exit code when the suite will not run because the
  /// target exited or stayed silent, or null once connected.
  Future<int?> _settleTargetDialBack(List<String> processLogs) async {
    switch (await _awaitDialBack()) {
      case _TargetExited(:final exitCode):
        stderr.writeln(
          'flutter_integration_test: ${_launcher.platformName} target exited '
          'with code $exitCode before connecting to the test harness.',
        );
        for (final line in processLogs) {
          stderr.writeln('  $line');
        }
        return exitCode == 0 ? 1 : exitCode;
      case _DialBackTimedOut():
        stderr.writeln(
          'flutter_integration_test: ${_launcher.platformName} target did not '
          'connect to the harness within ${_dialBackBound.inSeconds}s; '
          'killing it.',
        );
        for (final line in processLogs) {
          stderr.writeln('  $line');
        }
        return 1;
      case _BootstrapConnected(:final socket):
        _ws = socket;
        return null;
    }
  }

  /// Handles one message on the default channel: the suite tree plus
  /// print/error events. Resolves [suiteReady] once the in-app suite
  /// finishes registering tests (or surfaces a load failure).
  static void _onSuiteChannel(
    Object? data,
    _Results results,
    Completer<Map<String, dynamic>?> suiteReady,
  ) {
    final msg = (data as Map).cast<String, dynamic>();
    switch (msg['type']) {
      case 'success':
        if (!suiteReady.isCompleted) {
          suiteReady.complete((msg['root'] as Map).cast<String, dynamic>());
        }
      case 'loadException':
        results.recordError('load failure — ${msg['message']}');
        if (!suiteReady.isCompleted) suiteReady.complete(null);
      case 'error':
        final err = (msg['error'] as Map).cast<String, dynamic>();
        results.recordError(
          'uncaught error — ${err['message']}\n${err['stackChain']}',
        );
        if (!suiteReady.isCompleted) suiteReady.complete(null);
      case 'uncaughtError':
        results.recordError(
          'uncaught error — ${msg['message']}\n${msg['stack'] ?? ''}',
        );
        if (!suiteReady.isCompleted) suiteReady.complete(null);
      case 'print':
        stdout.writeln(msg['line']);
    }
  }

  /// Watches the suite socket: a close mid-suite surfaces as a failure on
  /// every outstanding test so nothing hangs waiting on a `complete` event
  /// that will never arrive.
  void _watchTargetSocket(Completer<Map<String, dynamic>?> suiteReady) {
    _ws!.listen(
      _onSocketMessage,
      onDone: () {
        _socketClosed = true;
        if (!suiteReady.isCompleted) suiteReady.complete(null);
        for (final c in _pendingTests.values) {
          if (!c.isCompleted) c.complete();
        }
        _pendingTests.clear();
      },
    );
  }

  /// Runs the registered suite under [selection], bounded by [ceiling].
  Future<void> _driveSelectedTests(
    Map<String, dynamic> root,
    TestSelection selection,
    _Results results,
    Duration ceiling,
  ) async {
    Map<String, dynamic>? selected;
    try {
      selected = selection.select(root);
    } on FormatException catch (e) {
      // An `include_tags` attribute selection that matches no test: a tag
      // name nobody carries is a typo, and passing an empty suite would
      // hide it.
      results.recordError(e.message);
    }
    if (selected != null) {
      await _runGroup(selected, results, ceiling);
    } else if (!results.hasFailure && selection.narrows) {
      stdout.writeln(
        'flutter_integration_test: no test case in this suite matches '
        'this run\'s --test_filter, tags or shard.',
      );
    }
  }

  /// Tells the suite to close, closes the socket, and waits out the target.
  Future<void> _shutdownTarget() async {
    _send(0, {'type': 'close'});
    await teardownQuietly(() async => await _ws?.close());

    _process?.kill(ProcessSignal.sigkill);
    await _process!.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );
  }

  Future<int> run({
    required String testPath,
    required TestSelection selection,
    Set<String> libraryTags = const {},
    required String? xmlOutput,
    required String? bazelTestTimeout,
  }) async {
    _serveHttp();

    final processLogs = <String>[];
    final launchExit = await _launchTarget(processLogs);
    if (launchExit != null) return launchExit;

    final dialBackExit = await _settleTargetDialBack(processLogs);
    if (dialBackExit != null) return dialBackExit;

    final results = _Results();
    final suiteReady = Completer<Map<String, dynamic>?>();

    _inbound[0] = (data) => _onSuiteChannel(data, results, suiteReady);
    _watchTargetSocket(suiteReady);

    _send(0, _initialMessage(testPath, bazelTestTimeout, libraryTags));

    final ceiling = testCeiling(bazelTestTimeout);
    final root = await suiteReady.future.timeout(
      ceiling,
      onTimeout: () => null,
    );

    if (root != null) {
      await _driveSelectedTests(root, selection, results, ceiling);
    } else {
      results.recordError('suite did not load');
      for (final line in processLogs) {
        stderr.writeln('  $line');
      }
    }

    if (xmlOutput != null) {
      await File(
        xmlOutput,
      ).writeAsString(junitXml(results.cases, suiteName: testPath));
    }

    await _shutdownTarget();

    stdout.writeln(results.summary());
    return results.hasFailure ? 1 : 0;
  }

  Future<_DialBack> _awaitDialBack() async {
    final outcome = await Future.any<_DialBack?>([
      _wsConnected.future.then<_DialBack?>(_BootstrapConnected.new),
      _process!.exitCode.then<_DialBack?>(_TargetExited.new),
    ]).timeout(_dialBackBound, onTimeout: () => null);
    return outcome ?? const _DialBackTimedOut();
  }

  void _onSocketMessage(dynamic raw) {
    final decoded = json.decode(raw as String);
    if (decoded is Map && decoded['type'] == 'uncaughtError') {
      final handler = _inbound[0];
      if (handler != null) {
        handler(decoded);
      }
      for (final c in _pendingTests.values) {
        if (!c.isCompleted) c.complete();
      }
      return;
    }
    final list = decoded as List;
    final id = (list[0] as num).toInt();
    if (list.length == 1) {
      _inbound.remove(id);
      return;
    }
    final handler = _inbound[id];
    if (handler != null) {
      handler(list[1]);
    }
  }

  Future<void> _runGroup(
    Map<String, dynamic> group,
    _Results results,
    Duration ceiling,
  ) async {
    final setUpAll = group['setUpAll'] as Map?;
    if (setUpAll != null) {
      await _runTest(
        setUpAll.cast<String, dynamic>(),
        results,
        ceiling,
        fixture: true,
      );
    }

    final entries = group['entries'] as List? ?? const [];
    for (final entry in entries) {
      final m = (entry as Map).cast<String, dynamic>();
      if (m['type'] == 'group') {
        await _runGroup(m, results, ceiling);
      } else {
        await _runTest(m, results, ceiling);
      }
    }

    final tearDownAll = group['tearDownAll'] as Map?;
    if (tearDownAll != null) {
      await _runTest(
        tearDownAll.cast<String, dynamic>(),
        results,
        ceiling,
        fixture: true,
      );
    }
  }

  Future<void> _runTest(
    Map<String, dynamic> test,
    _Results results,
    Duration ceiling, {
    bool fixture = false,
  }) async {
    final testChannelId = (test['channel'] as num).toInt();
    final reportName = test['name'] as String? ?? '';

    final metadata = test['metadata'] as Map?;
    final skipReason = metadata == null ? null : metadata['skipReason'];
    final skipFlag = metadata == null
        ? false
        : (metadata['skip'] as bool? ?? false);
    if (!fixture && skipFlag) {
      results.recordSkipped(reportName, skipReason as String?);
      return;
    }

    if (_socketClosed) {
      results.recordFailure(
        reportName,
        _TestFailureSummary(
          message:
              '${_launcher.platformName} target disconnected before this test ran',
          type: 'TestDeviceException',
          stackChain: '',
        ),
        Duration.zero,
        '',
      );
      return;
    }

    final ch = _allocChannel();
    final completer = Completer<void>();
    final started = Stopwatch()..start();
    final output = StringBuffer();
    _pendingTests[ch.inputId] = completer;
    _TestFailureSummary? failure;
    void noteFailure(_TestFailureSummary summary) => failure ??= summary;

    _inbound[ch.inputId] = _integrationTestMessageHandler(
      completer: completer,
      output: output,
      noteFailure: noteFailure,
    );

    _send(testChannelId + 1, {'command': 'run', 'channel': ch.outputId});

    await _awaitIntegrationTest(
      completer: completer,
      ceiling: ceiling,
      reportName: reportName,
      noteFailure: noteFailure,
    );
    _pendingTests.remove(ch.inputId);
    _inbound.remove(ch.inputId);

    if (_socketClosed && failure == null) {
      failure = _TestFailureSummary(
        message:
            '${_launcher.platformName} target disconnected mid-test '
            '(or crashed)',
        type: 'TestDeviceException',
        stackChain: '',
      );
    }

    started.stop();
    if (failure != null) {
      results.recordFailure(
        reportName,
        failure!,
        started.elapsed,
        output.toString(),
      );
    } else if (!fixture) {
      results.recordSuccess(reportName, started.elapsed, output.toString());
    }
  }

  /// Builds the inbound dispatcher for one running test: explicit error
  /// events become [noteFailure], prints go to stdout and the case log, and
  /// `complete` releases the test's completer.
  void Function(Object?) _integrationTestMessageHandler({
    required Completer<void> completer,
    required StringBuffer output,
    required void Function(_TestFailureSummary) noteFailure,
  }) {
    return (data) {
      final msg = (data as Map).cast<String, dynamic>();
      switch (msg['type']) {
        case 'state-change':
          break;
        case 'error':
          final err = (msg['error'] as Map).cast<String, dynamic>();
          noteFailure(
            _TestFailureSummary(
              message:
                  err['message'] as String? ?? err['toString'] as String? ?? '',
              type: err['type'] as String? ?? 'TestFailure',
              stackChain: err['stackChain'] as String? ?? '',
            ),
          );
        case 'message':
          final mtype = msg['message-type'] as String? ?? 'print';
          final text = msg['text'] as String? ?? '';
          final line = mtype == 'print' ? text : '[$mtype] $text';
          stdout.writeln(line);
          output.writeln(line);
        case 'complete':
          if (!completer.isCompleted) completer.complete();
      }
    };
  }

  /// Waits out one test's [ceiling], killing the target when a wedged test
  /// never yields so the remaining tests bail out fast.
  Future<void> _awaitIntegrationTest({
    required Completer<void> completer,
    required Duration ceiling,
    required String reportName,
    required void Function(_TestFailureSummary) noteFailure,
  }) async {
    await completer.future.timeout(
      ceiling,
      onTimeout: () {
        final msg =
            'test "$reportName" timed out after ${ceiling.inSeconds}s; '
            'killing ${_launcher.platformName} target.';
        stderr.writeln('flutter_integration_test: $msg');
        noteFailure(
          _TestFailureSummary(
            message: msg,
            type: 'TimeoutException',
            stackChain: '',
          ),
        );
        _socketClosed = true;
        _process?.kill(ProcessSignal.sigkill);
      },
    );
  }

  Map<String, dynamic> _initialMessage(
    String testPath,
    String? bazelTestTimeout,
    Set<String> libraryTags,
  ) {
    return {
      'type': 'initial',
      'metadata': _defaultMetadata(
        suiteTimeout(bazelTestTimeout),
        libraryTags,
      ),
      'platform': {
        'runtime': _launcher.suiteRuntime,
        'compiler': _launcher.suiteCompiler,
        'os': _launcher.suiteRuntime == 'chrome' ? 'none' : _osIdentifier(),
        'inGoogle': false,
      },
      'platformVariables': const <String>[],
      'collectTraces': true,
      'noRetry': true,
      'allowDuplicateTestNames': true,
      'foldTraceExcept': const <String>[],
      'foldTraceOnly': const <String>[],
      'path': testPath,
      'asciiGlyphs': !stdout.supportsAnsiEscapes,
      'ignoreTimeouts': false,
    };
  }

  static Map<String, Object?> _defaultMetadata(
    Object timeout,
    Set<String> libraryTags,
  ) {
    return {
      'testOn': null,
      'timeout': timeout,
      'skip': null,
      'skipReason': null,
      'verboseTrace': null,
      'chainStackTraces': null,
      'retry': null,
      'tags': libraryTags.toList(),
      'onPlatform': const <List<Object>>[],
      'forTag': const <String, Object?>{},
      'languageVersionComment': null,
    };
  }

  static String _osIdentifier() {
    if (Platform.isMacOS) return 'mac-os';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    return 'none';
  }
}

sealed class _DialBack {
  const _DialBack();
}

final class _BootstrapConnected extends _DialBack {
  const _BootstrapConnected(this.socket);
  final WebSocket socket;
}

final class _TargetExited extends _DialBack {
  const _TargetExited(this.exitCode);
  final int exitCode;
}

final class _DialBackTimedOut extends _DialBack {
  const _DialBackTimedOut();
}

class _TestFailureSummary {
  _TestFailureSummary({
    required this.message,
    required this.type,
    required this.stackChain,
  });

  final String message;
  final String type;
  final String stackChain;

  @override
  String toString() {
    final buf = StringBuffer()..writeln('$type: $message');
    if (stackChain.isNotEmpty) {
      buf.write(stackChain);
    }
    return buf.toString();
  }
}

/// Whether an integration run must be reported as a failure, given its counts.
///
/// A run that executes zero cases (nothing passed and nothing failed) is a
/// broken harness, not a pass, so it fails even without a suite error.
bool integrationRunFailed({
  required int passed,
  required int failed,
  required bool suiteError,
}) {
  return failed > 0 || suiteError || passed + failed == 0;
}

class _Results {
  int passed = 0;
  int failed = 0;
  int skipped = 0;
  bool _suiteError = false;

  final List<TestCaseResult> cases = [];

  void recordSuccess(String name, Duration elapsed, String output) {
    passed++;
    cases.add(TestCaseResult.passed(name, elapsed, output));
    stdout.writeln('  PASS  $name');
  }

  void recordFailure(
    String name,
    _TestFailureSummary summary,
    Duration elapsed,
    String output,
  ) {
    failed++;
    final formatted = summary.toString();
    cases.add(
      TestCaseResult.failed(
        name,
        elapsed,
        output,
        failureType: summary.type,
        message: summary.message,
        detail: formatted,
      ),
    );
    stdout.writeln('  FAIL  $name');
    stdout.writeln(_indent(formatted, '        '));
  }

  void recordSkipped(String name, String? reason) {
    skipped++;
    cases.add(TestCaseResult.skipped(name));
    stdout.writeln(
      reason == null ? '  SKIP  $name' : '  SKIP  $name (${reason.trim()})',
    );
  }

  void recordError(String message) {
    _suiteError = true;
    stdout.writeln('  FAIL  (suite error): $message');
    stderr.writeln('flutter_integration_test: $message');
  }

  bool get hasFailure => integrationRunFailed(
    passed: passed,
    failed: failed,
    suiteError: _suiteError,
  );

  String summary() {
    final pieces = <String>[
      if (passed > 0) '$passed passed',
      if (failed > 0) '$failed failed',
      if (skipped > 0) '$skipped skipped',
    ];
    final body = pieces.isEmpty ? 'no tests' : pieces.join(', ');
    return '\n$body${_suiteError ? ' (suite error)' : ''}';
  }
}

String _indent(String body, String prefix) {
  return body.split('\n').map((l) => l.isEmpty ? l : '$prefix$l').join('\n');
}
