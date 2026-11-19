/// The devices this host can run an app on, as `flutter_bazel devices` lists
/// them and as a refused `-d` id is looked up in.
///
/// One mechanism for both: the same lookups (`xcrun simctl`, `xcrun
/// devicectl`, the workspace's `adb`), concurrently, each under a bound, so a
/// tool that hangs is named as unanswered rather than holding the command up.
/// Desktop and Chrome are not looked up: the host is the desktop, and Chrome
/// is a file found on disk.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

import 'android_sdk.dart';
import 'child_processes.dart';
import 'dev_tool_exception.dart';
import 'device.dart';
import 'logging.dart';
import 'temp_dir.dart';

final _logger = Logger('dev_tool.device_discovery');

/// How long each lookup may take before it is killed, unless
/// `--device-timeout` says otherwise.
const deviceLookupBound = Duration(seconds: 3);

/// How a device is reached, as upstream's `--device-connection` splits them.
enum DeviceConnection { attached, wireless }

/// One device a lookup reported.
class DiscoveredDevice {
  /// The `-d` id that runs on it: `android:<serial>`, `ios:<udid>`,
  /// `ios-simulator:<udid>`, or a keyword for the host's own.
  final String id;

  /// Every bare id it answers to, which a refused `-d` is matched against.
  final Set<String> answersTo;

  /// The `-d` prefix or keyword of its kind.
  final String kind;

  /// Its name, as its own tool reports it.
  final String name;

  /// `desktop`, `mobile` or `web`, as upstream's categories.
  final String category;

  /// Upstream's target platform name: `darwin-arm64`, `ios`, `android-arm64`,
  /// `web-javascript`.
  final String targetPlatform;

  /// The OS or browser and its version.
  final String sdk;

  /// Whether it is an emulator or simulator on this host.
  final bool emulator;

  /// Whether rules_flutter builds for it.
  final bool supported;

  /// Whether it can be run on now: a booted simulator, an `adb` device in the
  /// `device` state. Only these are listed; the rest are what a refused id is
  /// still matched against, and their [state] says why.
  final bool available;

  /// Its state as its tool reports it (`Booted`, `Shutdown`, `unauthorized`,
  /// `wired`), for the refusal's sentence.
  final String state;

  final DeviceConnection connection;

  const DiscoveredDevice({
    required this.id,
    required this.answersTo,
    required this.kind,
    required this.name,
    required this.category,
    required this.targetPlatform,
    required this.sdk,
    required this.emulator,
    required this.supported,
    required this.available,
    required this.state,
    this.connection = DeviceConnection.attached,
  });

  /// What it is, for a sentence: "the iOS simulator 'iPhone 18 Pro' (Booted)".
  String get description {
    final what = switch (kind) {
      'ios-simulator' => 'the iOS simulator',
      'ios' => 'the iOS device',
      'android' => 'the Android device',
      _ => 'the device',
    };
    return "$what '$name' ($state)";
  }

  /// The row `flutter_bazel devices` prints, upstream's columns.
  List<String> get row => [
    '$name ($category)',
    id,
    targetPlatform,
    [
      sdk,
      if (!supported) '(unsupported)',
      if (emulator) kind == 'ios-simulator' ? '(simulator)' : '(emulator)',
    ].join(' '),
  ];

  /// Upstream's `flutter devices --machine` entry.
  Map<String, Object> toJson() => {
    'name': name,
    'id': id,
    'isSupported': supported,
    'targetPlatform': targetPlatform,
    'emulator': emulator,
    'sdk': sdk,
    'capabilities': {
      'hotReload': true,
      'hotRestart': true,
      'screenshot': true,
      // A web app has no `ext.flutter.exit` to call: its page is closed.
      'flutterExit': category != 'web',
      // Upstream's answer: an emulator renders with the host's GPU, an iOS
      // simulator does not.
      'hardwareRendering': emulator && kind != 'ios-simulator',
      'startPaused': true,
    },
  };
}

/// What the lookups found, and which of them could not answer.
class DeviceLookup {
  final List<DiscoveredDevice> devices;

  /// The lookups that answered, in the order they are listed in.
  final List<String> answered;

  /// The lookups that are missing, failed or timed out, with why.
  final Map<String, String> unanswered;

  /// Why Android devices are not looked up at all: the workspace has no
  /// Android SDK. Null when they are.
  final String? androidAbsence;

