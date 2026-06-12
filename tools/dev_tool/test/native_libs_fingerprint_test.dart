import 'dart:io';

import 'package:flutter_bazel_dev_tool/native_libs_fingerprint.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nlf_test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Directory makeBundle(String name, {required List<int> dylibBytes}) {
    final app = Directory('${tmp.path}/$name.app');
    final frameworks = Directory('${app.path}/Contents/Frameworks')
      ..createSync(recursive: true);
    File('${frameworks.path}/libdemo.dylib').writeAsBytesSync(dylibBytes);
    // Framework contents must be excluded: App.framework carries the kernel
    // and changes on every Dart edit.
    final fw = Directory('${frameworks.path}/App.framework/Versions/A')
      ..createSync(recursive: true);
    File('${fw.path}/App').writeAsBytesSync([1, 2, 3]);
    File('${app.path}/Contents/MacOS/runner')
      ..createSync(recursive: true)
      ..writeAsBytesSync([9, 9]);
    return app;
  }

  Future<String> zipBundle(Directory app) async {
    final zipPath = '${app.path}.zip';
    final r = await Process.run(
      'zip',
      ['-q', '-r', zipPath, app.uri.pathSegments.lastWhere((s) => s.isNotEmpty)],
      workingDirectory: app.parent.path,
    );
    expect(r.exitCode, 0, reason: r.stderr.toString());
    return zipPath;
  }

  test('extracted bundle: loose dylibs only, content-sensitive', () async {
    final app = makeBundle('a', dylibBytes: [1, 2, 3, 4]);
    final fp = await nativeLibsFingerprint(app.path);
    expect(fp.keys, ['Contents/Frameworks/libdemo.dylib']);

    final same = await nativeLibsFingerprint(app.path);
    expect(fingerprintsEqual(fp, same), isTrue);

    File('${app.path}/Contents/Frameworks/libdemo.dylib')
        .writeAsBytesSync([1, 2, 3, 5]);
    final changedFp = await nativeLibsFingerprint(app.path);
    expect(fingerprintsEqual(fp, changedFp), isFalse);
    expect(changedLibs(fp, changedFp), ['Contents/Frameworks/libdemo.dylib']);
  });

  test('framework edits do not change the fingerprint', () async {
    final app = makeBundle('b', dylibBytes: [1, 2, 3, 4]);
    final fp = await nativeLibsFingerprint(app.path);
    File('${app.path}/Contents/Frameworks/App.framework/Versions/A/App')
        .writeAsBytesSync([4, 5, 6, 7, 8]);
    final after = await nativeLibsFingerprint(app.path);
    expect(fingerprintsEqual(fp, after), isTrue);
  });

  test('zip artifact: TOC fingerprint, content-sensitive, frameworks excluded',
      () async {
    final app = makeBundle('c', dylibBytes: List.filled(1000, 7));
    final zip1 = await zipBundle(app);
    final fp1 = await nativeLibsFingerprint(zip1);
    expect(fp1.keys.single, endsWith('Contents/Frameworks/libdemo.dylib'));

    // Dart-edit analog: framework payload changes, dylib unchanged.
    File('${app.path}/Contents/Frameworks/App.framework/Versions/A/App')
        .writeAsBytesSync(List.filled(500, 3));
    File(zip1).deleteSync();
    final zip2 = await zipBundle(app);
    final fp2 = await nativeLibsFingerprint(zip2);
    expect(fingerprintsEqual(fp1, fp2), isTrue,
        reason: 'framework change must not trigger relaunch');

    // Rust-edit analog: dylib bytes change.
    File('${app.path}/Contents/Frameworks/libdemo.dylib')
        .writeAsBytesSync(List.filled(1000, 8));
    File(zip2).deleteSync();
    final zip3 = await zipBundle(app);
    final fp3 = await nativeLibsFingerprint(zip3);
    expect(fingerprintsEqual(fp1, fp3), isFalse);
  });

  test('bundle without loose native libs fingerprints empty', () async {
    final app = Directory('${tmp.path}/plain.app');
    Directory('${app.path}/Contents/Frameworks/App.framework')
        .createSync(recursive: true);
    File('${app.path}/Contents/Frameworks/App.framework/App')
        .writeAsBytesSync([1]);
    expect(await nativeLibsFingerprint(app.path), isEmpty);
  });
}
