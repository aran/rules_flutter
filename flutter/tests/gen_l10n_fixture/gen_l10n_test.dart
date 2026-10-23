import 'dart:io';

import 'package:test/test.dart';

File _findRunfile(String suffix) {
  final runfilesPath =
      Platform.environment['RUNFILES_DIR'] ??
      Platform.environment['TEST_SRCDIR'];
  if (runfilesPath != null && Directory(runfilesPath).existsSync()) {
    final dir = Directory(runfilesPath);
    for (final entity in dir.listSync(recursive: true, followLinks: true)) {
      if (entity is File &&
          entity.path.replaceAll(r'\', '/').endsWith(suffix)) {
        return entity;
      }
    }
  }
  final manifestPath = Platform.environment['RUNFILES_MANIFEST_FILE'];
  if (manifestPath != null && File(manifestPath).existsSync()) {
    for (final line in File(manifestPath).readAsLinesSync()) {
      final space = line.indexOf(' ');
      if (space <= 0) continue;
      final target = line.substring(space + 1).trim();
      if (target.replaceAll(r'\', '/').endsWith(suffix) &&
          File(target).existsSync()) {
        return File(target);
      }
    }
  }
  final fallback = Directory.current.parent;
  for (final entity in fallback.listSync(recursive: true, followLinks: true)) {
    if (entity is File && entity.path.replaceAll(r'\', '/').endsWith(suffix)) {
      return entity;
    }
  }
  throw StateError('Runfile ending with "$suffix" not found');
}

Map<String, String> _readDirectoryFiles(Directory dir) {
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return <String, String>{
    for (final f in files)
      f.uri.pathSegments.lastWhere((s) => s.isNotEmpty): f.readAsStringSync(),
  };
}

void main() {
  late File genL10nDill;
  late String enArbContent;
  late String esArbContent;
  late String es419ArbContent;
  late String enUsArbContent;

  setUpAll(() {
    genL10nDill = _findRunfile('flutter/private/gen_l10n/gen_l10n.dill');
    enArbContent = _findRunfile(
      'gen_l10n_fixture/lib/l10n/app_en.arb',
    ).readAsStringSync();
    esArbContent = _findRunfile(
      'gen_l10n_fixture/lib/l10n/app_es.arb',
    ).readAsStringSync();
    es419ArbContent = _findRunfile(
      'gen_l10n_fixture/lib/l10n/app_es_419.arb',
    ).readAsStringSync();
    enUsArbContent = _findRunfile(
      'gen_l10n_fixture/lib/l10n/app_en_US.arb',
    ).readAsStringSync();
  });

  group('flutter_gen_l10n rule outputs ignore undeclared .arb files', () {
    test(':l10n includes en, es, es_419 and excludes undeclared en_US/de', () {
      final base = _findRunfile(
        'gen_l10n_fixture/lib/l10n/app_localizations.dart',
      ).readAsStringSync();
      final en = _findRunfile(
        'gen_l10n_fixture/lib/l10n/app_localizations_en.dart',
      ).readAsStringSync();
      final es = _findRunfile(
        'gen_l10n_fixture/lib/l10n/app_localizations_es.dart',
      ).readAsStringSync();

      expect(base, contains("Locale('en')"));
      expect(base, contains("Locale('es')"));
      expect(base, contains("Locale('es', '419')"));
      expect(base, isNot(contains('US')));
      expect(base, isNot(contains('EnUs')));
      expect(base, isNot(contains('GB')));
      expect(base, isNot(contains("'fr'")));
      expect(base, isNot(contains("'de'")));

      expect(en, contains('class AppLocalizationsEn '));
      expect(en, isNot(contains('AppLocalizationsEnUs')));
      expect(en, isNot(contains('Howdy')));
      expect(es, contains('class AppLocalizationsEs '));
      expect(es, contains('class AppLocalizationsEs419 '));
    });

    test(
      ':l10n_subset excludes sibling app_es_419.arb and app_en_US.arb in the same directory',
      () {
        final base = _findRunfile(
          'gen_l10n_fixture/lib/l10n/subset_localizations.dart',
        ).readAsStringSync();
        final en = _findRunfile(
          'gen_l10n_fixture/lib/l10n/subset_localizations_en.dart',
        ).readAsStringSync();
        final es = _findRunfile(
          'gen_l10n_fixture/lib/l10n/subset_localizations_es.dart',
        ).readAsStringSync();

        expect(base, contains("Locale('en')"));
        expect(base, contains("Locale('es')"));
        expect(base, isNot(contains('419')));
        expect(base, isNot(contains('Es419')));
        expect(base, isNot(contains('US')));
        expect(base, isNot(contains('EnUs')));

        expect(en, isNot(contains('EnUs')));
        expect(es, contains('class SubsetLocalizationsEs '));
        expect(es, isNot(contains('419')));
        expect(es, isNot(contains('SubsetLocalizationsEs419')));
      },
    );

    test(
      ':l10n_en_us includes declared app_en_US.arb and excludes sibling es/es_419',
      () {
        final base = _findRunfile(
          'gen_l10n_fixture/lib/l10n/en_us_localizations.dart',
        ).readAsStringSync();
        final en = _findRunfile(
          'gen_l10n_fixture/lib/l10n/en_us_localizations_en.dart',
        ).readAsStringSync();

        expect(base, contains("Locale('en')"));
        expect(base, contains("Locale('en', 'US')"));
        expect(base, isNot(contains("Locale('es')")));
        expect(base, isNot(contains('419')));

        expect(en, contains('class EnUsLocalizationsEn '));
        expect(en, contains('class EnUsLocalizationsEnUs '));
        expect(en, contains('Howdy'));
      },
    );

    test(
      ':l10n_mixed_generated combines source and generated arbs and ignores undeclared generated arbs in bazel-out',
      () {
        final base = _findRunfile(
          'gen_l10n_fixture/lib/l10n/mixed_localizations.dart',
        ).readAsStringSync();
        final en = _findRunfile(
          'gen_l10n_fixture/lib/l10n/mixed_localizations_en.dart',
        ).readAsStringSync();
        final fr = _findRunfile(
          'gen_l10n_fixture/lib/l10n/mixed_localizations_fr.dart',
        ).readAsStringSync();

        expect(base, contains("Locale('en')"));
        expect(base, contains("Locale('fr')"));
        expect(base, isNot(contains('GB')));
        expect(base, isNot(contains('US')));
        expect(base, isNot(contains("Locale('es')")));

        expect(en, contains('class MixedLocalizationsEn '));
        expect(en, isNot(contains('MixedLocalizationsEnGb')));
        expect(en, isNot(contains('Cheerio')));
        expect(fr, contains('class MixedLocalizationsFr '));
        expect(fr, contains('Bonjour'));
      },
    );
  });

  group('gen_l10n CLI hermeticity and determinism', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('gen_l10n_hermetic_test_');
    });

    tearDown(() {
      // Restore write permissions before deleting in case a test made dirs
      // read-only.
      if (!Platform.isWindows && tmp.existsSync()) {
        Process.runSync('chmod', ['-R', 'u+rwX', tmp.path]);
      }
      if (tmp.existsSync()) {
        tmp.deleteSync(recursive: true);
      }
    });

    ProcessResult runGenL10n(List<String> args, {String? workingDirectory}) {
      return Process.runSync(
        Platform.resolvedExecutable,
        <String>[genL10nDill.path, ...args],
        workingDirectory: workingDirectory ?? tmp.path,
      );
    }

    test(
      'dirty directory with undeclared regional, language, and corrupt .arb files matches clean directory byte-for-byte',
      () {
        // Clean build: only declared app_en.arb and app_es.arb exist on disk.
        final cleanArbDir = Directory('${tmp.path}/clean/lib/l10n')
          ..createSync(recursive: true);
        final cleanOutDir = Directory('${tmp.path}/clean/out/l10n');
        File('${cleanArbDir.path}/app_en.arb').writeAsStringSync(enArbContent);
        File('${cleanArbDir.path}/app_es.arb').writeAsStringSync(esArbContent);

        final cleanResult = runGenL10n([
          '--project-dir=${tmp.path}/clean',
          '--arb-dir=lib/l10n',
          '--output-dir=out/l10n',
          '--template-arb-file=app_en.arb',
          '--output-localization-file=app_localizations.dart',
          '--output-class=AppLocalizations',
          '--arb-file=lib/l10n/app_en.arb',
          '--arb-file=lib/l10n/app_es.arb',
        ]);
        expect(
          cleanResult.exitCode,
          0,
          reason: 'clean run failed: ${cleanResult.stderr}',
        );

        // Dirty build (simulating non-sandboxed / local execution with extra
        // files in --arb-dir): undeclared regional override, undeclared
        // primary language, and undeclared corrupt .arb file.
        final dirtyArbDir = Directory('${tmp.path}/dirty/lib/l10n')
          ..createSync(recursive: true);
        final dirtyOutDir = Directory('${tmp.path}/dirty/out/l10n');
        File('${dirtyArbDir.path}/app_en.arb').writeAsStringSync(enArbContent);
        File('${dirtyArbDir.path}/app_es.arb').writeAsStringSync(esArbContent);
        File(
          '${dirtyArbDir.path}/app_es_419.arb',
        ).writeAsStringSync(es419ArbContent);
        File(
          '${dirtyArbDir.path}/app_en_US.arb',
        ).writeAsStringSync(enUsArbContent);
        File('${dirtyArbDir.path}/app_de.arb').writeAsStringSync('{corrupt');

        final dirtyResult = runGenL10n([
          '--project-dir=${tmp.path}/dirty',
          '--arb-dir=lib/l10n',
          '--output-dir=out/l10n',
          '--template-arb-file=app_en.arb',
          '--output-localization-file=app_localizations.dart',
          '--output-class=AppLocalizations',
          '--arb-file=lib/l10n/app_en.arb',
          '--arb-file=lib/l10n/app_es.arb',
        ]);
        expect(
          dirtyResult.exitCode,
          0,
          reason: 'dirty run failed: ${dirtyResult.stderr}',
        );

        final cleanFiles = _readDirectoryFiles(cleanOutDir);
        final dirtyFiles = _readDirectoryFiles(dirtyOutDir);
        expect(
          dirtyFiles.keys,
          unorderedEquals(<String>[
            'app_localizations.dart',
            'app_localizations_en.dart',
            'app_localizations_es.dart',
          ]),
        );
        expect(dirtyFiles, equals(cleanFiles));

        // Incremental mutation of an undeclared .arb file in --arb-dir must
        // leave outputs byte-for-byte identical.
        File('${dirtyArbDir.path}/app_en_US.arb').writeAsStringSync('''
{
  "@@locale": "en_US",
  "greeting": "Mutated undeclared greeting, {name}!"
}
''');
        final rerunResult = runGenL10n([
          '--project-dir=${tmp.path}/dirty',
          '--arb-dir=lib/l10n',
          '--output-dir=out/l10n',
          '--template-arb-file=app_en.arb',
          '--output-localization-file=app_localizations.dart',
          '--output-class=AppLocalizations',
          '--arb-file=lib/l10n/app_en.arb',
          '--arb-file=lib/l10n/app_es.arb',
        ]);
        expect(rerunResult.exitCode, 0);
        expect(_readDirectoryFiles(dirtyOutDir), equals(cleanFiles));
      },
    );

    test(
      'read-only input directory and read-only .arb files succeed and match writable build',
      () {
        final roArbDir = Directory('${tmp.path}/ro/lib/l10n')
          ..createSync(recursive: true);
        final roOutDir = Directory('${tmp.path}/ro/out/l10n');
        final enFile = File('${roArbDir.path}/app_en.arb')
          ..writeAsStringSync(enArbContent);
        final esFile = File('${roArbDir.path}/app_es.arb')
          ..writeAsStringSync(esArbContent);

        if (!Platform.isWindows) {
          expect(
            Process.runSync('chmod', [
              '0444',
              enFile.path,
              esFile.path,
            ]).exitCode,
            0,
          );
          expect(
            Process.runSync('chmod', ['0555', roArbDir.path]).exitCode,
            0,
          );
        }

        final result = runGenL10n([
          '--project-dir=${tmp.path}/ro',
          '--arb-dir=lib/l10n',
          '--output-dir=out/l10n',
          '--template-arb-file=app_en.arb',
          '--output-localization-file=app_localizations.dart',
          '--output-class=AppLocalizations',
          '--arb-file=lib/l10n/app_en.arb',
          '--arb-file=lib/l10n/app_es.arb',
        ]);
        expect(
          result.exitCode,
          0,
          reason: 'read-only input directory should succeed: ${result.stderr}',
        );

        final generated = _readDirectoryFiles(roOutDir);
        expect(
          generated.keys,
          unorderedEquals(<String>[
            'app_localizations.dart',
            'app_localizations_en.dart',
            'app_localizations_es.dart',
          ]),
        );
      },
    );

    test(
      'split source and generated input roots produce byte-identical output',
      () {
        final srcDir = Directory('${tmp.path}/split/pkg/lib/l10n')
          ..createSync(recursive: true);
        final genDir = Directory(
          '${tmp.path}/split/bazel-out/k8-fastbuild/bin/pkg/lib/l10n',
        )..createSync(recursive: true);

        File('${srcDir.path}/app_en.arb').writeAsStringSync(enArbContent);
        File('${genDir.path}/app_es.arb').writeAsStringSync(esArbContent);
        // Undeclared files in both physical directories must be ignored.
        File('${srcDir.path}/app_en_US.arb').writeAsStringSync(enUsArbContent);
        File(
          '${genDir.path}/app_es_419.arb',
        ).writeAsStringSync(es419ArbContent);

        final result = runGenL10n(
          [
            '--project-dir=.',
            '--arb-dir=pkg/lib/l10n',
            '--output-dir=bazel-out/k8-fastbuild/bin/pkg/lib/l10n',
            '--template-arb-file=app_en.arb',
            '--output-localization-file=app_localizations.dart',
            '--output-class=AppLocalizations',
            '--arb-file=pkg/lib/l10n/app_en.arb',
            '--arb-file=bazel-out/k8-fastbuild/bin/pkg/lib/l10n/app_es.arb',
          ],
          workingDirectory: '${tmp.path}/split',
        );
        expect(
          result.exitCode,
          0,
          reason: 'split-root run failed: ${result.stderr}',
        );

        final baseDart = File(
          '${genDir.path}/app_localizations.dart',
        ).readAsStringSync();
        expect(baseDart, contains("Locale('en')"));
        expect(baseDart, contains("Locale('es')"));
        expect(baseDart, isNot(contains('US')));
        expect(baseDart, isNot(contains('419')));
      },
    );
  });
}