  const DeviceLookup(
    this.devices,
    this.answered,
    this.unanswered, {
    this.androidAbsence,
  });
}

/// A [ProcessRunSync] whose every command is killed after [bound].
ProcessRunSync boundedRunner(Duration bound) =>
    (executable, arguments) => runProcessBounded(
      (exe, args, env) => startChildProcess(exe, args, environment: env),
      executable,
      arguments,
      environment: Platform.environment,
      bound: bound,
      what: '`$executable ${arguments.join(' ')}`',
    );

/// Asks the host's device tools which devices they know.
class DeviceDiscovery {
  final AndroidSdk androidSdk;
  final ProcessRunSync _run;

  /// Whether to ask `simctl` and `devicectl`, which exist only on macOS.
  final bool appleHost;

  DeviceDiscovery({
    required this.androidSdk,
    ProcessRunSync? run,
    Duration bound = deviceLookupBound,
    bool? appleHost,
  }) : _run = run ?? boundedRunner(bound),
       appleHost = appleHost ?? Platform.isMacOS;

  /// Every simulator, iOS device and Android device the lookups report, in
  /// any state.
  Future<DeviceLookup> lookUp() async {
    final androidTools = await _androidTools();
    final found = await Future.wait<(String, List<DiscoveredDevice>?, String?)>(
      [
        if (appleHost) ...[
          _probe('simctl', _simulators),
          _probe('devicectl', _iosDevices),
        ],
        if (androidTools case final tools?)
          _probe('adb', () async {
            final (adb, failure) = tools;
            if (adb == null) throw failure!;
            return _androidDevices(adb);
          }),
      ],
    );
    return DeviceLookup(
      [for (final (_, list, _) in found) ...?list],
      [
        for (final (what, list, _) in found)
          if (list != null) what,
      ],
      {
        for (final (what, list, why) in found)
          if (list == null) what: why!,
      },
      androidAbsence: androidTools == null ? androidSdk.absence : null,
    );
  }

  /// The workspace's adb, or the failure building it, or null when the
  /// workspace has no Android SDK: then `adb` is neither asked nor counted
  /// as unanswered. One whose SDK could not be built is unanswered, as a tool
  /// that failed is.
  Future<(String?, Object?)?> _androidTools() async {
    try {
      final tools = await androidSdk.find();
      return tools == null ? null : (tools.adb, null);
    } on DevToolException catch (e) {
      return (null, e);
    }
  }

  Future<(String, List<DiscoveredDevice>?, String?)> _probe(
    String what,
    Future<List<DiscoveredDevice>> Function() body,
  ) async {
    try {
      return (what, await body(), null);
    } catch (e) {
      // Not swallowed: the caller names the lookup as unanswered, with this.
      _logger.fine({
        'message': 'device_lookup_failed',
        'text': 'Could not ask $what for its devices: $e',
        'lookup': what,
        'error': '$e',
      });
      return (what, null, '$e');
    }
  }

  Future<List<DiscoveredDevice>> _simulators() async {
    final result = await _run('xcrun', ['simctl', 'list', 'devices', '-j']);
    _requireSuccess(result, 'xcrun simctl list devices -j');
    return parseSimctlDevices(result.stdout as String);
  }

  Future<List<DiscoveredDevice>> _iosDevices() =>
      withTempDir('flutter_devid_', (dir) async {
        final jsonPath = p.join(dir.path, 'devices.json');
        final result = await _run('xcrun', [
          'devicectl',
          'list',
          'devices',
          '--json-output',
          jsonPath,
        ]);
        _requireSuccess(result, 'xcrun devicectl list devices');
        return [
          for (final info in parseDevicectlDevices(
            File(jsonPath).readAsStringSync(),
          ))
            iosDeviceFrom(info),
        ];
      });

  /// `adb devices -l`, and for each device ready to run on, its properties
  /// (`adb shell getprop`, one call), asked concurrently.
  Future<List<DiscoveredDevice>> _androidDevices(String adb) async {
    final result = await _run(adb, ['devices', '-l']);
    _requireSuccess(result, '$adb devices -l');
    final listed = parseAdbDevices(result.stdout as String);
    return Future.wait([
      for (final device in listed)
        if (device.state != 'device')
          Future.value(androidDeviceFrom(device, null))
        else
          _run(adb, ['-s', device.serial, 'shell', 'getprop']).then(
            (props) {
              _requireSuccess(props, '$adb -s ${device.serial} shell getprop');
              return androidDeviceFrom(
                device,
                parseAdbProperties(props.stdout as String),
              );
            },
          ),
    ]);
  }

