/// Hermetic zip fixtures for dev_tool tests.
///
/// The host may not have `zip`/`unzip` binaries, so tests build and read their
/// archives in-process instead of spawning them: [writeTestZip] walks a
/// directory the test already laid out and writes a minimal deterministic zip
/// (stored or deflated entries, fixed DOS timestamp) with `dart:io`'s raw
/// deflate and a small CRC-32. Entry names, contents and compression methods
/// match what `zip -r` would have written for the same tree. [extractZip]
/// unpacks such an archive again, for tests that consume a zip file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Writes the directory [member] under [root] to [outPath], like running
/// `zip -r <out> <member>` with [root] as the working directory. Directory
/// entries are included, names use `/` separators, and the output is
/// deterministic (sorted entries, fixed timestamp). With [deflate] false every
/// entry is stored, like `zip -0`; otherwise entries are deflated when the
/// deflated form is shorter, like `zip`'s default.
void writeTestZip({
  required String outPath,
  required Directory root,
  required String member,
  bool deflate = true,
}) {
  final entries = <_Entry>[];
  _collect(entries, root, member);
  File(outPath).writeAsBytesSync(_encodeZip(entries, deflate: deflate));
}

class _Entry {
  final String name;
  final Uint8List data;
  final bool isDirectory;

  _Entry(this.name, this.data, this.isDirectory);
}

void _collect(List<_Entry> entries, Directory root, String rel) {
  final path = '${root.path}/$rel';
  switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    case FileSystemEntityType.directory:
      entries.add(_Entry('$rel/', Uint8List(0), true));
      final children = Directory(path).listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        final name = child.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        _collect(entries, root, '$rel/$name');
      }
    case FileSystemEntityType.file:
      entries.add(_Entry(rel, File(path).readAsBytesSync(), false));
    case FileSystemEntityType.link:
      throw ArgumentError('zip fixture cannot archive symlink: $path');
    case FileSystemEntityType.notFound:
      throw ArgumentError('zip fixture has no such entry: $path');
  }
}

/// IEEE 802.3 CRC-32, computed bit by bit: fixtures are kilobytes, so no
/// lookup table is worth carrying.
int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

const _dosTime = 0x0000;
const _dosDate = 0x0021; // 1980-01-01, the deterministic-zip epoch.

Uint8List _encodeZip(List<_Entry> entries, {required bool deflate}) {
  final local = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  final offsets = <int>[];
  var offset = 0;
  for (final entry in entries) {
    final name = Uint8List.fromList(entry.name.codeUnits);
    final crc = entry.isDirectory ? 0 : _crc32(entry.data);
    var method = 0;
    var payload = entry.data;
    if (deflate && !entry.isDirectory && entry.data.isNotEmpty) {
      final compressed = Uint8List.fromList(
        ZLibEncoder(raw: true).convert(entry.data),
      );
      if (compressed.length < entry.data.length) {
        method = 8;
        payload = compressed;
      }
    }
    offsets.add(offset);
    offset += _writeLocal(local, name, payload, method, crc, entry.data.length);
    _writeCentral(
      central,
      name,
      payload.length,
      entry.data.length,
      method,
      crc,
      entry.isDirectory,
      offsets.last,
    );
  }
  final centralBytes = central.takeBytes();
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, offset, Endian.little);
  return Uint8List.fromList([
    ...local.takeBytes(),
    ...centralBytes,
    ...end.buffer.asUint8List(),
  ]);
}

/// Appends a local file header plus [payload]; answers the bytes appended.
int _writeLocal(
  BytesBuilder out,
  Uint8List name,
  Uint8List payload,
  int method,
  int crc,
  int uncompressedSize,
) {
  final header = ByteData(30 + name.length)
    ..setUint32(0, 0x04034b50, Endian.little)
    ..setUint16(4, 20, Endian.little)
    ..setUint16(6, 0x0800, Endian.little)
    ..setUint16(8, method, Endian.little)
    ..setUint16(10, _dosTime, Endian.little)
    ..setUint16(12, _dosDate, Endian.little)
    ..setUint32(14, crc, Endian.little)
    ..setUint32(18, payload.length, Endian.little)
    ..setUint32(22, uncompressedSize, Endian.little)
    ..setUint16(26, name.length, Endian.little);
  header.buffer.asUint8List().setRange(30, 30 + name.length, name);
  out.add(header.buffer.asUint8List());
  out.add(payload);
  return 30 + name.length + payload.length;
}

