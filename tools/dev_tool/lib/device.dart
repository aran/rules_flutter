/// Device abstraction for launching Flutter apps.
///
/// Handles platform-specific launch, VM service discovery, and
/// process lifecycle management.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'compiler_config.dart';
import 'reload_strategy.dart';
import 'runfiles_helper.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';
import 'web_module_server.dart';

/// A running Flutter application instance.
class AppInstance {
  final Process process;
  final Uri? vmServiceUri;

  /// Optional HTTP server (used by WebDevice).
  final HttpServer? server;

  AppInstance({required this.process, this.vmServiceUri, this.server});
}

/// Abstract device that can launch and manage a Flutter app.
abstract class Device {
  /// Launch the app and return the running instance.
  ///
  /// [appPath] is the path to the built application artifact.
  Future<AppInstance> launch(String appPath);

  /// Stop the running app.
  Future<void> stop(AppInstance instance);

  /// Capture a screenshot of the running app.
  ///
  /// For native platforms, uses the VM service `_flutter.screenshot` extension
  /// (pass [vmClient]). For web, subclasses override with CDP.
  /// Throws [UnsupportedError] if no VM client is available.
  ///
  /// [window] is an optional, platform-specific selector for which window to
  /// capture (e.g. on macOS, the exact window title). Devices that don't
  /// support window selection ignore it.
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    throw UnsupportedError(
        'Screenshot not supported on $name without VM service');
  }

  /// Display name for this device.
  String get name;

  /// Pick the runnable artifact from a target's cquery outputs.
  ///
  /// Default returns the first output. Subclasses override when the
  /// rule emits multiple outputs in an order that doesn't put the
  /// runnable artifact first — `android_binary`, for example, lists
  /// `<name>_deploy.jar` before `<name>.apk`, and the deploy jar is
  /// not installable.
  String pickArtifact(List<String> outputs) => outputs.first;

  /// Platform-specific arguments for `bazel build`.
  ///
  /// These are injected into `bazel build` and `bazel cquery` to ensure
  /// correct cross-compilation and output resolution.
  List<String> get buildArgs => const [];

  /// Create the compiler config for hot reload on this platform.
  ///
  /// Returns null if this device does not support hot reload.
  CompilerConfig? createCompilerConfig(
    ToolchainPaths toolchain, {
    WebToolchainPaths? webToolchain,
    List<String> fileSystemRoots = const [],
    String fileSystemScheme = '',
    List<String> dartDefines = const [],
    String dartPluginRegistrantUri = '',
  }) =>
      NativeCompilerConfig(
        patchedSdkRoot: toolchain.patchedSdkRoot,
        fileSystemRoots: fileSystemRoots,
        fileSystemScheme: fileSystemScheme,
        dartDefines: dartDefines,
        dartPluginRegistrantUri: dartPluginRegistrantUri,
      );

  /// Create the reload strategy for this platform.
  ///
  /// Returns null if this device does not support hot reload.
  ReloadStrategy? createReloadStrategy() => VmServiceReloadStrategy();
}

/// macOS desktop device.
class MacOSDevice extends Device {
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  MacOSDevice({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  })  : _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? _defaultStart;

  static Future<Process> _defaultStart(String exe, List<String> args) {
    return Process.start(exe, args, environment: {
      ...Platform.environment,
      'FLUTTER_VM_SERVICE_PORT': '0',
    });
  }

  @override
  String get name => 'macOS';

  @override
  Future<AppInstance> launch(String appPath) async {
    // Extract .app from .zip if needed (Bazel macOS bundles are zipped).
    String resolvedPath = appPath;
    if (appPath.endsWith('.zip')) {
      resolvedPath = await _extractAppFromZip(appPath);
    }

    // For .app bundles, find the executable inside.
    String executable;
    if (resolvedPath.endsWith('.app')) {
      // The executable is at Contents/MacOS/<name>.
      final bundleName = resolvedPath.split('/').last.replaceAll('.app', '');
      executable = '$resolvedPath/Contents/MacOS/$bundleName';
    } else {
      executable = resolvedPath;
    }

    final process = await _startProcess(
      executable,
      [],
    );

    // Listen for the VM service URI on stdout.
    final vmServiceUri = await _discoverVmServiceUri(process);

    return AppInstance(process: process, vmServiceUri: vmServiceUri);
  }

  @override
  Future<void> stop(AppInstance instance) async {
    if (!instance.process.kill()) {
      stderr.writeln(
          'Warning: Failed to kill macOS app process (pid ${instance.process.pid}).');
    }
    await instance.process.exitCode;
  }

  /// Captures the launched app's windows via the bundled Swift helper.
  ///
  /// With [vmClient] set, uses `_flutter.screenshot` (Flutter view only).
  /// Otherwise invokes `tools/macos_screenshot:screenshot`, which uses
  /// ScreenCaptureKit's `SCShareableContent` to enumerate on-screen windows
  /// owned by the app's PID and either composites all of them or — when
  /// [window] is provided — captures only the window whose `SCWindow.title`
  /// matches exactly. The helper requires Screen Recording permission for
  /// the terminal that launched the dev tool.
  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    final resolved = resolveRunfileWithManifest(
        'rules_flutter/tools/macos_screenshot/screenshot');
    if (resolved == null) {
      throw StateError(
          'Could not find bundled macOS screenshot tool. '
          'Build first: bazel build //tools/dev_tool:flutter_bazel');
    }
    final result = await Process.run(
      resolved.path,
      [
        '--pid', '${instance.process.pid}',
        '--output', outputPath,
        if (window != null) ...['--title', window],
      ],
      environment: {
        ...Platform.environment,
        if (resolved.manifestPath != null)
          'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
      },
    );
    if (result.exitCode != 0) {
      throw StateError('macOS screenshot failed: ${result.stderr}');
    }
  }

  /// Extract .app bundle from a .zip archive.
  Future<String> _extractAppFromZip(String zipPath) async {
    final tempDir = await Directory.systemTemp.createTemp('flutter_macos_');
    final result =
        await _runProcess('unzip', ['-oq', zipPath, '-d', tempDir.path]);
    if (result.exitCode != 0) {
      throw StateError('Failed to extract zip: ${result.stderr}');
    }
    // Find the .app bundle inside.
    final apps =
        tempDir.listSync().where((e) => e.path.endsWith('.app')).toList();
    if (apps.isEmpty) {
      throw StateError('No .app bundle found in zip');
    }
    return apps.first.path;
  }
}

/// Linux desktop device.
class LinuxDevice extends Device {
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  LinuxDevice({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  })  : _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? _defaultStart;

  static Future<Process> _defaultStart(String exe, List<String> args) {
    return Process.start(exe, args, environment: {
      ...Platform.environment,
      'FLUTTER_VM_SERVICE_PORT': '0',
    });
  }

  @override
  String get name => 'Linux';

  @override
  List<String> get buildArgs => Platform.isLinux
      ? const []
      : const ['--platforms=@rules_flutter//flutter/platforms:linux_x64'];