  /// The host's own desktop, and Chrome when one is installed.
  Future<List<DiscoveredDevice>> hostDevices({String? chrome}) async {
    final desktop = await _desktop();
    final browser = chrome ?? findChrome();
    return [
      if (desktop != null) desktop,
      if (browser != null) await _chrome(browser),
    ];
  }

  Future<DiscoveredDevice?> _desktop() async {
    final (kind, name) = Platform.isMacOS
        ? ('macos', 'macOS')
        : Platform.isLinux
        ? ('linux', 'Linux')
        : Platform.isWindows
        ? ('windows', 'Windows')
        : (null, null);
    if (kind == null || name == null) return null;
    final platform = hostTargetPlatform();
    return DiscoveredDevice(
      id: kind,
      answersTo: {kind},
      kind: kind,
      name: name,
      category: 'desktop',
      targetPlatform: platform,
      sdk: '${await _osDescription()} $platform',
      emulator: false,
      supported: true,
      available: true,
      state: 'host',
    );
  }

  /// The host OS and its version, as upstream's desktop devices describe it.
  Future<String> _osDescription() async {
    if (Platform.isMacOS) {
      final fields = <String>[];
      for (final flag in ['-productName', '-productVersion', '-buildVersion']) {
        final result = await _run('sw_vers', [flag]);
        if (result.exitCode == 0) fields.add('${result.stdout}'.trim());
      }
      if (fields.isNotEmpty) return fields.join(' ');
    }
    if (Platform.isLinux) {
      final release = File('/etc/os-release');
      if (release.existsSync()) {
        final pretty = RegExp(
          r'^PRETTY_NAME="?([^"\n]*)"?$',
          multiLine: true,
        ).firstMatch(release.readAsStringSync());
        if (pretty != null) return pretty.group(1)!;
      }
    }
    return Platform.operatingSystemVersion;
  }

  Future<DiscoveredDevice> _chrome(String executable) async {
    var version = 'unknown';
    try {
      final result = await _run(executable, ['--version']);
      if (result.exitCode == 0) version = '${result.stdout}'.trim();
    } catch (e) {
      // The browser is listed all the same, as upstream lists it; only its
      // version is unknown.
      _logger.fine({
        'message': 'chrome_version_failed',
        'text': 'Could not ask $executable its version: $e',
        'error': '$e',
      });
    }
    return DiscoveredDevice(
      id: 'chrome',
      answersTo: const {'chrome'},
      kind: 'chrome',
      name: 'Chrome',
      category: 'web',
      targetPlatform: 'web-javascript',
      sdk: version,
      emulator: false,
      supported: true,
      available: true,
      state: 'installed',
    );
  }
}

void _requireSuccess(ProcessResult result, String command) {
  if (result.exitCode != 0) {
    throw StateError(
      '`$command` exited ${result.exitCode}: ${result.stderr}'.trim(),
    );
  }
}

/// Upstream's name for the host's own platform: `darwin-arm64`, `linux-x64`.
String hostTargetPlatform() => switch (Abi.current()) {
  Abi.macosArm64 => 'darwin-arm64',
  Abi.macosX64 => 'darwin-x64',
  Abi.linuxArm64 => 'linux-arm64',
  Abi.linuxX64 => 'linux-x64',
  Abi.windowsArm64 => 'windows-arm64',
  Abi.windowsX64 => 'windows-x64',
  final other => '$other',
};

/// The simulators `xcrun simctl list devices -j` lists, booted or not.
///
/// A booted one is [DiscoveredDevice.available], as upstream lists only those.
/// Its SDK is its runtime's identifier, as upstream shows it.
List<DiscoveredDevice> parseSimctlDevices(String jsonText) {
  final data = json.decode(jsonText) as Map<String, dynamic>;
  final runtimes = (data['devices'] as Map?) ?? const {};
  // rules_flutter builds the simulator for arm64 only.
  final supported = Abi.current() == Abi.macosArm64;
  return [
    for (final MapEntry(key: runtime, value: list) in runtimes.entries)
      for (final entry in (list as List).cast<Map<String, dynamic>>())
        if (entry['udid'] case final String udid)
          DiscoveredDevice(
            id: 'ios-simulator:$udid',
            answersTo: {udid},
            kind: 'ios-simulator',
            name: entry['name'] as String? ?? udid,
            category: 'mobile',
            targetPlatform: 'ios',
            sdk: '$runtime',
            emulator: true,
            supported: supported,
            available: entry['state'] == 'Booted',
            state: entry['state'] as String? ?? 'unknown',
          ),
  ];
}