void _writeCentral(
  BytesBuilder out,
  Uint8List name,
  int compressedSize,
  int uncompressedSize,
  int method,
  int crc,
  bool isDirectory,
  int localOffset,
) {
  final externalAttrs = isDirectory ? (0x41ED << 16) | 0x10 : (0x81A4 << 16);
  final header = ByteData(46 + name.length)
    ..setUint32(0, 0x02014b50, Endian.little)
    ..setUint16(4, (3 << 8) | 20, Endian.little)
    ..setUint16(6, 20, Endian.little)
    ..setUint16(8, 0x0800, Endian.little)
    ..setUint16(10, method, Endian.little)
    ..setUint16(12, _dosTime, Endian.little)
    ..setUint16(14, _dosDate, Endian.little)
    ..setUint32(16, crc, Endian.little)
    ..setUint32(20, compressedSize, Endian.little)
    ..setUint32(24, uncompressedSize, Endian.little)
    ..setUint16(28, name.length, Endian.little)
    ..setUint32(38, externalAttrs, Endian.little)
    ..setUint32(42, localOffset, Endian.little);
  header.buffer.asUint8List().setRange(46, 46 + name.length, name);
  out.add(header.buffer.asUint8List());
}

// ---------------------------------------------------------------------------
// Reader: extractZip.
// ---------------------------------------------------------------------------

/// A validated zip entry, fully read and CRC-checked before anything is
/// written to disk.
class _ReadEntry {
  final String name;
  final Uint8List data;
  final int unixMode;
  final bool isDirectory;
  final bool isSymlink;

  _ReadEntry(
    this.name,
    this.data,
    this.unixMode,
    this.isDirectory,
    this.isSymlink,
  );
}

/// Unpacks the zip at [zipPath] into [destDir], preserving Unix modes and
/// symlinks.
///
/// Reads stored (method 0) and deflated (method 8) entries and checks every
/// entry's CRC-32. Anything else — ZIP64, encryption, data descriptors, other
/// methods or file types, absolute or `..` paths — fails with a
/// [FormatException] before anything is written, so a rejected archive never
/// extracts partially.
Future<void> extractZip({
  required String zipPath,
  required Directory destDir,
}) async {
  final bytes = await File(zipPath).readAsBytes();
  final entries = _readAllEntries(bytes, zipPath);
  for (final entry in entries) {
    final path = '${destDir.path}/${entry.name}';
    if (entry.isDirectory) {
      Directory(path).createSync(recursive: true);
    } else if (entry.isSymlink) {
      Directory(path).parent.createSync(recursive: true);
      Link(path).createSync(utf8.decode(entry.data));
    } else {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.data);
    }
  }
  for (final entry in entries) {
    await _restoreMode(destDir, entry);
  }
}

/// Restores the archived Unix mode on [entry], unless it matches what the
/// fresh file already has. `chmod` is not an archive tool, and the repo's
/// tests already lean on it; Dart itself has no mode API.
Future<void> _restoreMode(Directory destDir, _ReadEntry entry) async {
  if (entry.isSymlink || (entry.unixMode & 0xF000) == 0) return;
  final path = '${destDir.path}/${entry.name}';
  final wanted = entry.unixMode & 0xFFF;
  if ((FileStat.statSync(path).mode & 0xFFF) == wanted) return;
  final r = await Process.run('chmod', [wanted.toRadixString(8), path]);
  if (r.exitCode != 0) {
    throw StateError('chmod $path failed: ${r.stderr}');
  }
}

List<_ReadEntry> _readAllEntries(Uint8List bytes, String zipPath) {
  final data = ByteData.sublistView(bytes);
  final tailStart =
      bytes.length - (bytes.length < 65558 ? bytes.length : 65558);
  var eocd = -1;
  for (var i = bytes.length - 22; i >= tailStart; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) {
    throw FormatException('No zip end-of-central-directory in $zipPath');
  }
  if (data.getUint16(eocd + 4, Endian.little) != 0 ||
      data.getUint16(eocd + 6, Endian.little) != 0) {
    throw FormatException(
      'Multi-disk zip archives are not supported: $zipPath',
    );
  }
  final thisDisk = data.getUint16(eocd + 8, Endian.little);
  final total = data.getUint16(eocd + 10, Endian.little);
  final cdSize = data.getUint32(eocd + 12, Endian.little);
  final cdOffset = data.getUint32(eocd + 16, Endian.little);
  if (thisDisk == 0xFFFF ||
      total == 0xFFFF ||
      cdSize == 0xFFFFFFFF ||
      cdOffset == 0xFFFFFFFF) {
    throw FormatException('ZIP64 archives are not supported: $zipPath');
  }
  if (thisDisk != total) {
    throw FormatException('Split zip archive: $zipPath');
  }
  final entries = <_ReadEntry>[];
  var at = cdOffset;
  for (var i = 0; i < total; i++) {
    at = _readCentralEntry(bytes, data, at, zipPath, entries);
  }
  return entries;
}