  @override
  Future<AppInstance> launch(String appPath) async {
    // Bundle directories contain the executable at <dir>/<name>.
    String executable = appPath;
    if (FileSystemEntity.isDirectorySync(appPath)) {
      final dirName = p.basename(appPath);
      executable = p.join(appPath, dirName);
    }

    final process = await _startProcess(executable, []);
    final vmServiceUri = await _discoverVmServiceUri(process);
    return AppInstance(process: process, vmServiceUri: vmServiceUri);
  }

  @override
  Future<void> stop(AppInstance instance) async {
    if (!instance.process.kill()) {
      stderr.writeln(
          'Warning: Failed to kill Linux app process (pid ${instance.process.pid}).');
    }
    await instance.process.exitCode;
  }

  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    final result = await _runProcess('scrot', [outputPath]);
    if (result.exitCode != 0) {
      throw StateError('scrot failed: ${result.stderr}');
    }
  }
}

/// Windows desktop device.
class WindowsDevice extends Device {
  final ProcessStarter _startProcess;

  WindowsDevice({
    ProcessStarter? startProcess,
  }) : _startProcess = startProcess ?? _defaultStart;

  static Future<Process> _defaultStart(String exe, List<String> args) {
    return Process.start(exe, args, environment: {
      ...Platform.environment,
      'FLUTTER_VM_SERVICE_PORT': '0',
    });
  }

  @override
  String get name => 'Windows';

  @override
  List<String> get buildArgs => Platform.isWindows
      ? const []
      : const ['--platforms=@rules_flutter//flutter/platforms:windows_x64'];

  @override
  Future<AppInstance> launch(String appPath) async {
    // Bundle directories contain the executable at <dir>/<name>.exe.
    String executable = appPath;
    if (FileSystemEntity.isDirectorySync(appPath)) {
      final dirName = p.basename(appPath);
      executable = p.join(appPath, '$dirName.exe');
    }

    final process = await _startProcess(executable, []);
    final vmServiceUri = await _discoverVmServiceUri(process);
    return AppInstance(process: process, vmServiceUri: vmServiceUri);
  }

  @override
  Future<void> stop(AppInstance instance) async {
    if (!instance.process.kill()) {
      stderr.writeln(
          'Warning: Failed to kill Windows app process (pid ${instance.process.pid}).');
    }
    await instance.process.exitCode;
  }

  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    // GDI CopyFromScreen cannot capture D3D/Flutter surfaces.
    // Use DXGI Desktop Duplication via bundled dxcam py_binary.
    final resolved = resolveRunfileWithManifest(
        'rules_flutter/tools/windows_screenshot/screenshot');
    if (resolved == null) {
      throw StateError('Could not find bundled Windows screenshot tool. '
          'Build first: bazel build //tools/dev_tool:flutter_bazel');
    }
    final result = await Process.run(resolved.path, [
      outputPath
    ], environment: {
      ...Platform.environment,
      if (resolved.manifestPath != null)
        'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
    });
    if (result.exitCode != 0) {
      throw StateError('DXGI screenshot failed: ${result.stderr}');
    }
  }
}

/// Signature for running a process and returning its result (allows test injection).
typedef ProcessRunSync = Future<ProcessResult> Function(
    String executable, List<String> arguments);

/// Signature for starting a streaming process (allows test injection).
typedef ProcessStarter = Future<Process> Function(
    String executable, List<String> arguments);

/// Resolve `adb` path — checks ANDROID_HOME, macOS default, then PATH.
String resolveAdb({ProcessRunSync? runProcess}) {
  // 1. $ANDROID_HOME/platform-tools/adb
  final androidHome = Platform.environment['ANDROID_HOME'];
  if (androidHome != null) {
    final adb = p.join(androidHome, 'platform-tools', 'adb');
    if (File(adb).existsSync()) return adb;
  }
  // 2. macOS default location
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home != null) {
      final adb =
          p.join(home, 'Library', 'Android', 'sdk', 'platform-tools', 'adb');
      if (File(adb).existsSync()) return adb;
    }
  }
  // 3. On PATH
  return 'adb';
}

/// Resolve `aapt2` path — checks ANDROID_HOME build-tools, then PATH.
String resolveAapt2() {
  final androidHome = Platform.environment['ANDROID_HOME'];
  if (androidHome != null) {
    final buildToolsDir = Directory(p.join(androidHome, 'build-tools'));
    if (buildToolsDir.existsSync()) {
      // Pick the latest version directory.
      final versions = buildToolsDir
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .toList()
        ..sort();
      if (versions.isNotEmpty) {
        final aapt2 =
            p.join(androidHome, 'build-tools', versions.last, 'aapt2');
        if (File(aapt2).existsSync()) return aapt2;
      }
    }
  }
  return 'aapt2';
}

/// Extract package name and launchable activity from an APK via aapt2.
Future<({String packageName, String? activityName})> extractPackageInfo(
  String apkPath, {
  ProcessRunSync? runProcess,
}) async {
  final run = runProcess ?? Process.run;
  final aapt2 = resolveAapt2();
  final result = await run(aapt2, ['dump', 'badging', apkPath]);
  if (result.exitCode != 0) {
    throw StateError('aapt2 dump badging failed: ${result.stderr}');
  }
  final output = result.stdout as String;
  final pkgMatch = RegExp(r"package: name='([^']+)'").firstMatch(output);
  if (pkgMatch == null) {
    throw StateError('Could not extract package name from APK');
  }
  final actMatch =
      RegExp(r"launchable-activity: name='([^']+)'").firstMatch(output);
  return (
    packageName: pkgMatch.group(1)!,
    activityName: actMatch?.group(1),
  );
}

/// Android device (via adb).
class AndroidDevice extends Device {
  final String? deviceId;
  String? _packageName;
  String? _activityName;
  final String abi;
  final String adbPath;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  /// Whether the upcoming launch expects the app to host a Dart VM service
  /// (debug/JIT builds). Set by the run command before [launch]; enables the
  /// INTERNET-permission preflight, which release/profile launches skip.
  bool expectsVmService = false;

  AndroidDevice({
    this.deviceId,
    String? packageName,
    String? activityName,
    this.abi = 'arm64',
    String? adbPath,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  })  : _packageName = packageName,
        _activityName = activityName,
        adbPath = adbPath ?? resolveAdb(),
        _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? Process.start;

  @override
  String get name => 'Android${deviceId != null ? ' ($deviceId)' : ''}';

  @override
  String pickArtifact(List<String> outputs) {
    // android_binary emits `<name>_deploy.jar`, `<name>_unsigned.apk`,
    // and `<name>.apk`. Only the signed `.apk` is installable; the
    // deploy jar comes first in the output list and would trip
    // `adb install` with `filename doesn't end .apk or .apex`.
    for (final f in outputs) {
      if (f.endsWith('.apk') && !f.endsWith('_unsigned.apk')) return f;
    }
    return outputs.first;
  }

  @override
  List<String> get buildArgs =>
      ['--platforms=@rules_flutter//flutter/platforms:android_$abi'];

  /// Build the common adb prefix args (includes -s <deviceId> if set).
  List<String> _adbArgs(List<String> args) {
    if (deviceId != null) return ['-s', deviceId!, ...args];
    return args;
  }