/// [info] as a [DiscoveredDevice]: a device `devicectl` reports attached,
/// by cable or over the network.
DiscoveredDevice iosDeviceFrom(IOSDeviceInfo info) => DiscoveredDevice(
  id: 'ios:${info.udid}',
  answersTo: {info.udid, info.coreDeviceId},
  kind: 'ios',
  name: info.name,
  category: 'mobile',
  targetPlatform: 'ios',
  sdk: 'iOS ${info.osVersion ?? 'unknown version'}',
  emulator: false,
  supported: true,
  available: true,
  state: info.transport.name,
  connection: info.transport == IOSDeviceTransport.wireless
      ? DeviceConnection.wireless
      : DeviceConnection.attached,
);

/// One line of `adb devices -l`.
typedef AdbListing = ({String serial, String state, String? model});

/// The devices `adb devices -l` lists, in any state.
List<AdbListing> parseAdbDevices(String output) => [
  for (final line in const LineSplitter().convert(output))
    if (!line.startsWith('List of devices') &&
        // "* daemon started successfully"
        !line.startsWith('*'))
      if (line.trim().split(RegExp(r'\s+')) case [
        final serial,
        final state,
        ...final rest,
      ])
        (
          serial: serial,
          state: state,
          model: rest
              .where((f) => f.startsWith('model:'))
              .map((f) => f.substring('model:'.length))
              .firstOrNull,
        ),
];

/// The `[key]: [value]` lines of `adb shell getprop`.
Map<String, String> parseAdbProperties(String output) => {
  for (final match in RegExp(
    r'^\[([^\]]+)\]: \[(.*)\]\s*$',
    multiLine: true,
  ).allMatches(output))
    match.group(1)!: match.group(2)!,
};

/// [listed] as a [DiscoveredDevice], described by its [properties] when it
/// could be asked them.
///
/// Upstream's reading of them: its model is its name, an emulator says so in
/// `ro.hardware` (`ranchu`, `goldfish`) or `ro.build.characteristics`, and its
/// platform is the ABI an app is built for, the one `flutter_bazel run` asks
/// it.
DiscoveredDevice androidDeviceFrom(
  AdbListing listed,
  Map<String, String>? properties,
) {
  final props = properties ?? const <String, String>{};
  final model = (props['ro.product.model'] ?? listed.model ?? listed.serial)
      .replaceAll('_', ' ');
  String? abi;
  try {
    abi = androidAbiFromAbiList(
      props['ro.product.cpu.abilist'] ?? props['ro.product.cpu.abi'] ?? '',
      deviceName: listed.serial,
    );
  } on StateError {
    abi = null;
  }
  final hardware = props['ro.hardware'];
  final emulator = hardware == 'ranchu' || hardware == 'goldfish'
      ? true
      : (props['ro.build.characteristics'] ?? '').contains('emulator');
  final release = props['ro.build.version.release'];
  final api = props['ro.build.version.sdk'];
  return DiscoveredDevice(
    id: 'android:${listed.serial}',
    answersTo: {listed.serial},
    kind: 'android',
    name: model,
    category: 'mobile',
    targetPlatform: switch (abi) {
      'arm64-v8a' => 'android-arm64',
      'x86_64' => 'android-x64',
      'armeabi-v7a' => 'android-arm',
      _ => 'android-${props['ro.product.cpu.abi'] ?? 'unknown'}',
    },
    sdk: release == null ? 'Android' : 'Android $release (API $api)',
    emulator: emulator,
    supported: properties == null || abi != null,
    available: listed.state == 'device',
    state: listed.state,
    // A device paired over Wi-Fi is named for its mDNS service.
    connection: listed.serial.contains('adb-tls-connect')
        ? DeviceConnection.wireless
        : DeviceConnection.attached,
  );
}
