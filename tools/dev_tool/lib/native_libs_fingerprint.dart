/// Fingerprinting of an app's native libraries, which is how both apply
/// paths find out that the running process can no longer be trusted.
///
/// A reload or a restart replaces Dart code but cannot replace native
/// libraries: the process keeps its originally-dlopened images, and in-process
/// dylib reload is unsound (library threads keep running in the old mapping).
/// So a restart that finds the rebuilt bundle's native libraries changed
/// relaunches the process instead, and a hot reload — which cannot relaunch
/// anything without throwing away the state it exists to preserve — withholds
/// the increment and says why.
///
/// "Native libraries" means the native code bundled into the app: loose
/// `.dylib`/`.so`/`.dll` files (macOS `Contents/Frameworks/`, Android `lib/`)
/// and the binary of every framework that is not Flutter's own. iOS forbids
/// loose dylibs, so each `native_deps` library ships there as
/// `<name>.framework/<name>`, and a plugin's native code is a framework on
/// both Apple platforms. Flutter's frameworks are excluded: `App.framework`
/// changes on every Dart edit (it carries the kernel) and would otherwise
/// force a relaunch on every restart, and `Flutter.framework` /
/// `FlutterMacOS.framework` only change with an engine bump. A framework's
/// resources never count, only its binary.
library;

import 'dart:io';
import 'dart:typed_data';

/// Per-library content fingerprint, keyed by bundle-relative path. Values
/// are opaque content tokens — only equality across two calls with the
/// same artifact form matters.
///
/// [artifactPath] is the launch artifact: a zip of the bundle (`.zip`, `.ipa`
/// or `.apk`, fingered from the central directory's CRC32 + size, no
/// extraction) or an extracted `.app` directory (fingered by hashing file
/// bytes).
///
/// An empty map means the bundle has no native libraries, in which case the
/// relaunch check should disable itself entirely.
Future<Map<String, String>> nativeLibsFingerprint(String artifactPath) async {
  // An .ipa and an .apk are zip archives under other names.
  if (const ['.zip', '.ipa', '.apk'].any(artifactPath.endsWith)) {
    return _fromZipTableOfContents(artifactPath);
  }
  final dir = Directory(artifactPath);
  if (dir.existsSync()) return _fromExtractedBundle(dir);
  return const {};
}

/// Per-file content fingerprint of [paths] — the native libraries a build
/// *declared*, keyed by the path it declared them at.
///
/// The companion to [nativeLibsFingerprint], which reads a launch artifact and
/// has to recognise a native library by its name. These paths come from
/// `_dev_config.json`, where the build wrote the same list it bundles, so
/// nothing here guesses which files are native libraries or where they live.
/// That is what makes this answer cheap enough to ask on every reload: the app
/// target a codegen reload already rebuilds writes these files, so the question
/// costs a hash per library and no bazel at all.
///
/// A declared path that does not exist throws. A build that reported success
/// without writing an output it declared is broken, and answering "nothing
/// moved" for it would let an increment be injected over stale machine code —
/// the exact failure this fingerprint exists to prevent.
Future<Map<String, String>> nativeLibsFingerprintOfFiles(
  Iterable<String> paths,
) async {
  final out = <String, String>{};
  for (final path in paths) {
    out[path] = 'fnv:${await _fnv1a64(File(path))}';
  }
  return out;
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
List<String> changedLibs(
  Map<String, String> before,
  Map<String, String> after,
) {
  final names = {...before.keys, ...after.keys};
  return [
    for (final n in names)
      if (before[n] != after[n]) n,
  ]..sort();
}

/// Flutter's own frameworks: the app's Dart (kernel or AOT) and the engine.
const _flutterFrameworks = {'App', 'Flutter', 'FlutterMacOS'};

/// Android's equivalents: `libapp.so` is the AOT Dart snapshot and
/// `libflutter.so` the engine.
const _flutterLibraries = {'libapp.so', 'libflutter.so'};

bool _isNativeLib(String path) {
  final segments = path.split('/');
  final fw = segments.lastIndexWhere((s) => s.endsWith('.framework'));
  if (fw < 0) {
    if (_flutterLibraries.contains(segments.last)) return false;
    return path.endsWith('.dylib') ||
        path.endsWith('.so') ||
        path.endsWith('.dll');
  }
  final name = segments[fw].substring(
    0,
    segments[fw].length - '.framework'.length,
  );
  if (_flutterFrameworks.contains(name)) return false;
  final rest = segments.sublist(fw + 1);
  // iOS frameworks are flat (`<name>.framework/<name>`); macOS frameworks are
  // versioned (`<name>.framework/Versions/A/<name>`), and `Versions/Current`
  // is a symlink to the real version.
  return (rest.length == 1 && rest[0] == name) ||
      (rest.length == 3 &&
          rest[0] == 'Versions' &&
          rest[1] != 'Current' &&
          rest[2] == name);
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
      final name = String.fromCharCodes(
        cd.sublist(pos + 46, pos + 46 + nameLen),
      );
      if (_isNativeLib(name)) {
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
    if (!_isNativeLib(rel)) continue;
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
