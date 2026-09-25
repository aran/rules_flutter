/// Turning the `-d` ids a user passes into [Device]s.
///
/// An id has to say what kind of device it names: a keyword (`macos`,
/// `ios-simulator`, `android`, ...) or a kind-prefixed form
/// (`ios-simulator:<udid>`, `ios:<udid>`, `android:<serial>`). Anything else is
/// refused rather than guessed at: a guess that picks the wrong kind sends the
/// id to the wrong tool, whose error names neither the id nor the flag, and
/// guessing right would mean asking `simctl`, `devicectl` and `adb` on every
/// launch. The prefix costs the user a few characters.
///
/// Refusing is where the tool may spend time: [resolveDevices] then asks those
/// same three tools, concurrently and each under a short bound, whether they
/// know the id, and says which prefix it needs. None of that runs when every id
/// resolves.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'dev_tool_exception.dart';
import 'device.dart';
import 'host_tools.dart';
import 'logging.dart';
import 'temp_dir.dart';

final _logger = Logger('dev_tool.device_id');

/// The ids `-d` accepts, as the refusal lists them.
const acceptedDeviceIdForms = [
  'macos',
  'linux',
  'windows',
  'chrome',
  'ios-simulator',
  'ios-simulator:<udid>',
  'ios',
  'ios:<udid>',
  'android',
  'android:<serial>',
];

/// How long each lookup on the refusal path may take before it is killed.
const deviceIdProbeBound = Duration(seconds: 3);

/// Resolve `-d` ids to [Device] instances.
///
/// With no [ids], one device for the current platform. Otherwise each id must
/// be one of [acceptedDeviceIdForms]; the prefixed forms name one device of
/// that kind, the bare keywords whichever one is booted or attached.
///
/// An id that names no kind throws a [DevToolException]. Only then are
/// `simctl`, `devicectl` and `adb` asked about it — through [runProbe], each
/// bounded by [deviceIdProbeBound] — so the message can give the exact form to
/// pass. [adbPath] overrides where `adb` is looked for.
Future<List<Device>> resolveDevices(
  List<String> ids, {
  ProcessRunSync? runProbe,
  String? adbPath,
}) async {
  if (ids.isEmpty) return [detectDevice()];
  final devices = <Device>[];
  final refused = <String>[];
  for (final id in ids) {
    final device = _resolveDevice(id);
    if (device == null) {
      refused.add(id);
    } else {
      devices.add(device);
    }
  }
  if (refused.isEmpty) return devices;
  final known = await _lookUpDevices(
    runProbe ?? _boundedRun,
    adbPath: adbPath,
  );
  throw DevToolException(
    [for (final id in refused) _explainRefusal(id, known)].join('\n\n'),
  );
}

/// The device [id] names, or null when it names no kind of device.
Device? _resolveDevice(String id) {
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
      return IOSDevice();
    // Whichever device `adb` itself picks, which is the one attached when there
    // is one and a named refusal from adb when there are several.
    case 'android':
      return AndroidDevice();
  }
  final colon = id.indexOf(':');
  if (colon < 0) return null;
  final kind = id.substring(0, colon);
  final rest = id.substring(colon + 1);
  final make = switch (kind) {
    'ios-simulator' => (String udid) => IOSSimulatorDevice(udid: udid),
    'ios' => (String udid) => IOSDevice(udid: udid),
    // The prefix is stripped, never passed on: a colon in `adb -s` means a
    // network device, so the server reads the serial as `android` and the rest
    // as a service name, and answers `unknown host service
    // '<serial>:features'` — a sentence naming neither the id nor the flag.
    'android' => (String serial) => AndroidDevice(deviceId: serial),
    _ => null,
  };
  if (make == null) return null;
  if (rest.isEmpty) {
    throw DevToolException(
      '-d $id names no device: put its id after the colon, or pass '
      '-d $kind for the one that is ${kind == 'ios-simulator' ? 'booted' : 'attached'}.',
    );
  }
  return make(rest);
}

/// A device one of the lookups reported, as the refusal describes it.
class KnownDevice {
  /// Every id it answers to.
  final Set<String> ids;

  /// The `-d` prefix that reaches it: `ios-simulator`, `ios` or `android`.
  final String kind;

  /// What it is, for a sentence: "the iOS simulator 'iPhone 18 Pro' (Booted)".
  final String description;

  const KnownDevice(this.ids, this.kind, this.description);
}

/// What the lookups found, and which of them could not answer.
class _Lookup {
  final List<KnownDevice> devices;

  /// The lookups that answered, in the order they are listed in.
  final List<String> answered;

  /// The lookups that are missing, failed or timed out, in the same order.
  final List<String> unanswered;

  const _Lookup(this.devices, this.answered, this.unanswered);
}