  @override
  Future<AppInstance> launch(String appPath) async {
    // Auto-detect package info from APK if not provided.
    if (_packageName == null && appPath.endsWith('.apk')) {
      try {
        final info = await extractPackageInfo(appPath, runProcess: _runProcess);
        _packageName = info.packageName;
        _activityName ??= info.activityName;
      } catch (e) {
        stderr.writeln('Warning: Could not extract package info from APK: $e');
      }
    }

    // Step 1: Install the APK.
    final installResult = await _runProcess(
      adbPath,
      _adbArgs(['install', '-r', appPath]),
    );
    if (installResult.exitCode != 0) {
      throw StateError('adb install failed: ${installResult.stderr}');
    }

    // Step 1a: Debug launches await the VM service, which can never come up
    // without android.permission.INTERNET — fail fast instead.
    if (expectsVmService && _packageName != null) {
      await _verifyInternetPermission(_packageName!, appPath);
    }

    // Step 2: Start adb logcat to capture VM service URI.
    final logcat = await _startProcess(
      adbPath,
      _adbArgs(['logcat', '-T', '1', 'flutter:I', '*:S']),
    );

    // Step 3: Launch the activity.
    if (_packageName != null) {
      final activity = _activityName ?? '.MainActivity';
      final component = '$_packageName/$activity';
      final startResult = await _runProcess(
        adbPath,
        _adbArgs(['shell', 'am', 'start', '-n', component]),
      );
      if (startResult.exitCode != 0) {
        throw StateError('adb am start failed: ${startResult.stderr}');
      }
    }

    // Step 4: Discover VM service URI from logcat.
    Uri? vmServiceUri;
    if (_packageName != null) {
      final deviceUri = await _discoverVmServiceUriFromLogcat(logcat);

      // Port forwarding — the VM service URI from logcat is device-local.
      if (deviceUri != null) {
        final devicePort = deviceUri.port;
        try {
          final forwardResult = await _runProcess(
            adbPath,
            _adbArgs(['forward', 'tcp:0', 'tcp:$devicePort']),
          );
          if (forwardResult.exitCode == 0) {
            final hostPort = int.tryParse(
              (forwardResult.stdout as String).trim(),
            );
            if (hostPort != null) {
              vmServiceUri = deviceUri.replace(
                host: '127.0.0.1',
                port: hostPort,
              );
            } else {
              vmServiceUri = deviceUri;
            }
          } else {
            vmServiceUri = deviceUri;
          }
        } catch (_) {
          vmServiceUri = deviceUri;
        }
      }
    }

    return AppInstance(process: logcat, vmServiceUri: vmServiceUri);
  }

  /// Fails the launch when the installed [packageName] does not request
  /// `android.permission.INTERNET`.
  ///
  /// Android enforces the INTERNET permission at the kernel level (AID_INET
  /// group membership): a process without it cannot create any socket —
  /// including the 127.0.0.1 server socket the Dart VM service must bind —
  /// so a debug launch would only ever time out waiting for the service.
  /// Queries the installed package (not the APK on disk) so the check
  /// reflects exactly what the device enforces.
  Future<void> _verifyInternetPermission(
      String packageName, String apkPath) async {
    final result = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'dumpsys', 'package', packageName]),
    );
    if (result.exitCode != 0) {
      throw StateError(
          'Could not verify INTERNET permission for $packageName: '
          '`adb shell dumpsys package` failed (exit ${result.exitCode}): '
          '${result.stderr}');
    }
    final output = result.stdout as String;
    if (!output.contains('Package [$packageName]')) {
      throw StateError(
          'Could not verify INTERNET permission for $packageName: '
          '`adb shell dumpsys package` returned no package record:\n'
          '${output.trim()}');
    }
    if (!_requestsInternetPermission(output)) {
      throw StateError(
          '$packageName ($apkPath) does not request '
          'android.permission.INTERNET, so the Dart VM service cannot bind '
          'its socket and this debug launch would hang.\n'
          'Cause: flutter create declares INTERNET only in variant manifests '
          '(android/app/src/debug/AndroidManifest.xml), which '
          'flutter_android_app does not merge into the APK.\n'
          'Workaround: add <uses-permission '
          'android:name="android.permission.INTERNET"/> to the manifest your '
          'debug APK is built from (see e2e/android_example\'s '
          'android/app/src/main/AndroidManifest.xml), or pass '
          '--allow-no-vm-service to launch without debugging.');
    }
  }

  /// True when the dumpsys package record lists
  /// `android.permission.INTERNET` under `requested permissions:`.
  /// A package that requests no permissions has no such section at all.
  static bool _requestsInternetPermission(String dumpsysOutput) {
    final lines = const LineSplitter().convert(dumpsysOutput);
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() != 'requested permissions:') continue;
      final headerIndent = lines[i].length - lines[i].trimLeft().length;
      for (var j = i + 1; j < lines.length; j++) {
        final line = lines[j];
        if (line.trim().isEmpty) break;
        final indent = line.length - line.trimLeft().length;
        if (indent <= headerIndent) break;
        final permission = line.trim().split(RegExp(r'[:\s]')).first;
        if (permission == 'android.permission.INTERNET') return true;
      }
    }
    return false;
  }

  @override
  Future<void> stop(AppInstance instance) async {
    if (_packageName != null) {
      await _runProcess(
        adbPath,
        _adbArgs(['shell', 'am', 'force-stop', _packageName!]),
      );
    }
    if (!instance.process.kill()) {
      stderr.writeln(
          'Warning: Failed to kill Android logcat process (pid ${instance.process.pid}).');
    }
    await instance.process.exitCode;
  }

  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    const remotePath = '/sdcard/flutter_screenshot.png';
    final capResult = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'screencap', '-p', remotePath]),
    );
    if (capResult.exitCode != 0) {
      throw StateError('adb screencap failed: ${capResult.stderr}');
    }
    final pullResult = await _runProcess(
      adbPath,
      _adbArgs(['pull', remotePath, outputPath]),
    );
    if (pullResult.exitCode != 0) {
      throw StateError('adb pull failed: ${pullResult.stderr}');
    }
    await _runProcess(adbPath, _adbArgs(['shell', 'rm', remotePath]));
  }
}

/// Wait until a local TCP listener on 127.0.0.1:[port] accepts connections.
///
/// Port forwarders (iproxy, adb forward) bind their local listener
/// asynchronously after `Process.start` returns; dialing the forward before
/// it is bound gets ECONNREFUSED. Polls `Socket.connect` with exponential
/// backoff and destroys each probe socket. Throws [StateError] naming [what]
/// if the listener never accepts within [budget].
Future<void> waitForLocalTcpPort(
  int port, {
  required String what,
  Duration budget = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(budget);
  var delay = const Duration(milliseconds: 50);
  while (true) {
    try {
      final probe = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(seconds: 1));
      probe.destroy();
      return;
    } catch (_) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
            '$what on 127.0.0.1:$port did not accept connections within '
            '${budget.inSeconds}s of starting.');
      }
      await Future<void>.delayed(delay);
      final doubled = delay * 2;
      delay = doubled > const Duration(milliseconds: 500)
          ? const Duration(milliseconds: 500)
          : doubled;
    }
  }
}

