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

/// Builds a minimal valid stored (uncompressed) ZIP from [files] and
/// [symlinks] (link path to target), with Unix modes matching the framework
/// producer (`0100644` files, `0120777` links). For
/// `extractFrameworkZip` unit coverage, including hostile names.
Uint8List _storedZip(
  Map<String, List<int>> files, {
  Map<String, String> symlinks = const {},
}) {
  final local = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  final names = [...files.keys, ...symlinks.keys]..sort();
  var offset = 0;
  for (final name in names) {
    final isLink = symlinks.containsKey(name);
    final payload = isLink ? utf8.encode(symlinks[name]!) : files[name]!;
    final nameBytes = utf8.encode(name);
    final lh = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, 0, Endian.little)
      ..setUint32(14, 0, Endian.little)
      ..setUint32(18, payload.length, Endian.little)
      ..setUint32(22, payload.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, 0, Endian.little);
    local.add(lh.buffer.asUint8List());
    local.add(nameBytes);
    local.add(payload);
    final mode = isLink ? 0xA1FF : 0x81A4;
    final ch = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, 0, Endian.little)
      ..setUint16(14, 0, Endian.little)
      ..setUint32(16, 0, Endian.little)
      ..setUint32(20, payload.length, Endian.little)
      ..setUint32(24, payload.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint16(30, 0, Endian.little)
      ..setUint16(32, 0, Endian.little)
      ..setUint16(34, 0, Endian.little)
      ..setUint16(36, 0, Endian.little)
      ..setUint32(38, mode << 16, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central.add(ch.buffer.asUint8List());
    central.add(nameBytes);
    offset += 30 + nameBytes.length + payload.length;
  }
  final centralBytes = central.toBytes();
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, names.length, Endian.little)
    ..setUint16(10, names.length, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, offset, Endian.little);
  return Uint8List.fromList([
    ...local.toBytes(),
    ...centralBytes,
    ...eocd.buffer.asUint8List(),
  ]);
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

String? _resolveHermeticTool(String envVar) {
  final rel = Platform.environment[envVar];
  if (rel == null || rel.isEmpty) return null;
  if (File(rel).existsSync()) return File(rel).absolute.path;
  final runfilesDir =
      Platform.environment['RUNFILES_DIR'] ??
      Platform.environment['TEST_SRCDIR'];
  if (runfilesDir != null) {
    for (final candidate in [
      '$runfilesDir/$rel',
      '$runfilesDir/_main/$rel',
    ]) {
      if (File(candidate).existsSync()) return File(candidate).absolute.path;
    }
  }
  return null;
}

/// Builds a synthetic 32-bit little-endian Mach-O header (`MH_MAGIC = 0xfeedface`).
Uint8List _buildMachO32({int cputype = macho.cpuTypeArm}) {
  final buf = Uint8List(64);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, macho.mhMagic32, Endian.little);
  bd.setUint32(4, cputype, Endian.little);
  bd.setUint32(8, 9, Endian.little); // cpusubtype = ARM_V7
  bd.setUint32(12, macho.mhDylib, Endian.little);
  bd.setUint32(16, 0, Endian.little); // ncmds = 0
  bd.setUint32(20, 0, Endian.little); // sizeofcmds = 0
  bd.setUint32(
    24,
    macho.mhNoundefs | macho.mhDyldlink | macho.mhTwolevel,
    Endian.little,
  );
  return buf;
}

