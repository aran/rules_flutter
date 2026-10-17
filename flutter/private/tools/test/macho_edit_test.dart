import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../macho_edit.dart' as macho;

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _readCString(Uint8List bytes, int start) {
  var end = start;
  while (end < bytes.length && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(start, end));
}

/// Builds a synthetic 64-bit Mach-O binary with an embedded `LC_CODE_SIGNATURE`
/// (`CS_SuperBlob` + `CS_CodeDirectory` with SHA-256 4096-byte page hashes)
/// at offset 0x2000 (spanning 2 code pages of 0x1000 bytes each).
Uint8List _buildSignedMachO({
  bool includeLegacyVersionMin = false,
  String installName = '@rpath/Old.framework/Old',
}) {
  const pageSize = 0x1000;
  const codeLimit = 0x2000; // 2 pages

  // Build CS_CodeDirectory (44-byte header + identifier "test\0" + 2 * 32-byte hashes)
  final ident = ascii.encode('test\x00');
  const cdHeaderSize = 44;
  final hashOffset = cdHeaderSize + ident.length;
  const nCodeSlots = 2;
  final cdLength = hashOffset + nCodeSlots * 32;

  // CS_SuperBlob: 12-byte header + 1 * 8-byte BlobIndex + CS_CodeDirectory
  final superLength = 12 + 8 + cdLength;
  final alignedSigSize = (superLength + 15) & ~15;
  final totalSize = codeLimit + alignedSigSize;

  final buf = Uint8List(totalSize);
  final bd = ByteData.sublistView(buf);

  // Fill page 1 (0x1000..0x2000) with deterministic code bytes.
  for (var i = pageSize; i < codeLimit; i++) {
    buf[i] = (i * 31 + 7) & 0xff;
  }

  // LC_SEGMENT_64 (__TEXT) covering 0..0x2000
  final textSeg = Uint8List(72);
  final textBd = ByteData.sublistView(textSeg);
  textBd.setUint32(0, macho.lcSegment64, Endian.little);
  textBd.setUint32(4, 72, Endian.little);
  textSeg.setRange(8, 14, ascii.encode('__TEXT'));
  textBd.setUint64(24, 0, Endian.little);
  textBd.setUint64(32, codeLimit, Endian.little);
  textBd.setUint64(40, 0, Endian.little);
  textBd.setUint64(48, codeLimit, Endian.little);
  textBd.setUint32(56, 5, Endian.little);
  textBd.setUint32(60, 5, Endian.little);

  // LC_SEGMENT_64 (__LINKEDIT) covering 0x2000..totalSize
  final linkeditSeg = Uint8List(72);
  final linkeditBd = ByteData.sublistView(linkeditSeg);
  linkeditBd.setUint32(0, macho.lcSegment64, Endian.little);
  linkeditBd.setUint32(4, 72, Endian.little);
  linkeditSeg.setRange(8, 18, ascii.encode('__LINKEDIT'));
  linkeditBd.setUint64(24, codeLimit, Endian.little);
  linkeditBd.setUint64(32, alignedSigSize, Endian.little);
  linkeditBd.setUint64(40, codeLimit, Endian.little);
  linkeditBd.setUint64(48, alignedSigSize, Endian.little);
  linkeditBd.setUint32(56, 1, Endian.little);
  linkeditBd.setUint32(60, 1, Endian.little);

  final commands = <macho.LoadCommand>[
    macho.LoadCommand(macho.lcSegment64, textSeg),
    macho.LoadCommand(macho.lcSegment64, linkeditSeg),
    macho.buildLcIdDylib(installName),
  ];

  if (includeLegacyVersionMin) {
    final legacy = Uint8List(16);
    final lbd = ByteData.sublistView(legacy);
    lbd.setUint32(0, macho.lcVersionMinIphoneos, Endian.little);
    lbd.setUint32(4, 16, Endian.little);
    lbd.setUint32(8, 0x000b0000, Endian.little); // 11.0
    lbd.setUint32(12, 0x000b0000, Endian.little);
    commands.add(macho.LoadCommand(macho.lcVersionMinIphoneos, legacy));
  }

  // LC_CODE_SIGNATURE pointing to offset 0x2000
  final codeSigLc = Uint8List(16);
  final csLcBd = ByteData.sublistView(codeSigLc);
  csLcBd.setUint32(0, macho.lcCodeSignature, Endian.little);
  csLcBd.setUint32(4, 16, Endian.little);
  csLcBd.setUint32(8, codeLimit, Endian.little);
  csLcBd.setUint32(12, superLength, Endian.little);
  commands.add(macho.LoadCommand(macho.lcCodeSignature, codeSigLc));

  var sizeofcmds = 0;
  for (final lc in commands) {
    sizeofcmds += lc.cmdsize;
  }

  bd.setUint32(0, macho.mhMagic64, Endian.little);
  bd.setUint32(4, macho.cpuTypeArm64, Endian.little);
  bd.setUint32(8, macho.cpuSubtypeArm64All, Endian.little);
  bd.setUint32(12, macho.mhDylib, Endian.little);
  bd.setUint32(16, commands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, macho.mhNoReexportedDylibs, Endian.little);
  bd.setUint32(28, 0, Endian.little);

  var off = macho.mhHeaderSize64;
  for (final lc in commands) {
    buf.setRange(off, off + lc.cmdsize, lc.bytes);
    off += lc.cmdsize;
  }

  // Write CS_SuperBlob at codeLimit (0x2000).
  bd.setUint32(codeLimit, macho.csMagicEmbeddedSignature, Endian.big);
  bd.setUint32(codeLimit + 4, superLength, Endian.big);
  bd.setUint32(codeLimit + 8, 1, Endian.big); // count = 1
  bd.setUint32(codeLimit + 12, 0, Endian.big); // type = CSSLOT_CODEDIRECTORY
  bd.setUint32(codeLimit + 16, 20, Endian.big); // offset = 20

  final cdOff = codeLimit + 20;
  bd.setUint32(cdOff, macho.csMagicCodeDirectory, Endian.big);
  bd.setUint32(cdOff + 4, cdLength, Endian.big);
  bd.setUint32(cdOff + 8, 0x20400, Endian.big); // version
  bd.setUint32(
    cdOff + 12,
    0x20002,
    Endian.big,
  ); // flags = adhoc | linker-signed
  bd.setUint32(cdOff + 16, hashOffset, Endian.big);
  bd.setUint32(cdOff + 20, cdHeaderSize, Endian.big); // identOffset
  bd.setUint32(cdOff + 24, 0, Endian.big); // nSpecialSlots
  bd.setUint32(cdOff + 28, nCodeSlots, Endian.big);
  bd.setUint32(cdOff + 32, codeLimit, Endian.big);
  bd.setUint8(cdOff + 36, 32); // hashSize = 32
  bd.setUint8(cdOff + 37, macho.csHashTypeSha256); // hashType = SHA-256
  bd.setUint8(cdOff + 38, 0); // platform
  bd.setUint8(cdOff + 39, 12); // pageSizeShift = 12 (4096 bytes)
  bd.setUint32(cdOff + 40, 0, Endian.big); // spare2
  buf.setRange(
    cdOff + cdHeaderSize,
    cdOff + cdHeaderSize + ident.length,
    ident,
  );

  // Fill initial hashes with zeroes so we can verify _resignEmbeddedCodeSignature
  // updates them to the real SHA-256 digests.
  return buf;
}

