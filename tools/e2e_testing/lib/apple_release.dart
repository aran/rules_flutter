/// What a release Apple app must carry, checked on its built `App` binary.
///
/// `flutter build ios --release` and `flutter build macos --release` ship the
/// Dart snapshot (`App.framework/App`) with its local symbols and debugging map
/// removed, and leave a dSYM beside the app so crash reports symbolicate. These
/// checks hold a bazel-built bundle to that.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'bundle_check.dart';
import 'mach_o.dart';

/// Checks that the `App` binary at [path] is stripped: no local symbols (the
/// names of the Dart functions in it) and no debugging-map entries.
///
/// Its external symbols stay: the engine looks up the snapshot's data and
/// instructions through them.
void checkAppBinaryStripped(BundleCheck check, String path) {
  final SymbolCounts counts;
  try {
    counts = MachO(path).symbolCounts();
  } on StateError catch (e) {
    check.fail('cannot read the symbol table of $path: $e');
    return;
  }
  check
    ..expect(
      'App binary has no local symbols',
      condition: counts.local == 0,
      detail: 'it lists $counts, named after the app\'s Dart functions',
    )
    ..expect(
      'App binary has no debugging-map (stab) entries',
      condition: counts.stabs == 0,
      detail: 'it lists $counts',
    );
}

/// Checks that the `App` binary at [path] keeps its local symbols, as one
/// built with `--no-strip` in `extra_gen_snapshot_options` does.
///
/// The counterpart of [checkAppBinaryStripped]: a build asked not to strip
/// must not be stripped anyway.
void checkAppBinaryKeepsSymbols(BundleCheck check, String path) {
  final SymbolCounts counts;
  try {
    counts = MachO(path).symbolCounts();
  } on StateError catch (e) {
    check.fail('cannot read the symbol table of $path: $e');
    return;
  }
  check.expect(
    'App binary keeps its local symbols',
    condition: counts.local > 0,
    detail: 'it lists $counts, so something stripped it',
  );
}

/// Checks that the `App` binary at [path] has the install name `flutter build`
/// gives it, `@rpath/App.framework/App`.
///
/// A host app that links `App.framework` records the install name and the
/// dynamic linker resolves it through the app's rpaths; a build-tree path
/// there fails at launch.
void checkAppInstallName(BundleCheck check, String path) {
  final String name;
  try {
    name = MachO(path).installName();
  } on StateError catch (e) {
    check.fail('cannot read the install name of $path: $e');
    return;
  }
  check.expect(
    'App binary install name is @rpath/App.framework/App',
    condition: name == '@rpath/App.framework/App',
    detail: 'it is $name',
  );
}

/// The one `App.framework/App` among the test's runfiles, whatever the target
/// that produced it.
///
/// Exits 1 unless there is exactly one.
String runfilesAppBinary() {
  final root = Directory(Runfiles.create().rlocation('_main'));
  final found = [
    if (root.existsSync())
      for (final entity in root.listSync(recursive: true, followLinks: false))
        if (entity.path.endsWith('/App.framework/App')) entity.path,
  ];
  if (found.length != 1) {
    stderr.writeln('expected one App.framework/App in the runfiles: $found');
    exit(1);
  }
  return found.single;
}

/// Every `.dSYM` bundle among the test's runfiles, whatever the target that
/// produced it or the repository it came from (an imported framework's dSYM
/// is a file of the repository that holds the framework).
List<String> runfilesDsyms() {
  final root = Directory(Runfiles.create().rlocation('_main')).parent;
  if (!root.existsSync()) return const [];
  return [
    for (final entity in root.listSync(recursive: true, followLinks: false))
      if (entity.path.endsWith('.dSYM')) entity.path,
  ];
}

/// Checks that one of [dsyms] holds debug info for the binary at [path]:
/// its UUID is the binary's. A crash report names the UUID of the binary that
/// crashed, and a dSYM of another UUID does not symbolicate it.
void checkDsymMatches(BundleCheck check, String path, List<String> dsyms) {
  final Set<String> binaryUuids;
  try {
    binaryUuids = MachO(path).uuids();
  } on StateError catch (e) {
    check.fail('cannot read the UUID of $path: $e');
    return;
  }
  if (binaryUuids.isEmpty) {
    check.fail('$path carries no LC_UUID, so no dSYM can match it');
    return;
  }
  final found = <String, Set<String>>{};
  for (final dsym in dsyms) {
    try {
      found[dsym] = MachO(dsym).uuids();
    } on StateError {
      found[dsym] = {};
    }
  }
  check.expect(
    'a dSYM matches ${path.split('/').last} (UUID ${binaryUuids.join(', ')})',
    condition: found.values.any((uuids) => uuids.containsAll(binaryUuids)),
    detail: dsyms.isEmpty
        ? 'the build produced no dSYM'
        : 'dSYMs found: $found',
  );
}
