/// Checks the `NOTICES` asset of one built `flutter_assets/` tree the way the
/// framework reads it.
///
///     notices_test <bundle> [--web] [--subdir=D] [--own-license=PATH
///                  --package=NAME] [--additional=PATH]...
///                  [--fixtures=PATH] [--absent=NAME]...
///
/// The framework loads `NOTICES` on the web (as the UTF-8 text it is) and
/// `NOTICES.Z` (gzip) everywhere else, and splits the text into entries as
/// `packages/flutter/lib/src/services/binding.dart` (`_parseLicenses`) does.
/// flutter_tools writes the entries sorted, then the files a pubspec's
/// `flutter: licenses:` lists as they are, and lists the engine's licences
/// under `sky_engine`. The engine's text is not compared (it changes with the
/// Flutter version); that it is there is.
///
/// `--fixtures` is the text the entries made only of `fx_` packages make: each
/// package of the program's closure is named by its `NOTICES` or `LICENSE`, one
/// text shared by two packages is one entry, and the lock's other packages
/// (`--absent`) are not listed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

typedef Entry = ({List<String> names, String text});

final separator = '\n${'-' * 80}\n';

/// The entries of [raw], as `_parseLicenses` makes them.
List<Entry> parse(List<String> components) => [
  for (final license in components)
    if (license.indexOf('\n\n') case final split when split >= 0)
      (
        names: license.substring(0, split).split('\n'),
        text: license.substring(split + 2),
      )
    else
      (names: <String>[], text: license),
];

void main(List<String> args) {
  final runfiles = Runfiles.create();
  String resolve(String path) => runfiles.rlocation(path);
  List<String> options(String name) => [
    for (final a in args)
      if (a.startsWith('--$name=')) a.substring(name.length + 3),
  ];

  final web = args.contains('--web');
  final key = web ? 'NOTICES' : 'NOTICES.Z';
  final otherKey = web ? 'NOTICES.Z' : 'NOTICES';
  final subdir = options('subdir');
  final bundle = Directory(
    [
      resolve(args.firstWhere((a) => !a.startsWith('--'))),
      ...subdir,
    ].join('/'),
  );
  final problems = <String>[];

  final file = File('${bundle.path}/$key');
  if (!file.existsSync()) {
    stderr.writeln('$key is not in the bundle');
    exit(1);
  }
  if (File('${bundle.path}/$otherKey').existsSync()) {
    problems.add('$otherKey is in the bundle too');
  }

  final bytes = file.readAsBytesSync();
  final components = utf8
      .decode(web ? bytes : gzip.decode(bytes))
      .split(
        separator,
      );
  final entries = parse(components);

  // The engine's licences are entries of their own, naming what they cover.
  if (entries.length < 1000) {
    problems.add(
      'only ${entries.length} entries; the engine alone has over 1000',
    );
  }
  if (!entries.any((e) => e.names.contains('skia'))) {
    problems.add('no entry names skia');
  }

  // After the sorted entries come the additional files, untouched.
  final additional = [
    for (final p in options('additional')) File(resolve(p)).readAsStringSync(),
  ];
  final merged = components.length - additional.length;
  final sortedPart = components.sublist(0, merged);
  final resorted = [...sortedPart]..sort();
  for (var i = 0; i < sortedPart.length; i++) {
    if (sortedPart[i] != resorted[i]) {
      problems.add(
        'entry $i is out of order: ${sortedPart[i].split('\n').first}',
      );
      break;
    }
  }
  if (additional.join(separator) !=
      components.sublist(merged).join(separator)) {
    problems.add(
      'the file does not end with the additional licences as listed',
    );
  }

  final fixtures = options('fixtures');
  if (fixtures.isNotEmpty) {
    final wanted = File(resolve(fixtures.single)).readAsStringSync();
    final found = [
      for (final e in entries.sublist(0, merged))
        if (e.names.isNotEmpty && e.names.every((n) => n.startsWith('fx_')))
          '${e.names.join('\n')}\n\n${e.text}',
    ].join(separator);
    if (found != wanted) {
      problems.add(
        'the fixture entries are not the expected ones.\n'
        '--- expected\n$wanted\n--- found\n$found',
      );
    }
  }
  for (final name in options('absent')) {
    if (entries.any((e) => e.names.contains(name))) {
      problems.add('$name is listed, but the program does not depend on it');
    }
  }

  final own = options('own-license');
  if (own.isNotEmpty) {
    final name = options('package').single;
    final text = File(resolve(own.single)).readAsStringSync();
    final owned = [
      for (final e in entries.sublist(0, merged))
        if (e.names.length == 1 && e.names.single == name && e.text == text) e,
    ];
    if (owned.length != 1) {
      problems.add(
        'expected one entry for $name with its LICENSE, found ${owned.length}',
      );
    }
  }

  if (problems.isNotEmpty) {
    stderr.writeln(
      'NOTICES is not what flutter build writes:\n  ${problems.join('\n  ')}',
    );
    exit(1);
  }
}
