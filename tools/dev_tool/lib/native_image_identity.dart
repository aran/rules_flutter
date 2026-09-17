/// Which build of a native library an app is carrying, by the identity its
/// linker stamped into it.
///
/// A patch is built against one exact image: its addresses are that image's
/// addresses, and a patch linked against a sibling build of the same source
/// would call into the running process at offsets that mean something else. So
/// the dev tool has to know which of the libraries a build produced is the one
/// the app bundled — and a build can produce several. A platform rule reaches its
/// `native_deps` both at the top level and through its own transition, so the
/// same `libbridge.dylib` exists twice, compiled twice, at different addresses.
///
/// Bytes cannot decide it. Bundling rewrites Apple libraries — measured on a
/// macOS app, the bundled `libmul.dylib` was 35008 bytes against the 16976 the
/// link wrote, because the bundler signs it — so no build output is
/// byte-identical to what the app loaded. The linker's own identity survives
/// that: a Mach-O `LC_UUID` is untouched by signing and by `install_name_tool`,
/// and an ELF build-id by stripping and by packaging, and it differs between
/// the two configurations (measured: the same two dylibs carried different
/// UUIDs).
library;

import 'dart:io';
import 'dart:typed_data';

/// The linker-assigned identity of the image in [bytes] — `uuid:<hex>` for
/// Mach-O, `build-id:<hex>` for ELF — or null when it carries none or is
/// neither format.
String? nativeImageIdentity(Uint8List bytes) =>
    _machOUuid(bytes) ?? _elfBuildId(bytes);

String _hex(Uint8List bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

const _machOMagic64 = 0xfeedfacf;
const _lcUuid = 0x1b;

String? _machOUuid(Uint8List bytes) {
  if (bytes.length < 32) return null;
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0, Endian.little) != _machOMagic64) return null;
  final commands = data.getUint32(16, Endian.little);
  var at = 32;
  for (var i = 0; i < commands && at + 8 <= bytes.length; i++) {
    final command = data.getUint32(at, Endian.little);
    final size = data.getUint32(at + 4, Endian.little);
    if (command == _lcUuid && at + 24 <= bytes.length) {
      return 'uuid:${_hex(Uint8List.sublistView(bytes, at + 8, at + 24))}';
    }
    if (size < 8) return null;
    at += size;
  }
  return null;
}

const _ptNote = 4;
const _ntGnuBuildId = 3;

String? _elfBuildId(Uint8List bytes) {
  if (bytes.length < 52 ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4c ||
      bytes[3] != 0x46) {
    return null;
  }
  // Little-endian only: every Flutter target's ELF is.
  if (bytes[5] != 1) return null;
  final wide = bytes[4] == 2;
  final data = ByteData.sublistView(bytes);
  int word(int at) => wide
      ? data.getUint64(at, Endian.little)
      : data.getUint32(at, Endian.little);

  final headersAt = word(wide ? 0x20 : 0x1c);
  final headerSize = data.getUint16(wide ? 0x36 : 0x2a, Endian.little);
  final headerCount = data.getUint16(wide ? 0x38 : 0x2c, Endian.little);
  for (var i = 0; i < headerCount; i++) {
    final header = headersAt + i * headerSize;
    if (header + headerSize > bytes.length) return null;
    if (data.getUint32(header, Endian.little) != _ptNote) continue;
    final offset = word(header + (wide ? 0x08 : 0x04));
    final size = word(header + (wide ? 0x20 : 0x10));
    final id = _buildIdNote(bytes, offset, size);
    if (id != null) return id;
  }
  return null;
}

String? _buildIdNote(Uint8List bytes, int offset, int size) {
  final data = ByteData.sublistView(bytes);
  final end = offset + size;
  var at = offset;
  int aligned(int n) => (n + 3) & ~3;
  while (at + 12 <= end && end <= bytes.length) {
    final nameSize = data.getUint32(at, Endian.little);
    final descSize = data.getUint32(at + 4, Endian.little);
    final type = data.getUint32(at + 8, Endian.little);
    final nameAt = at + 12;
    final descAt = nameAt + aligned(nameSize);
    if (descAt + descSize > end) return null;
    final isGnu =
        nameSize == 4 &&
        bytes[nameAt] == 0x47 &&
        bytes[nameAt + 1] == 0x4e &&
        bytes[nameAt + 2] == 0x55 &&
        bytes[nameAt + 3] == 0;
    if (isGnu && type == _ntGnuBuildId) {
      return 'build-id:${_hex(Uint8List.sublistView(bytes, descAt, descAt + descSize))}';
    }
    at = descAt + aligned(descSize);
  }
  return null;
}

/// The bytes of [member] inside the launched artifact at [artifactPath]: a file
/// under a bundle directory, or an entry of an `.apk`, `.ipa` or `.zip`.
Future<Uint8List> readBundledFile(String artifactPath, String member) async {
  if (const ['.zip', '.ipa', '.apk'].any(artifactPath.endsWith)) {
    return _readZipMember(artifactPath, member);
  }
  return File('$artifactPath/$member').readAsBytes();
}

const _eocdSignature = 0x06054b50;
const _centralDirSignature = 0x02014b50;
const _localHeaderSignature = 0x04034b50;

Future<Uint8List> _readZipMember(String zipPath, String member) async {
  final raf = await File(zipPath).open();
  try {
    final length = await raf.length();
    final tailLength = length < 65558 ? length : 65558;
    await raf.setPosition(length - tailLength);
    final tail = await raf.read(tailLength);
    final tailData = ByteData.sublistView(tail);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tailData.getUint32(i, Endian.little) == _eocdSignature) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      throw FormatException('No zip end-of-central-directory in $zipPath');
    }
    final entries = tailData.getUint16(eocd + 10, Endian.little);
    final directorySize = tailData.getUint32(eocd + 12, Endian.little);
    final directoryOffset = tailData.getUint32(eocd + 16, Endian.little);
    await raf.setPosition(directoryOffset);
    final directory = await raf.read(directorySize);
    final data = ByteData.sublistView(directory);
    var at = 0;
    for (var i = 0; i < entries; i++) {
      if (data.getUint32(at, Endian.little) != _centralDirSignature) {
        throw FormatException('Corrupt zip central directory in $zipPath');
      }
      final method = data.getUint16(at + 10, Endian.little);
      final compressedSize = data.getUint32(at + 20, Endian.little);
      final nameLength = data.getUint16(at + 28, Endian.little);
      final extraLength = data.getUint16(at + 30, Endian.little);
      final commentLength = data.getUint16(at + 32, Endian.little);
      final localOffset = data.getUint32(at + 42, Endian.little);
      final name = String.fromCharCodes(
        directory.sublist(at + 46, at + 46 + nameLength),
      );
      at += 46 + nameLength + extraLength + commentLength;
      if (name != member) continue;

      await raf.setPosition(localOffset);
      final local = await raf.read(30);
      final localData = ByteData.sublistView(local);
      if (localData.getUint32(0, Endian.little) != _localHeaderSignature) {
        throw FormatException(
          'Corrupt zip local header for $member in $zipPath',
        );
      }
      final skip =
          localData.getUint16(26, Endian.little) +
          localData.getUint16(28, Endian.little);
      await raf.setPosition(localOffset + 30 + skip);
      final stored = await raf.read(compressedSize);
      return switch (method) {
        0 => stored,
        8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(stored)),
        _ => throw FormatException(
          '$member in $zipPath uses zip compression method $method, which the '
          'dev tool cannot read',
        ),
      };
    }
    throw FormatException('$zipPath has no entry $member');
  } finally {
    await raf.close();
  }
}
