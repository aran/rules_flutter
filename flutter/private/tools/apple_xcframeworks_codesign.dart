/// Signs the xcframeworks of an add-to-app layout, as `flutter build
/// ios-framework` and `macos-framework` sign theirs.
///
/// Usage:
///   dart apple_xcframeworks_codesign.dart --input <layout> --output <layout>
///       --identity <identity> --mode <Debug|Profile|Release>
///
/// Each `<Mode>/<name>.xcframework` is signed with `codesign --force --sign
/// <identity>`, with `--timestamp=none` but in release, as upstream signs it.
/// An xcframework already signed keeps its signature: Flutter's own engine,
/// which upstream re-signs only when it is unsigned, and a prebuilt one a
/// plugin links, which upstream copies as it is. The identity `-` signs ad
/// hoc; any other must be a valid code-signing identity in the keychain.
///
/// A versioned (macOS) framework is signed with its links, made here, and
/// written out without them, as every directory artifact of these rules holds
/// it (`apple_frameworks.dart`); the export makes the same links again, so the
/// signature holds.
library;

import 'dart:io';

import 'apple_frameworks.dart' show copyBundle;
import 'assemble_directory.dart' show copyFile;

const _usage =
    'usage: apple_xcframeworks_codesign.dart --input <layout> --output <layout> '
    '--identity <identity> --mode <Debug|Profile|Release>';

/// Whether `codesign` finds a signature on [path].
bool isSigned(String path) {
  final result = Process.runSync('codesign', ['-d', path]);
  return !result.stderr.toString().contains('not signed at all');
}

/// The `codesign` arguments that sign [path] as upstream does in [mode].
List<String> codesignArguments(String path, String identity, String mode) => [
  '--force',
  '--sign',
  identity,
  if (mode != 'Release') '--timestamp=none',
  path,
];

void _copy(Directory source, Directory destination, {required bool link}) {
  destination.createSync(recursive: true);
  for (final entry in source.listSync()) {
    final name = entry.path.split('/').last;
    if (entry is Directory) {
      copyBundle(entry, Directory('${destination.path}/$name'), link: link);
    } else {
      copyFile(File(entry.path), '${destination.path}/$name');
    }
  }
}

int run(List<String> args) {
  final values = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    values[args[i]] = args[i + 1];
  }
  final input = values['--input'];
  final output = values['--output'];
  final identity = values['--identity'];
  final mode = values['--mode'];
  if (input == null ||
      output == null ||
      identity == null ||
      mode == null ||
      args.length != 8) {
    stderr.writeln(_usage);
    return 64;
  }
  if (identity != '-') {
    final found = Process.runSync('security', [
      'find-identity',
      '-v',
      '-p',
      'codesigning',
    ]).stdout.toString();
    if (!found.contains(identity)) {
      stderr.writeln(
        'The code-signing identity "$identity" is not in the keychain. '
        'Its valid identities:\n$found',
      );
      return 1;
    }
  }
  final work = Directory.systemTemp.createTempSync('xcframeworks_codesign');
  try {
    _copy(Directory(input), work, link: true);
    final modeDirectory = Directory('${work.path}/$mode');
    for (final xcframework
        in modeDirectory.listSync()..sort((a, b) => a.path.compareTo(b.path))) {
      if (!xcframework.path.endsWith('.xcframework')) continue;
      final name = xcframework.path.split('/').last;
      // The xcframeworks these rules build are unsigned, so one already
      // signed came prebuilt: Flutter's engine, or a plugin's vendored one.
      if (isSigned(xcframework.path)) continue;
      // Copies are read-only, as Bazel's outputs are.
      Process.runSync('chmod', ['-R', 'u+w', xcframework.path]);
      final result = Process.runSync(
        'codesign',
        codesignArguments(xcframework.path, identity, mode),
      );
      if (result.exitCode != 0) {
        stderr.writeln('Unable to codesign $name: ${result.stderr}');
        return 1;
      }
    }
    _copy(work, Directory(output), link: false);
  } finally {
    Process.runSync('chmod', ['-R', 'u+w', work.path]);
    work.deleteSync(recursive: true);
  }
  return 0;
}

void main(List<String> args) {
  exitCode = run(args);
}