Future<ProcessResult> _boundedRun(String executable, List<String> arguments) =>
    runProcessBounded(
      (exe, args, env) => Process.start(exe, args, environment: env),
      executable,
      arguments,
      environment: Platform.environment,
      bound: deviceIdProbeBound,
      what: '`$executable ${arguments.join(' ')}`',
    );

Future<_Lookup> _lookUpDevices(ProcessRunSync run, {String? adbPath}) async {
  Future<(String, List<KnownDevice>?)> probe(
    String what,
    Future<List<KnownDevice>> Function() body,
  ) async {
    try {
      return (what, await body());
    } catch (e) {
      // Not swallowed: the refusal names the lookup as unanswered, and the
      // reason is here for anyone who asks for fine logs.
      _logger.fine({
        'message': 'device_id_lookup_failed',
        'text': 'Could not ask $what about the device id: $e',
        'lookup': what,
        'error': '$e',
      });
      return (what, null);
    }
  }

  final found = await Future.wait([
    probe('simctl', () async {
      final result = await run('xcrun', ['simctl', 'list', 'devices', '-j']);
      _requireSuccess(result, 'xcrun simctl list devices -j');
      return parseSimctlDevices(result.stdout as String);
    }),
    probe('devicectl', () async {
      return withTempDir('flutter_devid_', (dir) async {
        final jsonPath = p.join(dir.path, 'devices.json');
        final result = await run('xcrun', [
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
            KnownDevice(
              {info.udid, info.coreDeviceId},
              'ios',
              "the iOS device '${info.name}' (${info.transport.name})",
            ),
        ];
      });
    }),
    probe('adb', () async {
      final adb = adbPath ?? adbTool().find();
      if (adb == null) throw StateError('adb was not found');
      final result = await run(adb, ['devices', '-l']);
      _requireSuccess(result, '$adb devices -l');
      return parseAdbDevices(result.stdout as String);
    }),
  ]);
  return _Lookup(
    [for (final (_, list) in found) ...?list],
    [
      for (final (what, list) in found)
        if (list != null) what,
    ],
    [
      for (final (what, list) in found)
        if (list == null) what,
    ],
  );
}

void _requireSuccess(ProcessResult result, String command) {
  if (result.exitCode != 0) {
    throw StateError(
      '`$command` exited ${result.exitCode}: ${result.stderr}'.trim(),
    );
  }
}

/// The simulators `xcrun simctl list devices -j` lists, booted or not.
List<KnownDevice> parseSimctlDevices(String jsonText) {
  final data = json.decode(jsonText) as Map<String, dynamic>;
  final runtimes = (data['devices'] as Map?) ?? const {};
  return [
    for (final list in runtimes.values)
      for (final entry in (list as List).cast<Map<String, dynamic>>())
        if (entry['udid'] is String)
          KnownDevice(
            {entry['udid'] as String},
            'ios-simulator',
            "the iOS simulator '${entry['name'] ?? entry['udid']}'"
                "${entry['state'] is String ? ' (${entry['state']})' : ''}",
          ),
  ];
}

/// The devices `adb devices -l` lists, in any state.
List<KnownDevice> parseAdbDevices(String output) {
  final devices = <KnownDevice>[];
  for (final line in const LineSplitter().convert(output)) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 2 || line.startsWith('List of devices')) continue;
    if (line.startsWith('*')) continue; // "* daemon started successfully"
    final serial = fields[0];
    final state = fields[1];
    final model = fields
        .firstWhere((f) => f.startsWith('model:'), orElse: () => '')
        .replaceFirst('model:', '');
    devices.add(
      KnownDevice(
        {serial},
        'android',
        "the Android device '${model.isEmpty ? serial : model}' ($state)",
      ),
    );
  }
  return devices;
}

String _explainRefusal(String id, _Lookup lookup) {
  // A prefix with a typo in it is still worth looking up by what follows it.
  final colon = id.indexOf(':');
  final keys = {id, if (colon >= 0) id.substring(colon + 1)};
  final matches = [
    for (final device in lookup.devices)
      for (final key in keys)
        if (device.ids.contains(key)) (key: key, device: device),
  ];
  final head =
      '-d $id does not say what kind of device it is, so it is refused '
      'rather than guessed at.';
  if (matches.isNotEmpty) {
    return [
      head,
      for (final m in matches)
        '${m.key} is ${m.device.description}; pass -d ${m.device.kind}:${m.key}',
    ].join('\n');
  }
  final bare = keys.last;
  return [
    head,
    if (lookup.answered.isNotEmpty)
      'No device that ${lookup.answered.join(' or ')} lists has that id.',
    if (lookup.unanswered.isNotEmpty)
      '${lookup.unanswered.join(', ')} could not be asked '
          '(LOG_LEVEL=fine says why).',
    'For an Android serial pass -d android:$bare, for an iOS simulator '
        '-d ios-simulator:$bare, for an iOS device -d ios:$bare.',
    'Accepted forms: ${acceptedDeviceIdForms.join(', ')}.',
  ].join('\n');
}
