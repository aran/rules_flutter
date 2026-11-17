/// The `devices` command: every device `flutter_bazel run -d` can run on, as
/// `flutter devices` lists them.
///
/// Upstream's output: the same columns (name and category, id, target
/// platform, SDK), attached and wireless devices under their own headings, the
/// same `--machine` JSON, `--device-timeout` and `--device-connection`. The id
/// column is the `-d` id, which here says what kind of device it is
/// (`android:<serial>`). The lookups are [DeviceDiscovery]'s, the ones a run
/// refusing an id asks.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'android_sdk.dart';
import 'bazel.dart';
import 'dev_tool_exception.dart';
import 'device_discovery.dart';
import 'shutdown_signals.dart';

class DevicesCommand {
  static final parser = ArgParser()
    ..addFlag(
      'machine',
      negatable: false,
      help: 'Print the devices as JSON, as `flutter devices --machine` does.',
    )
    ..addOption(
      'device-timeout',
      valueHelp: '${deviceLookupBound.inSeconds}',
      help:
          'Time in seconds each device lookup (simctl, devicectl, adb) may '
          'take. Longer timeouts may be necessary for networked devices.',
    )
    ..addOption(
      'device-connection',
      defaultsTo: 'both',
      allowed: ['attached', 'wireless', 'both'],
      allowedHelp: {
        'both': 'Lists both attached and wireless devices.',
        'attached':
            'Lists only devices connected by USB or built in (simulators, '
            'emulators, the desktop, Chrome).',
        'wireless': 'Lists only devices connected wirelessly.',
      },
      help: 'Which devices to list, by how they are connected.',
    )
    ..addMultiOption(
      'config',
      help:
          'Bazel config from the workspace .bazelrc, passed as '
          '--config=<name> to the build of the Android SDK\'s adb. Repeat for '
          'several.',
    )
    ..addMultiOption(
      'build-arg',
      splitCommas: false,
      help: 'Additional arguments for the build of the Android SDK\'s adb.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show help for this command.',
    );

  final ArgResults _results;

  DevicesCommand(this._results);

  Future<void> execute() async {
    final timeoutArg = _results['device-timeout'] as String?;
    final seconds = timeoutArg == null ? null : int.tryParse(timeoutArg);
    if (timeoutArg != null && (seconds == null || seconds <= 0)) {
      throw DevToolException(
        'Could not parse "--device-timeout" argument. It must be a positive '
        'integer.',
      );
    }
    final connection = switch (_results['device-connection'] as String) {
      'attached' => DeviceConnection.attached,
      'wireless' => DeviceConnection.wireless,
      _ => null,
    };
    final configs = _results['config'] as List<String>;

    final bazel = Bazel();
    // As `build` does: a first signal stops the adb build and waits for it, a
    // second exits at once.
    final handler = ShutdownSignalHandler(
      onShutdown: bazel.close,
      exitProcess: exit,
    );
    final subscriptions = [
      for (final signal in shutdownSignalsFor(isWindows: Platform.isWindows))
        handler.listen(signal.watch()),
    ];
    final String report;
    try {
      final workspace = await bazel.findWorkspaceRoot();
      final discovery = DeviceDiscovery(
        androidSdk: WorkspaceAndroidSdk(
          workspace: workspace,
          runBazel: bazel.run,
          configFlags: bazelConfigFlags(configs),
          // The options a `flutter_bazel run` with hot reload builds in but
          // its own flags, so that listing devices between two runs does not
          // throw away the analysis the next run's build reuses.
          buildFlags: [
            '-c',
            'dbg',
            ...devToolBazelFlags(
              configs: configs,
              buildArgs: _results['build-arg'] as List<String>,
            ),
          ],
        ),
        bound: seconds == null ? deviceLookupBound : Duration(seconds: seconds),
      );
      final (lookup, host) = await (
        discovery.lookUp(),
        discovery.hostDevices(),
      ).wait;
      report = devicesReport(
        lookup: lookup,
        host: host,
        connection: connection,
        machine: _results['machine'] as bool,
        timeoutGiven: seconds != null,
      );
    } on BazelCancelled {
      // The handler stopped it and exits once Bazel has.
      return;
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    stdout.write(report);
  }
}

/// The order devices are listed in: upstream's, phones first and the host
/// last.
const _kindOrder = [
  'android',
  'ios',
  'ios-simulator',
  'macos',
  'linux',
  'windows',
  'chrome',
];

/// What `flutter_bazel devices` prints for [lookup] and the [host]'s own
/// devices: only those [DiscoveredDevice.available], of [connection] (both
/// when null), as upstream's table or, with [machine], its JSON.
String devicesReport({
  required DeviceLookup lookup,
  required List<DiscoveredDevice> host,
  DeviceConnection? connection,
  bool machine = false,
  bool timeoutGiven = false,
}) {
  final listed = [
    for (final device in [...lookup.devices, ...host])
      if (device.available &&
          (connection == null || device.connection == connection))
        device,
  ]..sort((a, b) => _kindOrder.indexOf(a.kind) - _kindOrder.indexOf(b.kind));
  if (machine) {
    return '${const JsonEncoder.withIndent('  ').convert([for (final d in listed) d.toJson()])}\n';
  }

  final out = StringBuffer();
  final attached = [
    for (final d in listed)
      if (d.connection == DeviceConnection.attached) d,
  ];
  final wireless = [
    for (final d in listed)
      if (d.connection == DeviceConnection.wireless) d,
  ];
  if (listed.isEmpty) {
    out.writeln('No authorized devices detected.');
  }
  for (final (devices, how) in [
    (attached, 'connected'),
    (wireless, 'wirelessly connected'),
  ]) {
    if (devices.isEmpty) continue;
    if (identical(devices, wireless) && attached.isNotEmpty) out.writeln();
    out.writeln(
      'Found ${devices.length} $how device${devices.length == 1 ? '' : 's'}:',
    );
    for (final line in formatTable([for (final d in devices) d.row])) {
      out.writeln('  $line');
    }
  }

  final diagnostics = [
    for (final MapEntry(key: what, value: why) in lookup.unanswered.entries)
      '$what could not be asked for its devices: $why',
    if (lookup.androidAbsence case final absence?)
      'No Android devices are listed: $absence',
    for (final d in lookup.devices)
      if (d.kind == 'android' && !d.available)
        'The Android device ${d.answersTo.first} is ${d.state}, so it is not '
            'listed.',
  ];
  out.writeln();
  for (final diagnostic in diagnostics) {
    out
      ..writeln(diagnostic)
      ..writeln();
  }
  out.writeln(
    [
      'If you expected ${listed.isEmpty ? 'a' : 'another'} device to be '
          'detected, check that it is booted or attached and unlocked.',
      if (!timeoutGiven)
        'You may also try giving each lookup longer with the '
            '"--device-timeout" flag (${deviceLookupBound.inSeconds}s by '
            'default).',
    ].join(' '),
  );
  return out.toString();
}

/// [table]'s rows as lines, each column but the last padded to its widest
/// cell and the columns joined with ` • `, as upstream's `formatTable`.
List<String> formatTable(List<List<String>> table) {
  if (table.isEmpty) return const [];
  final widths = List.filled(table.first.length - 1, 0);
  for (final row in table) {
    for (var i = 0; i < widths.length; i++) {
      if (row[i].length > widths[i]) widths[i] = row[i].length;
    }
  }
  return [
    for (final row in table)
      [
        for (var i = 0; i < widths.length; i++) row[i].padRight(widths[i]),
        row.last,
      ].join(' • '),
  ];
}
