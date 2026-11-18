/// Verifies that each add-to-app module's audio_session framework carries the
/// code its `Package.swift` selects for the module.
///
/// Usage: `add_to_app_microphone_test TARGET=BOOL...`, each `TARGET` a
/// `flutter_ios_xcframeworks` in the test's runfiles, built in debug, and
/// `BOOL` whether its audio_session carries the record permission code.
/// `audio_session` 0.1.x compiles that code in unless
/// `AUDIO_SESSION_MICROPHONE` is 0 in the manifest's environment, which a
/// module sets in `swift_package_environment`.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/add_to_app.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';

const _recordPermission = '-[DarwinAudioSession flutterToRecordPermission:]';

void main(List<String> args) {
  final failures = <String>[];
  for (final arg in args) {
    final [target, expected] = arg.split('=');
    final microphone = expected == 'true';
    final binaries = _audioSessionBinaries(exportXcframeworks(target));
    if (binaries.isEmpty) {
      failures.add('$target has no audio_session framework binary');
      continue;
    }
    for (final binary in binaries) {
      final machO = MachO(binary);
      if (!machO.hasSymbolContaining('DarwinAudioSession')) {
        failures.add('$binary does not carry audio_session');
      } else if (machO.hasSymbolContaining(_recordPermission) != microphone) {
        failures.add(
          "$binary ${microphone ? 'leaves out' : 'carries'} audio_session's "
          'record permission code',
        );
      }
    }
  }
  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exit(1);
  }
  stdout.writeln(
    'Each module carries the audio_session code its manifest selects.',
  );
}

/// The binary of each slice of `Debug/audio_session.xcframework` in the
/// exported layout at [layout].
List<String> _audioSessionBinaries(String layout) {
  final xcframework = Directory('$layout/Debug/audio_session.xcframework');
  if (!xcframework.existsSync()) return [];
  return [
    for (final entry in xcframework.listSync(
      recursive: true,
      followLinks: false,
    ))
      if (entry is File && entry.uri.pathSegments.last == 'audio_session')
        entry.path,
  ];
}
