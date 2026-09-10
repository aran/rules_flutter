/// Runs `dart pub` from the pinned Flutter toolchain against the user's
/// workspace, so `pubspec.lock` is resolved by the SDK that will compile it.
///
/// Bazel consumes `pubspec.lock` but never produces one. Resolving it with a
/// separately installed Flutter — whatever version happens to be on `PATH` —
/// silently changes which versions get pinned, because pub's solver takes the
/// running Dart SDK's version and the Flutter SDK's version as constraints.
/// This binary removes that variable: the `dart` it runs is the toolchain's,
/// and `FLUTTER_ROOT` points at a tree assembled from the same Flutter tag.
///
/// Environment, set by the `flutter_pub` rule (runfiles-relative paths):
///   FLUTTER_PUB_DART              the toolchain's `dart` executable
///   FLUTTER_PUB_VERSION_MANIFEST  `bin/cache/flutter.version.json` inside the
///                                 assembled FLUTTER_ROOT
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Depth of `bin/cache/flutter.version.json` below the root it anchors.
const _manifestDepth = 3;

/// Entries whose absence means the tree cannot resolve a Flutter app's pubspec.
const _requiredEntries = <String>[
  'packages/flutter/pubspec.yaml',
  'bin/cache/pkg/sky_engine/pubspec.yaml',
];

const _usage =
    'Usage:\n'
    '  bazel run @rules_flutter//flutter:pub -- get\n'
    '  bazel run @rules_flutter//flutter:pub -- upgrade\n'
    '  bazel run @rules_flutter//flutter:pub -- add qr';

Never _fail(String message) {
  stderr.writeln('flutter:pub: $message');
  exit(1);
}

String _requireEnv(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    _fail('$name is not set; run this through `bazel run`.\n$_usage');
  }
  return value;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _fail('no pub command given.\n$_usage');
  }

  // `bazel run` sets this to the source tree. pub has to run there rather than
  // in the runfiles tree: `pubspec.lock` is a checked-in file.
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null || workspace.isEmpty) {
    _fail(
      'BUILD_WORKSPACE_DIRECTORY is not set. Use `bazel run`, not the '
      'built binary directly.\n$_usage',
    );
  }

  final runfiles = Runfiles.create();
  final dart = runfiles.rlocation(_requireEnv('FLUTTER_PUB_DART'));
  final manifest = runfiles.rlocation(
    _requireEnv('FLUTTER_PUB_VERSION_MANIFEST'),
  );

  var flutterRoot = File(manifest).absolute.parent;
  for (var i = 1; i < _manifestDepth; i++) {
    flutterRoot = flutterRoot.parent;
  }
  for (final entry in _requiredEntries) {
    if (!File('${flutterRoot.path}/$entry').existsSync()) {
      _fail(
        'the FLUTTER_ROOT assembled at ${flutterRoot.path} has no $entry, '
        'so pub cannot resolve `sdk: flutter` dependencies. The flutter '
        'tag layout may have changed — see '
        'flutter/private/flutter_dev_root_repo.bzl.',
      );
    }
  }

  stderr.writeln(
    'flutter:pub: resolving in $workspace with the pinned '
    'toolchain (FLUTTER_ROOT=${flutterRoot.path})',
  );

  final process = await Process.start(
    dart,
    ['pub', ...args],
    workingDirectory: workspace,
    environment: {'FLUTTER_ROOT': flutterRoot.path},
    mode: ProcessStartMode.inheritStdio,
  );
  exit(await process.exitCode);
}
