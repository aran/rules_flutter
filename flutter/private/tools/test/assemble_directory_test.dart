import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../assemble_directory.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('assemble_directory'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(String relative, String content) {
    final file = File('${dir.path}/$relative')..createSync(recursive: true);
    file.writeAsStringSync(content);
    return file.path;
  }

  String read(String relative) =>
      File('${dir.path}/$relative').readAsStringSync();

  int assemble(List<String> steps) =>
      run(['--output', '${dir.path}/out', ...steps]);

  test('copies a tree into the root, nested directories included', () {
    write('tree/AssetManifest.bin', 'manifest');
    write('tree/fonts/a.ttf', 'font');
    expect(assemble(['--add-tree', '.', '${dir.path}/tree']), 0);
    expect(read('out/AssetManifest.bin'), 'manifest');
    expect(read('out/fonts/a.ttf'), 'font');
  });

  test('copies a tree into a directory of its own, creating it', () {
    write('tree/a.txt', 'a');
    expect(
      assemble(['--add-tree', 'App.framework/Res', '${dir.path}/tree']),
      0,
    );
    expect(read('out/App.framework/Res/a.txt'), 'a');
  });

  test('follows symlinks to files and to directories', () {
    write('real/inner/file.txt', 'linked');
    write('real/top.txt', 'top');
    Directory('${dir.path}/tree').createSync();
    // Targets spelled with the host's separator: Windows does not resolve a
    // link whose target mixes in `/`.
    Link('${dir.path}/tree/dir').createSync(p.join(dir.path, 'real', 'inner'));
    Link(
      '${dir.path}/tree/top.txt',
    ).createSync(p.join(dir.path, 'real', 'top.txt'));
    assemble(['--add-tree', '.', '${dir.path}/tree']);
    expect(FileSystemEntity.isLinkSync('${dir.path}/out/dir'), isFalse);
    expect(read('out/dir/file.txt'), 'linked');
    expect(read('out/top.txt'), 'top');
  });

  test('adds named files after the tree, replacing one it has', () {
    write('tree/kernel_blob.bin', 'old');
    write('tree/keep', 'kept');
    final kernel = write('kernel.dill', 'kernel');
    final snapshot = write('vm.bin', 'snapshot');
    assemble([
      '--add-tree',
      '.',
      '${dir.path}/tree',
      '--add',
      'kernel_blob.bin',
      kernel,
      '--add',
      'vm_snapshot_data',
      snapshot,
    ]);
    expect(read('out/kernel_blob.bin'), 'kernel');
    expect(read('out/vm_snapshot_data'), 'snapshot');
    expect(read('out/keep'), 'kept');
  });

  test(
    'never copies a file of the tree that an added one replaces',
    () {
      write('tree/NativeAssetsManifest.json', 'one ABI');
      write('tree/keep', 'kept');
      // Unreadable, so copying it fails: the replaced file must not be
      // copied, as on Windows a read-only copy of it could not be deleted.
      Process.runSync('chmod', [
        '000',
        '${dir.path}/tree/NativeAssetsManifest.json',
      ]);
      addTearDown(
        () => Process.runSync('chmod', [
          '644',
          '${dir.path}/tree/NativeAssetsManifest.json',
        ]),
      );
      final merged = write('merged.json', 'every ABI');
      expect(
        assemble([
          '--add-tree',
          '.',
          '${dir.path}/tree',
          '--add',
          'NativeAssetsManifest.json',
          merged,
        ]),
        0,
      );
      expect(read('out/NativeAssetsManifest.json'), 'every ABI');
      expect(read('out/keep'), 'kept');
    },
    testOn: '!windows',
  );

  test('keeps an empty directory of a tree', () {
    Directory('${dir.path}/tree/empty').createSync(recursive: true);
    expect(assemble(['--add-tree', '.', '${dir.path}/tree']), 0);
    expect(Directory('${dir.path}/out/empty').existsSync(), isTrue);
  });

  test('builds a directory from added files alone, creating parents', () {
    final file = write('prebuilt.dart', 'const prebuilt = 1;\n');
    expect(assemble(['--add', 'lib/prebuilt.dart', file]), 0);
    expect(read('out/lib/prebuilt.dart'), 'const prebuilt = 1;\n');
  });

  test('an added file lands inside a tree copied before it', () {
    write('tree/flutter_assets/a', 'a');
    final kernel = write('kernel.dill', 'kernel');
    assemble([
      '--add-tree',
      'Resources/flutter_assets',
      '${dir.path}/tree/flutter_assets',
      '--add',
      'Resources/flutter_assets/kernel_blob.bin',
      kernel,
    ]);
    expect(read('out/Resources/flutter_assets/a'), 'a');
    expect(read('out/Resources/flutter_assets/kernel_blob.bin'), 'kernel');
  });

  test('refuses an argument it does not know, and a missing --output', () {
    expect(run(['--bogus']), 64);
    expect(run(['--add', 'x', 'y']), 64);
  });
}
