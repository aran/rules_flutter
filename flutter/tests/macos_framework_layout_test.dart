import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

class _ZipCentralEntry {
  final String name;
  final int compressionMethod;
  final int compressedSize;
  final int uncompressedSize;
  final int externalAttr;
  final int localHeaderOffset;
  final Uint8List rawData;

  _ZipCentralEntry({
    required this.name,
    required this.compressionMethod,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.externalAttr,
    required this.localHeaderOffset,
    required this.rawData,
  });

  int get unixMode => (externalAttr >> 16) & 0xFFFF;
  bool get isSymlink => (unixMode & 0xF000) == 0xA000;
  bool get isRegularFile => (unixMode & 0xF000) == 0x8000;
  bool get isExecutable => (unixMode & 0x0049) != 0;

  Uint8List decodeBytes() {
    if (compressionMethod == 0) {
      return rawData;
    }
    if (compressionMethod == 8) {
      return Uint8List.fromList(ZLibCodec(raw: true).decode(rawData));
    }
    throw StateError(
      'Unsupported ZIP compression method $compressionMethod for $name',
    );
  }
}

Map<String, _ZipCentralEntry> _readZip(File zipFile) {
  final bytes = zipFile.readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  var eocdOffset = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocdOffset = i;
      break;
    }
  }
  if (eocdOffset < 0) {
    throw StateError('Missing EOCD record in ${zipFile.path}');
  }
  final entryCount = bd.getUint16(eocdOffset + 10, Endian.little);
  final cdOffset = bd.getUint32(eocdOffset + 16, Endian.little);
  final entries = <String, _ZipCentralEntry>{};
  var pos = cdOffset;
  for (var i = 0; i < entryCount; i++) {
    expect(bd.getUint32(pos, Endian.little), equals(0x02014b50));
    final compressionMethod = bd.getUint16(pos + 10, Endian.little);
    final compressedSize = bd.getUint32(pos + 20, Endian.little);
    final uncompressedSize = bd.getUint32(pos + 24, Endian.little);
    final nameLen = bd.getUint16(pos + 28, Endian.little);
    final extraLen = bd.getUint16(pos + 30, Endian.little);
    final commentLen = bd.getUint16(pos + 32, Endian.little);
    final externalAttr = bd.getUint32(pos + 38, Endian.little);
    final localHeaderOffset = bd.getUint32(pos + 42, Endian.little);
    final name = utf8.decode(bytes.sublist(pos + 46, pos + 46 + nameLen));

    expect(bd.getUint32(localHeaderOffset, Endian.little), equals(0x04034b50));
    final localNameLen = bd.getUint16(localHeaderOffset + 26, Endian.little);
    final localExtraLen = bd.getUint16(localHeaderOffset + 28, Endian.little);
    final dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen;
    final rawData = Uint8List.sublistView(
      bytes,
      dataStart,
      dataStart + compressedSize,
    );

    entries[name] = _ZipCentralEntry(
      name: name,
      compressionMethod: compressionMethod,
      compressedSize: compressedSize,
      uncompressedSize: uncompressedSize,
      externalAttr: externalAttr,
      localHeaderOffset: localHeaderOffset,
      rawData: rawData,
    );
    pos += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

void _expectMachoDylib(
  Uint8List bytes, {
  required String expectedInstallName,
  bool expectFat = false,
}) {
  expect(bytes.length, greaterThanOrEqualTo(32));
  final bd = ByteData.sublistView(bytes);
  final magicBE = bd.getUint32(0, Endian.big);
  final slices = <Uint8List>[];
  if (magicBE == 0xcafebabe) {
    final nfat = bd.getUint32(4, Endian.big);
    expect(nfat, greaterThanOrEqualTo(2));
    for (var i = 0; i < nfat; i++) {
      final entryOff = 8 + i * 20;
      final offset = bd.getUint32(entryOff + 8, Endian.big);
      final size = bd.getUint32(entryOff + 12, Endian.big);
      slices.add(Uint8List.sublistView(bytes, offset, offset + size));
    }
  } else {
    expect(expectFat, isFalse, reason: 'Expected universal Mach-O binary');
    slices.add(bytes);
  }

  for (final slice in slices) {
    final sbd = ByteData.sublistView(slice);
    // MH_MAGIC_64 (0xfeedfacf)
    expect(sbd.getUint32(0, Endian.little), equals(0xfeedfacf));
    // MH_DYLIB (6)
    expect(sbd.getUint32(12, Endian.little), equals(6));
    final ncmds = sbd.getUint32(16, Endian.little);
    var cmdOffset = 32;
    String? installName;
    for (var i = 0; i < ncmds; i++) {
      final cmd = sbd.getUint32(cmdOffset, Endian.little);
      final cmdsize = sbd.getUint32(cmdOffset + 4, Endian.little);
      if (cmd == 0x0d) {
        // LC_ID_DYLIB
        final strOffset = sbd.getUint32(cmdOffset + 8, Endian.little);
        var end = cmdOffset + strOffset;
        while (end < cmdOffset + cmdsize && slice[end] != 0) {
          end++;
        }
        installName = utf8.decode(slice.sublist(cmdOffset + strOffset, end));
      }
      cmdOffset += cmdsize;
    }
    expect(installName, equals(expectedInstallName));
  }
}

void _expectPlistPackageTypeFmwk(String plistContent, String binaryName) {
  expect(
    RegExp(
      r'<key>CFBundlePackageType</key>\s*<string>FMWK</string>',
    ).hasMatch(plistContent),
    isTrue,
    reason: 'Expected CFBundlePackageType = FMWK in:\n$plistContent',
  );
  expect(
    RegExp(
      '<key>CFBundleExecutable</key>\\s*<string>${RegExp.escape(binaryName)}</string>',
    ).hasMatch(plistContent),
    isTrue,
    reason: 'Expected CFBundleExecutable = $binaryName in:\n$plistContent',
  );
}

Directory _findRunfilesRoot() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  if (testSrcDir != null && Directory(testSrcDir).existsSync()) {
    return Directory(testSrcDir);
  }
  return Directory.current;
}

