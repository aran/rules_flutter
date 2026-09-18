import 'package:flutter_bazel_dev_tool/hot_reload/source_uri_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('SourceUriResolver', () {
    const ws = '/work/app';

    SourceUriResolver make(List<({String name, String libRoot})> pkgs) =>
        SourceUriResolver(workspaceRoot: ws, sourcePackages: pkgs);

    test(
      'maps an app lib file (root package, empty libRoot) to package: URI',
      () {
        final r = make([(name: 'app', libRoot: '')]);
        expect(r.uriFor('$ws/lib/main.dart'), 'package:app/main.dart');
        expect(
          r.uriFor('$ws/lib/sub/widget.dart'),
          'package:app/sub/widget.dart',
        );
      },
    );

    test('maps a dependency package source under its libRoot', () {
      final r = make([
        (name: 'app', libRoot: ''),
        (name: 'dep', libRoot: 'packages/dep'),
      ]);
      expect(
        r.uriFor('$ws/packages/dep/lib/api.dart'),
        'package:dep/api.dart',
      );
    });

    test('longest libDir prefix wins for nested packages', () {
      // A package nested under another: the inner package must claim its files,
      // not the outer one.
      final r = make([
        (name: 'outer', libRoot: ''),
        (name: 'inner', libRoot: 'lib/vendored'),
      ]);
      // libDir(outer) = /work/app/lib ; libDir(inner) = /work/app/lib/vendored/lib
      expect(
        r.uriFor('$ws/lib/vendored/lib/x.dart'),
        'package:inner/x.dart',
      );
      expect(r.uriFor('$ws/lib/main.dart'), 'package:outer/main.dart');
    });

    test('returns null for a path outside every source package lib dir', () {
      final r = make([(name: 'app', libRoot: '')]);
      // Not under any lib/ (e.g. a tool script, or a pub dep in external/).
      expect(r.uriFor('$ws/tools/gen.dart'), isNull);
      expect(r.uriFor('/elsewhere/lib/x.dart'), isNull);
    });

    test('sourceLibDirs lists each package lib directory', () {
      final r = make([
        (name: 'app', libRoot: ''),
        (name: 'dep', libRoot: 'packages/dep'),
      ]);
      expect(r.sourceLibDirs.map(p.normalize), [
        p.normalize('$ws/lib'),
        p.normalize('$ws/packages/dep/lib'),
      ]);
    });

    group('app sources outside every package', () {
      // A `main` outside its package's `lib/` — `flutter run -t
      // test_driver/app.dart` — and the sibling it imports are compiled under
      // the app scheme. The build declares both, with their URIs.
      SourceUriResolver withAppSources() => SourceUriResolver(
        workspaceRoot: ws,
        sourcePackages: [(name: 'app', libRoot: '')],
        appSources: [
          (
            path: 'test_driver/app.dart',
            uri: 'org-dartlang-app:///test_driver/app.dart',
          ),
          (
            path: 'test_driver/banner.dart',
            uri: 'org-dartlang-app:///test_driver/banner.dart',
          ),
        ],
      );

      test('maps each declared file to the URI the build declared', () {
        final r = withAppSources();
        expect(
          r.uriFor('$ws/test_driver/app.dart'),
          'org-dartlang-app:///test_driver/app.dart',
        );
        expect(
          r.uriFor('$ws/test_driver/./banner.dart'),
          'org-dartlang-app:///test_driver/banner.dart',
        );
      });

      test('leaves an undeclared neighbour unmapped', () {
        // The build's compile sees nothing it does not declare, so a file the
        // build did not list is one the app never reads: an edit to it is not
        // a reload, whatever directory it shares with the `main`.
        expect(withAppSources().uriFor('$ws/test_driver/notes.dart'), isNull);
      });

      test('still maps a lib/ file by its package: URI', () {
        expect(
          withAppSources().uriFor('$ws/lib/main.dart'),
          'package:app/main.dart',
        );
      });

      test('lists them for the snapshot, by URI', () {
        expect(withAppSources().appSourceFiles, {
          'org-dartlang-app:///test_driver/app.dart': p.normalize(
            '$ws/test_driver/app.dart',
          ),
          'org-dartlang-app:///test_driver/banner.dart': p.normalize(
            '$ws/test_driver/banner.dart',
          ),
        });
      });
    });

    test('normalizes input paths (handles .. and trailing separators)', () {
      final r = make([(name: 'app', libRoot: '')]);
      expect(
        r.uriFor('$ws/lib/foo/../main.dart'),
        'package:app/main.dart',
      );
    });
  });
}
