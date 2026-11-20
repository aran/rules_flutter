// A release bundle, native or web, carries the asset the app's own package's
// link hook wrote from the motto in the app's own `lib/`, though no library of
// that package is in the app's `deps`. A debug bundle (`--debug`) runs no hook
// and carries none.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const _motto = 'linked by own_hook';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final debug = args.contains('--debug');
  final bundles = <String>[
    for (final path in args.where((a) => a != '--debug'))
      if (path.endsWith('_flutter_assets'))
        runfiles.rlocation(path)
      else if (path.endsWith('_web'))
        '${runfiles.rlocation(path)}/assets',
  ];
  if (bundles.length != 2) {
    throw StateError('want the native assets and a web bundle, got $bundles');
  }
  for (final bundle in bundles) {
    final linked = File('$bundle/packages/own_hook/motto.txt');
    if (debug) {
      if (linked.existsSync()) {
        throw StateError('a debug bundle has ${linked.path}');
      }
    } else if (linked.readAsStringSync() != _motto) {
      throw StateError('${linked.path} does not hold the motto');
    }
  }
}