List<FileSystemEntity> _findRunfileEntities(bool Function(String path) match) {
  final root = _findRunfilesRoot();
  final results = <String, FileSystemEntity>{};
  final visitedDirs = <String>{};
  void walk(Directory dir) {
    final realDir = dir.resolveSymbolicLinksSync();
    if (!visitedDirs.add(realDir)) return;
    for (final entity in dir.listSync(followLinks: false)) {
      final path = entity.path.replaceAll('\\', '/');
      if (match(path)) {
        results[path] = entity;
      }
      if (FileSystemEntity.typeSync(entity.path, followLinks: true) ==
              FileSystemEntityType.directory &&
          !path.endsWith('.framework')) {
        walk(Directory(entity.path));
      }
    }
  }

  walk(root);
  return results.values.toList();
}

void _assertFrameworkDirLayout(
  Directory fwDir, {
  required String binaryName,
  bool expectFat = false,
}) {
  final path = fwDir.path;
  final rootEntries = fwDir
      .listSync(followLinks: false)
      .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .toSet();
  expect(
    rootEntries,
    equals({'Versions', binaryName, 'Resources'}),
    reason:
        'Unsealed files at root of $path would fail codesign; got $rootEntries',
  );

  final currentLinkPath = '$path/Versions/Current';
  expect(
    FileSystemEntity.typeSync(currentLinkPath, followLinks: false),
    equals(FileSystemEntityType.link),
  );
  expect(Link(currentLinkPath).targetSync(), equals('A'));

  final binaryLinkPath = '$path/$binaryName';
  expect(
    FileSystemEntity.typeSync(binaryLinkPath, followLinks: false),
    equals(FileSystemEntityType.link),
  );
  expect(
    Link(binaryLinkPath).targetSync(),
    equals('Versions/Current/$binaryName'),
  );

  final resourcesLinkPath = '$path/Resources';
  expect(
    FileSystemEntity.typeSync(resourcesLinkPath, followLinks: false),
    equals(FileSystemEntityType.link),
  );
  expect(
    Link(resourcesLinkPath).targetSync(),
    equals('Versions/Current/Resources'),
  );

  final versionedBinaryPath = '$path/Versions/A/$binaryName';
  expect(
    FileSystemEntity.typeSync(versionedBinaryPath, followLinks: false),
    equals(FileSystemEntityType.file),
  );
  final binaryBytes = File(versionedBinaryPath).readAsBytesSync();
  _expectMachoDylib(
    binaryBytes,
    expectedInstallName: '@rpath/$binaryName.framework/Versions/A/$binaryName',
    expectFat: expectFat,
  );
  // Resolving the top-level symlink reaches the exact same Mach-O binary.
  expect(File(binaryLinkPath).readAsBytesSync(), equals(binaryBytes));

  final versionedPlistPath = '$path/Versions/A/Resources/Info.plist';
  expect(
    FileSystemEntity.typeSync(versionedPlistPath, followLinks: false),
    equals(FileSystemEntityType.file),
  );
  final plistContent = File(versionedPlistPath).readAsStringSync();
  _expectPlistPackageTypeFmwk(plistContent, binaryName);
  expect(
    File('$path/Resources/Info.plist').readAsStringSync(),
    equals(plistContent),
  );
}

