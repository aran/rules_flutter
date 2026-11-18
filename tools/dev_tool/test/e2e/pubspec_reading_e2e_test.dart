/// A hosted package's pubspec is read the way pub reads it, by rules_dart's
/// `read_pubspec`, and rules_flutter projects its `flutter:` block.
///
/// **The properties:**
///
///  1. A pubspec pub refuses (YAML that does not load, a `name` that is not
///     the package's, none, a dependency or a constraint of the wrong type)
///     fails the fetch of the package's repository, naming the package and
///     saying what pub says. It never yields a build of something else.
///  2. The `flutter:` block is read from the document, not from its layout: a
///     plugin and the assets written in YAML's flow style reach the package's
///     Android library and its files exactly as the block style does.
///  3. A `flutter:` block flutter_tools refuses leaves the repository
///     fetching, and the package's target failing at analysis naming the
///     package and the entry.
///
/// The workspaces are generated (`pub_inputs_fixture.dart`): a real
/// `flutter_pub.from_lock()` hub over packages served from `file://`.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

String _pubspec(String name, String body) =>
    'name: $name\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n$body';

void main() {
  group('a pubspec pub refuses', () {
    // Package name to the pubspec in its archive, and what pub says.
    final refused = <String, (String, String)>{
      'bad_yaml': (
        'name: bad_yaml\ndependencies: [unclosed\n',
        'pub would refuse',
      ),
      'other_name': ('name: someone_else\n', "doesn't match expected name"),
      'unnamed': ('version: 1.0.0\n', 'Missing the required "name" field'),
      'empty': ('', 'Missing the required "name" field'),
      'list_deps': (
        'name: list_deps\ndependencies: [a, b]\n',
        '"dependencies" field must be a map',
      ),
      'numeric_sdk': (
        'name: numeric_sdk\nenvironment:\n  sdk: 3\n',
        'A version constraint must be a string',
      ),
      'self_dep': (
        'name: self_dep\ndependencies:\n  self_dep: any\n',
        'may not list itself as a dependency',
      ),
    };
    late PubInputsWorkspace ws;

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          for (final entry in refused.entries)
            HostedPackage(entry.key, pubspec: entry.value.$1),
        ],
      ).materialize();
    });

    for (final entry in refused.entries) {
      test('${entry.key} fails the fetch, naming the package', () async {
        final result = await ws.loadSpoke(entry.key);
        expect(result.succeeded, isFalse, reason: 'built from it:\n$result');
        expect(
          refusedAtFetch(result),
          isTrue,
          reason: 'the failure should be the fetch refusing it:\n$result',
        );
        expect(
          namesPackage(result.output, entry.key),
          isTrue,
          reason: 'the refusal does not name the package:\n$result',
        );
        expect(
          result.output,
          contains(entry.value.$2),
          reason: 'the refusal does not say what pub says:\n$result',
        );
      });
    }
  });

  group('a flutter block flutter build refuses', () {
    // Package name to its `flutter:` block, and what flutter_tools says of it
    // (every refusal is a case in `flutter_pubspec_test.bzl`; these go through
    // the repository). The package's repository fetches, and its target fails
    // at analysis, so a package no target uses breaks nothing. The entry is
    // named by where it is in the pubspec.
    final refused = <String, (String, List<String>)>{
      'asset_not_a_list': (
        'flutter:\n  assets: a.txt\n',
        ['flutter.assets', 'Expected "assets" to be a list'],
      ),
      'asset_unknown_platform': (
        'flutter:\n  assets:\n    - path: a.txt\n      platforms: [fuchsia]\n',
        ['flutter.assets[0]', 'Invalid platform(s): "fuchsia"'],
      ),
      'asset_without_path': (
        'flutter:\n  assets:\n    - flavors: [x]\n',
        ['flutter.assets[0]', 'containing a "path" entry'],
      ),
      'shader_empty_entry': (
        'flutter:\n  shaders:\n    - ""\n',
        ['flutter.shaders[0]', 'null or empty uri'],
      ),
      'font_bad_weight': (
        'flutter:\n  fonts:\n    - family: F\n      fonts:\n'
            '        - asset: f.ttf\n          weight: 450\n',
        ['flutter.fonts[0]', 'Invalid value 450', 'weight'],
      ),
      'font_bad_style': (
        'flutter:\n  fonts:\n    - family: F\n      fonts:\n'
            '        - asset: f.ttf\n          style: oblique\n',
        ['flutter.fonts[0]', 'Invalid value oblique', 'style'],
      ),
      'asset_bad_uri': (
        'flutter:\n  assets:\n    - "1a:b"\n',
        ['flutter.assets[0]', 'invalid uri: 1a:b'],
      ),
      'unknown_flutter_key': (
        'flutter:\n  colour: red\n',
        ['flutter.colour', 'Unexpected child "colour" found under "flutter"'],
      ),
      'material_design_not_bool': (
        'flutter:\n  uses-material-design: yes please\n',
        ['flutter.uses-material-design', 'to be a bool'],
      ),
      'license_not_a_string': (
        'flutter:\n  licenses:\n    - 7\n',
        ['flutter.licenses', 'element at index 0 was a int'],
      ),
      'fonts_not_maps': (
        'flutter:\n  fonts:\n    - F\n',
        ['flutter.fonts', 'to contain maps'],
      ),
    };
    late PubInputsWorkspace ws;

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          for (final entry in refused.entries)
            HostedPackage(
              entry.key,
              pubspec: _pubspec(entry.key, entry.value.$1),
            ),
        ],
      ).materialize();
    });

    for (final entry in refused.entries) {
      test(
        '${entry.key} fails its target, naming the package and entry',
        () async {
          final loaded = await ws.loadSpoke(entry.key);
          expect(loaded.succeeded, isTrue, reason: '$loaded');
          final result = await ws.analyzeSpoke(entry.key);
          expect(result.succeeded, isFalse, reason: 'built from it:\n$result');
          expect(refusedAtAnalysis(result), isTrue, reason: '$result');
          expect(
            namesPackage(result.output, entry.key),
            isTrue,
            reason: '$result',
          );
          for (final mention in entry.value.$2) {
            expect(result.output, contains(mention), reason: '$result');
          }
        },
      );
    }
  });

  group('the forms of the flutter block flutter build accepts', () {
    late PubInputsWorkspace ws;

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          HostedPackage(
            'odd_but_valid',
            pubspec: _pubspec(
              'odd_but_valid',
              'flutter:\n'
                  '  assets:\n'
                  '    - a.txt\n'
                  '    - {}\n'
                  '    - path: b.txt\n'
                  '      flavors: [x]\n'
                  '      platforms: [ios, web]\n'
                  '  shaders:\n'
                  '  fonts:\n'
                  '    - family: F\n'
                  '      fonts:\n'
                  '        - asset: f.ttf\n'
                  '          weight: 900\n'
                  '          style: italic\n'
                  '    - family: G\n',
            ),
            files: {'a.txt': 'a', 'b.txt': 'b', 'f.ttf': 'f'},
          ),
        ],
      ).materialize();
    });

    test('builds, with the files it lists', () async {
      final result = await ws.loadSpoke('odd_but_valid');
      expect(result.succeeded, isTrue, reason: '$result');
    });
  });

  group('the flutter block in YAML flow style', () {
    late PubInputsWorkspace ws;

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          HostedPackage(
            'flow_assets',
            pubspec: _pubspec(
              'flow_assets',
              'flutter: {assets: [assets/a.txt, {path: assets/b.txt}], '
                  'fonts: [{family: F, fonts: [{asset: fonts/f.ttf, weight: 700}]}]}\n',
            ),
            files: {
              'assets/a.txt': 'a',
              'assets/b.txt': 'b',
              'fonts/f.ttf': 'f',
            },
          ),
          HostedPackage(
            'flow_plugin',
            pubspec: _pubspec(
              'flow_plugin',
              'flutter: {plugin: {platforms: {android: '
                  '{package: dev.example.flow_plugin, pluginClass: Plugin}}}}\n',
            ),
            files: {
              'android/src/main/kotlin/dev/example/Plugin.kt':
                  'package dev.example\nclass Plugin\n',
            },
          ),
        ],
      ).materialize();
    });

    test('declares its assets and fonts under their names', () async {
      // The member names its assets, and its fonts through the font family
      // targets the spoke generates beside it, so read those too.
      final build = await ws.bazel([
        'query',
        '--output=build',
        'deps(@flutter_pub__flow_assets//:flow_assets) '
            'intersect @flutter_pub__flow_assets//:*',
      ]);
      expect(build.succeeded, isTrue, reason: '$build');
      for (final text in [
        'assets/a.txt',
        'assets/b.txt',
        'fonts/f.ttf',
        'family = "F"',
        'weight = 700',
      ]) {
        expect(build.output, contains(text), reason: '$build');
      }
    });

    test('registers its Android plugin', () async {
      expect((await ws.loadSpoke('flow_plugin')).succeeded, isTrue);
      final dir = await ws.spokeDirectory('flow_plugin');
      final build = File(
        p.join(dir.path, 'android', 'BUILD.bazel'),
      ).readAsStringSync();
      expect(build, contains('custom_package = "dev.example.flow_plugin"'));
    });
  });
}