/// Discover the VM service URI from adb logcat output.
Future<Uri?> _discoverVmServiceUriFromLogcat(Process logcat) async {
  final completer = Completer<Uri?>();
  Timer? timeout;

  timeout = Timer(const Duration(seconds: 30), () {
    if (!completer.isCompleted) completer.complete(null);
  });

  StreamSubscription<String>? subscription;
  subscription = logcat.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
    (line) {
      final match = vmServiceUriPattern.firstMatch(line);
      if (match != null && !completer.isCompleted) {
        timeout?.cancel();
        completer.complete(Uri.parse(match.group(1)!));
        subscription?.cancel();
      }
    },
    onDone: () {
      timeout?.cancel();
      if (!completer.isCompleted) completer.complete(null);
    },
  );

  return completer.future;
}

/// Pattern matching Dart VM service URI announcements from Flutter apps.
/// Matches Flutter's own `kVMServiceMessageRegExp` from globals.dart.
final vmServiceUriPattern = RegExp(
  r'The Dart VM service is listening on ((http|//)[a-zA-Z0-9:/=_\-\.\[\]]+)',
);

/// Detect the VM service URI from a Flutter app's stdout and stderr.
///
/// The Flutter engine prints a line like:
///   "The Dart VM service is listening on http://127.0.0.1:XXXXX/..."
///
/// Matches Flutter's own approach: merge stdout + stderr into a single stream
/// and search for the VM service announcement in both.
Future<Uri?> _discoverVmServiceUri(Process process) async {
  final completer = Completer<Uri?>();
  Timer? timeout;
  final subscriptions = <StreamSubscription<String>>[];

  timeout = Timer(const Duration(seconds: 30), () {
    if (!completer.isCompleted) completer.complete(null);
  });

  void handleLine(String line) {
    stdout.writeln(line);
    final match = vmServiceUriPattern.firstMatch(line);
    if (match != null && !completer.isCompleted) {
      timeout?.cancel();
      completer.complete(Uri.parse(match.group(1)!));
      for (final s in subscriptions) {
        s.cancel();
      }
    }
  }

  subscriptions.add(
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      handleLine,
      onDone: () {
        timeout?.cancel();
        if (!completer.isCompleted) completer.complete(null);
      },
    ),
  );

  subscriptions.add(
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          handleLine,
        ),
  );

  return completer.future;
}

/// Detect the appropriate device for the current platform.
Device detectDevice() {
  if (Platform.isMacOS) return MacOSDevice();
  if (Platform.isLinux) return LinuxDevice();
  if (Platform.isWindows) return WindowsDevice();
  throw UnsupportedError(
    'No device available for ${Platform.operatingSystem}. '
    'Desktop devices are supported on macOS, Linux, and Windows.',
  );
}

/// Resolve device IDs to [Device] instances.
///
/// If [ids] is empty, auto-detects one device for the current platform.
/// Accepted IDs: `macos`, `linux`, `windows`, `ios-simulator`,
/// `ios-simulator:<udid>`, `ios`, `ios:<udid>`, `chrome`, or an Android serial.
///
/// Unknown IDs are treated as Android serial numbers with a warning.
List<Device> resolveDevices(List<String> ids) {
  if (ids.isEmpty) return [detectDevice()];
  return ids.map(_resolveDevice).toList();
}

Device _resolveDevice(String id) {
  switch (id) {
    case 'macos':
      return MacOSDevice();
    case 'linux':
      return LinuxDevice();
    case 'windows':
      return WindowsDevice();
    case 'chrome':
      return WebDevice();
    case 'ios-simulator':
      return IOSSimulatorDevice.booted();
    case 'ios':
      return IOSDevice.connected();
    default:
      if (id.startsWith('ios-simulator:')) {
        return IOSSimulatorDevice(udid: id.substring('ios-simulator:'.length));
      }
      if (id.startsWith('ios:')) {
        return IOSDevice(udid: id.substring('ios:'.length));
      }
      // Warn if it looks like a typo of a known device name.
      const knownIds = [
        'macos',
        'linux',
        'windows',
        'chrome',
        'ios-simulator',
        'ios',
      ];
      stderr.writeln(
        "Warning: Unknown device ID '$id', treating as Android serial number. "
        'Known device IDs: ${knownIds.join(', ')}.',
      );
      return AndroidDevice(deviceId: id);
  }
}

/// iOS Simulator device (via xcrun simctl).
class IOSSimulatorDevice extends Device {
  final String udid;
  final String? _bundleId;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  IOSSimulatorDevice({
    required this.udid,
    String? bundleId,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  })  : _bundleId = bundleId,
        _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? Process.start;

  /// Create a device targeting the first booted simulator.
  factory IOSSimulatorDevice.booted({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) {
    final run = runProcess ?? Process.run;
    return _IOSSimulatorDeviceBooted(
      runProcess: run,
      startProcess: startProcess ?? Process.start,
    );
  }

  @override
  String get name => 'iOS Simulator ($udid)';

  @override
  List<String> get buildArgs => const ['--ios_multi_cpus=sim_arm64'];

  @override
  Future<AppInstance> launch(String appPath) async {
    // Extract .app from .ipa if needed — simctl install requires .app.
    String installPath = appPath;
    if (appPath.endsWith('.ipa')) {
      installPath = await _extractAppFromIpa(appPath);
    }

    // Boot sim (idempotent — no-op if already booted).
    await _runProcess('xcrun', ['simctl', 'boot', udid]);

    // Install.
    final installResult =
        await _runProcess('xcrun', ['simctl', 'install', udid, installPath]);
    if (installResult.exitCode != 0) {
      throw StateError('simctl install failed: ${installResult.stderr}');
    }

    // Start log stream for VM service URI.
    final log = await _startProcess('xcrun', [
      'simctl',
      'spawn',
      udid,
      'log',
      'stream',
      '--predicate',
      'eventMessage contains "Observatory" or eventMessage contains "Dart VM service"',
    ]);

    // Launch app.
    final bundleId = _bundleId ?? await _extractBundleId(installPath);
    await _runProcess('xcrun', ['simctl', 'launch', udid, bundleId]);

    // Discover VM service URI from log stream.
    final uri = await _discoverVmServiceUriFromStream(log);

    return AppInstance(process: log, vmServiceUri: uri);
  }

  @override
  Future<void> stop(AppInstance instance) async {
    if (_bundleId != null) {
      await _runProcess('xcrun', ['simctl', 'terminate', udid, _bundleId!]);
    }
    instance.process.kill();
    await instance.process.exitCode;
  }

  /// iOS Simulator uses `simctl io screenshot` because `_flutter.screenshot`
  /// returns "Could not capture image screenshot" on the Simulator rendering
  /// pipeline. Waits for the first frame via VM service before capturing.
  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      await vmClient.waitForFirstFrame();
    }
    final result = await _runProcess(
        'xcrun', ['simctl', 'io', udid, 'screenshot', outputPath]);
    if (result.exitCode != 0) {
      throw StateError('simctl screenshot failed: ${result.stderr}');
    }
  }

  Future<String> _extractBundleId(String appPath) async {
    final result = await _runProcess('defaults', [
      'read',
      '$appPath/Info.plist',
      'CFBundleIdentifier',
    ]);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
    throw StateError('Could not extract bundle ID from $appPath');
  }

  /// Extract the .app directory from an .ipa archive.
  Future<String> _extractAppFromIpa(String ipaPath) async {
    final tempDir = await Directory.systemTemp.createTemp('flutter_ipa_');
    final result =
        await _runProcess('unzip', ['-oq', ipaPath, '-d', tempDir.path]);
    if (result.exitCode != 0) {
      throw StateError('Failed to extract IPA: ${result.stderr}');
    }
    final payloadDir = Directory(p.join(tempDir.path, 'Payload'));
    if (!payloadDir.existsSync()) {
      throw StateError('No Payload directory found in IPA');
    }
    final apps =
        payloadDir.listSync().where((e) => e.path.endsWith('.app')).toList();
    if (apps.isEmpty) {
      throw StateError('No .app found in IPA Payload directory');
    }
    return apps.first.path;
  }
}