String _testTmpDir() {
  final tmp = Platform.environment['TEST_TMPDIR'];
  if (tmp != null && Directory(tmp).existsSync()) {
    return tmp;
  }
  return Directory.systemTemp.createTempSync('macos_layout_test').path;
}

/// Extracts framework ZIP [entries] under [destDir], recreating symbolic
/// links with their exact stored targets.
///
/// The on-disk layout assertions below run against this local extraction:
/// Bazel does not preserve a framework tree artifact's directory symlinks
/// when staging it as a test input (a link to a directory arrives as a real
/// directory), so the test extracts the deterministic `App.framework.zip`
/// exactly as every other consumer (codesign input staging, the .app
/// assembler, the xtool packager) does, then asserts real `test -L` links.
void _extractZip(Map<String, _ZipCentralEntry> entries, Directory destDir) {
  final names = entries.keys.toList()..sort();
  for (final name in names) {
    final entry = entries[name]!;
    final segments = name.split('/');
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw StateError('Refusing to extract unsafe zip entry: $name');
    }
    final destPath = '${destDir.path}/$name';
    if (entry.isSymlink) {
      final target = utf8.decode(entry.decodeBytes());
      final targetSegments = target.split('/');
      if (target.isEmpty ||
          target.startsWith('/') ||
          targetSegments.any((s) => s == '..')) {
        throw StateError(
          'Refusing to extract unsafe symlink $name -> $target',
        );
      }
      Directory(destPath).parent.createSync(recursive: true);
      final link = Link(destPath);
      if (link.existsSync()) {
        link.deleteSync();
      }
      link.createSync(target);
    } else if (!name.endsWith('/')) {
      final file = File(destPath);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(entry.decodeBytes());
    }
  }
}

void _assertFrameworkZipLayout(
  Map<String, _ZipCentralEntry> entries, {
  required String prefix,
  required String binaryName,
  bool expectFat = false,
  bool forbidDirectoryEntries = false,
}) {
  if (forbidDirectoryEntries) {
    final dirEntries = entries.keys.where((k) => k.endsWith('/')).toList();
    expect(
      dirEntries,
      isEmpty,
      reason: 'rules_apple bundletool rejects directory entries in .framework.zip when compressing',
    );
  }

  final currentEntry = entries['${prefix}Versions/Current'];
  expect(currentEntry, isNotNull, reason: 'Missing ${prefix}Versions/Current');
  expect(currentEntry!.isSymlink, isTrue);
  expect(utf8.decode(currentEntry.decodeBytes()), equals('A'));

  final binaryLinkEntry = entries['$prefix$binaryName'];
  expect(binaryLinkEntry, isNotNull, reason: 'Missing $prefix$binaryName');
  expect(binaryLinkEntry!.isSymlink, isTrue);
  expect(
    utf8.decode(binaryLinkEntry.decodeBytes()),
    equals('Versions/Current/$binaryName'),
  );

  final resourcesLinkEntry = entries['${prefix}Resources'];
  expect(resourcesLinkEntry, isNotNull, reason: 'Missing ${prefix}Resources');
  expect(resourcesLinkEntry!.isSymlink, isTrue);
  expect(
    utf8.decode(resourcesLinkEntry.decodeBytes()),
    equals('Versions/Current/Resources'),
  );

  final binaryEntry = entries['${prefix}Versions/A/$binaryName'];
  expect(
    binaryEntry,
    isNotNull,
    reason: 'Missing ${prefix}Versions/A/$binaryName',
  );
  expect(binaryEntry!.isRegularFile, isTrue);
  expect(binaryEntry.isExecutable, isTrue);
  _expectMachoDylib(
    binaryEntry.decodeBytes(),
    expectedInstallName: '@rpath/$binaryName.framework/Versions/A/$binaryName',
    expectFat: expectFat,
  );

  final plistEntry = entries['${prefix}Versions/A/Resources/Info.plist'];
  expect(
    plistEntry,
    isNotNull,
    reason: 'Missing ${prefix}Versions/A/Resources/Info.plist',
  );
  expect(plistEntry!.isRegularFile, isTrue);
  _expectPlistPackageTypeFmwk(
    utf8.decode(plistEntry.decodeBytes()),
    binaryName,
  );
}