/// Builds a synthetic 64-bit Mach-O exercising every load-command kind the
/// patcher rewrites or scans: a `__TEXT` segment with one section (file bytes
/// at 0x1000), a `__LINKEDIT` segment, `LC_SYMTAB`/`LC_DYSYMTAB`, the four
/// linkedit table commands (`LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`,
/// `LC_DYLD_EXPORTS_TRIE`, `LC_DYLD_CHAINED_FIXUPS`), all four legacy
/// `LC_VERSION_MIN_*` commands, and `LC_ID_DYLIB` (but no `LC_BUILD_VERSION`
/// or `LC_RPATH`, so the patcher takes the add paths for those).
Uint8List _buildFullCoverageMachO() {
  Uint8List tableCommand(int cmd, int dataoff, int datasize) {
    final buf = Uint8List(16);
    final bd = ByteData.sublistView(buf);
    bd.setUint32(0, cmd, Endian.little);
    bd.setUint32(4, 16, Endian.little);
    bd.setUint32(8, dataoff, Endian.little);
    bd.setUint32(12, datasize, Endian.little);
    return buf;
  }

  Uint8List versionMin(int cmd) {
    final buf = Uint8List(16);
    final bd = ByteData.sublistView(buf);
    bd.setUint32(0, cmd, Endian.little);
    bd.setUint32(4, 16, Endian.little);
    bd.setUint32(8, 0x000b0000, Endian.little);
    bd.setUint32(12, 0x000b0000, Endian.little);
    return buf;
  }

  // `__TEXT` segment with one `section_64` (80 bytes at command offset 72).
  final textSeg = Uint8List(72 + 80);
  final textBd = ByteData.sublistView(textSeg);
  textBd.setUint32(0, macho.lcSegment64, Endian.little);
  textBd.setUint32(4, 152, Endian.little);
  textSeg.setRange(8, 8 + '__TEXT'.length, ascii.encode('__TEXT'));
  textBd.setUint64(24, 0, Endian.little);
  textBd.setUint64(32, 0x4000, Endian.little);
  textBd.setUint64(40, 0, Endian.little);
  textBd.setUint64(48, 0x4000, Endian.little);
  textBd.setUint32(56, 5, Endian.little);
  textBd.setUint32(60, 5, Endian.little);
  textBd.setUint32(64, 1, Endian.little);
  textSeg.setRange(72, 72 + '__text'.length, ascii.encode('__text'));
  textSeg.setRange(
    72 + 16,
    72 + 16 + '__TEXT'.length,
    ascii.encode('__TEXT'),
  );
  textBd.setUint64(72 + 32, 0x100, Endian.little);
  textBd.setUint64(72 + 40, 0x200, Endian.little);
  textBd.setUint32(72 + 48, 0x1000, Endian.little);
  textBd.setUint32(72 + 52, 2, Endian.little);

  final commands = <Uint8List>[
    textSeg,
    macho.buildLcSegment64((
      segname: '__LINKEDIT',
      vmaddr: 0x4000,
      vmsize: 0x1000,
      fileoff: 0x4000,
      filesize: 0x1000,
      maxprot: 1,
      initprot: 1,
      nsects: 0,
      flags: 0,
    )).bytes,
    macho
        .buildLcSymtab(symoff: 0x4000, nsyms: 2, stroff: 0x4020, strsize: 0x20)
        .bytes,
    macho.buildLcDysymtab().bytes,
    tableCommand(macho.lcFunctionStarts, 0x4100, 0x10),
    tableCommand(macho.lcDataInCode, 0x4110, 0x10),
    tableCommand(macho.lcDyldExportsTrie, 0x4120, 0x10),
    tableCommand(macho.lcDyldChainedFixups, 0x4130, 0x10),
    versionMin(macho.lcVersionMinMacosx),
    versionMin(macho.lcVersionMinIphoneos),
    versionMin(macho.lcVersionMinTvos),
    versionMin(macho.lcVersionMinWatchos),
    macho.buildLcIdDylib('@rpath/Old.framework/Old').bytes,
  ];

  var sizeofcmds = 0;
  for (final c in commands) {
    sizeofcmds += c.length;
  }
  const fileSize = 0x5000;
  final buf = Uint8List(fileSize);
  for (var i = 0; i < fileSize; i++) {
    buf[i] = (i * 31 + 7) & 0xff;
  }
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, macho.mhMagic64, Endian.little);
  bd.setUint32(4, macho.cpuTypeArm64, Endian.little);
  bd.setUint32(8, macho.cpuSubtypeArm64All, Endian.little);
  bd.setUint32(12, macho.mhDylib, Endian.little);
  bd.setUint32(16, commands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, macho.mhNoReexportedDylibs, Endian.little);
  bd.setUint32(28, 0, Endian.little);
  var off = macho.mhHeaderSize64;
  for (final c in commands) {
    buf.setRange(off, off + c.length, c);
    off += c.length;
  }
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
    test('synthesizes well-formed arm64 iOS stub dylib with segments, symtab, UUID, and flags', () {
      final bytes = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformIos,
        minOs: macho.parsePackedVersion('13.0'),
        sdkVersion: macho.parsePackedVersion('16.2'),
        installName: '@rpath/App.framework/App',
      );
      expect(macho.isMachO64(bytes), isTrue);
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint32(4, Endian.little), macho.cpuTypeArm64);
      expect(bd.getUint32(12, Endian.little), macho.mhDylib);
      final flags = bd.getUint32(24, Endian.little);
      expect(
        flags,
        macho.mhNoundefs |
            macho.mhDyldlink |
            macho.mhTwolevel |
            macho.mhNoReexportedDylibs,
      );

      final cmds = macho.parseLoadCommands(bytes);
      expect(cmds.map((c) => c.cmd), [
        macho.lcSegment64, // __TEXT
        macho.lcSegment64, // __LINKEDIT
        macho.lcIdDylib,
        macho.lcSymtab,
        macho.lcDysymtab,
        macho.lcUuid,
        macho.lcBuildVersion,
      ]);

      // Verify __TEXT segment.
      expect(_readCString(cmds[0].bytes, 8), '__TEXT');
      final textBd = ByteData.sublistView(cmds[0].bytes);
      expect(textBd.getUint64(24, Endian.little), 0); // vmaddr
      expect(textBd.getUint64(32, Endian.little), 0x4000); // vmsize
      expect(textBd.getUint64(40, Endian.little), 0); // fileoff
      expect(textBd.getUint64(48, Endian.little), 0x4000); // filesize
      expect(textBd.getUint32(56, Endian.little), 5); // maxprot = r-x
      expect(textBd.getUint32(60, Endian.little), 5); // initprot = r-x

      // Verify __LINKEDIT segment.
      expect(_readCString(cmds[1].bytes, 8), '__LINKEDIT');
      final linkeditBd = ByteData.sublistView(cmds[1].bytes);
      expect(linkeditBd.getUint64(24, Endian.little), 0x4000); // vmaddr
      expect(linkeditBd.getUint64(32, Endian.little), 0x4000); // vmsize
      expect(linkeditBd.getUint64(40, Endian.little), 0x4000); // fileoff
      expect(linkeditBd.getUint64(48, Endian.little), 8); // filesize
      expect(linkeditBd.getUint32(56, Endian.little), 1); // maxprot = r--
      expect(linkeditBd.getUint32(60, Endian.little), 1); // initprot = r--

      // Verify LC_ID_DYLIB.
      final idLc = cmds.singleWhere((c) => c.cmd == macho.lcIdDylib);
      expect(_readCString(idLc.bytes, 24), '@rpath/App.framework/App');

      // Verify LC_SYMTAB points into __LINKEDIT.
      final symtabLc = cmds.singleWhere((c) => c.cmd == macho.lcSymtab);
      final symtabBd = ByteData.sublistView(symtabLc.bytes);
      expect(symtabBd.getUint32(8, Endian.little), 0x4000); // symoff
      expect(symtabBd.getUint32(12, Endian.little), 0); // nsyms
      expect(symtabBd.getUint32(16, Endian.little), 0x4000); // stroff
      expect(symtabBd.getUint32(20, Endian.little), 8); // strsize

      // Verify LC_DYSYMTAB is 80 bytes.
      final dysymtabLc = cmds.singleWhere((c) => c.cmd == macho.lcDysymtab);
      expect(dysymtabLc.cmdsize, 80);

      // Verify LC_UUID is non-zero, deterministic, and content-derived.
      final uuidLc = cmds.singleWhere((c) => c.cmd == macho.lcUuid);
      final uuidBytes = uuidLc.bytes.sublist(8, 24);
      expect(uuidBytes.any((b) => b != 0), isTrue);

      final bytesSame = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformIos,
        minOs: macho.parsePackedVersion('13.0'),
        sdkVersion: macho.parsePackedVersion('16.2'),
        installName: '@rpath/App.framework/App',
      );
      expect(_hex(bytes), _hex(bytesSame));

      final bytesDiffContent = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformIos,
        minOs: macho.parsePackedVersion('14.0'),
        sdkVersion: macho.parsePackedVersion('16.2'),
        installName: '@rpath/App.framework/App',
      );
      final uuidDiff = macho
          .parseLoadCommands(bytesDiffContent)
          .singleWhere((c) => c.cmd == macho.lcUuid)
          .bytes
          .sublist(8, 24);
      expect(_hex(uuidBytes), isNot(_hex(uuidDiff)));

      // Verify LC_BUILD_VERSION.
      final bvLc = cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion);
      final bvBd = ByteData.sublistView(bvLc.bytes);
      expect(bvBd.getUint32(8, Endian.little), macho.platformIos);
      expect(bvBd.getUint32(12, Endian.little), 0x000d0000);
      expect(bvBd.getUint32(16, Endian.little), 0x00100200);
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
      final bvLc = cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion);
      final bvBd = ByteData.sublistView(bvLc.bytes);
      expect(bvBd.getUint32(8, Endian.little), macho.platformIosSimulator);
      expect(bvBd.getUint32(12, Endian.little), 0x000e0000);
      expect(bvBd.getUint32(16, Endian.little), 0x000f0000);
    });

    test('hermetic llvm-objdump and llvm-otool accept generated stubs', () {
      final objdump = _resolveHermeticTool('LLVM_OBJDUMP');
      final otool = _resolveHermeticTool('LLVM_OTOOL');
      if (Platform.environment.containsKey('TEST_SRCDIR')) {
        expect(
          objdump,
          isNotNull,
          reason: 'LLVM_OBJDUMP must resolve in Bazel test',
        );
        expect(
          otool,
          isNotNull,
          reason: 'LLVM_OTOOL must resolve in Bazel test',
        );
      }
      if (objdump == null || otool == null) return;

      final tempDir = Directory.systemTemp.createTempSync('macho_llvm_stub_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      for (final arch in ['arm64', 'x86_64']) {
        final dylibPath = '${tempDir.path}/stub_$arch.dylib';
        File(dylibPath).writeAsBytesSync(
          macho.generateStubMachO(
            arch: arch,
            platform: macho.platformMacos,
            minOs: macho.parsePackedVersion('12.3'),
            sdkVersion: macho.parsePackedVersion('14.1'),
            installName: '@rpath/App.framework/Versions/A/App',
          ),
        );

        final objdumpRes = Process.runSync(objdump, [
          '--macho',
          '--private-headers',
          '--dylib-id',
          dylibPath,
        ]);
        expect(objdumpRes.exitCode, 0, reason: '${objdumpRes.stderr}');
        final out = objdumpRes.stdout as String;
        expect(out, contains('NOUNDEFS'));
        expect(out, contains('DYLDLINK'));
        expect(out, contains('TWOLEVEL'));
        expect(out, contains('NO_REEXPORTED_DYLIBS'));
        expect(out, contains('segname __TEXT'));
        expect(out, contains('segname __LINKEDIT'));
        expect(out, contains('cmd LC_ID_DYLIB'));
        expect(out, contains('@rpath/App.framework/Versions/A/App'));
        expect(out, contains('cmd LC_SYMTAB'));
        expect(out, contains('cmd LC_DYSYMTAB'));
        expect(out, contains('cmd LC_UUID'));
        expect(out, contains('cmd LC_BUILD_VERSION'));
        expect(out, contains('platform macos'));
        expect(out, contains('minos 12.3'));
        expect(out, contains('sdk 14.1'));

        final otoolRes = Process.runSync(otool, ['-hv', '-l', '-L', dylibPath]);
        expect(otoolRes.exitCode, 0, reason: '${otoolRes.stderr}');
        expect(
          otoolRes.stdout as String,
          contains('NOUNDEFS DYLDLINK TWOLEVEL'),
        );
      }
    });
  });

  group('patchMachO', () {
    test('patches LC_BUILD_VERSION, LC_ID_DYLIB, LC_RPATH and re-signs LC_CODE_SIGNATURE', () {
      final input = _buildSignedMachO(includeLegacyVersionMin: true);
      final patched = macho.patchMachO(
        input,
        macho.PatchOptions(
          platform: macho.platformIos,
          minOs: macho.parsePackedVersion('13.0'),
          sdkVersion: macho.parsePackedVersion('16.0'),
          installName: '@rpath/MyPlugin.framework/MyPlugin',
          rpaths: ['@executable_path/Frameworks', '@loader_path/Frameworks'],
        ),
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
        macho.PatchOptions(
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('11.0'),
          sdkVersion: macho.parsePackedVersion('14.0'),
          rpaths: ['@executable_path/Frameworks'],
        ),
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

    test('patches all slices in a fat (0xcafebabe) Mach-O binary and thins when arch is set', () {
      final arm64Slice = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('11.0'),
        installName: '@rpath/Old.dylib',
      );
      final x86Slice = macho.generateStubMachO(
        arch: 'x86_64',
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('11.0'),
        installName: '@rpath/Old.dylib',
      );

      final fatInput = macho.buildFatMachO([
        macho.FatSlice(
          cputype: macho.cpuTypeX86_64,
          cpusubtype: macho.cpuSubtypeX86_64All,
          bytes: x86Slice,
        ),
        macho.FatSlice(
          cputype: macho.cpuTypeArm64,
          cpusubtype: macho.cpuSubtypeArm64All,
          bytes: arm64Slice,
        ),
      ]);
      expect(macho.isFatMachO(fatInput), isTrue);

      // Patch all slices in fat binary.
      final patchedFat = macho.patchMachO(
        fatInput,
        macho.PatchOptions(
          platform: macho.platformIosSimulator,
          minOs: macho.parsePackedVersion('15.4'),
          sdkVersion: macho.parsePackedVersion('17.0'),
          installName: '@rpath/MyFat.framework/MyFat',
        ),
      );
      expect(macho.isFatMachO(patchedFat), isTrue);
      final slices = macho.extractFatSlices(patchedFat);
      expect(slices.length, 2);
      for (final s in slices) {
        final cmds = macho.parseLoadCommands(s.bytes);
        final idCmd = cmds.singleWhere((c) => c.cmd == macho.lcIdDylib);
        expect(_readCString(idCmd.bytes, 24), '@rpath/MyFat.framework/MyFat');
        final bvCmd = cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion);
        final bvBd = ByteData.sublistView(bvCmd.bytes);
        expect(bvBd.getUint32(8, Endian.little), macho.platformIosSimulator);
        expect(bvBd.getUint32(12, Endian.little), 0x000f0400);
        expect(bvBd.getUint32(16, Endian.little), 0x00110000);
      }

      // Thin fat binary to arm64 slice while patching.
      final thinnedArm64 = macho.patchMachO(
        fatInput,
        macho.PatchOptions(
          platform: macho.platformIos,
          minOs: macho.parsePackedVersion('16.1'),
          sdkVersion: macho.parsePackedVersion('17.0'),
          installName: '@rpath/Thinned.framework/Thinned',
          arch: 'arm64',
        ),
      );
      expect(macho.isFatMachO(thinnedArm64), isFalse);
      expect(macho.isMachO64(thinnedArm64), isTrue);
      expect(
        ByteData.sublistView(thinnedArm64).getUint32(4, Endian.little),
        macho.cpuTypeArm64,
      );
      final thinCmds = macho.parseLoadCommands(thinnedArm64);
      expect(
        _readCString(
          thinCmds.singleWhere((c) => c.cmd == macho.lcIdDylib).bytes,
          24,
        ),
        '@rpath/Thinned.framework/Thinned',
      );

      // Verify with hermetic llvm-lipo and llvm-objdump if available.
      final lipo = _resolveHermeticTool('LLVM_LIPO');
      final objdump = _resolveHermeticTool('LLVM_OBJDUMP');
      if (lipo != null && objdump != null) {
        final tempDir = Directory.systemTemp.createTempSync('macho_fat_test_');
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final fatPath = '${tempDir.path}/patched_fat.dylib';
        File(fatPath).writeAsBytesSync(patchedFat);

        final lipoRes = Process.runSync(lipo, ['-archs', fatPath]);
        expect(lipoRes.exitCode, 0, reason: '${lipoRes.stderr}');
        expect((lipoRes.stdout as String).trim(), 'x86_64 arm64');

        final objdumpRes = Process.runSync(objdump, [
          '--macho',
          '--private-headers',
          '--arch=all',
          fatPath,
        ]);
        expect(objdumpRes.exitCode, 0, reason: '${objdumpRes.stderr}');
        final out = objdumpRes.stdout as String;
        expect('minos 15.4'.allMatches(out).length, 2);
        expect('@rpath/MyFat.framework/MyFat'.allMatches(out).length, 2);
      }
    });

    test(
      'rejects 32-bit Mach-O and non-Mach-O inputs with FormatException',
      () {
        final macho32 = _buildMachO32();
        expect(macho.isMachO32(macho32), isTrue);
        expect(
          () => macho.patchMachO(
            macho32,
            macho.PatchOptions(
              platform: macho.platformIos,
              minOs: macho.parsePackedVersion('13.0'),
            ),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('32-bit Mach-O'),
            ),
          ),
        );

        // Fat binary containing a 32-bit slice must also fail loudly.
        final fatWith32 = macho.buildFatMachO([
          macho.FatSlice(
            cputype: macho.cpuTypeArm,
            cpusubtype: 9,
            bytes: macho32,
          ),
        ]);
        expect(macho.isFatMachO(fatWith32), isTrue);
        expect(
          () => macho.patchMachO(
            fatWith32,
            macho.PatchOptions(
              platform: macho.platformIos,
              minOs: macho.parsePackedVersion('13.0'),
            ),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('32-bit Mach-O'),
            ),
          ),
        );

        // Plain non-Mach-O bytes must fail loudly.
        final plainBytes = Uint8List.fromList(
          utf8.encode('not a macho binary'),
        );
        expect(
          () => macho.patchMachO(
            plainBytes,
            macho.PatchOptions(
              platform: macho.platformMacos,
              minOs: macho.parsePackedVersion('11.0'),
            ),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Not a Mach-O'),
            ),
          ),
        );
      },
    );

    test(
      'patches every load-command kind and pins the patched bytes',
      () {
        final input = _buildFullCoverageMachO();
        final patched = macho.patchMachO(
          input,
          macho.PatchOptions(
            platform: macho.platformIos,
            minOs: macho.parsePackedVersion('13.0'),
            sdkVersion: macho.parsePackedVersion('16.0'),
            installName: '@rpath/New.framework/New',
            rpaths: ['@executable_path/Frameworks'],
          ),
        );
        expect(patched.length, input.length);

        // All four legacy version-min commands are stripped; the linkedit
        // table commands keep their offsets; build-version and rpath append.
        expect(macho.parseLoadCommands(patched).map((c) => c.cmd), [
          macho.lcSegment64,
          macho.lcSegment64,
          macho.lcSymtab,
          macho.lcDysymtab,
          macho.lcFunctionStarts,
          macho.lcDataInCode,
          macho.lcDyldExportsTrie,
          macho.lcDyldChainedFixups,
          macho.lcIdDylib,
          macho.lcBuildVersion,
          macho.lcRpath,
        ]);

        final idCmd = macho
            .parseLoadCommands(patched)
            .singleWhere((c) => c.cmd == macho.lcIdDylib);
        expect(_readCString(idCmd.bytes, 24), '@rpath/New.framework/New');

        // Section and linkedit payload bytes survive the rewrite untouched.
        expect(patched.sublist(0x1000, 0x1200), input.sublist(0x1000, 0x1200));
        expect(patched.sublist(0x4000, 0x5000), input.sublist(0x4000, 0x5000));

        // Pins the patched bytes: any moved byte fails this digest.
        expect(
          _hex(macho.sha256(patched)),
          'b6730c0ff3cdd07b52f2e122679a38b27865479eaee0db94ae49af27b5364fcc',
        );
      },
    );

    test('patches a fat64 binary and keeps the fat64 header', () {
      final arm = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('11.0'),
        installName: '@rpath/Old.dylib',
      );
      final fat64 = macho.buildFatMachO([
        macho.FatSlice(
          cputype: macho.cpuTypeArm64,
          cpusubtype: macho.cpuSubtypeArm64All,
          bytes: arm,
        ),
      ], fat64: true);
      expect(macho.isFatMachO(fat64), isTrue);

      final patched = macho.patchMachO(
        fat64,
        macho.PatchOptions(
          platform: macho.platformIos,
          minOs: macho.parsePackedVersion('13.0'),
          installName: '@rpath/New.dylib',
        ),
      );
      expect(
        ByteData.sublistView(patched).getUint32(0, Endian.big),
        macho.fatMagic64,
      );
      final slices = macho.extractFatSlices(patched);
      expect(slices.length, 1);
      final cmds = macho.parseLoadCommands(slices.single.bytes);
      expect(
        _readCString(
          cmds.singleWhere((c) => c.cmd == macho.lcIdDylib).bytes,
          24,
        ),
        '@rpath/New.dylib',
      );
      expect(
        _hex(macho.sha256(patched)),
        '36506d4d5d9e1190abc535e120d81b15cb5bb74f8f801412e159ef83428a7cc3',
      );
    });

    test('checks the requested arch against a thin binary', () {
      final stub = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('11.0'),
        installName: '@rpath/Arch.dylib',
      );
      final matched = macho.patchMachO(
        stub,
        macho.PatchOptions(
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('12.0'),
          arch: 'arm64',
        ),
      );
      expect(macho.isMachO64(matched), isTrue);
      expect(
        () => macho.patchMachO(
          stub,
          macho.PatchOptions(
            platform: macho.platformMacos,
            minOs: macho.parsePackedVersion('12.0'),
            arch: 'x86_64',
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('does not match'),
          ),
        ),
      );
    });

    test('adds LC_ID_DYLIB to an execute stub that has none', () {
      final stub = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformIos,
        minOs: macho.parsePackedVersion('14.0'),
        sdkVersion: macho.parsePackedVersion('14.0'),
        installName: '',
        fileType: macho.mhExecute,
      );
      expect(
        macho.parseLoadCommands(stub).where((c) => c.cmd == macho.lcIdDylib),
        isEmpty,
      );
      final patched = macho.patchMachO(
        stub,
        macho.PatchOptions(
          platform: macho.platformIos,
          minOs: macho.parsePackedVersion('14.0'),
          installName: '@rpath/Runner',
        ),
      );
      final cmds = macho.parseLoadCommands(patched);
      expect(
        _readCString(
          cmds.singleWhere((c) => c.cmd == macho.lcIdDylib).bytes,
          24,
        ),
        '@rpath/Runner',
      );
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

    test('patch fails loudly on non-Mach-O and 32-bit Mach-O unless named in --allow-non-macho', () {
      final dummyIn = File('${tempDir.path}/dummy.dylib')
        ..writeAsStringSync('not a macho file');
      final macho32In = File('${tempDir.path}/legacy32.dylib')
        ..writeAsBytesSync(_buildMachO32());
      final dummyOut = File('${tempDir.path}/out.dylib');

      // Without --allow-non-macho, non-Mach-O fails with FormatException.
      expect(
        () => macho.main([
          'patch',
          '--input',
          dummyIn.path,
          '--output',
          dummyOut.path,
          '--install-name',
          '@rpath/Foo.framework/Foo',
        ]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('dummy.dylib'), contains('non-Mach-O')),
          ),
        ),
      );

      // Without --allow-non-macho (or with a different name), 32-bit Mach-O fails.
      expect(
        () => macho.main([
          'patch',
          '--input',
          macho32In.path,
          '--output',
          dummyOut.path,
          '--install-name',
          '@rpath/Legacy.framework/Legacy',
          '--allow-non-macho',
          'Other.framework',
        ]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('legacy32.dylib'), contains('32-bit Mach-O')),
          ),
        ),
      );

      // Naming the input or framework in --allow-non-macho allows it through.
      macho.main([
        'patch',
        '--input',
        dummyIn.path,
        '--output',
        dummyOut.path,
        '--install-name',
        '@rpath/Foo.framework/Foo',
        '--allow-non-macho',
        'dummy.dylib',
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
      expect(
        bd.getUint32(24, Endian.little),
        macho.mhNoundefs | macho.mhDyldlink | macho.mhTwolevel | macho.mhPie,
      );
      final cmds = macho.parseLoadCommands(bytes);
      expect(cmds.where((c) => c.cmd == macho.lcIdDylib), isEmpty);
      expect(cmds.where((c) => c.cmd == macho.lcBuildVersion).length, 1);
      expect(cmds.where((c) => c.cmd == macho.lcUuid).length, 1);
      expect(cmds.where((c) => c.cmd == macho.lcSymtab).length, 1);
      expect(cmds.where((c) => c.cmd == macho.lcDysymtab).length, 1);
      expect(cmds.where((c) => c.cmd == macho.lcRpath).length, 1);

      final macExecPath = '${tempDir.path}/MacRunner';
      macho.main([
        'stub',
        '--type',
        'execute',
        '--output',
        macExecPath,
        '--arch',
        'arm64',
        '--platform',
        'macos',
        '--min-os',
        '11.0',
      ]);
      final macCmds = macho.parseLoadCommands(
        File(macExecPath).readAsBytesSync(),
      );
      final macRpaths = macCmds
          .where((c) => c.cmd == macho.lcRpath)
          .map((c) => _readCString(c.bytes, 12))
          .toList();
      expect(
        macRpaths,
        containsAll([
          '@executable_path/../Frameworks',
          '@executable_path/Frameworks',
        ]),
      );
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
      'assemble-macos-framework builds versioned macOS App.framework layout and zip',
      () {
        final dylibBytes = macho.generateStubMachO(
          arch: 'arm64',
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('15.0'),
          sdkVersion: macho.parsePackedVersion('15.0'),
          installName: '@rpath/App.framework/Versions/A/App',
        );
        final binFile = File('${tempDir.path}/App_bin')
          ..writeAsBytesSync(dylibBytes);
        const plistXml =
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<plist version="1.0"><dict>\n'
            '  <key>CFBundleExecutable</key><string>App</string>\n'
            '  <key>CFBundleIdentifier</key><string>io.flutter.flutter.app</string>\n'
            '  <key>CFBundlePackageType</key><string>FMWK</string>\n'
            '</dict></plist>\n';
        final plistFile = File('${tempDir.path}/Info.plist')
          ..writeAsStringSync(plistXml);
        final assetsDir = Directory('${tempDir.path}/flutter_assets')
          ..createSync(recursive: true);
        File('${assetsDir.path}/AssetManifest.bin').writeAsBytesSync([9, 9]);
        final wrapperDir = '${tempDir.path}/wrapper';
        final outputZip = '${tempDir.path}/App.framework.zip';

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
          '--output-zip',
          outputZip,
        ]);

        final fwPath = '$wrapperDir/App.framework';
        expect(
          File('$fwPath/Versions/A/App').readAsBytesSync(),
          equals(dylibBytes),
        );
        expect(
          File('$fwPath/Versions/A/Resources/Info.plist').readAsStringSync(),
          plistXml,
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

        // Verify the framework directory and zip pass verifyMacosFramework.
        macho.verifyMacosFramework(
          fwPath,
          frameworkName: 'App',
          frameworkZipPath: outputZip,
        );

        // Corrupting a symlink into a regular file (as rules_apple's _add_files does
        // when AppleBundleInfo is absent) must fail verifyMacosFramework.
        Link('$fwPath/App').deleteSync();
        File('$fwPath/App').writeAsBytesSync(dylibBytes);
        expect(
          () => macho.verifyMacosFramework(fwPath, frameworkName: 'App'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Expected top-level symlink at'),
            ),
          ),
        );
      },
    );

    test(
      'extractFrameworkZip recreates the versioned layout with real symlinks',
      () {
        final dylibBytes = macho.generateStubMachO(
          arch: 'arm64',
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('15.0'),
          sdkVersion: macho.parsePackedVersion('15.0'),
          installName: '@rpath/App.framework/Versions/A/App',
        );
        final binFile = File('${tempDir.path}/App_bin2')
          ..writeAsBytesSync(dylibBytes);
        const plistXml =
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<plist version="1.0"><dict>\n'
            '  <key>CFBundleExecutable</key><string>App</string>\n'
            '  <key>CFBundleIdentifier</key><string>io.flutter.flutter.app</string>\n'
            '  <key>CFBundlePackageType</key><string>FMWK</string>\n'
            '</dict></plist>\n';
        final plistFile = File('${tempDir.path}/Info2.plist')
          ..writeAsStringSync(plistXml);
        final assetsDir = Directory('${tempDir.path}/flutter_assets2')
          ..createSync(recursive: true);
        File('${assetsDir.path}/a.txt').writeAsStringSync('asset');
        final wrapperDir = '${tempDir.path}/wrapper2';
        final outputZip = '${tempDir.path}/App2.framework.zip';

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
          '--output-zip',
          outputZip,
        ]);

        // A consumer extracts the archive locally instead of trusting Bazel
        // to stage the framework tree with its symlinks intact.
        final extractedRoot = Directory('${tempDir.path}/extracted')
          ..createSync(recursive: true);
        macho.extractFrameworkZip(
          File(outputZip).readAsBytesSync(),
          extractedRoot,
        );
        final fwPath = '${extractedRoot.path}/App.framework';
        expect(
          File('$fwPath/Versions/A/App').readAsBytesSync(),
          equals(dylibBytes),
        );
        expect(
          File('$fwPath/Versions/A/Resources/flutter_assets/a.txt')
              .readAsStringSync(),
          'asset',
        );
        expect(
          FileSystemEntity.typeSync(
            '$fwPath/Versions/Current',
            followLinks: false,
          ),
          FileSystemEntityType.link,
        );
        expect(Link('$fwPath/Versions/Current').targetSync(), 'A');
        expect(Link('$fwPath/App').targetSync(), 'Versions/Current/App');
        expect(
          Link('$fwPath/Resources').targetSync(),
          'Versions/Current/Resources',
        );
        macho.verifyMacosFramework(
          fwPath,
          frameworkName: 'App',
          frameworkZipPath: outputZip,
        );
      },
    );

    test('extractFrameworkZip refuses unsafe entry paths and targets', () {
      Directory fresh(String name) =>
          Directory('${tempDir.path}/$name')..createSync(recursive: true);

      // Well-formed entries extract with contents and link targets intact.
      final goodDir = fresh('good');
      macho.extractFrameworkZip(
        _storedZip(
          {
            'F/Versions/A/f': [1, 2, 3],
          },
          symlinks: {
            'F/Versions/Current': 'A',
            'F/top': 'Versions/Current/f',
          },
        ),
        goodDir,
      );
      expect(File('${goodDir.path}/F/Versions/A/f').readAsBytesSync(), [
        1,
        2,
        3,
      ]);
      expect(Link('${goodDir.path}/F/Versions/Current').targetSync(), 'A');
      expect(Link('${goodDir.path}/F/top').targetSync(), 'Versions/Current/f');

      // Parent escapes in entry paths.
      expect(
        () => macho.extractFrameworkZip(
          _storedZip({
            '../evil': [1],
          }),
          fresh('evil1'),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => macho.extractFrameworkZip(
          _storedZip({
            'F/../../evil': [1],
          }),
          fresh('evil2'),
        ),
        throwsA(isA<FormatException>()),
      );
      // Absolute entry path.
      expect(
        () => macho.extractFrameworkZip(
          _storedZip({
            '/abs/evil': [1],
          }),
          fresh('evil3'),
        ),
        throwsA(isA<FormatException>()),
      );
      // Absolute and escaping symlink targets.
      expect(
        () => macho.extractFrameworkZip(
          _storedZip(
            {
              'F/Versions/A/f': [1],
            },
            symlinks: {'F/l': '/abs'},
          ),
          fresh('evil4'),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => macho.extractFrameworkZip(
          _storedZip(
            {
              'F/Versions/A/f': [1],
            },
            symlinks: {'F/l': '../A'},
          ),
          fresh('evil5'),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'copy-files copies source files under basenames or explicit names and patches when --platform/--min-os are given',
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

        // With --platform and --min-os, copy-files rewrites LC_BUILD_VERSION on Mach-O dylibs
        // and rejects non-Mach-O files unless named in --allow-non-macho.
        final machoLib = File('${tempDir.path}/three/libreal.dylib')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(
            macho.generateStubMachO(
              arch: 'arm64',
              platform: macho.platformMacos,
              minOs: macho.parsePackedVersion('10.15'),
              sdkVersion: macho.parsePackedVersion('10.15'),
              installName: '@rpath/libreal.dylib',
            ),
          );
        final patchedStaged = '${tempDir.path}/staged_patched';
        expect(
          () => macho.main([
            'copy-files',
            '--platform',
            'macos',
            '--min-os',
            '13.2',
            '--sdk-version',
            '13.2',
            '--output-dir',
            patchedStaged,
            f1.path,
            'libadd.dylib',
          ]),
          throwsA(isA<FormatException>()),
        );

        macho.main([
          'copy-files',
          '--platform',
          'macos',
          '--min-os',
          '13.2',
          '--sdk-version',
          '13.2',
          '--allow-non-macho',
          'libadd.dylib',
          '--output-dir',
          patchedStaged,
          machoLib.path,
          'libreal.dylib',
          f1.path,
          'libadd.dylib',
        ]);

        final realCmds = macho.parseLoadCommands(
          File('$patchedStaged/libreal.dylib').readAsBytesSync(),
        );
        final bvBd = ByteData.sublistView(
          realCmds.singleWhere((c) => c.cmd == macho.lcBuildVersion).bytes,
        );
        expect(bvBd.getUint32(12, Endian.little), 0x000d0200);
        expect(File('$patchedStaged/libadd.dylib').readAsStringSync(), 'add');
      },
    );

    test('fat combines thin slices into a universal binary', () {
      final armPath = '${tempDir.path}/arm.dylib';
      final x86Path = '${tempDir.path}/x86.dylib';
      final fatPath = '${tempDir.path}/fat.dylib';
      File(armPath).writeAsBytesSync(
        macho.generateStubMachO(
          arch: 'arm64',
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('11.0'),
          sdkVersion: macho.parsePackedVersion('11.0'),
          installName: '@rpath/Fat.dylib',
        ),
      );
      File(x86Path).writeAsBytesSync(
        macho.generateStubMachO(
          arch: 'x86_64',
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('11.0'),
          sdkVersion: macho.parsePackedVersion('11.0'),
          installName: '@rpath/Fat.dylib',
        ),
      );

      macho.main(['fat', '--output', fatPath, armPath, x86Path]);

      final fat = File(fatPath).readAsBytesSync();
      expect(macho.isFatMachO(fat), isTrue);
      expect(macho.extractFatSlices(fat).length, 2);
    });

    test('verify checks a thin dylib and writes the stamp file', () {
      final libPath = '${tempDir.path}/libverify.dylib';
      final stampPath = '${tempDir.path}/verified.stamp';
      File(libPath).writeAsBytesSync(
        macho.generateStubMachO(
          arch: 'arm64',
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('11.0'),
          sdkVersion: macho.parsePackedVersion('11.0'),
          installName: '@rpath/Verify.dylib',
        ),
      );

      macho.main(['verify', '--input', libPath, '--output', stampPath]);

      expect(File(stampPath).readAsStringSync(), 'verified\n');
    });

    test('verify checks a binary inside a zip archive', () {
      final zipPath = '${tempDir.path}/app.zip';
      File(zipPath).writeAsBytesSync(
        _storedZip({
          'Payload/App': macho.generateStubMachO(
            arch: 'arm64',
            platform: macho.platformMacos,
            minOs: macho.parsePackedVersion('11.0'),
            sdkVersion: macho.parsePackedVersion('11.0'),
            installName: '@rpath/Verify.dylib',
          ),
        }),
      );
      final stampPath = '${tempDir.path}/zip.stamp';

      macho.main([
        'verify',
        '--input',
        zipPath,
        '--binary-relpath',
        'Payload/App',
        '--expect-entry',
        'Payload/App',
        '--output',
        stampPath,
      ]);
      expect(File(stampPath).readAsStringSync(), 'verified\n');

      expect(
        () => macho.main([
          'verify',
          '--input',
          zipPath,
          '--binary-relpath',
          'Payload/App',
          '--expect-entry',
          'Payload/Missing',
          '--output',
          stampPath,
        ]),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('thinFatMachO', () {
    test('reports a missing arch and 32-bit-only binaries', () {
      final arm = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('11.0'),
        installName: '@rpath/Thin.dylib',
      );
      final fat = macho.buildFatMachO([
        macho.FatSlice(
          cputype: macho.cpuTypeArm64,
          cpusubtype: macho.cpuSubtypeArm64All,
          bytes: arm,
        ),
      ]);
      expect(
        () => macho.thinFatMachO(fat, 'x86_64'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('does not contain a slice'),
          ),
        ),
      );

      final fat32 = macho.buildFatMachO([
        macho.FatSlice(
          cputype: macho.cpuTypeArm,
          cpusubtype: 9,
          bytes: _buildMachO32(),
        ),
      ]);
      expect(
        () => macho.thinFatMachO(fat32, 'arm64'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('32-bit'),
          ),
        ),
      );
    });
  });

  group('frameworkZipDeflate', () {
    test('compresses large payloads and pins the archive bytes', () {
      final dir = Directory.systemTemp.createTempSync('macho_zip_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sliceDir = Directory('${dir.path}/App.framework/Versions/A')
        ..createSync(recursive: true);
      final big = Uint8List(8192);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i ~/ 64) & 0xff;
      }
      File('${sliceDir.path}/App').writeAsBytesSync(big);
      File('${sliceDir.path}/small.txt').writeAsStringSync('x');

      final zip = macho.createFrameworkZipBytes(
        Directory('${dir.path}/App.framework'),
        archiveRootName: 'App.framework',
        executableRelPaths: {'App.framework/Versions/A/App'},
      );

      // 8 KiB of repetitive payload must deflate well below its raw size.
      expect(zip.length, lessThan(1024));
      final entries = macho.readFrameworkZipEntries(zip);
      expect(entries.length, 2);
      expect(entries.singleWhere((e) => e.path.endsWith('/App')).data, big);
      expect(
        _hex(macho.sha256(zip)),
        'f8c76bcd3d1d1ac19ab345a1043d3916f94ce22b188951762bb5f66dcd838ec4',
      );
    });
  });
}