/// An [IOSSimulatorDevice] that resolves the UDID on first launch.
class _IOSSimulatorDeviceBooted extends IOSSimulatorDevice {
  String? _resolvedUdid;

  _IOSSimulatorDeviceBooted({
    required ProcessRunSync runProcess,
    required ProcessStarter startProcess,
  }) : super(
          udid: 'booted',
          runProcess: runProcess,
          startProcess: startProcess,
        );

  @override
  String get name => _resolvedUdid != null
      ? 'iOS Simulator ($_resolvedUdid)'
      : 'iOS Simulator (booted)';

  Future<String> _resolveBootedUdid() async {
    if (_resolvedUdid != null) return _resolvedUdid!;
    final result = await _runProcess(
        'xcrun', ['simctl', 'list', 'devices', 'booted', '-j']);
    if (result.exitCode == 0) {
      final output = result.stdout as String;
      final match = RegExp(r'"udid"\s*:\s*"([^"]+)"').firstMatch(output);
      if (match != null) {
        _resolvedUdid = match.group(1)!;
        return _resolvedUdid!;
      }
    }
    throw StateError('No booted iOS simulator found. '
        'Boot one with: xcrun simctl boot <device-name>');
  }

  @override
  Future<AppInstance> launch(String appPath) async {
    final resolvedUdid = await _resolveBootedUdid();
    final real = IOSSimulatorDevice(
      udid: resolvedUdid,
      runProcess: _runProcess,
      startProcess: _startProcess,
    );
    return real.launch(appPath);
  }
}

/// iOS physical device (via xcrun devicectl + iproxy).
class IOSDevice extends Device {
  final String udid;
  final String? _bundleId;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  /// iproxy process for port forwarding (killed on stop).
  Process? _iproxyProcess;

  /// devicectl --console process for stdout capture (killed on stop).
  Process? _consoleLauncherProcess;

  /// lldb process for debugger attachment (killed on stop).
  Process? _lldbProcess;

  /// Installation URL from devicectl install (for PID matching).
  String? _installationUrl;

  IOSDevice({
    required this.udid,
    String? bundleId,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  })  : _bundleId = bundleId,
        _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? Process.start;

