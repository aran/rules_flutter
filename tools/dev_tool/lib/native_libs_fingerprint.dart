/// Fingerprinting of an app bundle's loose native libraries, used by the
/// restart path to decide between an in-process hot restart and a full
/// process relaunch.
///
/// A hot restart replaces Dart code but cannot replace native libraries:
/// the process keeps its originally-dlopened images, and in-process dylib
/// reload is unsound (library threads keep running in the old mapping). So
/// when a restart finds the rebuilt bundle's native libraries changed, the
/// dev tool must relaunch the process instead.
///
/// "Native libraries" means the loose `.dylib`/`.so`/`.dll` files bundled
/// into the app (macOS: `Contents/Frameworks/`) — the `native_deps`
/// contract. Framework directories are deliberately excluded:
/// `App.framework` changes on every Dart edit (it carries the kernel) and
/// would otherwise force a relaunch on every restart, and
/// `FlutterMacOS.framework` only changes with an engine bump.
library;

import 'dart:io';
import 'dart:typed_data';

/// Per-library content fingerprint, keyed by bundle-relative path. Values
/// are opaque content tokens — only equality across two calls with the
/// same artifact form matters.
///
/// [artifactPath] is the launch artifact: a `.zip` of the bundle (fingered
/// from the central directory's CRC32 + size, no extraction) or an
/// extracted `.app` directory (fingered by hashing file bytes).
///
/// An empty map means the bundle has no loose native libraries, in which
/// case the relaunch check should disable itself entirely.
Future<Map<String, String>> nativeLibsFingerprint(String artifactPath) async {
  if (artifactPath.endsWith('.zip')) {
    return _fromZipTableOfContents(artifactPath);
  }
  final dir = Directory(artifactPath);
  if (dir.existsSync()) return _fromExtractedBundle(dir);
  return const {};
}

bool fingerprintsEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// Names whose fingerprints differ between [before] and [after] (changed,
/// added, or removed).
List<String> changedLibs(Map<String, String> before, Map<String, String> after) {
  final names = {...before.keys, ...after.keys};
  return [
    for (final n in names)
      if (before[n] != after[n]) n,
  ]..sort();
}

bool _isLooseNativeLib(String path) {
  if (path.contains('.framework/')) return false;
  return path.endsWith('.dylib') || path.endsWith('.so') || path.endsWith('.dll');
}

// ---------------------------------------------------------------- zip TOC --

const _eocdSignature = 0x06054b50;
const _centralDirSignature = 0x02014b50;

/// Read CRC32 + uncompressed size per matching entry from the zip central
/// directory — content-sensitive and cheap (no decompression).
Future<Map<String, String>> _fromZipTableOfContents(String zipPath) async {
  final file = File(zipPath);
  final raf = await file.open();
  try {
    final length = await raf.length();
    // The end-of-central-directory record is within the last 64 KiB + 22
    // bytes (max comment length).
    final tailLen = length < 65558 ? length : 65558;
    await raf.setPosition(length - tailLen);
    final tail = await raf.read(tailLen);
    final eocd = _findEocd(tail);
    if (eocd < 0) {
      throw FormatException('No zip end-of-central-directory in $zipPath');
    }
    final bd = ByteData.sublistView(tail);
    final entryCount = bd.getUint16(eocd + 10, Endian.little);
    final cdSize = bd.getUint32(eocd + 12, Endian.little);
    final cdOffset = bd.getUint32(eocd + 16, Endian.little);

    await raf.setPosition(cdOffset);
    final cd = await raf.read(cdSize);
    final cdData = ByteData.sublistView(cd);

    final out = <String, String>{};
    var pos = 0;
    for (var i = 0; i < entryCount; i++) {
      if (cdData.getUint32(pos, Endian.little) != _centralDirSignature) {
        throw FormatException('Corrupt zip central directory in $zipPath');
      }
      final crc32 = cdData.getUint32(pos + 16, Endian.little);
      final uncompressedSize = cdData.getUint32(pos + 24, Endian.little);
      final nameLen = cdData.getUint16(pos + 28, Endian.little);
      final extraLen = cdData.getUint16(pos + 30, Endian.little);
      final commentLen = cdData.getUint16(pos + 32, Endian.little);
      final name = String.fromCharCodes(cd.sublist(pos + 46, pos + 46 + nameLen));
      if (_isLooseNativeLib(name)) {
        out[name] = 'crc32:$crc32:$uncompressedSize';
      }
      pos += 46 + nameLen + extraLen + commentLen;
    }
    return out;
  } finally {
    await raf.close();
  }
}

int _findEocd(Uint8List tail) {
  final bd = ByteData.sublistView(tail);
  for (var i = tail.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == _eocdSignature) return i;
  }
  return -1;
}

// ------------------------------------------------------- extracted bundle --

Future<Map<String, String>> _fromExtractedBundle(Directory appDir) async {
  final out = <String, String>{};
  await for (final entity in appDir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final rel = entity.path.substring(appDir.path.length + 1);
    if (!_isLooseNativeLib(rel)) continue;
    out[rel] = 'fnv:${await _fnv1a64(entity)}';
  }
  return out;
}

Future<int> _fnv1a64(File f) async {
  var hash = 0xcbf29ce484222325;
  await for (final chunk in f.openRead()) {
    for (final b in chunk) {
      hash ^= b;
      hash *= 0x100000001b3;
    }
  }
  return hash;
}
