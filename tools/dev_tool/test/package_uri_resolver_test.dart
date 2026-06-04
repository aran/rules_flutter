import 'package:flutter_bazel_dev_tool/hot_reload/package_uri_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('PackageUriResolver', () {
    const ws = '/work/app';

    PackageUriResolver make(List<({String name, String libRoot})> pkgs) =>
        PackageUriResolver(workspaceRoot: ws, sourcePackages: pkgs);

    test('maps an app lib file (root package, empty libRoot) to package: URI',
        () {
      final r = make([(name: 'app', libRoot: '')]);
      expect(r.toPackageUri('$ws/lib/main.dart'), 'package:app/main.dart');
      expect(r.toPackageUri('$ws/lib/sub/widget.dart'),
          'package:app/sub/widget.dart');
    });

    test('maps a dependency package source under its libRoot', () {
      final r = make([
        (name: 'app', libRoot: ''),
        (name: 'dep', libRoot: 'packages/dep'),
      ]);
      expect(r.toPackageUri('$ws/packages/dep/lib/api.dart'),
          'package:dep/api.dart');
    });

    test('longest libDir prefix wins for nested packages', () {
      // A package nested under another: the inner package must claim its files,
      // not the outer one.
      final r = make([
        (name: 'outer', libRoot: ''),
        (name: 'inner', libRoot: 'lib/vendored'),
      ]);
      // libDir(outer) = /work/app/lib ; libDir(inner) = /work/app/lib/vendored/lib
      expect(r.toPackageUri('$ws/lib/vendored/lib/x.dart'),
          'package:inner/x.dart');
      expect(r.toPackageUri('$ws/lib/main.dart'), 'package:outer/main.dart');
    });

    test('returns null for a path outside every source package lib dir', () {
      final r = make([(name: 'app', libRoot: '')]);
      // Not under any lib/ (e.g. a tool script, or a pub dep in external/).
      expect(r.toPackageUri('$ws/tools/gen.dart'), isNull);
      expect(r.toPackageUri('/elsewhere/lib/x.dart'), isNull);
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

    test('normalizes input paths (handles .. and trailing separators)', () {
      final r = make([(name: 'app', libRoot: '')]);
      expect(r.toPackageUri('$ws/lib/foo/../main.dart'), 'package:app/main.dart');
    });
  });
}