  /// Create a device targeting the first connected physical device.
  factory IOSDevice.connected({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) {
    return _IOSDeviceConnected(
      runProcess: runProcess ?? Process.run,
      startProcess: startProcess ?? Process.start,
    );
  }

  @override
  String get name => 'iOS ($udid)';

  @override
  List<String> get buildArgs => const ['--ios_multi_cpus=arm64'];

  @override
  Future<AppInstance> launch(String appPath) async {
    // Extract .app from .ipa if needed — devicectl install requires .app.
    String installPath = appPath;
    if (appPath.endsWith('.ipa')) {
      installPath = await _extractAppFromIpa(appPath);
    }

    // Install with JSON output to capture installationURL.
    final installJsonDir =
        await Directory.systemTemp.createTemp('flutter_install_');
    final installJsonPath = p.join(installJsonDir.path, 'install.json');

    final installResult = await _runProcess('xcrun', [
      'devicectl',
      'device',
      'install',
      'app',
      '--device',
      udid,
      '--json-output',
      installJsonPath,
      installPath,
    ]);
    if (installResult.exitCode != 0) {
      throw StateError('devicectl install failed: ${installResult.stderr}');
    }

    // Capture installationURL for PID matching.
    final installJsonFile = File(installJsonPath);
    if (installJsonFile.existsSync()) {
      try {
        final jsonData = json.decode(installJsonFile.readAsStringSync())
            as Map<String, dynamic>;
        final apps = jsonData['result']?['installedApplications'] as List?;
        if (apps != null && apps.isNotEmpty) {
          _installationUrl = (apps[0] as Map)['installationURL'] as String?;
        }
      } catch (_) {}
    }

    // Extract bundle ID from .app/Info.plist if not provided.
    final bundleId = _bundleId ?? await _extractBundleId(installPath);

    // iOS debug apps require a debugger (ptrace) to be attached before the
    // Flutter engine will start. This matches what `flutter run` does:
    //   1. Launch paused via devicectl --console --start-stopped
    //   2. Get PID from process list
    //   3. Attach lldb (which starts debugserver / ptrace)
    //   4. Set JIT page notification breakpoint
    //   5. Resume
    //   6. Discover VM service URI from devicectl --console stdout

    // Step 1: Launch paused with --console to capture stdout.
    _consoleLauncherProcess = await _startProcess('xcrun', [
      'devicectl',
      'device',
      'process',
      'launch',
      '--device',
      udid,
      '--start-stopped',
      '--console',
      '--environment-variables',
      '{"OS_ACTIVITY_DT_MODE": "enable"}',
      bundleId,
      '--enable-dart-profiling',
      '--enable-checked-mode',
    ]);

    // Listen on both stdout and stderr for launch confirmation and VM URI.
    // devicectl sends its own messages to stdout, app console output to stderr.
    final launchCompleter = Completer<void>();
    final vmUriCompleter = Completer<Uri?>();
    Timer(const Duration(seconds: 30), () {
      if (!launchCompleter.isCompleted) launchCompleter.complete();
    });
    Timer(const Duration(seconds: 30), () {
      if (!vmUriCompleter.isCompleted) vmUriCompleter.complete(null);
    });
    void handleConsoleOutput(String data) {
      if (!launchCompleter.isCompleted &&
          (data.contains('Waiting for the application to terminate') ||
              data.contains('Launched application with'))) {
        launchCompleter.complete();
      }
      final match = vmServiceUriPattern.firstMatch(data);
      if (match != null && !vmUriCompleter.isCompleted) {
        vmUriCompleter.complete(Uri.parse(match.group(1)!));
      }
    }

    _consoleLauncherProcess!.stdout
        .transform(utf8.decoder)
        .listen(handleConsoleOutput, onDone: () {
      if (!launchCompleter.isCompleted) launchCompleter.complete();
      if (!vmUriCompleter.isCompleted) vmUriCompleter.complete(null);
    });
    _consoleLauncherProcess!.stderr
        .transform(utf8.decoder)
        .listen(handleConsoleOutput);

    await launchCompleter.future;

    // Step 2: Get PID from running process list.
    final processId = await _findAppProcessId(bundleId);
    if (processId == null) {
      throw StateError('Could not find process ID for $bundleId');
    }

    // Step 3-5: Attach lldb debugger, set breakpoint, resume.
    // Matches flutter_tools LLDB._selectDevice, _setBreakpoint,
    // _attachToAppProcess, _resumeProcess.
    final lldb = await _startProcess('lldb', []);
    _lldbProcess = lldb;
    await _lldbCommand(lldb, 'device select $udid');
    final bpOutput = await _lldbCommand(
        lldb, r"breakpoint set --func-regex '^NOTIFY_DEBUGGER_ABOUT_RX_PAGES$'",
        waitFor: RegExp(r'Breakpoint (\d+):'), returnMatch: true);
    final bpId =
        RegExp(r'Breakpoint (\d+):').firstMatch(bpOutput ?? '')?.group(1) ??
            '1';
    await _lldbWriteln(
        lldb, 'breakpoint command add --script-type python $bpId');
    await _lldbWriteln(lldb, _jitBreakpointScript);
    await _lldbWriteln(lldb, 'DONE');
    await _lldbCommand(lldb, 'device process attach --pid $processId',
        waitFor: RegExp(r'Process \d+ stopped'));
    await _lldbCommand(lldb, 'process continue',
        waitFor: RegExp(r'Process \d+ resuming'));

    // Step 6: Discover VM service URI from devicectl --console stdout.
    final deviceUri = await vmUriCompleter.future;

    // Port-forward VM service from device to host via iproxy.
    Uri? vmServiceUri;
    if (deviceUri != null) {
      final devicePort = deviceUri.port;
      _iproxyProcess = await _startProcess(
          'iproxy', ['$devicePort:$devicePort', '-u', udid]);

      // Process.start returns at spawn time, before iproxy has bound its
      // local listener. DDS dials this forward immediately after launch()
      // returns; an unbound listener means ECONNREFUSED and the session
      // loses its VM service. Return only once the forward actually accepts.
      await waitForLocalTcpPort(devicePort,
          what: 'iproxy forward for the iOS VM service');
      vmServiceUri = deviceUri.replace(host: '127.0.0.1');
    }

    return AppInstance(process: lldb, vmServiceUri: vmServiceUri);
  }

  /// Python script for the JIT page notification breakpoint.
  /// Matches flutter_tools' LLDB._pythonScript.
  static const _jitBreakpointScript = '''
"""Intercept NOTIFY_DEBUGGER_ABOUT_RX_PAGES and touch the pages."""
base = frame.register["x0"].GetValueAsAddress()
page_len = frame.register["x1"].GetValueAsUnsigned()
data = bytearray(page_len)
data[0:8] = b'IHELPED!'
error = lldb.SBError()
frame.GetThread().GetProcess().WriteMemory(base, data, error)
if not error.Success():
    print(f'Failed to write into {base}[+{page_len}]', error)
    return
return False
''';

  /// Broadcast stream for lldb stdout (created once per launch).
  Stream<String>? _lldbStdoutBroadcast;

  /// Send a command to lldb stdin and optionally wait for expected output.
  /// If [returnMatch] is true, returns the matched line; otherwise returns null.
  Future<String?> _lldbCommand(Process lldb, String command,
      {RegExp? waitFor, bool returnMatch = false}) async {
    _lldbStdoutBroadcast ??= lldb.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();

    String? matchedLine;
    final completer = waitFor != null ? Completer<void>() : null;
    StreamSubscription<String>? sub;

    if (completer != null) {
      sub = _lldbStdoutBroadcast!.listen((line) {
        if (waitFor!.hasMatch(line) && !completer.isCompleted) {
          matchedLine = line;
          completer.complete();
          sub?.cancel();
        }
      });
    }

    lldb.stdin.writeln(command);
    if (completer != null) {
      await completer.future.timeout(const Duration(seconds: 30));
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return returnMatch ? matchedLine : null;
  }

  /// Write a line to lldb stdin without waiting for output.
  Future<void> _lldbWriteln(Process lldb, String text) async {
    lldb.stdin.writeln(text);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// Find the process ID of a running app by bundle ID.
  ///
  /// Uses `devicectl device info processes --json-output` and matches the
  /// process executable against the installationURL (from install step)
  /// or bundle ID.
  Future<int?> _findAppProcessId(String bundleId) async {
    final jsonDir = await Directory.systemTemp.createTemp('flutter_proc_');
    final jsonPath = p.join(jsonDir.path, 'processes.json');

    final result = await _runProcess('xcrun', [
      'devicectl',
      'device',
      'info',
      'processes',
      '--device',
      udid,
      '--json-output',
      jsonPath,
    ]);
    if (result.exitCode != 0) return null;

    final jsonFile = File(jsonPath);
    if (!jsonFile.existsSync()) return null;

    try {
      final data =
          json.decode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
      final processes = (data['result']?['runningProcesses'] as List?) ?? [];

      for (final proc in processes) {
        final executable = (proc as Map)['executable'] as String? ?? '';
        final pid = proc['processIdentifier'] as int?;
        if (pid == null) continue;

        if (_installationUrl != null &&
            executable.contains(_installationUrl!)) {
          return pid;
        }
        if (executable.contains(bundleId)) {
          return pid;
        }
      }
    } catch (_) {}

    return null;
  }

  @override
  Future<void> stop(AppInstance instance) async {
    _iproxyProcess?.kill();
    if (_iproxyProcess != null) {
      await _iproxyProcess!.exitCode;
      _iproxyProcess = null;
    }
    _consoleLauncherProcess?.kill();
    if (_consoleLauncherProcess != null) {
      await _consoleLauncherProcess!.exitCode;
      _consoleLauncherProcess = null;
    }
    // Killing lldb terminates the debugserver, which kills the app.
    _lldbProcess?.kill();
    if (_lldbProcess != null) {
      await _lldbProcess!.exitCode;
      _lldbProcess = null;
    }
    instance.process.kill();
    await instance.process.exitCode;
  }

  /// iOS physical device screenshot via pymobiledevice3 DVT service.
  ///
  /// `_flutter.screenshot` does not work on iOS because the Impeller renderer
  /// (always enabled on iOS) does not implement compressed image capture.
  /// Instead, we use pymobiledevice3's DVT screenshot, which captures via
  /// Apple's Developer Tools service (same mechanism as Xcode).
  ///
  /// The screenshot binary is bundled as a Bazel py_binary and resolved from
  /// runfiles. Requires building via `bazel build //tools/dev_tool:flutter_bazel`.
  ///
  /// Prerequisites:
  ///   sudo flutter_bazel ios-tunnel  # in a separate terminal
  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      await vmClient.waitForFirstFrame();
    }

    final resolved = resolveRunfileWithManifest(
        'rules_flutter/tools/ios_screenshot/screenshot');
    if (resolved == null) {
      throw StateError(
          'iOS device screenshot requires the bundled screenshot tool.\n'
          'Build via: bazel build //tools/dev_tool:flutter_bazel');
    }

    // The py_binary needs RUNFILES_MANIFEST_FILE to find its venv and
    // bootstrap scripts within the dart_binary's runfiles.
    final result = await Process.run(resolved.path, [
      outputPath,
      '--udid',
      udid,
    ], environment: {
      if (resolved.manifestPath != null)
        'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
    });
    if (result.exitCode != 0) {
      final err = result.stderr as String;
      if (err.contains('Unable to connect to Tunneld') ||
          err.contains('no devices found')) {
        throw StateError(
            'iOS device screenshot requires a running tunnel daemon.\n'
            'Start in a separate terminal:\n'
            '  sudo flutter_bazel ios-tunnel');
      }
      throw StateError('iOS screenshot failed: $err');
    }
  }

  Future<String> _extractBundleId(String appPath) async {
    final result = await _runProcess('defaults', [
      'read',
      '$appPath/Info.plist',
      'CFBundleIdentifier',
    ]);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
    throw StateError('Could not extract bundle ID from $appPath');
  }

  /// Extract the .app directory from an .ipa archive.
  Future<String> _extractAppFromIpa(String ipaPath) async {
    final tempDir = await Directory.systemTemp.createTemp('flutter_ipa_');
    final result =
        await _runProcess('unzip', ['-oq', ipaPath, '-d', tempDir.path]);
    if (result.exitCode != 0) {
      throw StateError('Failed to extract IPA: ${result.stderr}');
    }
    final payloadDir = Directory(p.join(tempDir.path, 'Payload'));
    if (!payloadDir.existsSync()) {
      throw StateError('No Payload directory found in IPA');
    }
    final apps =
        payloadDir.listSync().where((e) => e.path.endsWith('.app')).toList();
    if (apps.isEmpty) {
      throw StateError('No .app found in IPA Payload directory');
    }
    return apps.first.path;
  }
}

/// An [IOSDevice] that resolves the UDID on first use.
class _IOSDeviceConnected extends IOSDevice {
  String? _resolvedUdid;

