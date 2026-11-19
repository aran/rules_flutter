/// Checks one built `flutter_assets/` tree against an expectation file.
///
///     bundle_test <bundle> <expectation.json> [--prefix=P] [--platform=OS]
///                 [--flavor=F] [--subdir=D] [--allow-extra]
///                 [--unlisted=PATH]...
///
/// `<bundle>` and `<expectation.json>` are runfiles paths
/// (`$(rlocationpath ...)`). Exits non-zero, listing every difference, when the
/// tree is not the one `flutter build` would produce for those assets.
library;

import 'dart:io';

import 'package:asset_bundle_checks/bundle_check.dart';
import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  String resolve(String path) => runfiles.rlocation(path);

  final positional = args.where((a) => !a.startsWith('--')).toList();
  String? option(String name) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return null;
  }

  final subdir = option('subdir');
  final bundle = Directory(
    subdir == null
        ? resolve(positional[0])
        : '${resolve(positional[0])}/$subdir',
  );
  final expected = readExpectation(
    File(resolve(positional[1])),
    prefix: option('prefix') ?? '',
    platform: option('platform'),
    flavor: option('flavor'),
  );
  final problems = compare(
    bundle,
    expected,
    allowExtra: args.contains('--allow-extra'),
    unlisted: [
      for (final a in args)
        if (a.startsWith('--unlisted=')) a.substring('--unlisted='.length),
    ],
  );
  final fonts = readExpectedFonts(
    File(resolve(positional[1])),
    prefix: option('prefix') ?? '',
  );
  if (fonts != null) problems.addAll(compareFonts(bundle, fonts));
  if (problems.isNotEmpty) {
    stderr.writeln(
      'The bundle differs from what `flutter build` produces:\n'
      '  ${problems.join('\n  ')}',
    );
    exit(1);
  }
}
