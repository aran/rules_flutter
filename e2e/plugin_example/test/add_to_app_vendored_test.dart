/// Verifies that an add-to-app module carries a prebuilt dynamic framework a
/// plugin links as it is, as `flutter build ios-framework` and
/// `macos-framework` copy a pod's vendored xcframework.
///
/// Usage: `add_to_app_vendored_test --platform=<ios|macos> TARGET XCFRAMEWORK`,
/// `TARGET` a `flutter_ios_xcframeworks` or `flutter_macos_xcframeworks` in
/// the test's runfiles built in release, whose plugin links `XCFRAMEWORK` (a
/// workspace path in the runfiles, its files as a glob of a vendored one
/// lists them).
///
/// Every file of the original is in the exported copy, byte for byte, and
/// nothing else; a versioned (macOS) framework has its links again
/// (`Versions/Current` and the entries at its top); the copy is a binary
/// target of the layout's Swift package; and each slice of the plugin's
/// framework links the framework rather than carrying its code.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/add_to_app.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

void main(List<String> args) {
  final platform = args.first.substring('--platform='.length);
  final [target, xcframeworkPath] = args.sublist(1);
  final original = requireRunfile(xcframeworkPath, what: 'xcframework');
  final name = xcframeworkPath.split('/').last.replaceAll('.xcframework', '');
  final release = '${exportXcframeworks(target)}/Release';
  final copy = '$release/$name.xcframework';
  final failures = <String>[];

  final originalFiles = _files(original);
  final copyFiles = _files(copy);
  final missing = originalFiles.keys.toSet().difference(copyFiles.keys.toSet());
  if (missing.isNotEmpty) failures.add('$copy lacks $missing');
  final extra = copyFiles.keys.toSet().difference(originalFiles.keys.toSet());
  if (extra.isNotEmpty) {
    failures.add('$copy has $extra, which the original does not');
  }
  for (final MapEntry(key: path, value: file) in originalFiles.entries) {
    final copied = copyFiles[path];
    if (copied == null) continue;
    final same = path.endsWith('Info.plist')
        ? _plist(file.path) == _plist(copied.path)
        : _sameBytes(file.readAsBytesSync(), copied.readAsBytesSync());
    if (!same) failures.add('$copy/$path differs from the original');
  }

  final package = File('$release/Package.swift').readAsStringSync();
  if (!package.contains(
    '.binaryTarget(name: "$name", path: "$name.xcframework")',
  )) {
    failures.add('Package.swift has no binary target of $name');
  }

  final slices = platform == 'ios'
      ? ['ios-arm64', 'ios-arm64-simulator']
      : ['macos-arm64'];
  for (final slice in slices) {
    if (platform == 'macos') {
      final framework = '$copy/$slice/$name.framework';
      for (final link in ['Versions/Current', name, 'Headers', 'Resources']) {
        if (!FileSystemEntity.isLinkSync('$framework/$link')) {
          failures.add('$framework/$link is not a link');
        }
      }
    }
    final binary = platform == 'ios'
        ? 'vendored_plugin.framework/vendored_plugin'
        : 'vendored_plugin.framework/Versions/A/vendored_plugin';
    final plugin = '$release/vendored_plugin.xcframework/$slice/$binary';
    final links = Process.runSync('otool', ['-L', plugin]).stdout.toString();
    if (!links.contains('@rpath/$name.framework/')) {
      failures.add('$plugin does not link $name.framework:\n$links');
    }
    if (MachO(plugin).definitionsOf('_vendored_greeting') != 0) {
      failures.add('$plugin carries $name');
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exit(1);
  }
  stdout.writeln('The module carries $name.xcframework as it is.');
}

/// Every file under [root], links followed, by its path relative to it.
Map<String, File> _files(String root) => {
  for (final entry in Directory(root).listSync(recursive: true))
    if (FileSystemEntity.isFileSync(entry.path))
      entry.path.substring(root.length + 1): File(entry.path),
};

/// The keys and values of the property list at [path], less the SDK build
/// rules_apple stamps it with, which differs between the configuration the
/// module builds the xcframework in and the test's.
String _plist(String path) => [
  for (final line in Process.runSync('plutil', [
    '-p',
    path,
  ]).stdout.toString().split('\n'))
    if (!line.contains('"DTPlatformBuild"') && !line.contains('"DTSDKBuild"'))
      line,
].join('\n');

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