  _IOSDeviceConnected({
    required ProcessRunSync runProcess,
    required ProcessStarter startProcess,
  }) : super(
          udid: '',
          runProcess: runProcess,
          startProcess: startProcess,
        );

  @override
  String get name =>
      _resolvedUdid != null ? 'iOS ($_resolvedUdid)' : 'iOS (auto-detect)';

  Future<String> _resolveConnectedUdid() async {
    if (_resolvedUdid != null) return _resolvedUdid!;
    // Use xctrace to list devices — physical devices have a UDID in parens.
    final result = await _runProcess('xcrun', ['xctrace', 'list', 'devices']);
    if (result.exitCode == 0) {
      final output = result.stdout as String;
      // Parse lines like: "Name (version) (UDID)"
      // Physical devices have version + UDID; skip simulators section.
      bool inDevices = false;
      for (final line in output.split('\n')) {
        if (line.startsWith('== Devices ==')) {
          inDevices = true;
          continue;
        }
        if (line.startsWith('== Simulators ==')) break;
        if (!inDevices) continue;
        // Match lines like "My iPhone (26.3.1) (00008101-...)"
        final match =
            RegExp(r'\(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})\)').firstMatch(line);
        if (match != null) {
          _resolvedUdid = match.group(1)!;
          return _resolvedUdid!;
        }
      }
    }
    throw StateError('No connected iOS device found. '
        'Connect a device via USB or run: xcrun xctrace list devices');
  }

  @override
  Future<AppInstance> launch(String appPath) async {
    final resolvedUdid = await _resolveConnectedUdid();
    final real = IOSDevice(
      udid: resolvedUdid,
      runProcess: _runProcess,
      startProcess: _startProcess,
    );
    return real.launch(appPath);
  }
}

/// Discover VM service URI from a log stream process.
Future<Uri?> _discoverVmServiceUriFromStream(Process log) async {
  final completer = Completer<Uri?>();
  Timer? timeout;

  timeout = Timer(const Duration(seconds: 30), () {
    if (!completer.isCompleted) completer.complete(null);
  });

  StreamSubscription<String>? subscription;
  subscription =
      log.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      final match = vmServiceUriPattern.firstMatch(line);
      if (match != null && !completer.isCompleted) {
        timeout?.cancel();
        completer.complete(Uri.parse(match.group(1)!));
        subscription?.cancel();
      }
    },
    onDone: () {
      timeout?.cancel();
      if (!completer.isCompleted) completer.complete(null);
    },
  );

  return completer.future;
}

/// Chrome launch flags matching Flutter's defaults for web dev mode.
///
/// These ensure predictable behavior during development:
/// - No extensions/popups that could interfere with the app
/// - Background timer throttling disabled for accurate async behavior
/// - No first-run/default-browser prompts
const chromeDebugFlags = [
  '--disable-extensions',
  '--disable-popup-blocking',
  '--bwsi',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-default-apps',
  '--disable-translate',
  '--disable-search-engine-choice-screen',
  '--disable-background-timer-throttling',
];

/// Web device — serves build output via HTTP and launches Chrome.
class WebDevice extends Device {
  final ProcessStarter _startProcess;

  /// CDP debugging port discovered from Chrome stderr.
  int? _cdpPort;

  /// The localhost URL serving the app (used to find the correct CDP tab).
  String? _appUrl;

  /// Module server for DDC dev mode. Set by RunCommand before launch.
  WebModuleServer? _moduleServer;

  WebDevice({ProcessStarter? startProcess})
      : _startProcess = startProcess ?? Process.start;

  @override
  String get name => 'Chrome';

  /// Set the DDC module server for dev mode (hot restart support).
  void setModuleServer(WebModuleServer server) => _moduleServer = server;

  /// The CDP debugging port, if discovered.
  int? get cdpPort => _cdpPort;

  /// The localhost URL serving the app, if launched.
  String? get appUrl => _appUrl;

  @override
  CompilerConfig? createCompilerConfig(
    ToolchainPaths toolchain, {
    WebToolchainPaths? webToolchain,
    List<String> fileSystemRoots = const [],
    String fileSystemScheme = '',
    List<String> dartDefines = const [],
    String dartPluginRegistrantUri = '',
  }) {
    // Web builds its own filesystem roots (synthetic entrypoint dir + workspace)
    // in run_command; the native roots/scheme args are not used here. The
    // registrant URI is ignored too — the web synthetic main calls
    // registerPlugins() directly and re-runs on page-reload restart.
    if (webToolchain == null) return null;
    return WebCompilerConfig(webToolchain: webToolchain, dartDefines: dartDefines);
  }

  @override
  ReloadStrategy? createReloadStrategy() {
    if (_moduleServer == null) return null;
    // Prefer DWDS-based reload for DDC mode (state-preserving hot reload).
    if (_moduleServer!.connectedApps != null) {
      return DwdsReloadStrategy(moduleServer: _moduleServer!);
    }
    // Fall back to CDP page reload (WASM mode or when DWDS is unavailable).
    if (_cdpPort == null) return null;
    return CdpReloadStrategy(cdpPort: _cdpPort!, appUrl: _appUrl);
  }

  @override
  Future<AppInstance> launch(String appPath) async {
    if (_moduleServer != null) {
      return _launchWithModuleServer();
    }
    return _launchStaticServer(appPath);
  }