void main() {
  group('sha256', () {
    test('matches FIPS 180-4 test vectors', () {
      expect(
        _hex(macho.sha256(Uint8List(0))),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        _hex(macho.sha256(Uint8List.fromList(ascii.encode('abc')))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        _hex(
          macho.sha256(
            Uint8List.fromList(
              ascii.encode(
                'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
              ),
            ),
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });
  });

  group('parsePackedVersion', () {
    test('packs major.minor.patch into uint32', () {
      expect(macho.parsePackedVersion('13.0'), 0x000d0000);
      expect(macho.parsePackedVersion('16.2.1'), 0x00100201);
      expect(macho.parsePackedVersion('10.15'), 0x000a0f00);
    });
  });

  group('generateStubMachO', () {
    test('synthesizes valid arm64 iOS stub dylib', () {
      final bytes = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformIos,
        minOs: macho.parsePackedVersion('13.0'),
        sdkVersion: macho.parsePackedVersion('13.0'),
        installName: '@rpath/App.framework/App',
      );
      expect(macho.isMachO64(bytes), isTrue);
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint32(4, Endian.little), macho.cpuTypeArm64);
      expect(bd.getUint32(12, Endian.little), macho.mhDylib);

      final cmds = macho.parseLoadCommands(bytes);
      expect(cmds.map((c) => c.cmd), [
        macho.lcSegment64,
        macho.lcIdDylib,
        macho.lcBuildVersion,
      ]);

      final idLc = cmds[1];
      expect(_readCString(idLc.bytes, 24), '@rpath/App.framework/App');

      final bvBd = ByteData.sublistView(cmds[2].bytes);
      expect(bvBd.getUint32(8, Endian.little), macho.platformIos);
      expect(bvBd.getUint32(12, Endian.little), 0x000d0000);
      expect(bvBd.getUint32(16, Endian.little), 0x000d0000);
    });

    test('synthesizes valid x86_64 iOS simulator stub dylib', () {
      final bytes = macho.generateStubMachO(
        arch: 'x86_64',
        platform: macho.platformIosSimulator,
        minOs: macho.parsePackedVersion('14.0'),
        sdkVersion: macho.parsePackedVersion('15.0'),
        installName: '@rpath/App.framework/App',
      );
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint32(4, Endian.little), macho.cpuTypeX86_64);
      expect(bd.getUint32(8, Endian.little), macho.cpuSubtypeX86_64All);
      final cmds = macho.parseLoadCommands(bytes);
      final bvBd = ByteData.sublistView(cmds[2].bytes);
      expect(bvBd.getUint32(8, Endian.little), macho.platformIosSimulator);
      expect(bvBd.getUint32(12, Endian.little), 0x000e0000);
      expect(bvBd.getUint32(16, Endian.little), 0x000f0000);
    });
  });

  group('patchMachO', () {
    test('patches LC_BUILD_VERSION, LC_ID_DYLIB, LC_RPATH and re-signs LC_CODE_SIGNATURE', () {
      final input = _buildSignedMachO(includeLegacyVersionMin: true);
      final patched = macho.patchMachO(
        input,
        platform: macho.platformIos,
        minOs: macho.parsePackedVersion('13.0'),
        sdkVersion: macho.parsePackedVersion('16.0'),
        installName: '@rpath/MyPlugin.framework/MyPlugin',
        rpaths: ['@executable_path/Frameworks', '@loader_path/Frameworks'],
      );

      final cmds = macho.parseLoadCommands(patched);
      // Legacy LC_VERSION_MIN_IPHONEOS must be stripped.
      expect(
        cmds.where((c) => c.cmd == macho.lcVersionMinIphoneos),
        isEmpty,
      );
      // LC_CODE_SIGNATURE must remain the final load command.
      expect(cmds.last.cmd, macho.lcCodeSignature);

      // Verify LC_ID_DYLIB was updated and 8-byte aligned.
      final idCmd = cmds.singleWhere((c) => c.cmd == macho.lcIdDylib);
      expect(idCmd.cmdsize % 8, 0);
      expect(
        _readCString(idCmd.bytes, 24),
        '@rpath/MyPlugin.framework/MyPlugin',
      );

      // Verify LC_BUILD_VERSION was added.
      final bvCmd = cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion);
      final bvBd = ByteData.sublistView(bvCmd.bytes);
      expect(bvBd.getUint32(8, Endian.little), macho.platformIos);
      expect(bvBd.getUint32(12, Endian.little), 0x000d0000);
      expect(bvBd.getUint32(16, Endian.little), 0x00100000);

      // Verify LC_RPATH commands were added and deduplicated on second patch.
      final rpathCmds = cmds.where((c) => c.cmd == macho.lcRpath).toList();
      expect(rpathCmds.length, 2);
      expect(
        _readCString(rpathCmds[0].bytes, 12),
        '@executable_path/Frameworks',
      );
      expect(_readCString(rpathCmds[1].bytes, 12), '@loader_path/Frameworks');

      // Verify embedded CS_CodeDirectory page hashes match actual SHA-256 of pages 0 and 1.
      const cdOff = 0x2000 + 20;
      const hashOffset = 44 + 5; // "test\0"
      final hashesStart = cdOff + hashOffset;
      final page0Hash = patched.sublist(hashesStart, hashesStart + 32);
      final page1Hash = patched.sublist(hashesStart + 32, hashesStart + 64);

      expect(
        _hex(page0Hash),
        _hex(macho.sha256(Uint8List.sublistView(patched, 0, 0x1000))),
      );
      expect(
        _hex(page1Hash),
        _hex(macho.sha256(Uint8List.sublistView(patched, 0x1000, 0x2000))),
      );

      // Re-patching with an existing LC_BUILD_VERSION and duplicate rpath replaces
      // LC_BUILD_VERSION in place without duplicating rpaths.
      final repatched = macho.patchMachO(
        patched,
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('14.0'),
        rpaths: ['@executable_path/Frameworks'],
      );
      final cmds2 = macho.parseLoadCommands(repatched);
      expect(cmds2.where((c) => c.cmd == macho.lcBuildVersion).length, 1);
      expect(cmds2.where((c) => c.cmd == macho.lcRpath).length, 2);
      final bv2Bd = ByteData.sublistView(
        cmds2.singleWhere((c) => c.cmd == macho.lcBuildVersion).bytes,
      );
      expect(bv2Bd.getUint32(8, Endian.little), macho.platformMacos);
      expect(bv2Bd.getUint32(12, Endian.little), 0x000b0000);
      expect(bv2Bd.getUint32(16, Endian.little), 0x000e0000);
    });
  });

  group('CLI', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('macho_edit_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('stub and patch CLI round-trip', () {
      final stubPath = '${tempDir.path}/stub.dylib';
      final patchedPath = '${tempDir.path}/patched.dylib';

      macho.main([
        'stub',
        '--output',
        stubPath,
        '--arch',
        'arm64',
        '--platform',
        'ios',
        '--min-os',
        '13.0',
        '--install-name',
        '@rpath/App.framework/App',
      ]);

      macho.main([
        'patch',
        '--input',
        stubPath,
        '--output',
        patchedPath,
        '--platform',
        'ios',
        '--min-os',
        '15.0',
        '--sdk-version',
        '16.2',
        '--install-name',
        '@rpath/Updated.framework/Updated',
        '--rpath',
        '@executable_path/Frameworks,@loader_path/Frameworks',
      ]);

      final patchedBytes = File(patchedPath).readAsBytesSync();
      final cmds = macho.parseLoadCommands(patchedBytes);
      final idCmd = cmds.singleWhere((c) => c.cmd == macho.lcIdDylib);
      expect(_readCString(idCmd.bytes, 24), '@rpath/Updated.framework/Updated');
      final bvCmd = cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion);
      final bvBd = ByteData.sublistView(bvCmd.bytes);
      expect(bvBd.getUint32(12, Endian.little), 0x000f0000);
      expect(bvBd.getUint32(16, Endian.little), 0x00100200);
    });

    test('--allow-non-macho copies non-Mach-O input unchanged', () {
      final dummyIn = File('${tempDir.path}/dummy.dylib')
        ..writeAsStringSync('not a macho file');
      final dummyOut = File('${tempDir.path}/out.dylib');

      macho.main([
        'patch',
        '--input',
        dummyIn.path,
        '--output',
        dummyOut.path,
        '--install-name',
        '@rpath/Foo.framework/Foo',
        '--allow-non-macho',
      ]);

      expect(dummyOut.readAsStringSync(), 'not a macho file');
    });

    test('stub --type execute generates valid MH_EXECUTE Mach-O binary', () {
      final execPath = '${tempDir.path}/Runner';
      macho.main([
        'stub',
        '--type',
        'execute',
        '--output',
        execPath,
        '--arch',
        'arm64',
        '--platform',
        'ios',
        '--min-os',
        '14.0',
      ]);

      final bytes = File(execPath).readAsBytesSync();
      expect(macho.isMachO64(bytes), isTrue);
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint32(12, Endian.little), macho.mhExecute);
      expect(bd.getUint32(24, Endian.little), macho.mhPie);
      final cmds = macho.parseLoadCommands(bytes);
      expect(cmds.where((c) => c.cmd == macho.lcIdDylib), isEmpty);
      expect(cmds.where((c) => c.cmd == macho.lcBuildVersion).length, 1);
      expect(cmds.where((c) => c.cmd == macho.lcRpath).length, 1);
    });

    test('copy-assets copies directory tree and optional debug snapshots', () {
      final srcAssets = Directory('${tempDir.path}/src_assets/sub')
        ..createSync(recursive: true);
      File('${srcAssets.path}/a.txt').writeAsStringSync('hello');
      final dill = File('${tempDir.path}/app.dill')..writeAsStringSync('dill');
      final vmSnap = File('${tempDir.path}/vm.bin')..writeAsStringSync('vm');
      final isoSnap = File('${tempDir.path}/iso.bin')..writeAsStringSync('iso');
      final dstAssets = '${tempDir.path}/dst_assets';

      macho.main([
        'copy-assets',
        '--src',
        '${tempDir.path}/src_assets',
        '--dst',
        dstAssets,
        '--kernel-blob',
        dill.path,
        '--vm-snapshot-data',
        vmSnap.path,
        '--isolate-snapshot-data',
        isoSnap.path,
      ]);

      expect(File('$dstAssets/sub/a.txt').readAsStringSync(), 'hello');
      expect(File('$dstAssets/kernel_blob.bin').readAsStringSync(), 'dill');
      expect(File('$dstAssets/vm_snapshot_data').readAsStringSync(), 'vm');
      expect(
        File('$dstAssets/isolate_snapshot_data').readAsStringSync(),
        'iso',
      );
    });

    test(
      'assemble-macos-framework builds versioned macOS App.framework layout',
      () {
        final binFile = File('${tempDir.path}/App_bin')
          ..writeAsBytesSync([1, 2, 3, 4]);
        final plistFile = File('${tempDir.path}/Info.plist')
          ..writeAsStringSync('<plist/>');
        final assetsDir = Directory('${tempDir.path}/flutter_assets')
          ..createSync(recursive: true);
        File('${assetsDir.path}/AssetManifest.bin').writeAsBytesSync([9, 9]);
        final wrapperDir = '${tempDir.path}/wrapper';

        macho.main([
          'assemble-macos-framework',
          '--binary',
          binFile.path,
          '--info-plist',
          plistFile.path,
          '--assets',
          assetsDir.path,
          '--output-dir',
          wrapperDir,
        ]);

        final fwPath = '$wrapperDir/App.framework';
        expect(File('$fwPath/Versions/A/App').readAsBytesSync(), [1, 2, 3, 4]);
        expect(
          File('$fwPath/Versions/A/Resources/Info.plist').readAsStringSync(),
          '<plist/>',
        );
        expect(
          File(
            '$fwPath/Versions/A/Resources/flutter_assets/AssetManifest.bin',
          ).readAsBytesSync(),
          [9, 9],
        );
        expect(Link('$fwPath/Versions/Current').targetSync(), 'A');
        expect(Link('$fwPath/App').targetSync(), 'Versions/Current/App');
        expect(
          Link('$fwPath/Resources').targetSync(),
          'Versions/Current/Resources',
        );
      },
    );

    test(
      'copy-files copies source files under basenames or explicit names',
      () {
        final f1 = File('${tempDir.path}/one/libadd.dylib')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('add');
        final f2 = File('${tempDir.path}/two/libsub.dylib')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('sub');
        final outDir = '${tempDir.path}/staged';

        macho.main([
          'copy-files',
          '--output-dir',
          outDir,
          f1.path,
          'libadd.dylib',
          f2.path,
        ]);

        expect(File('$outDir/libadd.dylib').readAsStringSync(), 'add');
        expect(File('$outDir/libsub.dylib').readAsStringSync(), 'sub');
      },
    );
  });
}