void main() {
  const expectedFrameworkTargets = <String, bool>{
    'macos_test_fake_debug_app_framework': false,
    'macos_test_fake_release_macho_app_framework': false,
    'macos_test_fake_fat_macos_app_framework': true,
    '__macos_test_e2e_macos_app_app_framework': false,
    '__macos_test_default_macos_app_app_framework': false,
    'macos_test_default_fg': false,
  };

  group('macOS App.framework directory and AppleBundleInfo archive layout', () {
    for (final entry in expectedFrameworkTargets.entries) {
      final targetName = entry.key;
      final expectFat = entry.value;

      test(
        '$targetName produces versioned App.framework directory and zip',
        () {
          final fwZips = _findRunfileEntities(
            (p) => p.endsWith('/$targetName/App.framework.zip'),
          );
          expect(
            fwZips,
            isNotEmpty,
            reason: 'Expected $targetName/App.framework.zip in runfiles',
          );
          final zipEntries = _readZip(File(fwZips.first.path));
          _assertFrameworkZipLayout(
            zipEntries,
            prefix: 'App.framework/',
            binaryName: 'App',
            expectFat: expectFat,
            forbidDirectoryEntries: true,
          );

          final extractRoot = Directory('${_testTmpDir()}/$targetName')
            ..createSync(recursive: true);
          _extractZip(zipEntries, extractRoot);
          _assertFrameworkDirLayout(
            Directory('${extractRoot.path}/App.framework'),
            binaryName: 'App',
            expectFat: expectFat,
          );
        },
      );
    }
  });

  group('macOS .app.zip bundle framework layout', () {
    test('e2e_macos_app.app.zip embeds versioned App.framework and FlutterMacOS.framework', () {
      final appZips = _findRunfileEntities(
        (p) => p.endsWith('/macos_test_e2e_macos_app.app.zip'),
      );
      expect(appZips, isNotEmpty);
      final entries = _readZip(File(appZips.first.path));

      _assertFrameworkZipLayout(
        entries,
        prefix:
            'macos_test_e2e_macos_app.app/Contents/Frameworks/App.framework/',
        binaryName: 'App',
      );
      _assertFrameworkZipLayout(
        entries,
        prefix: 'macos_test_e2e_macos_app.app/Contents/Frameworks/FlutterMacOS.framework/',
        binaryName: 'FlutterMacOS',
      );
    });

    test('xtool macOS bundles built under different staging roots with certificate_password_env=TMPDIR are byte-identical', () {
      final zipAEntities = _findRunfileEntities(
        (p) => p.endsWith('/macos_test_fake_xtool_macos_bundle.app.zip'),
      );
      final zipBEntities = _findRunfileEntities(
        (p) => p.endsWith('/macos_test_fake_xtool_macos_bundle_alt.app.zip'),
      );
      expect(zipAEntities, isNotEmpty);
      expect(zipBEntities, isNotEmpty);

      final fileA = File(zipAEntities.first.path);
      final fileB = File(zipBEntities.first.path);
      final bytesA = fileA.readAsBytesSync();
      final bytesB = fileB.readAsBytesSync();
      expect(bytesA, equals(bytesB));

      final entriesA = _readZip(fileA);
      final codeRes =
          entriesA['Runner.app/Contents/_CodeSignature/CodeResources'];
      expect(codeRes, isNotNull);
      expect(
        utf8.decode(codeRes!.decodeBytes()),
        equals('pw=\ntmpdir=\ntest_tmpdir=\n'),
      );
    });
  });
}