  /// Launch using DDC module server (dev mode with hot restart).
  Future<AppInstance> _launchWithModuleServer() async {
    final url = _moduleServer!.uri.toString();
    _appUrl = url;

    final chromePath = findChrome();
    if (chromePath == null) {
      throw StateError(
          'Chrome not found. Install Chrome or use -d macos for desktop.');
    }
    final userDataDir =
        await Directory.systemTemp.createTemp('flutter_chrome_');
    final chrome = await _startProcess(chromePath, [
      '--remote-debugging-port=0',
      ...chromeDebugFlags,
      '--user-data-dir=${userDataDir.path}',
      url,
    ]);

    _cdpPort = await _discoverCdpPort(chrome);
    return AppInstance(process: chrome, vmServiceUri: null);
  }

  /// Launch using static file server (production/WASM mode).
  Future<AppInstance> _launchStaticServer(String appPath) async {
    final server = await HttpServer.bind('localhost', 0);
    final port = server.port;
    final url = 'http://localhost:$port';

    _serveDirectory(server, appPath);

    final chromePath = findChrome();
    if (chromePath == null) {
      await server.close();
      throw StateError(
          'Chrome not found. Install Chrome or use -d macos for desktop.');
    }
    final userDataDir =
        await Directory.systemTemp.createTemp('flutter_chrome_');
    _appUrl = url;
    final chrome = await _startProcess(chromePath, [
      '--remote-debugging-port=0',
      ...chromeDebugFlags,
      '--user-data-dir=${userDataDir.path}',
      url,
    ]);

    _cdpPort = await _discoverCdpPort(chrome);
    return AppInstance(process: chrome, vmServiceUri: null, server: server);
  }

  @override
  Future<void> stop(AppInstance instance) async {
    await _moduleServer?.stop();
    await instance.server?.close();
    instance.process.kill();
  }

  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (_cdpPort == null) {
      throw StateError('CDP port not discovered — cannot capture screenshot');
    }
    await _cdpScreenshot(_cdpPort!, outputPath, appUrl: _appUrl);
  }
}

/// Serve static files from a directory with CORS headers for WASM.
void _serveDirectory(HttpServer server, String rootPath) {
  server.listen((request) async {
    // CORS headers required for WASM SharedArrayBuffer.
    request.response.headers.add('Cross-Origin-Opener-Policy', 'same-origin');
    request.response.headers
        .add('Cross-Origin-Embedder-Policy', 'require-corp');

    var path = request.uri.path;
    if (path == '/') path = '/index.html';
    final file = File('$rootPath$path');
    if (await file.exists()) {
      final ext = path.split('.').last;
      request.response.headers.contentType = _contentType(ext);
      await request.response.addStream(file.openRead());
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });
}

ContentType _contentType(String ext) {
  return switch (ext) {
    'html' => ContentType.html,
    'js' || 'mjs' => ContentType('application', 'javascript'),
    'wasm' => ContentType('application', 'wasm'),
    'json' => ContentType.json,
    'css' => ContentType('text', 'css'),
    'png' => ContentType('image', 'png'),
    'ico' => ContentType('image', 'x-icon'),
    _ => ContentType.binary,
  };
}

/// Discover the CDP debugging port from Chrome's stderr.
///
/// Chrome prints "DevTools listening on ws://127.0.0.1:<port>/..." to stderr
/// when launched with `--remote-debugging-port=0`.
Future<int?> _discoverCdpPort(Process chrome) async {
  final completer = Completer<int?>();
  Timer? timeout;

  timeout = Timer(const Duration(seconds: 15), () {
    if (!completer.isCompleted) completer.complete(null);
  });

  StreamSubscription<String>? subscription;
  subscription = chrome.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
    (line) {
      // Chrome prints: DevTools listening on ws://127.0.0.1:PORT/devtools/browser/...
      final match =
          RegExp(r'DevTools listening on ws://\S+?:(\d+)/').firstMatch(line);
      if (match != null && !completer.isCompleted) {
        timeout?.cancel();
        completer.complete(int.parse(match.group(1)!));
        subscription?.cancel();
      }
    },
    onDone: () {
      timeout?.cancel();
      if (!completer.isCompleted) completer.complete(null);
    },
  );

  return completer.future;
}

/// Capture a screenshot via Chrome DevTools Protocol.
///
/// Connects to `http://127.0.0.1:<port>/json` to discover the app tab's
/// WebSocket URL, then sends `Page.captureScreenshot` over CDP.
/// If [appUrl] is provided, selects the tab matching that URL.
Future<void> _cdpScreenshot(int cdpPort, String outputPath,
    {String? appUrl}) async {
  final client = HttpClient();
  try {
    // Get the list of targets (tabs).
    final listReq =
        await client.getUrl(Uri.parse('http://127.0.0.1:$cdpPort/json'));
    final listResp = await listReq.close();
    final listBody = await listResp.transform(utf8.decoder).join();
    final targets = json.decode(listBody) as List;
    if (targets.isEmpty) {
      throw StateError('No CDP targets found');
    }
    // Find the target matching our app URL, falling back to first page target.
    final pageTargets =
        targets.where((t) => (t as Map)['type'] == 'page').toList();
    Map target;
    if (appUrl != null) {
      final appTarget = pageTargets.where((t) {
        final url = (t as Map)['url'] as String? ?? '';
        return url.startsWith(appUrl);
      });
      target = appTarget.isNotEmpty
          ? appTarget.first as Map
          : (pageTargets.isNotEmpty
              ? pageTargets.first as Map
              : targets.first as Map);
    } else {
      target = pageTargets.isNotEmpty
          ? pageTargets.first as Map
          : targets.first as Map;
    }
    final wsUrl = target['webSocketDebuggerUrl'] as String?;
    if (wsUrl == null) {
      throw StateError('No WebSocket URL in CDP target');
    }

    // Connect WebSocket and send Page.captureScreenshot.
    final ws = await WebSocket.connect(wsUrl);
    final responseCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      final msg = json.decode(data as String) as Map<String, dynamic>;
      if (msg['id'] == 1 && !responseCompleter.isCompleted) {
        responseCompleter.complete(msg);
      }
    });

    ws.add(json.encode({
      'id': 1,
      'method': 'Page.captureScreenshot',
      'params': {'format': 'png'},
    }));

    final response =
        await responseCompleter.future.timeout(const Duration(seconds: 10));
    await ws.close();

    final result = response['result'] as Map<String, dynamic>?;
    if (result == null || result['data'] == null) {
      throw StateError('CDP screenshot returned no data');
    }

    // Decode base64 PNG and write to file.
    final bytes = base64.decode(result['data'] as String);
    await File(outputPath).writeAsBytes(bytes);
  } finally {
    client.close();
  }
}

/// Find the Chrome executable path, or null if not found.
String? findChrome() {
  if (Platform.isMacOS) {
    const p = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    if (File(p).existsSync()) return p;
  }
  if (Platform.isLinux) {
    final r = Process.runSync('which', ['google-chrome']);
    if (r.exitCode == 0) return (r.stdout as String).trim();
    final r2 = Process.runSync('which', ['chromium-browser']);
    if (r2.exitCode == 0) return (r2.stdout as String).trim();
  }
  if (Platform.isWindows) {
    const paths = [
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    ];
    for (final p in paths) {
      if (File(p).existsSync()) return p;
    }
  }
  return null;
}