int _readCentralEntry(
  Uint8List bytes,
  ByteData data,
  int at,
  String zipPath,
  List<_ReadEntry> out,
) {
  if (data.getUint32(at, Endian.little) != 0x02014b50) {
    throw FormatException('Corrupt zip central directory in $zipPath');
  }
  final flags = data.getUint16(at + 8, Endian.little);
  final method = data.getUint16(at + 10, Endian.little);
  final crc = data.getUint32(at + 16, Endian.little);
  final compSize = data.getUint32(at + 20, Endian.little);
  final uncompSize = data.getUint32(at + 24, Endian.little);
  final nameLen = data.getUint16(at + 28, Endian.little);
  final extraLen = data.getUint16(at + 30, Endian.little);
  final commentLen = data.getUint16(at + 32, Endian.little);
  final externalAttrs = data.getUint32(at + 38, Endian.little);
  final localOffset = data.getUint32(at + 42, Endian.little);
  final name = utf8.decode(bytes.sublist(at + 46, at + 46 + nameLen));
  if (flags & 0x1 != 0) {
    throw FormatException(
      'Encrypted zip entries are not supported: $name in $zipPath',
    );
  }
  if (flags & 0x8 != 0) {
    throw FormatException(
      'Zip data descriptors are not supported: $name in $zipPath',
    );
  }
  if (method != 0 && method != 8) {
    throw FormatException(
      '$name in $zipPath uses zip compression method $method, '
      'which is not supported',
    );
  }
  if (compSize == 0xFFFFFFFF ||
      uncompSize == 0xFFFFFFFF ||
      localOffset == 0xFFFFFFFF) {
    throw FormatException('ZIP64 archives are not supported: $zipPath');
  }
  if (name.isEmpty || name.startsWith('/') || name.split('/').contains('..')) {
    throw FormatException(
      'Refusing to extract absolute or parent path: $name in $zipPath',
    );
  }
  final unixMode = (externalAttrs >> 16) & 0xFFFF;
  final kind = unixMode & 0xF000;
  final isDirectory = name.endsWith('/') || kind == 0x4000;
  final isSymlink = kind == 0xA000;
  if (!isDirectory && !isSymlink && kind != 0x8000 && kind != 0) {
    throw FormatException('Unsupported file type for $name in $zipPath');
  }
  out.add(
    _ReadEntry(
      name,
      _readEntryPayload(
        bytes,
        data,
        localOffset,
        method,
        compSize,
        uncompSize,
        crc,
        name,
        zipPath,
      ),
      unixMode,
      isDirectory,
      isSymlink,
    ),
  );
  return at + 46 + nameLen + extraLen + commentLen;
}

Uint8List _readEntryPayload(
  Uint8List bytes,
  ByteData data,
  int localOffset,
  int method,
  int compSize,
  int uncompSize,
  int crc,
  String name,
  String zipPath,
) {
  if (data.getUint32(localOffset, Endian.little) != 0x04034b50) {
    throw FormatException('Corrupt zip local header for $name in $zipPath');
  }
  if (data.getUint16(localOffset + 8, Endian.little) != method) {
    throw FormatException('Corrupt zip local header for $name in $zipPath');
  }
  final skip =
      data.getUint16(localOffset + 26, Endian.little) +
      data.getUint16(localOffset + 28, Endian.little);
  final start = localOffset + 30 + skip;
  final stored = bytes.sublist(start, start + compSize);
  final Uint8List out = switch (method) {
    0 => stored,
    _ => Uint8List.fromList(ZLibDecoder(raw: true).convert(stored)),
  };
  if (out.length != uncompSize) {
    throw FormatException('Size mismatch for $name in $zipPath');
  }
  if (_crc32(out) != crc) {
    throw FormatException('CRC mismatch for $name in $zipPath');
  }
  return out;
}
