// Pure-Dart Mach-O 64-bit binary patcher and stub generator.
//
// Replaces macOS-only `xcrun vtool`, `xcrun install_name_tool`, and
// `xcrun clang -dynamiclib` (for empty debug stub dylibs) so Apple framework
// packaging and Mach-O post-processing work identically on Linux and macOS.
//
// Zero external pub dependencies (only `dart:convert`, `dart:io`,
// `dart:math`, `dart:typed_data`).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'crc32.dart' as crc32lib;
import 'sha256.dart' as sha256lib;

// Mach-O 32-bit, 64-bit, and Universal (Fat) constants.
const int mhMagic32 = 0xfeedface;
const int mhCigam32 = 0xcefaedfe;
const int mhMagic64 = 0xfeedfacf;
const int mhCigam64 = 0xcffaedfe;
const int fatMagic = 0xcafebabe;
const int fatCigam = 0xbebafeca;
const int fatMagic64 = 0xcafebabf;
const int fatCigam64 = 0xbfbafeca;
const int mhHeaderSize64 = 32;

const int cpuArchAbi64 = 0x01000000;
const int cpuTypeI386 = 0x00000007;
const int cpuTypeX86_64 = cpuTypeI386 | cpuArchAbi64; // 0x01000007
const int cpuSubtypeX86_64All = 3;
const int cpuTypeArm = 0x0000000c;
const int cpuTypeArm64 = cpuTypeArm | cpuArchAbi64; // 0x0100000c
const int cpuSubtypeArm64All = 0;

const int mhExecute = 0x2;
const int mhDylib = 0x6;
const int mhNoundefs = 0x00000001;
const int mhDyldlink = 0x00000004;
const int mhTwolevel = 0x00000080;
const int mhNoReexportedDylibs = 0x00100000;
const int mhPie = 0x00200000;

// Load command constants.
const int lcReqDyld = 0x80000000;
const int lcSymtab = 0x02;
const int lcDysymtab = 0x0b;
const int lcIdDylib = 0x0d;
const int lcSegment64 = 0x19;
const int lcUuid = 0x1b;
const int lcRpath = 0x1c | lcReqDyld; // 0x8000001c
const int lcCodeSignature = 0x1d;
const int lcDyldInfo = 0x22;
const int lcDyldInfoOnly = 0x22 | lcReqDyld; // 0x80000022
const int lcVersionMinMacosx = 0x24;
const int lcVersionMinIphoneos = 0x25;
const int lcFunctionStarts = 0x26;
const int lcDataInCode = 0x29;
const int lcVersionMinTvos = 0x2f;
const int lcVersionMinWatchos = 0x30;
const int lcBuildVersion = 0x32;
const int lcDyldExportsTrie = 0x33 | lcReqDyld;
const int lcDyldChainedFixups = 0x34 | lcReqDyld;

// Platform constants for LC_BUILD_VERSION.
const int platformMacos = 1;
const int platformIos = 2;
const int platformIosSimulator = 7;

// Code signature constants (big-endian in Mach-O).
const int csMagicEmbeddedSignature = 0xfade0cc0;
const int csMagicCodeDirectory = 0xfade0c02;
const int csHashTypeSha256 = 2;

void main(List<String> args) {
  if (args.isEmpty) {
    _usageError(
      'Expected subcommand: "patch", "stub", "fat", "verify", "copy-assets", '
      '"assemble-macos-framework", or "copy-files".',
    );
  }
  final subcommand = args.first;
  final rest = args.sublist(1);
  switch (subcommand) {
    case 'patch':
      _runPatch(rest);
    case 'stub':
      _runStub(rest);
    case 'fat':
      _runFat(rest);
    case 'verify':
      _runVerify(rest);
    case 'copy-assets':
      _runCopyAssets(rest);
    case 'assemble-macos-framework':
      _runAssembleMacosFramework(rest);
    case 'copy-files':
      _runCopyFiles(rest);
    default:
      _usageError(
        'Unknown subcommand "$subcommand". Expected "patch", "stub", "fat", '
        '"verify", "copy-assets", "assemble-macos-framework", or "copy-files".',
      );
  }
}

Never _usageError(String message) {
  stderr.writeln('macho_edit: $message');
  exit(64);
}

String _basename(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final parts = normalized.split('/').where((s) => s.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

String _stripExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Checks whether a non-Mach-O or 32-bit binary is explicitly named in [allowList].
bool _isAllowedNonMacho(
  Set<String> allowList, {
  required String inputPath,
  String? outputPath,
  String? installName,
}) {
  if (allowList.isEmpty) return false;
  if (allowList.contains('*')) return true;

  final candidates = <String>{};
  void addPathCandidates(String? p) {
    if (p == null || p.isEmpty) return;
    candidates.add(p);
    final base = _basename(p);
    candidates.add(base);
    final stem = _stripExtension(base);
    candidates.add(stem);
    if (stem.startsWith('lib') && stem.length > 3) {
      candidates.add(stem.substring(3));
    }
    for (final seg in p.replaceAll(r'\', '/').split('/')) {
      if (seg.endsWith('.framework')) {
        candidates.add(seg);
        candidates.add(seg.substring(0, seg.length - '.framework'.length));
      }
    }
  }

  addPathCandidates(inputPath);
  addPathCandidates(outputPath);
  addPathCandidates(installName);
  return candidates.any(allowList.contains);
}

/// Cursor over CLI flag words with take/peek helpers for `--flag value` pairs.
class _FlagCursor {
  _FlagCursor(this.args);

  final List<String> args;
  int _index = -1;

  /// Advances to the next flag word; false when the words are exhausted.
  bool moveNext() {
    _index++;
    return _index < args.length;
  }

  /// The current flag word.
  String get current => args[_index];

  /// The next word without consuming it, or null when exhausted.
  String? peek() => _index + 1 < args.length ? args[_index + 1] : null;

  /// Consumes the next word as [flag]'s value, failing usage when absent.
  String take(String flag) {
    if (++_index >= args.length) _usageError('$flag requires a value');
    return args[_index];
  }
}

/// Appends the comma-separated parts of [value] to [into], skipping empties.
void _addCommaParts(Set<String> into, String value) {
  for (final part in value.split(',')) {
    if (part.isNotEmpty) into.add(part);
  }
}

/// Parses the `--platform`/`--min-os`/`--sdk-version` triple shared by the
/// `patch`, `stub` and `copy-files` subcommands. Returns nulls when neither
/// `--platform` nor `--min-os` was given; `--sdk-version` defaults to the
/// minimum OS version.
({int? platform, int? minOs, int? sdkVersion}) _parsePlatformVersions(
  String? platformName,
  String? minOsStr,
  String? sdkVersionStr,
) {
  if (platformName == null && minOsStr == null) {
    return (platform: null, minOs: null, sdkVersion: null);
  }
  if (platformName == null || minOsStr == null) {
    _usageError('--platform and --min-os must be provided together');
  }
  final platform = parsePlatform(platformName);
  final minOs = parsePackedVersion(minOsStr);
  return (
    platform: platform,
    minOs: minOs,
    sdkVersion: sdkVersionStr != null
        ? parsePackedVersion(sdkVersionStr)
        : minOs,
  );
}

/// Writes [bytes] to [outputPath], creating parent directories as needed.
void _writePatchedOutput(Uint8List bytes, String outputPath) {
  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(bytes);
}

/// Copies optional kernel/snapshot blobs into [destDirPath], skipping blanks.
void _copySnapshotBlobs(
  String? kernelBlobPath,
  String? vmSnapshotPath,
  String? isolateSnapshotPath,
  String destDirPath,
) {
  if (kernelBlobPath != null && kernelBlobPath.isNotEmpty) {
    File(kernelBlobPath).copySync('$destDirPath/kernel_blob.bin');
  }
  if (vmSnapshotPath != null && vmSnapshotPath.isNotEmpty) {
    File(vmSnapshotPath).copySync('$destDirPath/vm_snapshot_data');
  }
  if (isolateSnapshotPath != null && isolateSnapshotPath.isNotEmpty) {
    File(
      isolateSnapshotPath,
    ).copySync('$destDirPath/isolate_snapshot_data');
  }
}

/// Parsed `patch` subcommand flags.
class _PatchArgs {
  _PatchArgs({
    required this.inputPath,
    required this.outputPath,
    required this.platformName,
    required this.minOsStr,
    required this.sdkVersionStr,
    required this.installName,
    required this.arch,
    required this.rpaths,
    required this.allowNonMacho,
  });

  final String? inputPath;
  final String? outputPath;
  final String? platformName;
  final String? minOsStr;
  final String? sdkVersionStr;
  final String? installName;
  final String? arch;
  final List<String> rpaths;
  final Set<String> allowNonMacho;
}

/// Parses `patch` flags; unknown flags fail usage.
_PatchArgs _parsePatchArgs(List<String> args) {
  String? inputPath;
  String? outputPath;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? installName;
  String? arch;
  final rpaths = <String>[];
  final allowNonMacho = <String>{};
  final flags = _FlagCursor(args);
  while (flags.moveNext()) {
    final arg = flags.current;
    if (arg.startsWith('--allow-non-macho=')) {
      _addCommaParts(
        allowNonMacho,
        arg.substring('--allow-non-macho='.length),
      );
      continue;
    }
    switch (arg) {
      case '--input':
        inputPath = flags.take('--input');
      case '--output':
        outputPath = flags.take('--output');
      case '--platform':
        platformName = flags.take('--platform');
      case '--min-os':
        minOsStr = flags.take('--min-os');
      case '--sdk-version':
        sdkVersionStr = flags.take('--sdk-version');
      case '--install-name':
        installName = flags.take('--install-name');
      case '--arch':
        arch = flags.take('--arch');
      case '--rpath':
        for (final part in flags.take('--rpath').split(',')) {
          if (part.isNotEmpty) rpaths.add(part);
        }
      case '--allow-non-macho':
        final next = flags.peek();
        if (next == null || next.startsWith('--')) {
          _usageError(
            '--allow-non-macho requires an explicit binary or framework name',
          );
        }
        _addCommaParts(allowNonMacho, flags.take('--allow-non-macho'));
      default:
        _usageError('Unknown flag for patch: $arg');
    }
  }
  return _PatchArgs(
    inputPath: inputPath,
    outputPath: outputPath,
    platformName: platformName,
    minOsStr: minOsStr,
    sdkVersionStr: sdkVersionStr,
    installName: installName,
    arch: arch,
    rpaths: rpaths,
    allowNonMacho: allowNonMacho,
  );
}

void _runPatch(List<String> args) {
  final parsed = _parsePatchArgs(args);
  final inputPath = parsed.inputPath;
  final outputPath = parsed.outputPath;
  if (inputPath == null || outputPath == null) {
    _usageError('patch requires --input and --output');
  }

  final versions = _parsePlatformVersions(
    parsed.platformName,
    parsed.minOsStr,
    parsed.sdkVersionStr,
  );

  final inputBytes = File(inputPath).readAsBytesSync();
  final isAllowed = _isAllowedNonMacho(
    parsed.allowNonMacho,
    inputPath: inputPath,
    outputPath: outputPath,
    installName: parsed.installName,
  );

  if (!isMachO64(inputBytes) && !isFatMachO(inputBytes)) {
    _passThroughOrRejectPatchInput(
      inputBytes,
      inputPath,
      outputPath,
      isAllowed,
    );
    return;
  }

  final Uint8List patched;
  try {
    patched = patchMachO(
      inputBytes,
      PatchOptions(
        platform: versions.platform,
        minOs: versions.minOs,
        sdkVersion: versions.sdkVersion,
        installName: parsed.installName,
        rpaths: parsed.rpaths,
        arch: parsed.arch,
      ),
    );
  } on FormatException catch (e) {
    if (isAllowed) {
      _writePatchedOutput(inputBytes, outputPath);
      return;
    }
    throw FormatException('Input file "$inputPath": ${e.message}');
  }

  _writePatchedOutput(patched, outputPath);
}

/// Handles a non-64-bit `patch` input: passes it through when explicitly
/// allowed, otherwise throws the 32-bit or non-Mach-O error.
void _passThroughOrRejectPatchInput(
  Uint8List inputBytes,
  String inputPath,
  String outputPath,
  bool isAllowed,
) {
  if (isAllowed) {
    _writePatchedOutput(inputBytes, outputPath);
    return;
  }
  if (isMachO32(inputBytes)) {
    throw FormatException(
      'Input file "$inputPath" is an unsupported 32-bit Mach-O binary '
      '(0xfeedface). Only 64-bit Mach-O binaries are supported unless '
      'explicitly listed in allow_non_macho.',
    );
  }
  throw FormatException(
    'Input file "$inputPath" is a non-Mach-O file (not a 64-bit or '
    'universal Mach-O binary). Only Mach-O binaries are permitted unless '
    'explicitly listed in allow_non_macho.',
  );
}

/// Parsed `stub` subcommand flags.
class _StubArgs {
  _StubArgs({
    required this.outputPath,
    required this.arch,
    required this.platformName,
    required this.minOsStr,
    required this.sdkVersionStr,
    required this.installName,
    required this.typeStr,
  });

  final String? outputPath;
  final String? arch;
  final String? platformName;
  final String? minOsStr;
  final String? sdkVersionStr;
  final String? installName;
  final String typeStr;
}

/// Parses `stub` flags; unknown flags fail usage.
_StubArgs _parseStubArgs(List<String> args) {
  String? outputPath;
  String? arch;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? installName;
  var typeStr = 'dylib';
  final flags = _FlagCursor(args);
  while (flags.moveNext()) {
    final arg = flags.current;
    switch (arg) {
      case '--output':
        outputPath = flags.take('--output');
      case '--arch':
        arch = flags.take('--arch');
      case '--platform':
        platformName = flags.take('--platform');
      case '--min-os':
        minOsStr = flags.take('--min-os');
      case '--sdk-version':
        sdkVersionStr = flags.take('--sdk-version');
      case '--install-name':
        installName = flags.take('--install-name');
      case '--type':
        typeStr = flags.take('--type');
      default:
        _usageError('Unknown flag for stub: $arg');
    }
  }
  return _StubArgs(
    outputPath: outputPath,
    arch: arch,
    platformName: platformName,
    minOsStr: minOsStr,
    sdkVersionStr: sdkVersionStr,
    installName: installName,
    typeStr: typeStr,
  );
}

void _runStub(List<String> args) {
  final parsed = _parseStubArgs(args);
  final outputPath = parsed.outputPath;
  final arch = parsed.arch;
  final platformName = parsed.platformName;
  final minOsStr = parsed.minOsStr;
  if (parsed.typeStr != 'dylib' && parsed.typeStr != 'execute') {
    _usageError('--type must be "dylib" or "execute", got "${parsed.typeStr}"');
  }

  if (outputPath == null ||
      arch == null ||
      platformName == null ||
      minOsStr == null ||
      (parsed.typeStr == 'dylib' && parsed.installName == null)) {
    _usageError(
      'stub requires --output, --arch, --platform, --min-os, and --install-name',
    );
  }

  final platform = parsePlatform(platformName);
  final minOs = parsePackedVersion(minOsStr);
  final sdkVersionStr = parsed.sdkVersionStr;
  final sdkVersion = sdkVersionStr != null
      ? parsePackedVersion(sdkVersionStr)
      : minOs;

  final bytes = generateStubMachO(
    arch: arch,
    platform: platform,
    minOs: minOs,
    sdkVersion: sdkVersion,
    installName: parsed.installName ?? '',
    fileType: parsed.typeStr == 'execute' ? mhExecute : mhDylib,
  );

  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(bytes);
}

void _copyDirDereferencingSync(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  if (!src.existsSync()) return;
  final children = src.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in children) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final destPath = '${dst.path}/$name';
    if (entity is Link) {
      final resolved = entity.resolveSymbolicLinksSync();
      if (FileSystemEntity.isDirectorySync(resolved)) {
        _copyDirDereferencingSync(Directory(resolved), Directory(destPath));
      } else {
        File(resolved).copySync(destPath);
      }
    } else if (entity is Directory) {
      _copyDirDereferencingSync(entity, Directory(destPath));
    } else if (entity is File) {
      entity.copySync(destPath);
    }
  }
}

/// Parsed `copy-assets` subcommand flags.
class _CopyAssetsArgs {
  _CopyAssetsArgs({
    required this.srcPath,
    required this.dstPath,
    required this.kernelBlobPath,
    required this.vmSnapshotPath,
    required this.isolateSnapshotPath,
  });

  final String? srcPath;
  final String? dstPath;
  final String? kernelBlobPath;
  final String? vmSnapshotPath;
  final String? isolateSnapshotPath;
}

/// Parses `copy-assets` flags; unknown flags fail usage.
_CopyAssetsArgs _parseCopyAssetsArgs(List<String> args) {
  String? srcPath;
  String? dstPath;
  String? kernelBlobPath;
  String? vmSnapshotPath;
  String? isolateSnapshotPath;
  final flags = _FlagCursor(args);
  while (flags.moveNext()) {
    final arg = flags.current;
    switch (arg) {
      case '--src':
        srcPath = flags.take('--src');
      case '--dst':
        dstPath = flags.take('--dst');
      case '--kernel-blob':
        kernelBlobPath = flags.take('--kernel-blob');
      case '--vm-snapshot-data':
        vmSnapshotPath = flags.take('--vm-snapshot-data');
      case '--isolate-snapshot-data':
        isolateSnapshotPath = flags.take('--isolate-snapshot-data');
      default:
        _usageError('Unknown flag for copy-assets: $arg');
    }
  }
  return _CopyAssetsArgs(
    srcPath: srcPath,
    dstPath: dstPath,
    kernelBlobPath: kernelBlobPath,
    vmSnapshotPath: vmSnapshotPath,
    isolateSnapshotPath: isolateSnapshotPath,
  );
}

void _runCopyAssets(List<String> args) {
  final parsed = _parseCopyAssetsArgs(args);
  final srcPath = parsed.srcPath;
  final dstPath = parsed.dstPath;
  if (srcPath == null || dstPath == null) {
    _usageError('copy-assets requires --src and --dst');
  }

  final dstDir = Directory(dstPath);
  _copyDirDereferencingSync(Directory(srcPath), dstDir);
  _copySnapshotBlobs(
    parsed.kernelBlobPath,
    parsed.vmSnapshotPath,
    parsed.isolateSnapshotPath,
    dstDir.path,
  );
}

void _createSymlinkReplacingSync(String linkPath, String target) {
  final link = Link(linkPath);
  if (FileSystemEntity.typeSync(linkPath, followLinks: false) !=
      FileSystemEntityType.notFound) {
    link.deleteSync();
  }
  link.createSync(target);
}

/// An entry in a deterministic framework ZIP archive.
class FrameworkZipEntry {
  final String path;
  final Uint8List data;
  final bool isExecutable;
  final bool isSymlink;

  const FrameworkZipEntry({
    required this.path,
    required this.data,
    this.isExecutable = false,
    this.isSymlink = false,
  });
}

/// Builds a deterministic ZIP archive for [frameworkDir] (e.g. `App.framework`)
/// suitable for `rules_apple`'s `AppleBundleInfo.archive` (`bundle_merge_zips`).
///
/// Only file and symlink entries are emitted (no directory entries), matching
/// `rules_apple`'s `imported_dynamic_framework_processor.py` and `bundletool.py`.
/// Symbolic links are stored with Unix mode `0120777` (`S_IFLNK`) and
/// uncompressed target bytes; [executableRelPaths] receive `0100755`.
Uint8List createFrameworkZipBytes(
  Directory frameworkDir, {
  required String archiveRootName,
  Set<String> executableRelPaths = const {},
}) {
  final entries = _collectFrameworkEntries(
    frameworkDir,
    archiveRootName,
    executableRelPaths,
  );
  entries.sort((a, b) => a.path.compareTo(b.path));

  final localParts = BytesBuilder(copy: false);
  final centralParts = BytesBuilder(copy: false);
  final rawDeflate = ZLibCodec(raw: true);

  const dosTime = 0x0000;
  const dosDate = 0x0021;
  const versionMadeBy = (3 << 8) | 20;
  const versionNeeded = 20;

  var offset = 0;
  for (final entry in entries) {
    final nameBytes = utf8.encode(entry.path);
    final crc = crc32lib.crc32(entry.data);
    final (:payload, :method) = _zipEntryPayload(entry, rawDeflate);
    final externalAttrs = _zipExternalAttrs(entry);
    final header = (
      nameBytes: nameBytes,
      payload: payload,
      method: method,
      crc: crc,
      uncompressedLength: entry.data.length,
      dosTime: dosTime,
      dosDate: dosDate,
      versionNeeded: versionNeeded,
      externalAttrs: externalAttrs,
      offset: offset,
      versionMadeBy: versionMadeBy,
    );
    _writeZipLocalEntry(localParts, header);
    _writeZipCentralEntry(centralParts, header);
    offset += 30 + nameBytes.length + payload.length;
  }

  return _finishFrameworkZip(localParts, centralParts, entries.length, offset);
}

/// Collects the framework's file and symlink entries in sorted path order.
List<FrameworkZipEntry> _collectFrameworkEntries(
  Directory frameworkDir,
  String archiveRootName,
  Set<String> executableRelPaths,
) {
  final entries = <FrameworkZipEntry>[];
  _walkFrameworkEntries(
    frameworkDir,
    archiveRootName,
    entries,
    executableRelPaths,
  );
  return entries;
}

/// Walks [dir] depth-first, appending file and symlink entries to [into].
void _walkFrameworkEntries(
  Directory dir,
  String relPrefix,
  List<FrameworkZipEntry> into,
  Set<String> executableRelPaths,
) {
  final children = dir.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in children) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final relPath = '$relPrefix/$name';
    if (entity is Link) {
      final target = entity.targetSync();
      into.add(
        FrameworkZipEntry(
          path: relPath,
          data: Uint8List.fromList(utf8.encode(target)),
          isSymlink: true,
        ),
      );
    } else if (entity is Directory) {
      _walkFrameworkEntries(entity, relPath, into, executableRelPaths);
    } else if (entity is File) {
      final stat = entity.statSync();
      final isExec =
          executableRelPaths.contains(relPath) || ((stat.mode & 0x49) != 0);
      into.add(
        FrameworkZipEntry(
          path: relPath,
          data: entity.readAsBytesSync(),
          isExecutable: isExec,
        ),
      );
    }
  }
}

/// The stored payload for [entry]: deflated when that is smaller.
({Uint8List payload, int method}) _zipEntryPayload(
  FrameworkZipEntry entry,
  ZLibCodec rawDeflate,
) {
  final uncompressed = entry.data;
  if (entry.isSymlink || uncompressed.isEmpty) {
    return (payload: uncompressed, method: 0);
  }
  final deflated = Uint8List.fromList(rawDeflate.encode(uncompressed));
  if (deflated.length < uncompressed.length) {
    return (payload: deflated, method: 8);
  }
  return (payload: uncompressed, method: 0);
}

/// The ZIP external-attributes word for [entry]'s file type and mode.
int _zipExternalAttrs(FrameworkZipEntry entry) {
  if (entry.isSymlink) {
    return 0xA1FF << 16; // lrwxrwxrwx (0120777)
  }
  if (entry.isExecutable) {
    return 0x81ED << 16; // -rwxr-xr-x (0100755)
  }
  return 0x81A4 << 16; // -rw-r--r-- (0100644)
}

/// The header fields shared by one ZIP local file header and its central
/// directory entry. Grouped into a record so the ZIP writers stay small.
typedef _ZipEntryHeader = ({
  List<int> nameBytes,
  Uint8List payload,
  int method,
  int crc,
  int uncompressedLength,
  int dosTime,
  int dosDate,
  int versionNeeded,
  int externalAttrs,
  int offset,
  int versionMadeBy,
});

/// Appends one local file header and payload to [into].
void _writeZipLocalEntry(BytesBuilder into, _ZipEntryHeader header) {
  final localHeader = ByteData(30 + header.nameBytes.length);
  localHeader.setUint32(0, 0x04034b50, Endian.little);
  localHeader.setUint16(4, header.versionNeeded, Endian.little);
  localHeader.setUint16(6, 0x0800, Endian.little);
  localHeader.setUint16(8, header.method, Endian.little);
  localHeader.setUint16(10, header.dosTime, Endian.little);
  localHeader.setUint16(12, header.dosDate, Endian.little);
  localHeader.setUint32(14, header.crc, Endian.little);
  localHeader.setUint32(18, header.payload.length, Endian.little);
  localHeader.setUint32(22, header.uncompressedLength, Endian.little);
  localHeader.setUint16(26, header.nameBytes.length, Endian.little);
  localHeader.setUint16(28, 0, Endian.little);
  localHeader.buffer.asUint8List().setRange(
    30,
    30 + header.nameBytes.length,
    header.nameBytes,
  );

  into.add(localHeader.buffer.asUint8List());
  into.add(header.payload);
}

/// Appends one central directory header to [into].
void _writeZipCentralEntry(BytesBuilder into, _ZipEntryHeader header) {
  final centralHeader = ByteData(46 + header.nameBytes.length);
  centralHeader.setUint32(0, 0x02014b50, Endian.little);
  centralHeader.setUint16(4, header.versionMadeBy, Endian.little);
  centralHeader.setUint16(6, header.versionNeeded, Endian.little);
  centralHeader.setUint16(8, 0x0800, Endian.little);
  centralHeader.setUint16(10, header.method, Endian.little);
  centralHeader.setUint16(12, header.dosTime, Endian.little);
  centralHeader.setUint16(14, header.dosDate, Endian.little);
  centralHeader.setUint32(16, header.crc, Endian.little);
  centralHeader.setUint32(20, header.payload.length, Endian.little);
  centralHeader.setUint32(24, header.uncompressedLength, Endian.little);
  centralHeader.setUint16(28, header.nameBytes.length, Endian.little);
  centralHeader.setUint16(30, 0, Endian.little);
  centralHeader.setUint16(32, 0, Endian.little);
  centralHeader.setUint16(34, 0, Endian.little);
  centralHeader.setUint16(36, 0, Endian.little);
  centralHeader.setUint32(38, header.externalAttrs, Endian.little);
  centralHeader.setUint32(42, header.offset, Endian.little);
  centralHeader.buffer.asUint8List().setRange(
    46,
    46 + header.nameBytes.length,
    header.nameBytes,
  );

  into.add(centralHeader.buffer.asUint8List());
}

/// Appends the central directory and end-of-central-directory record.
Uint8List _finishFrameworkZip(
  BytesBuilder localParts,
  BytesBuilder centralParts,
  int entryCount,
  int offset,
) {
  final centralBytes = centralParts.takeBytes();
  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054b50, Endian.little);
  eocd.setUint16(4, 0, Endian.little);
  eocd.setUint16(6, 0, Endian.little);
  eocd.setUint16(8, entryCount, Endian.little);
  eocd.setUint16(10, entryCount, Endian.little);
  eocd.setUint32(12, centralBytes.length, Endian.little);
  eocd.setUint32(16, offset, Endian.little);
  eocd.setUint16(20, 0, Endian.little);

  localParts.add(centralBytes);
  localParts.add(eocd.buffer.asUint8List());
  return localParts.takeBytes();
}

/// One central-directory entry of a framework ZIP with its payload inflated.
/// Mode bits stay packed: each reader interprets [externalAttrs] itself.
List<({String path, Uint8List data, int externalAttrs})>
_readRawFrameworkZipEntries(
  ByteData bd,
  Uint8List zipBytes,
  int entryCount,
  int cdOffset,
) {
  final rawInflate = ZLibCodec(raw: true);
  final entries = <({String path, Uint8List data, int externalAttrs})>[];
  var pos = cdOffset;
  for (var i = 0; i < entryCount; i++) {
    if (bd.getUint32(pos, Endian.little) != 0x02014b50) {
      throw FormatException('Invalid central directory header at $pos.');
    }
    final method = bd.getUint16(pos + 10, Endian.little);
    final compressedSize = bd.getUint32(pos + 20, Endian.little);
    final nameLen = bd.getUint16(pos + 28, Endian.little);
    final extraLen = bd.getUint16(pos + 30, Endian.little);
    final commentLen = bd.getUint16(pos + 32, Endian.little);
    final externalAttrs = bd.getUint32(pos + 38, Endian.little);
    final localOffset = bd.getUint32(pos + 42, Endian.little);

    final path = utf8.decode(zipBytes.sublist(pos + 46, pos + 46 + nameLen));
    pos += 46 + nameLen + extraLen + commentLen;

    final localNameLen = bd.getUint16(localOffset + 26, Endian.little);
    final localExtraLen = bd.getUint16(localOffset + 28, Endian.little);
    final dataStart = localOffset + 30 + localNameLen + localExtraLen;
    final rawPayload = zipBytes.sublist(dataStart, dataStart + compressedSize);

    final Uint8List data;
    if (method == 0) {
      data = Uint8List.fromList(rawPayload);
    } else if (method == 8) {
      data = Uint8List.fromList(rawInflate.decode(rawPayload));
    } else {
      throw UnsupportedError('Unsupported ZIP compression method: $method');
    }
    entries.add((path: path, data: data, externalAttrs: externalAttrs));
  }
  return entries;
}

/// Decodes a ZIP archive into [FrameworkZipEntry] items for inspection/testing.
List<FrameworkZipEntry> readFrameworkZipEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  var eocdOffset = -1;
  for (var i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocdOffset = i;
      break;
    }
  }
  if (eocdOffset == -1) {
    throw const FormatException('Invalid ZIP archive: EOCD not found.');
  }
  final entryCount = bd.getUint16(eocdOffset + 10, Endian.little);
  final cdOffset = bd.getUint32(eocdOffset + 16, Endian.little);

  final entries = <FrameworkZipEntry>[];
  for (final raw in _readRawFrameworkZipEntries(
    bd,
    zipBytes,
    entryCount,
    cdOffset,
  )) {
    final unixMode = (raw.externalAttrs >>> 16) & 0xFFFF;
    final fileType = unixMode & 0xF000;
    final isSymlink = fileType == 0xA000;
    entries.add(
      FrameworkZipEntry(
        path: raw.path,
        data: raw.data,
        isExecutable: !isSymlink && ((unixMode & 0x49) != 0),
        isSymlink: isSymlink,
      ),
    );
  }
  return entries;
}

/// Extracts a framework ZIP archive produced by [createFrameworkZipBytes] into
/// [destDir], recreating symbolic links with their exact stored targets.
///
/// Bazel does not preserve directory symlinks inside tree artifacts when it
/// stages them as action or test inputs (a link to a directory is materialized
/// as a real directory), so `App.framework` travels between actions as its
/// deterministic `.framework.zip` and each consumer extracts it locally with
/// this helper. Extraction is deterministic: entries are applied in sorted
/// path order, and only file contents and link targets affect the result.
///
/// Entry paths and symlink targets must be relative and free of `..`
/// segments; anything else throws, since archives only ever come from the
/// rules' own producer.
void extractFrameworkZip(Uint8List zipBytes, Directory destDir) {
  final entries = readFrameworkZipEntries(zipBytes)
    ..sort((a, b) => a.path.compareTo(b.path));
  if (entries.isEmpty) {
    throw const FormatException('Refusing to extract an empty ZIP archive.');
  }
  for (final entry in entries) {
    final segments = entry.path.split('/');
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..') ||
        entry.path.startsWith('/')) {
      throw FormatException(
        'Refusing to extract unsafe ZIP entry: ${entry.path}',
      );
    }
    final destPath = '${destDir.path}/${entry.path}';
    if (entry.isSymlink) {
      final target = utf8.decode(entry.data);
      final targetSegments = target.split('/');
      if (target.isEmpty ||
          target.startsWith('/') ||
          targetSegments.any((s) => s == '..')) {
        throw FormatException(
          'Refusing to extract unsafe symlink ${entry.path} -> $target',
        );
      }
      Directory(destPath).parent.createSync(recursive: true);
      _createSymlinkReplacingSync(destPath, target);
    } else {
      final destFile = File(destPath);
      destFile.parent.createSync(recursive: true);
      destFile.writeAsBytesSync(entry.data);
    }
  }
}

/// Parsed `assemble-macos-framework` subcommand flags.
class _AssembleArgs {
  _AssembleArgs({
    required this.binaryPath,
    required this.infoPlistPath,
    required this.assetsPath,
    required this.outputDirPath,
    required this.outputZipPath,
    required this.kernelBlobPath,
    required this.vmSnapshotPath,
    required this.isolateSnapshotPath,
  });

  final String? binaryPath;
  final String? infoPlistPath;
  final String? assetsPath;
  final String? outputDirPath;
  final String? outputZipPath;
  final String? kernelBlobPath;
  final String? vmSnapshotPath;
  final String? isolateSnapshotPath;
}

/// Parses `assemble-macos-framework` flags; unknown flags fail usage.
_AssembleArgs _parseAssembleArgs(List<String> args) {
  String? binaryPath;
  String? infoPlistPath;
  String? assetsPath;
  String? outputDirPath;
  String? outputZipPath;
  String? kernelBlobPath;
  String? vmSnapshotPath;
  String? isolateSnapshotPath;
  final flags = _FlagCursor(args);
  while (flags.moveNext()) {
    final arg = flags.current;
    switch (arg) {
      case '--binary':
        binaryPath = flags.take('--binary');
      case '--info-plist':
        infoPlistPath = flags.take('--info-plist');
      case '--assets':
        assetsPath = flags.take('--assets');
      case '--output-dir':
        outputDirPath = flags.take('--output-dir');
      case '--output-zip':
        outputZipPath = flags.take('--output-zip');
      case '--kernel-blob':
        kernelBlobPath = flags.take('--kernel-blob');
      case '--vm-snapshot-data':
        vmSnapshotPath = flags.take('--vm-snapshot-data');
      case '--isolate-snapshot-data':
        isolateSnapshotPath = flags.take('--isolate-snapshot-data');
      default:
        _usageError('Unknown flag for assemble-macos-framework: $arg');
    }
  }
  return _AssembleArgs(
    binaryPath: binaryPath,
    infoPlistPath: infoPlistPath,
    assetsPath: assetsPath,
    outputDirPath: outputDirPath,
    outputZipPath: outputZipPath,
    kernelBlobPath: kernelBlobPath,
    vmSnapshotPath: vmSnapshotPath,
    isolateSnapshotPath: isolateSnapshotPath,
  );
}

void _runAssembleMacosFramework(List<String> args) {
  final parsed = _parseAssembleArgs(args);
  final binaryPath = parsed.binaryPath;
  final infoPlistPath = parsed.infoPlistPath;
  final assetsPath = parsed.assetsPath;
  final outputDirPath = parsed.outputDirPath;
  if (binaryPath == null ||
      infoPlistPath == null ||
      assetsPath == null ||
      outputDirPath == null) {
    _usageError(
      'assemble-macos-framework requires --binary, --info-plist, --assets, '
      'and --output-dir',
    );
  }

  final fwDir = outputDirPath.endsWith('.framework')
      ? Directory(outputDirPath)
      : Directory('$outputDirPath/App.framework');
  final fwDirName = fwDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  final fwName = fwDirName.substring(0, fwDirName.length - '.framework'.length);
  final versionADir = Directory('${fwDir.path}/Versions/A');
  final resourcesDir = Directory('${versionADir.path}/Resources');
  final assetsDestDir = Directory('${resourcesDir.path}/flutter_assets');
  assetsDestDir.createSync(recursive: true);

  File(binaryPath).copySync('${versionADir.path}/$fwName');
  File(infoPlistPath).copySync('${resourcesDir.path}/Info.plist');
  _copyDirDereferencingSync(Directory(assetsPath), assetsDestDir);
  _copySnapshotBlobs(
    parsed.kernelBlobPath,
    parsed.vmSnapshotPath,
    parsed.isolateSnapshotPath,
    assetsDestDir.path,
  );

  _createSymlinkReplacingSync('${fwDir.path}/Versions/Current', 'A');
  _createSymlinkReplacingSync(
    '${fwDir.path}/$fwName',
    'Versions/Current/$fwName',
  );
  _createSymlinkReplacingSync(
    '${fwDir.path}/Resources',
    'Versions/Current/Resources',
  );

  final outputZipPath = parsed.outputZipPath;
  if (outputZipPath != null && outputZipPath.isNotEmpty) {
    final zipBytes = createFrameworkZipBytes(
      fwDir,
      archiveRootName: fwDirName,
      executableRelPaths: {'$fwDirName/Versions/A/$fwName'},
    );
    final zipFile = File(outputZipPath);
    zipFile.parent.createSync(recursive: true);
    zipFile.writeAsBytesSync(zipBytes);
  }
}

/// Parsed `copy-files` subcommand flags.
class _CopyFilesArgs {
  _CopyFilesArgs({
    required this.outputDirPath,
    required this.platformName,
    required this.minOsStr,
    required this.sdkVersionStr,
    required this.arch,
    required this.allowNonMacho,
    required this.positional,
  });

  final String outputDirPath;
  final String? platformName;
  final String? minOsStr;
  final String? sdkVersionStr;
  final String? arch;
  final Set<String> allowNonMacho;
  final List<String> positional;
}

/// Parses `copy-files` flags; unknown flags fail usage.
_CopyFilesArgs _parseCopyFilesArgs(List<String> args) {
  String? outputDirPath;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? arch;
  final allowNonMacho = <String>{};
  final positional = <String>[];
  final flags = _FlagCursor(args);
  while (flags.moveNext()) {
    final arg = flags.current;
    if (arg.startsWith('--allow-non-macho=')) {
      _addCommaParts(
        allowNonMacho,
        arg.substring('--allow-non-macho='.length),
      );
    } else if (arg == '--output-dir') {
      outputDirPath = flags.take('--output-dir');
    } else if (arg == '--platform') {
      platformName = flags.take('--platform');
    } else if (arg == '--min-os') {
      minOsStr = flags.take('--min-os');
    } else if (arg == '--sdk-version') {
      sdkVersionStr = flags.take('--sdk-version');
    } else if (arg == '--arch') {
      arch = flags.take('--arch');
    } else if (arg == '--allow-non-macho') {
      final next = flags.peek();
      if (next == null || next.startsWith('--')) {
        _usageError(
          '--allow-non-macho requires an explicit binary or framework name',
        );
      }
      _addCommaParts(allowNonMacho, flags.take('--allow-non-macho'));
    } else if (arg.startsWith('--')) {
      _usageError('Unknown flag for copy-files: $arg');
    } else {
      positional.add(arg);
    }
  }

  final checked = outputDirPath;
  if (checked == null) {
    _usageError('copy-files requires --output-dir');
  }
  return _CopyFilesArgs(
    outputDirPath: checked,
    platformName: platformName,
    minOsStr: minOsStr,
    sdkVersionStr: sdkVersionStr,
    arch: arch,
    allowNonMacho: allowNonMacho,
    positional: positional,
  );
}

void _runCopyFiles(List<String> args) {
  final parsed = _parseCopyFilesArgs(args);
  final versions = _parsePlatformVersions(
    parsed.platformName,
    parsed.minOsStr,
    parsed.sdkVersionStr,
  );

  Directory(parsed.outputDirPath).createSync(recursive: true);
  _stageCopyFilesEntries(
    parsed.positional,
    (
      outDirPath: parsed.outputDirPath,
      platform: versions.platform,
      minOs: versions.minOs,
      sdkVersion: versions.sdkVersion,
      arch: parsed.arch,
      allowNonMacho: parsed.allowNonMacho,
    ),
  );
}

/// Staging options shared by the `copy-files` entry walkers: destination and
/// patch settings applied to every entry. Grouped so the walkers stay small.
typedef _CopyFilesStaging = ({
  String outDirPath,
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? arch,
  Set<String> allowNonMacho,
});

/// Stages each `copy-files` positional (a source path with an optional
/// explicit destination name) under [staging.outDirPath].
void _stageCopyFilesEntries(
  List<String> positional,
  _CopyFilesStaging staging,
) {
  var i = 0;
  while (i < positional.length) {
    final srcPath = positional[i];
    final String destName;
    if (i + 1 < positional.length &&
        !positional[i + 1].contains('/') &&
        !positional[i + 1].contains(r'\')) {
      destName = positional[i + 1];
      i += 2;
    } else {
      destName = Uri.file(
        srcPath,
      ).pathSegments.where((s) => s.isNotEmpty).last;
      i += 1;
    }
    _stageCopyFilesEntry(srcPath, destName, staging);
  }
}

/// Stages one `copy-files` entry, patching Mach-O binaries when a platform
/// was requested and copying anything else verbatim.
void _stageCopyFilesEntry(
  String srcPath,
  String destName,
  _CopyFilesStaging staging,
) {
  final destPath = '${staging.outDirPath}/$destName';
  final platform = staging.platform;
  final minOs = staging.minOs;
  if (platform == null || minOs == null) {
    File(srcPath).copySync(destPath);
    return;
  }
  final inputBytes = File(srcPath).readAsBytesSync();
  final isAllowed = _isAllowedNonMacho(
    staging.allowNonMacho,
    inputPath: srcPath,
    outputPath: destName,
  );
  if (!isMachO64(inputBytes) && !isFatMachO(inputBytes)) {
    if (isAllowed) {
      File(destPath).writeAsBytesSync(inputBytes);
      return;
    }
    if (isMachO32(inputBytes)) {
      throw FormatException(
        'Input file "$srcPath" ("$destName") is an unsupported 32-bit '
        'Mach-O binary (0xfeedface). Only 64-bit Mach-O binaries are '
        'supported unless explicitly listed in allow_non_macho.',
      );
    }
    throw FormatException(
      'Input file "$srcPath" ("$destName") is a non-Mach-O file (not a '
      '64-bit or universal Mach-O binary). Only Mach-O binaries are '
      'permitted unless explicitly listed in allow_non_macho.',
    );
  }
  try {
    final patched = patchMachO(
      inputBytes,
      PatchOptions(
        platform: platform,
        minOs: minOs,
        sdkVersion: staging.sdkVersion,
        arch: staging.arch,
      ),
    );
    File(destPath).writeAsBytesSync(patched);
  } on FormatException catch (e) {
    if (isAllowed) {
      File(destPath).writeAsBytesSync(inputBytes);
      return;
    }
    throw FormatException(
      'Input file "$srcPath" ("$destName"): ${e.message}',
    );
  }
}

void _runFat(List<String> args) {
  String? outputPath;
  final slicePaths = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--output') {
      if (++i >= args.length) _usageError('--output requires a value');
      outputPath = args[i];
    } else if (arg.startsWith('--')) {
      _usageError('Unknown flag for fat: $arg');
    } else {
      slicePaths.add(arg);
    }
  }

  if (outputPath == null || slicePaths.isEmpty) {
    _usageError('fat requires --output and at least one input slice path');
  }

  final slices = <FatSlice>[];
  for (final p in slicePaths) {
    final bytes = File(p).readAsBytesSync();
    if (!isMachO64(bytes) && !isMachO32(bytes)) {
      throw FormatException('Input slice "$p" is not a thin Mach-O binary.');
    }
    final bd = ByteData.sublistView(bytes);
    final cputype = bd.getUint32(4, Endian.little);
    final cpusubtype = bd.getUint32(8, Endian.little);
    slices.add(
      FatSlice(cputype: cputype, cpusubtype: cpusubtype, bytes: bytes),
    );
  }

  final out = buildFatMachO(slices);
  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(out);
}

void _verifyMachODylibBytes(Uint8List bytes, String description) {
  if (!isMachO64(bytes) && !isFatMachO(bytes)) {
    throw FormatException(
      '$description is not a 64-bit or universal Mach-O binary.',
    );
  }
  final slices = isFatMachO(bytes)
      ? extractFatSlices(bytes).map((s) => s.bytes).toList()
      : <Uint8List>[bytes];
  for (final slice in slices) {
    final bd = ByteData.sublistView(slice);
    final filetype = bd.getUint32(12, Endian.little);
    if (filetype != mhDylib) {
      throw FormatException(
        '$description has Mach-O filetype 0x${filetype.toRadixString(16)}, '
        'expected MH_DYLIB (0x6).',
      );
    }
    parseLoadCommands(slice);
  }
}

void _verifyFrameworkInfoPlistXml(
  String plistXml,
  String frameworkName,
  String sourceDesc,
) {
  final pkgTypeMatch = RegExp(
    r'<key>\s*CFBundlePackageType\s*</key>\s*<string>\s*([^<\s]+)\s*</string>',
  ).firstMatch(plistXml);
  if (pkgTypeMatch == null || pkgTypeMatch.group(1) != 'FMWK') {
    throw FormatException(
      '$sourceDesc must declare CFBundlePackageType = FMWK, got: '
      '${pkgTypeMatch?.group(1)}',
    );
  }
  final execMatch = RegExp(
    r'<key>\s*CFBundleExecutable\s*</key>\s*<string>\s*([^<\s]+)\s*</string>',
  ).firstMatch(plistXml);
  if (execMatch == null || execMatch.group(1) != frameworkName) {
    throw FormatException(
      '$sourceDesc must declare CFBundleExecutable = $frameworkName, got: '
      '${execMatch?.group(1)}',
    );
  }
}

/// Verifies that a macOS `.framework` directory (and optional `AppleBundleInfo`
/// `.framework.zip` archive) has the canonical versioned layout required by
/// macOS `codesign`:
///   - `Versions/A/<binary>` (Mach-O `MH_DYLIB`),
///   - `Versions/A/Resources/Info.plist` (`CFBundlePackageType = FMWK`),
///   - `Versions/Current -> A` symlink,
///   - top-level symlinks `<binary> -> Versions/Current/<binary>` and
///     `Resources -> Versions/Current/Resources`,
///   - no unversioned regular files or directories at the framework root.
void verifyMacosFramework(
  String frameworkOrWrapperPath, {
  String frameworkName = 'App',
  String? frameworkZipPath,
}) {
  final fwDir = _resolveFrameworkDir(frameworkOrWrapperPath, frameworkName);

  final versionABinary = File('${fwDir.path}/Versions/A/$frameworkName');
  final versionAPlist = File('${fwDir.path}/Versions/A/Resources/Info.plist');
  _expectFrameworkFile(versionABinary.path);
  _expectFrameworkFile(versionAPlist.path);

  final currentLinkPath = '${fwDir.path}/Versions/Current';
  _expectFrameworkSymlink(currentLinkPath, 'A', 'symlink');

  final topBinaryLinkPath = '${fwDir.path}/$frameworkName';
  _expectFrameworkSymlink(
    topBinaryLinkPath,
    'Versions/Current/$frameworkName',
    'top-level symlink',
  );

  final topResourcesLinkPath = '${fwDir.path}/Resources';
  _expectFrameworkSymlink(
    topResourcesLinkPath,
    'Versions/Current/Resources',
    'top-level symlink',
  );

  _checkFrameworkTopEntries(fwDir, frameworkName);

  if (File(topBinaryLinkPath).resolveSymbolicLinksSync() !=
      versionABinary.resolveSymbolicLinksSync()) {
    throw StateError(
      '$topBinaryLinkPath does not resolve to ${versionABinary.path}.',
    );
  }
  if (File('$topResourcesLinkPath/Info.plist').resolveSymbolicLinksSync() !=
      versionAPlist.resolveSymbolicLinksSync()) {
    throw StateError(
      '$topResourcesLinkPath/Info.plist does not resolve to ${versionAPlist.path}.',
    );
  }

  final binaryBytes = versionABinary.readAsBytesSync();
  _verifyMachODylibBytes(binaryBytes, versionABinary.path);
  _verifyFrameworkInfoPlistXml(
    versionAPlist.readAsStringSync(),
    frameworkName,
    versionAPlist.path,
  );

  if (frameworkZipPath != null && frameworkZipPath.isNotEmpty) {
    _verifyFrameworkZipEntries(frameworkZipPath, frameworkName);
  }
}

/// Resolves [frameworkOrWrapperPath] to the framework directory, unwrapping
/// Bazel's symlinked tree-artifact staging when present.
Directory _resolveFrameworkDir(
  String frameworkOrWrapperPath,
  String frameworkName,
) {
  var fwDir = frameworkOrWrapperPath.endsWith('.framework')
      ? Directory(frameworkOrWrapperPath)
      : Directory('$frameworkOrWrapperPath/$frameworkName.framework');
  if (!fwDir.existsSync()) {
    throw StateError('macOS framework directory not found: ${fwDir.path}');
  }

  // When Bazel's sandbox or runfiles tree materializes a tree artifact by
  // symlinking its leaf files into the execroot, unwrap to the underlying
  // tree artifact directory in the execroot so we inspect the real entries.
  final probeBinary = '${fwDir.path}/Versions/A/$frameworkName';
  if (FileSystemEntity.typeSync(probeBinary, followLinks: false) ==
      FileSystemEntityType.link) {
    final target = Link(probeBinary).targetSync().replaceAll('\\', '/');
    final suffix = '/$frameworkName.framework/Versions/A/$frameworkName';
    if (target.startsWith('/') && target.endsWith(suffix)) {
      fwDir = Directory(
        target.substring(
          0,
          target.length - '/Versions/A/$frameworkName'.length,
        ),
      );
    }
  }
  return fwDir;
}

/// Throws unless [path] is a regular file.
void _expectFrameworkFile(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw StateError('Expected regular file at $path, found $type');
  }
}

/// Throws unless [linkPath] is a symlink pointing at [expectedTarget].
/// [noun] names the link kind in the error ('symlink', 'top-level symlink').
void _expectFrameworkSymlink(
  String linkPath,
  String expectedTarget,
  String noun,
) {
  if (FileSystemEntity.typeSync(linkPath, followLinks: false) !=
      FileSystemEntityType.link) {
    throw StateError(
      'Expected $noun at $linkPath, found '
      '${FileSystemEntity.typeSync(linkPath, followLinks: false)}',
    );
  }
  final target = Link(linkPath).targetSync();
  if (target != expectedTarget) {
    throw StateError('Expected $linkPath -> "$expectedTarget", got "$target"');
  }
}

/// Checks the framework root holds only `Versions/` and approved symlinks,
/// and that `Versions/` holds only `A` and `Current`.
void _checkFrameworkTopEntries(Directory fwDir, String frameworkName) {
  // Ensure no unsealed files or non-Versions directories exist at framework root.
  final allowedTopSymlinks = <String>{
    frameworkName,
    'Resources',
    'Headers',
    'Modules',
  };
  for (final entity in fwDir.listSync(followLinks: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == 'Versions') {
      if (entity is! Directory || entity is Link) {
        throw StateError('Expected Versions to be a real directory.');
      }
      continue;
    }
    if (entity is! Link || !allowedTopSymlinks.contains(name)) {
      throw StateError(
        'Ambiguous unsealed entry "$name" (${entity.runtimeType}) at root of '
        '${fwDir.path}; macOS codesign requires only Versions/ and top-level '
        'symlinks into Versions/Current/.',
      );
    }
  }

  for (final entity in Directory('${fwDir.path}/Versions').listSync(
    followLinks: false,
  )) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name != 'A' && name != 'Current') {
      throw StateError(
        'Unexpected entry "$name" inside ${fwDir.path}/Versions.',
      );
    }
  }
}

/// Verifies the framework ZIP archive entries for [frameworkName].
void _verifyFrameworkZipEntries(
  String frameworkZipPath,
  String frameworkName,
) {
  final zipFile = File(frameworkZipPath);
  if (!zipFile.existsSync()) {
    throw StateError('Framework zip archive not found: $frameworkZipPath');
  }
  final entries = {
    for (final e in readFrameworkZipEntries(zipFile.readAsBytesSync()))
      e.path: e,
  };
  final prefix = '$frameworkName.framework';
  final binEntry = entries['$prefix/Versions/A/$frameworkName'];
  if (binEntry == null || binEntry.isSymlink || !binEntry.isExecutable) {
    throw StateError(
      'Expected executable Mach-O entry "$prefix/Versions/A/$frameworkName" '
      'in $frameworkZipPath, got: $binEntry',
    );
  }
  _verifyMachODylibBytes(
    binEntry.data,
    '$frameworkZipPath:$prefix/Versions/A/$frameworkName',
  );

  final plistEntry = entries['$prefix/Versions/A/Resources/Info.plist'];
  if (plistEntry == null || plistEntry.isSymlink) {
    throw StateError(
      'Expected regular file entry "$prefix/Versions/A/Resources/Info.plist" '
      'in $frameworkZipPath',
    );
  }
  _verifyFrameworkInfoPlistXml(
    utf8.decode(plistEntry.data),
    frameworkName,
    '$frameworkZipPath:$prefix/Versions/A/Resources/Info.plist',
  );

  _checkFrameworkZipSymlinks(entries, frameworkZipPath, prefix, frameworkName);
}

/// Checks the expected symlink entries of a framework ZIP archive.
void _checkFrameworkZipSymlinks(
  Map<String, FrameworkZipEntry> entries,
  String frameworkZipPath,
  String prefix,
  String frameworkName,
) {
  final expectedLinks = <String, String>{
    '$prefix/Versions/Current': 'A',
    '$prefix/$frameworkName': 'Versions/Current/$frameworkName',
    '$prefix/Resources': 'Versions/Current/Resources',
  };
  for (final expected in expectedLinks.entries) {
    final entry = entries[expected.key];
    if (entry == null || !entry.isSymlink) {
      throw StateError(
        'Expected symlink entry "${expected.key}" in $frameworkZipPath, '
        'found: ${entry == null ? "missing" : "regular file"}',
      );
    }
    final target = utf8.decode(entry.data);
    if (target != expected.value) {
      throw StateError(
        'Expected symlink "${expected.key}" -> "${expected.value}" in '
        '$frameworkZipPath, got "$target"',
      );
    }
  }
}

Map<String, Uint8List> _readZipArchiveEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  var eocdOffset = -1;
  for (var i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocdOffset = i;
      break;
    }
  }
  if (eocdOffset == -1) {
    throw const FormatException(
      'Invalid ZIP archive: EOCD signature not found.',
    );
  }
  final entryCount = bd.getUint16(eocdOffset + 10, Endian.little);
  final cdOffset = bd.getUint32(eocdOffset + 16, Endian.little);
  return {
    for (final entry in _readRawFrameworkZipEntries(
      bd,
      zipBytes,
      entryCount,
      cdOffset,
    ))
      entry.path: entry.data,
  };
}

/// Parsed `verify` subcommand flags.
class _VerifyArgs {
  _VerifyArgs({
    required this.inputPath,
    required this.binaryRelpath,
    required this.frameworkZipPath,
    required this.objdumpPath,
    required this.outputPath,
    required this.expectedSubstrings,
    required this.expectedEntries,
    required this.forbiddenEntries,
  });

  final String? inputPath;
  final String? binaryRelpath;
  final String? frameworkZipPath;
  final String? objdumpPath;
  final String? outputPath;
  final List<String> expectedSubstrings;
  final List<String> expectedEntries;
  final List<String> forbiddenEntries;
}

/// Parses `verify` flags; unknown flags fail usage.
_VerifyArgs _parseVerifyArgs(List<String> args) {
  String? inputPath;
  String? binaryRelpath;
  String? frameworkZipPath;
  String? objdumpPath;
  String? outputPath;
  final expectedSubstrings = <String>[];
  final expectedEntries = <String>[];
  final forbiddenEntries = <String>[];
  final flags = _FlagCursor(args);
  while (flags.moveNext()) {
    final arg = flags.current;
    switch (arg) {
      case '--input':
        inputPath = flags.take('--input');
      case '--binary-relpath':
        binaryRelpath = flags.take('--binary-relpath');
      case '--framework-zip':
        frameworkZipPath = flags.take('--framework-zip');
      case '--objdump':
        objdumpPath = flags.take('--objdump');
      case '--expect':
        expectedSubstrings.add(flags.take('--expect'));
      case '--expect-entry':
        expectedEntries.add(flags.take('--expect-entry'));
      case '--forbid-entry':
        forbiddenEntries.add(flags.take('--forbid-entry'));
      case '--output':
        outputPath = flags.take('--output');
      default:
        _usageError('Unknown flag for verify: $arg');
    }
  }
  return _VerifyArgs(
    inputPath: inputPath,
    binaryRelpath: binaryRelpath,
    frameworkZipPath: frameworkZipPath,
    objdumpPath: objdumpPath,
    outputPath: outputPath,
    expectedSubstrings: expectedSubstrings,
    expectedEntries: expectedEntries,
    forbiddenEntries: forbiddenEntries,
  );
}

void _runVerify(List<String> args) {
  final parsed = _parseVerifyArgs(args);
  final inputPath = parsed.inputPath;
  final outputPath = parsed.outputPath;
  if (inputPath == null || outputPath == null) {
    _usageError('verify requires --input and --output');
  }

  final binaryRelpath = parsed.binaryRelpath;
  final frameworkZipPath = parsed.frameworkZipPath;
  final isZipArchive =
      FileSystemEntity.isFileSync(inputPath) &&
      (inputPath.endsWith('.ipa') || inputPath.endsWith('.zip'));

  if (!isZipArchive &&
      ((binaryRelpath != null &&
              binaryRelpath.contains('.framework/Versions/')) ||
          (frameworkZipPath != null && frameworkZipPath.isNotEmpty))) {
    var fwName = 'App';
    if (binaryRelpath != null && binaryRelpath.contains('.framework/')) {
      final seg = binaryRelpath
          .split('/')
          .firstWhere((s) => s.endsWith('.framework'));
      fwName = seg.substring(0, seg.length - '.framework'.length);
    }
    verifyMacosFramework(
      inputPath,
      frameworkName: fwName,
      frameworkZipPath: frameworkZipPath,
    );
  }

  String? tempExtractedBinaryPath;
  try {
    final String targetPath;
    final Uint8List bytes;
    if (isZipArchive) {
      final loaded = _loadZipVerifyTarget(parsed, inputPath, outputPath);
      targetPath = loaded.targetPath;
      bytes = loaded.bytes;
      tempExtractedBinaryPath = loaded.tempPath;
    } else {
      final loaded = _loadBundleVerifyTarget(parsed, inputPath);
      targetPath = loaded.targetPath;
      bytes = loaded.bytes;
    }

    _checkParsedMachO(targetPath, bytes);
    _checkObjdumpOutput(
      parsed.objdumpPath,
      targetPath,
      parsed.expectedSubstrings,
    );
    _writeVerifyStamp(outputPath);
  } finally {
    if (tempExtractedBinaryPath != null) {
      final f = File(tempExtractedBinaryPath);
      if (f.existsSync()) {
        f.deleteSync();
      }
    }
  }
}

/// Loads the verified binary from a ZIP/IPA archive, staging it at a
/// temporary path next to the stamp output.
({String targetPath, Uint8List bytes, String tempPath}) _loadZipVerifyTarget(
  _VerifyArgs parsed,
  String inputPath,
  String outputPath,
) {
  final zipEntries = _readZipArchiveEntries(
    File(inputPath).readAsBytesSync(),
  );
  _checkZipVerifyEntries(
    zipEntries,
    inputPath,
    parsed.expectedEntries,
    parsed.forbiddenEntries,
  );
  final binaryRelpath = parsed.binaryRelpath;
  if (binaryRelpath == null || binaryRelpath.isEmpty) {
    throw ArgumentError(
      '--binary-relpath is required when verifying a ZIP/IPA archive.',
    );
  }
  final entryBytes = zipEntries[binaryRelpath];
  if (entryBytes == null) {
    throw StateError(
      'Binary "$binaryRelpath" not found in archive "$inputPath". '
      'Entries: ${zipEntries.keys.toList()}',
    );
  }
  final tempPath = '$outputPath.extracted_macho';
  final tempFile = File(tempPath);
  tempFile.parent.createSync(recursive: true);
  tempFile.writeAsBytesSync(entryBytes);
  return (targetPath: tempPath, bytes: entryBytes, tempPath: tempPath);
}

/// Loads the verified binary from a staged bundle directory or file.
({String targetPath, Uint8List bytes}) _loadBundleVerifyTarget(
  _VerifyArgs parsed,
  String inputPath,
) {
  _checkBundleVerifyEntries(
    inputPath,
    parsed.expectedEntries,
    parsed.forbiddenEntries,
  );
  final binaryRelpath = parsed.binaryRelpath;
  final targetPath = binaryRelpath != null && binaryRelpath.isNotEmpty
      ? '$inputPath/$binaryRelpath'
      : inputPath;
  return (
    targetPath: targetPath,
    bytes: File(targetPath).readAsBytesSync(),
  );
}

/// Throws when an expected archive entry is missing or a forbidden one hits.
void _checkZipVerifyEntries(
  Map<String, Uint8List> zipEntries,
  String inputPath,
  List<String> expectedEntries,
  List<String> forbiddenEntries,
) {
  for (final expectedEntry in expectedEntries) {
    if (!zipEntries.containsKey(expectedEntry) &&
        !zipEntries.containsKey('$expectedEntry/')) {
      throw StateError(
        'Expected archive entry "$expectedEntry" not found in "$inputPath". '
        'Entries: ${zipEntries.keys.toList()}',
      );
    }
  }
  for (final forbiddenEntry in forbiddenEntries) {
    final matching = zipEntries.keys.where(
      (k) =>
          k == forbiddenEntry ||
          k.startsWith('$forbiddenEntry/') ||
          k.contains(forbiddenEntry),
    );
    if (matching.isNotEmpty) {
      throw StateError(
        'Forbidden archive entry "$forbiddenEntry" found in "$inputPath": '
        '${matching.toList()}',
      );
    }
  }
}

/// Throws when an expected bundle entry is missing or a forbidden one hits.
void _checkBundleVerifyEntries(
  String inputPath,
  List<String> expectedEntries,
  List<String> forbiddenEntries,
) {
  for (final expectedEntry in expectedEntries) {
    final candidate = '$inputPath/$expectedEntry';
    if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
        FileSystemEntityType.notFound) {
      throw StateError(
        'Expected bundle entry "$expectedEntry" not found under "$inputPath".',
      );
    }
  }
  for (final forbiddenEntry in forbiddenEntries) {
    final candidate = '$inputPath/$forbiddenEntry';
    if (FileSystemEntity.typeSync(candidate, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError(
        'Forbidden bundle entry "$forbiddenEntry" found under "$inputPath".',
      );
    }
  }
}

/// Parses the loaded binary's load commands, failing unless it is Mach-O.
void _checkParsedMachO(String targetPath, Uint8List bytes) {
  if (!isMachO64(bytes) && !isFatMachO(bytes)) {
    throw FormatException(
      'File "$targetPath" is not a 64-bit or universal Mach-O binary.',
    );
  }
  if (isFatMachO(bytes)) {
    for (final s in extractFatSlices(bytes)) {
      parseLoadCommands(s.bytes);
    }
  } else {
    parseLoadCommands(bytes);
  }
}

/// Runs llvm-objdump on [targetPath] and checks the expected substrings.
void _checkObjdumpOutput(
  String? objdumpPath,
  String targetPath,
  List<String> expectedSubstrings,
) {
  if (objdumpPath == null || objdumpPath.isEmpty) return;
  final res = Process.runSync(objdumpPath, [
    '--macho',
    '--private-headers',
    '--dylib-id',
    '--arch=all',
    targetPath,
  ]);
  if (res.exitCode != 0) {
    throw StateError(
      'llvm-objdump failed on "$targetPath" (exit ${res.exitCode}):\n'
      '${res.stderr}',
    );
  }
  final stdoutStr = res.stdout as String;
  for (final expected in expectedSubstrings) {
    if (!stdoutStr.contains(expected)) {
      throw StateError(
        'Expected substring "$expected" not found in llvm-objdump output for '
        '"$targetPath":\n$stdoutStr',
      );
    }
  }
}

/// Writes the `verified` stamp file for a successful `verify` run.
void _writeVerifyStamp(String outputPath) {
  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync('verified\n');
}

/// Returns true if [bytes] begins with a 64-bit little-endian Mach-O header.
bool isMachO64(Uint8List bytes) {
  if (bytes.length < mhHeaderSize64) return false;
  final bd = ByteData.sublistView(bytes);
  return bd.getUint32(0, Endian.little) == mhMagic64;
}

/// Returns true if [bytes] begins with a 32-bit Mach-O magic (`MH_MAGIC` or `MH_CIGAM`).
bool isMachO32(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final bd = ByteData.sublistView(bytes);
  final magic = bd.getUint32(0, Endian.little);
  return magic == mhMagic32 || magic == mhCigam32;
}

/// Returns true if [bytes] begins with a Universal (Fat) Mach-O header
/// (`FAT_MAGIC` `0xcafebabe` or `FAT_MAGIC_64` `0xcafebabf`).
bool isFatMachO(Uint8List bytes) {
  if (bytes.length < 8) return false;
  final bd = ByteData.sublistView(bytes);
  final magicBE = bd.getUint32(0, Endian.big);
  if (magicBE == fatMagic || magicBE == fatMagic64) {
    final nfat = bd.getUint32(4, Endian.big);
    return nfat >= 1 && nfat <= 32;
  }
  final magicLE = bd.getUint32(0, Endian.little);
  if (magicLE == fatMagic || magicLE == fatMagic64) {
    final nfat = bd.getUint32(4, Endian.little);
    return nfat >= 1 && nfat <= 32;
  }
  return false;
}

/// Represents a single architecture slice inside a universal (fat) Mach-O binary.
class FatSlice {
  final int cputype;
  final int cpusubtype;
  final int align;
  final Uint8List bytes;

  FatSlice({
    required this.cputype,
    required this.cpusubtype,
    required this.bytes,
    int? align,
  }) : align = align ?? (cputype == cpuTypeArm64 ? 14 : 12);
}

/// Extracts all architecture slices from a universal (fat) Mach-O binary.
List<FatSlice> extractFatSlices(Uint8List bytes) {
  if (bytes.length < 8) {
    throw const FormatException('Not a universal (fat) Mach-O binary.');
  }
  final bd = ByteData.sublistView(bytes);
  final magicBE = bd.getUint32(0, Endian.big);
  final magicLE = bd.getUint32(0, Endian.little);
  late final Endian headerEndian;
  late final bool is64;
  if (magicBE == fatMagic) {
    headerEndian = Endian.big;
    is64 = false;
  } else if (magicBE == fatMagic64) {
    headerEndian = Endian.big;
    is64 = true;
  } else if (magicLE == fatMagic) {
    headerEndian = Endian.little;
    is64 = false;
  } else if (magicLE == fatMagic64) {
    headerEndian = Endian.little;
    is64 = true;
  } else {
    throw const FormatException('Not a universal (fat) Mach-O binary.');
  }

  final nfatArch = bd.getUint32(4, headerEndian);
  if (nfatArch == 0 || nfatArch > 32) {
    throw FormatException('Invalid fat Mach-O nfat_arch count: $nfatArch.');
  }
  final archEntrySize = is64 ? 32 : 20;
  final tableEnd = 8 + nfatArch * archEntrySize;
  if (tableEnd > bytes.length) {
    throw const FormatException('Truncated fat Mach-O architecture table.');
  }

  final slices = <FatSlice>[];
  for (var i = 0; i < nfatArch; i++) {
    final entryOff = 8 + i * archEntrySize;
    final cputype = bd.getUint32(entryOff, headerEndian);
    final cpusubtype = bd.getUint32(entryOff + 4, headerEndian);
    final sliceOffset = is64
        ? bd.getUint64(entryOff + 8, headerEndian)
        : bd.getUint32(entryOff + 8, headerEndian);
    final sliceSize = is64
        ? bd.getUint64(entryOff + 16, headerEndian)
        : bd.getUint32(entryOff + 12, headerEndian);
    final align = is64
        ? bd.getUint32(entryOff + 24, headerEndian)
        : bd.getUint32(entryOff + 16, headerEndian);
    if (sliceOffset < tableEnd ||
        sliceSize == 0 ||
        sliceOffset + sliceSize > bytes.length) {
      throw FormatException(
        'Fat Mach-O slice $i (offset $sliceOffset, size $sliceSize) is out of '
        'bounds (file length ${bytes.length}).',
      );
    }
    slices.add(
      FatSlice(
        cputype: cputype,
        cpusubtype: cpusubtype,
        align: align,
        bytes: Uint8List.fromList(
          bytes.sublist(sliceOffset, sliceOffset + sliceSize),
        ),
      ),
    );
  }
  return slices;
}

/// Builds a universal (fat) Mach-O binary from [slices].
Uint8List buildFatMachO(List<FatSlice> slices, {bool fat64 = false}) {
  if (slices.isEmpty) {
    throw ArgumentError.value(
      slices,
      'slices',
      'Must contain at least one slice.',
    );
  }
  final archEntrySize = fat64 ? 32 : 20;
  final headerAndTableSize = 8 + slices.length * archEntrySize;
  final sliceOffsets = <int>[];
  var currentOffset = headerAndTableSize;
  for (final s in slices) {
    final effAlign = s.align.clamp(0, 20);
    final alignment = 1 << effAlign;
    currentOffset = (currentOffset + alignment - 1) & ~(alignment - 1);
    sliceOffsets.add(currentOffset);
    currentOffset += s.bytes.length;
  }

  final out = Uint8List(currentOffset);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, fat64 ? fatMagic64 : fatMagic, Endian.big);
  bd.setUint32(4, slices.length, Endian.big);
  for (var i = 0; i < slices.length; i++) {
    final s = slices[i];
    final entryOff = 8 + i * archEntrySize;
    final off = sliceOffsets[i];
    bd.setUint32(entryOff, s.cputype, Endian.big);
    bd.setUint32(entryOff + 4, s.cpusubtype, Endian.big);
    if (fat64) {
      bd.setUint64(entryOff + 8, off, Endian.big);
      bd.setUint64(entryOff + 16, s.bytes.length, Endian.big);
      bd.setUint32(entryOff + 24, s.align, Endian.big);
      bd.setUint32(entryOff + 28, 0, Endian.big);
    } else {
      bd.setUint32(entryOff + 8, off, Endian.big);
      bd.setUint32(entryOff + 12, s.bytes.length, Endian.big);
      bd.setUint32(entryOff + 16, s.align, Endian.big);
    }
    out.setRange(off, off + s.bytes.length, s.bytes);
  }
  return out;
}

int _cpuTypeForArch(String arch) {
  switch (arch) {
    case 'arm64':
      return cpuTypeArm64;
    case 'x86_64':
      return cpuTypeX86_64;
    default:
      throw ArgumentError.value(arch, 'arch', 'Expected "arm64" or "x86_64".');
  }
}

/// Extracts the single 64-bit Mach-O slice matching [arch] (`arm64` or `x86_64`)
/// from a universal (fat) Mach-O binary.
Uint8List thinFatMachO(Uint8List bytes, String arch) {
  final targetCpuType = _cpuTypeForArch(arch);
  final slices = extractFatSlices(bytes);
  for (final s in slices) {
    if (s.cputype == targetCpuType) {
      if (isMachO32(s.bytes) || (s.cputype & cpuArchAbi64) == 0) {
        throw FormatException(
          'Fat Mach-O slice for "$arch" is an unsupported 32-bit Mach-O binary.',
        );
      }
      if (!isMachO64(s.bytes)) {
        throw FormatException(
          'Fat Mach-O slice for "$arch" is not a valid 64-bit Mach-O binary.',
        );
      }
      return s.bytes;
    }
  }
  final has32Bit = slices.any(
    (s) => isMachO32(s.bytes) || (s.cputype & cpuArchAbi64) == 0,
  );
  if (has32Bit) {
    throw FormatException(
      'Fat Mach-O binary contains unsupported 32-bit Mach-O slice(s) and no '
      '64-bit slice for architecture "$arch".',
    );
  }
  throw FormatException(
    'Fat Mach-O binary does not contain a slice for architecture "$arch".',
  );
}

/// Parses a platform name (`ios`, `iossim`, `macos`) into its Mach-O constant.
int parsePlatform(String name) {
  switch (name) {
    case 'macos':
      return platformMacos;
    case 'ios':
      return platformIos;
    case 'iossim':
      return platformIosSimulator;
    default:
      throw ArgumentError.value(
        name,
        'platform',
        'Expected "ios", "iossim", or "macos".',
      );
  }
}

/// Encodes `"major[.minor[.patch]]"` into `(major << 16) | (minor << 8) | patch`.
int parsePackedVersion(String version) {
  final parts = version.split('.');
  if (parts.isEmpty || parts.length > 3) {
    throw FormatException('Invalid version string "$version"');
  }
  final major = int.parse(parts[0]);
  final minor = parts.length > 1 ? int.parse(parts[1]) : 0;
  final patch = parts.length > 2 ? int.parse(parts[2]) : 0;
  if (major < 0 ||
      major > 0xffff ||
      minor < 0 ||
      minor > 0xff ||
      patch < 0 ||
      patch > 0xff) {
    throw FormatException('Version component out of range in "$version"');
  }
  return (major << 16) | (minor << 8) | patch;
}

/// Represents a single raw Mach-O load command.
class LoadCommand {
  final int cmd;
  final Uint8List bytes;

  LoadCommand(this.cmd, this.bytes);

  int get cmdsize => bytes.length;
}

/// The fields of a 72-byte `LC_SEGMENT_64` load command with 0 sections.
/// Shared by [buildLcSegment64] and xtool_pack's stub synthesizer so a segment
/// command is described once.
typedef Segment64Spec = ({
  String segname,
  int vmaddr,
  int vmsize,
  int fileoff,
  int filesize,
  int maxprot,
  int initprot,
  int nsects,
  int flags,
});

/// Builds a 72-byte `LC_SEGMENT_64` load command with 0 sections.
LoadCommand buildLcSegment64(Segment64Spec spec) {
  final buf = Uint8List(72);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcSegment64, Endian.little);
  bd.setUint32(4, 72, Endian.little);
  final nameBytes = ascii.encode(spec.segname);
  buf.setRange(8, 8 + math.min<int>(16, nameBytes.length), nameBytes);
  bd.setUint64(24, spec.vmaddr, Endian.little);
  bd.setUint64(32, spec.vmsize, Endian.little);
  bd.setUint64(40, spec.fileoff, Endian.little);
  bd.setUint64(48, spec.filesize, Endian.little);
  bd.setUint32(56, spec.maxprot, Endian.little);
  bd.setUint32(60, spec.initprot, Endian.little);
  bd.setUint32(64, spec.nsects, Endian.little);
  bd.setUint32(68, spec.flags, Endian.little);
  return LoadCommand(lcSegment64, buf);
}

/// Builds a 24-byte `LC_SYMTAB` load command.
LoadCommand buildLcSymtab({
  required int symoff,
  required int nsyms,
  required int stroff,
  required int strsize,
}) {
  final buf = Uint8List(24);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcSymtab, Endian.little);
  bd.setUint32(4, 24, Endian.little);
  bd.setUint32(8, symoff, Endian.little);
  bd.setUint32(12, nsyms, Endian.little);
  bd.setUint32(16, stroff, Endian.little);
  bd.setUint32(20, strsize, Endian.little);
  return LoadCommand(lcSymtab, buf);
}

/// Builds an 80-byte `LC_DYSYMTAB` load command with empty symbol tables.
LoadCommand buildLcDysymtab() {
  final buf = Uint8List(80);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcDysymtab, Endian.little);
  bd.setUint32(4, 80, Endian.little);
  return LoadCommand(lcDysymtab, buf);
}

/// Builds a 24-byte `LC_UUID` load command with the given 16-byte [uuid].
LoadCommand buildLcUuid(Uint8List uuid) {
  if (uuid.length != 16) {
    throw ArgumentError.value(uuid.length, 'uuid.length', 'Must be 16 bytes.');
  }
  final buf = Uint8List(24);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcUuid, Endian.little);
  bd.setUint32(4, 24, Endian.little);
  buf.setRange(8, 24, uuid);
  return LoadCommand(lcUuid, buf);
}

/// Builds a 24-byte `LC_BUILD_VERSION` load command (`ntools = 0`).
LoadCommand buildLcBuildVersion({
  required int platform,
  required int minos,
  required int sdk,
}) {
  final buf = Uint8List(24);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcBuildVersion, Endian.little);
  bd.setUint32(4, 24, Endian.little);
  bd.setUint32(8, platform, Endian.little);
  bd.setUint32(12, minos, Endian.little);
  bd.setUint32(16, sdk, Endian.little);
  bd.setUint32(20, 0, Endian.little); // ntools = 0
  return LoadCommand(lcBuildVersion, buf);
}

/// Builds an 8-byte-aligned `LC_ID_DYLIB` load command.
LoadCommand buildLcIdDylib(
  String installName, {
  int timestamp = 2,
  int currentVersion = 0x00010000,
  int compatibilityVersion = 0x00010000,
}) {
  final strBytes = utf8.encode(installName);
  // dylib_command is 24 bytes header + string + NUL + padding to 8-byte boundary.
  final unalignedSize = 24 + strBytes.length + 1;
  final cmdsize = (unalignedSize + 7) & ~7;
  final buf = Uint8List(cmdsize);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcIdDylib, Endian.little);
  bd.setUint32(4, cmdsize, Endian.little);
  bd.setUint32(8, 24, Endian.little); // name.offset = 24
  bd.setUint32(12, timestamp, Endian.little);
  bd.setUint32(16, currentVersion, Endian.little);
  bd.setUint32(20, compatibilityVersion, Endian.little);
  buf.setRange(24, 24 + strBytes.length, strBytes);
  return LoadCommand(lcIdDylib, buf);
}

/// Builds an 8-byte-aligned `LC_RPATH` load command.
LoadCommand buildLcRpath(String rpath) {
  final strBytes = utf8.encode(rpath);
  // rpath_command is 12 bytes header + string + NUL + padding to 8-byte boundary.
  final unalignedSize = 12 + strBytes.length + 1;
  final cmdsize = (unalignedSize + 7) & ~7;
  final buf = Uint8List(cmdsize);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcRpath, Endian.little);
  bd.setUint32(4, cmdsize, Endian.little);
  bd.setUint32(8, 12, Endian.little); // path.offset = 12
  buf.setRange(12, 12 + strBytes.length, strBytes);
  return LoadCommand(lcRpath, buf);
}

/// Extracts the NUL-terminated string starting at [offset] in [bytes].
String _readLcString(Uint8List bytes, int offset) {
  if (offset < 0 || offset >= bytes.length) return '';
  var end = offset;
  while (end < bytes.length && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(offset, end), allowMalformed: true);
}

/// Parses the load commands from a 64-bit Mach-O binary.
List<LoadCommand> parseLoadCommands(Uint8List bytes) {
  if (!isMachO64(bytes)) {
    if (isMachO32(bytes)) {
      throw const FormatException(
        'Unsupported 32-bit Mach-O binary; expected 64-bit Mach-O.',
      );
    }
    throw const FormatException('Not a 64-bit little-endian Mach-O binary.');
  }
  final bd = ByteData.sublistView(bytes);
  final ncmds = bd.getUint32(16, Endian.little);
  final sizeofcmds = bd.getUint32(20, Endian.little);
  if (mhHeaderSize64 + sizeofcmds > bytes.length) {
    throw const FormatException('Truncated Mach-O load commands.');
  }
  final commands = <LoadCommand>[];
  var offset = mhHeaderSize64;
  for (var i = 0; i < ncmds; i++) {
    if (offset + 8 > mhHeaderSize64 + sizeofcmds) {
      throw const FormatException(
        'Load command header extends past sizeofcmds.',
      );
    }
    final cmd = bd.getUint32(offset, Endian.little);
    final cmdsize = bd.getUint32(offset + 4, Endian.little);
    if (cmdsize < 8 || offset + cmdsize > mhHeaderSize64 + sizeofcmds) {
      throw FormatException('Invalid cmdsize $cmdsize at offset $offset.');
    }
    commands.add(
      LoadCommand(
        cmd,
        Uint8List.fromList(bytes.sublist(offset, offset + cmdsize)),
      ),
    );
    offset += cmdsize;
  }
  return commands;
}

/// Finds the lowest non-zero file offset referenced by any segment, section,
/// or linkedit table in the Mach-O binary. Load commands may grow up to this
/// boundary without overwriting section/segment payload bytes.
int _findFirstPayloadOffset(List<LoadCommand> commands, int totalLength) {
  final floor = _PayloadFloor(totalLength);
  for (final lc in commands) {
    _considerCommandPayload(lc, floor);
  }
  return floor.value;
}

/// Tracks the lowest referenced file offset seen so far.
class _PayloadFloor {
  int value;

  _PayloadFloor(this.value);

  void consider(int offset, int size) {
    if (offset > 0 && size > 0 && offset < value) {
      value = offset;
    }
  }
}

/// Folds one load command's referenced file range into [floor].
void _considerCommandPayload(LoadCommand lc, _PayloadFloor floor) {
  final bd = ByteData.sublistView(lc.bytes);
  switch (lc.cmd) {
    case lcSegment64:
      _considerSegmentPayload(lc, bd, floor);
    case lcSymtab:
      if (lc.bytes.length >= 24) {
        floor.consider(
          bd.getUint32(8, Endian.little),
          bd.getUint32(12, Endian.little) * 16,
        );
        floor.consider(
          bd.getUint32(16, Endian.little),
          bd.getUint32(20, Endian.little),
        );
      }
    case lcFunctionStarts:
    case lcDataInCode:
    case lcCodeSignature:
    case lcDyldExportsTrie:
    case lcDyldChainedFixups:
      if (lc.bytes.length >= 16) {
        floor.consider(
          bd.getUint32(8, Endian.little),
          bd.getUint32(12, Endian.little),
        );
      }
  }
}

/// Folds a `LC_SEGMENT_64` command's file range and its sections into [floor].
void _considerSegmentPayload(
  LoadCommand lc,
  ByteData bd,
  _PayloadFloor floor,
) {
  if (lc.bytes.length < 72) return;
  final fileoff = bd.getUint64(40, Endian.little);
  final filesize = bd.getUint64(48, Endian.little);
  final nsects = bd.getUint32(64, Endian.little);
  if (fileoff > 0 && filesize > 0) {
    floor.consider(fileoff, filesize);
  }
  // Inspect each section_64 (80 bytes each starting at offset 72).
  for (var s = 0; s < nsects; s++) {
    final sectOff = 72 + s * 80;
    if (sectOff + 80 <= lc.bytes.length) {
      final sSize = bd.getUint64(sectOff + 40, Endian.little);
      final sOffset = bd.getUint32(sectOff + 48, Endian.little);
      floor.consider(sOffset, sSize);
    }
  }
}

/// Resolved `patchMachO` options: platform versions, identity, and search
/// paths applied to the binary. Grouped so the patch entry points stay small.
class PatchOptions {
  const PatchOptions({
    this.platform,
    this.minOs,
    this.sdkVersion,
    this.installName,
    this.rpaths = const [],
    this.arch,
  });

  /// The `LC_BUILD_VERSION` platform constant, if any.
  final int? platform;

  /// The packed minimum-OS version, if any.
  final int? minOs;

  /// The packed SDK version, if any.
  final int? sdkVersion;

  /// The new `LC_ID_DYLIB` install name, if any.
  final String? installName;

  /// The `LC_RPATH` entries to add.
  final List<String> rpaths;

  /// The fat slice to thin (`"arm64"` or `"x86_64"`), if any.
  final String? arch;
}

/// Patches a 64-bit or universal (fat) Mach-O binary in memory and recomputes
/// its embedded `LC_CODE_SIGNATURE` SHA-256 page hashes if present.
///
/// When [inputBytes] is a universal (fat) Mach-O binary:
/// - If [arch] is provided (`"arm64"` or `"x86_64"`), the fat binary is thinned
///   to that slice and the slice is patched.
/// - Otherwise, every slice in the fat binary is patched and reassembled into
///   a universal (fat) Mach-O binary.
///
/// Throws [FormatException] if [inputBytes] (or any slice being patched) is a
/// 32-bit Mach-O binary or non-Mach-O data.
Uint8List patchMachO(
  Uint8List inputBytes, [
  PatchOptions options = const PatchOptions(),
]) {
  final arch = options.arch;
  if (isFatMachO(inputBytes)) {
    if (arch != null) {
      final thinSlice = thinFatMachO(inputBytes, arch);
      return _patchSingleMachO64(
        thinSlice,
        platform: options.platform,
        minOs: options.minOs,
        sdkVersion: options.sdkVersion,
        installName: options.installName,
        rpaths: options.rpaths,
      );
    }
    return _patchFatMachO(
      inputBytes,
      platform: options.platform,
      minOs: options.minOs,
      sdkVersion: options.sdkVersion,
      installName: options.installName,
      rpaths: options.rpaths,
    );
  }

  if (isMachO32(inputBytes)) {
    throw const FormatException(
      'Unsupported 32-bit Mach-O binary (0xfeedface); only 64-bit Mach-O '
      'binaries are supported.',
    );
  }

  if (!isMachO64(inputBytes)) {
    throw const FormatException(
      'Not a Mach-O binary (expected 64-bit or universal Mach-O).',
    );
  }

  if (arch != null) {
    _checkThinArch(inputBytes, arch);
  }

  return _patchSingleMachO64(
    inputBytes,
    platform: options.platform,
    minOs: options.minOs,
    sdkVersion: options.sdkVersion,
    installName: options.installName,
    rpaths: options.rpaths,
  );
}

/// Patches every slice of a universal (fat) Mach-O binary and reassembles it,
/// preserving the fat32/fat64 header width.
Uint8List _patchFatMachO(
  Uint8List inputBytes, {
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? installName,
  List<String> rpaths = const [],
}) {
  final slices = extractFatSlices(inputBytes);
  final bd = ByteData.sublistView(inputBytes);
  final isFat64 =
      bd.getUint32(0, Endian.big) == fatMagic64 ||
      bd.getUint32(0, Endian.little) == fatMagic64;
  final patchedSlices = <FatSlice>[];
  for (var i = 0; i < slices.length; i++) {
    final s = slices[i];
    if (isMachO32(s.bytes) || (s.cputype & cpuArchAbi64) == 0) {
      throw FormatException(
        'Fat Mach-O slice $i (cputype 0x${s.cputype.toRadixString(16)}) is '
        'an unsupported 32-bit Mach-O binary.',
      );
    }
    if (!isMachO64(s.bytes)) {
      throw FormatException(
        'Fat Mach-O slice $i is not a valid 64-bit Mach-O binary.',
      );
    }
    final patchedBytes = _patchSingleMachO64(
      s.bytes,
      platform: platform,
      minOs: minOs,
      sdkVersion: sdkVersion,
      installName: installName,
      rpaths: rpaths,
    );
    patchedSlices.add(
      FatSlice(
        cputype: s.cputype,
        cpusubtype: s.cpusubtype,
        align: s.align,
        bytes: patchedBytes,
      ),
    );
  }
  return buildFatMachO(patchedSlices, fat64: isFat64);
}

/// Throws when a thin binary's cputype is not the requested [arch].
void _checkThinArch(Uint8List inputBytes, String arch) {
  final targetCpu = _cpuTypeForArch(arch);
  final actualCpu = ByteData.sublistView(
    inputBytes,
  ).getUint32(4, Endian.little);
  if (actualCpu != targetCpu) {
    throw FormatException(
      'Mach-O cputype 0x${actualCpu.toRadixString(16)} does not match '
      'requested architecture "$arch".',
    );
  }
}

Uint8List _patchSingleMachO64(
  Uint8List inputBytes, {
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? installName,
  List<String> rpaths = const [],
}) {
  final bdIn = ByteData.sublistView(inputBytes);
  final oldSizeofcmds = bdIn.getUint32(20, Endian.little);
  final originalCommands = parseLoadCommands(inputBytes);
  final maxLoadCommandEnd = _findFirstPayloadOffset(
    originalCommands,
    inputBytes.length,
  );

  final state = _PatchRewrite();
  for (final lc in originalCommands) {
    _rewriteLoadCommand(
      lc,
      platform: platform,
      minOs: minOs,
      sdkVersion: sdkVersion,
      installName: installName,
      state: state,
    );
  }

  if (platform != null && minOs != null && !state.wroteBuildVersion) {
    state.updatedCommands.add(
      buildLcBuildVersion(
        platform: platform,
        minos: minOs,
        sdk: sdkVersion ?? minOs,
      ),
    );
  }

  if (installName != null && !state.wroteIdDylib) {
    state.updatedCommands.add(buildLcIdDylib(installName));
  }

  for (final rpath in rpaths) {
    if (state.existingRpaths.add(rpath)) {
      state.updatedCommands.add(buildLcRpath(rpath));
    }
  }

  if (state.codeSigCommand != null) {
    state.updatedCommands.add(state.codeSigCommand!);
  }

  return _emitPatchedMachO(
    inputBytes,
    oldSizeofcmds,
    maxLoadCommandEnd,
    state.updatedCommands,
    state.codeSigCommand,
  );
}

/// Mutable rewrite state for [_patchSingleMachO64].
class _PatchRewrite {
  final updatedCommands = <LoadCommand>[];
  var wroteBuildVersion = false;
  var wroteIdDylib = false;
  final existingRpaths = <String>{};
  LoadCommand? codeSigCommand;
}

/// Rewrites one load command into [state], stripping legacy version-minimum
/// commands and holding `LC_CODE_SIGNATURE` last.
void _rewriteLoadCommand(
  LoadCommand lc, {
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? installName,
  required _PatchRewrite state,
}) {
  // Strip legacy LC_VERSION_MIN_* commands when setting LC_BUILD_VERSION.
  if (platform != null &&
      (lc.cmd == lcVersionMinMacosx ||
          lc.cmd == lcVersionMinIphoneos ||
          lc.cmd == lcVersionMinTvos ||
          lc.cmd == lcVersionMinWatchos)) {
    return;
  }

  if (lc.cmd == lcBuildVersion && platform != null && minOs != null) {
    if (!state.wroteBuildVersion) {
      state.updatedCommands.add(
        buildLcBuildVersion(
          platform: platform,
          minos: minOs,
          sdk: sdkVersion ?? minOs,
        ),
      );
      state.wroteBuildVersion = true;
    }
    return;
  }

  if (lc.cmd == lcIdDylib && installName != null) {
    if (!state.wroteIdDylib) {
      final versions = _idDylibVersions(lc);
      state.updatedCommands.add(
        buildLcIdDylib(
          installName,
          timestamp: versions.timestamp,
          currentVersion: versions.currentVersion,
          compatibilityVersion: versions.compatibilityVersion,
        ),
      );
      state.wroteIdDylib = true;
    }
    return;
  }

  if (lc.cmd == lcRpath && lc.bytes.length >= 12) {
    final lcBd = ByteData.sublistView(lc.bytes);
    final pathOffset = lcBd.getUint32(8, Endian.little);
    state.existingRpaths.add(_readLcString(lc.bytes, pathOffset));
    state.updatedCommands.add(lc);
    return;
  }

  // Hold LC_CODE_SIGNATURE so any newly added load commands are placed
  // before LC_CODE_SIGNATURE (matching ld64 / vtool conventions).
  if (lc.cmd == lcCodeSignature && state.codeSigCommand == null) {
    state.codeSigCommand = lc;
    return;
  }

  state.updatedCommands.add(lc);
}

/// The version fields an `LC_ID_DYLIB` rewrite preserves, defaulting as new.
({int timestamp, int currentVersion, int compatibilityVersion})
_idDylibVersions(LoadCommand lc) {
  if (lc.bytes.length < 24) {
    return (
      timestamp: 2,
      currentVersion: 0x00010000,
      compatibilityVersion: 0x00010000,
    );
  }
  final lcBd = ByteData.sublistView(lc.bytes);
  return (
    timestamp: lcBd.getUint32(12, Endian.little),
    currentVersion: lcBd.getUint32(16, Endian.little),
    compatibilityVersion: lcBd.getUint32(20, Endian.little),
  );
}

/// Serializes [updatedCommands] over [inputBytes], growing a header-only
/// buffer or fitting before the first payload offset, then re-signs.
Uint8List _emitPatchedMachO(
  Uint8List inputBytes,
  int oldSizeofcmds,
  int maxLoadCommandEnd,
  List<LoadCommand> updatedCommands,
  LoadCommand? codeSigCommand,
) {
  var newSizeofcmds = 0;
  for (final lc in updatedCommands) {
    newSizeofcmds += lc.cmdsize;
  }

  final newLoadCmdEnd = mhHeaderSize64 + newSizeofcmds;
  // If the file has no payload sections/segments at all (header-only fixture)
  // and grows past EOF, extend the buffer; otherwise verify we fit before
  // the first payload offset.
  final bool isHeaderOnly =
      maxLoadCommandEnd == inputBytes.length &&
      mhHeaderSize64 + oldSizeofcmds == inputBytes.length;

  if (!isHeaderOnly && newLoadCmdEnd > maxLoadCommandEnd) {
    throw StateError(
      'Not enough header padding for load commands: need $newLoadCmdEnd bytes, '
      'first payload is at $maxLoadCommandEnd.',
    );
  }

  final outLength = isHeaderOnly
      ? math.max<int>(inputBytes.length, newLoadCmdEnd)
      : inputBytes.length;
  final out = Uint8List(outLength);
  out.setRange(0, inputBytes.length, inputBytes);

  // Zero the old load command region first so any shrinkage leaves clean zeroes.
  final clearEnd = math.min<int>(
    out.length,
    mhHeaderSize64 + math.max<int>(oldSizeofcmds, newSizeofcmds),
  );
  out.fillRange(mhHeaderSize64, clearEnd, 0);

  // Write updated header fields (ncmds, sizeofcmds) and load commands.
  final bdOut = ByteData.sublistView(out);
  bdOut.setUint32(16, updatedCommands.length, Endian.little);
  bdOut.setUint32(20, newSizeofcmds, Endian.little);

  var writeOffset = mhHeaderSize64;
  for (final lc in updatedCommands) {
    out.setRange(writeOffset, writeOffset + lc.cmdsize, lc.bytes);
    writeOffset += lc.cmdsize;
  }

  if (codeSigCommand != null) {
    _resignEmbeddedCodeSignature(out, codeSigCommand);
  }

  return out;
}

/// Recomputes SHA-256 page hashes inside `LC_CODE_SIGNATURE`'s `CS_CodeDirectory`
/// blob if present.
void _resignEmbeddedCodeSignature(Uint8List bytes, LoadCommand codeSigLc) {
  if (codeSigLc.bytes.length < 16) return;
  final lcBd = ByteData.sublistView(codeSigLc.bytes);
  final dataoff = lcBd.getUint32(8, Endian.little);
  final datasize = lcBd.getUint32(12, Endian.little);
  if (dataoff == 0 || datasize < 12 || dataoff + datasize > bytes.length) {
    return;
  }

  final bd = ByteData.sublistView(bytes);
  final superMagic = bd.getUint32(dataoff, Endian.big);
  if (superMagic != csMagicEmbeddedSignature) {
    return;
  }
  final blobCount = bd.getUint32(dataoff + 8, Endian.big);
  for (var i = 0; i < blobCount; i++) {
    final indexOff = dataoff + 12 + i * 8;
    if (indexOff + 8 > dataoff + datasize) break;
    final blobOffset = bd.getUint32(indexOff + 4, Endian.big);
    final cdOff = dataoff + blobOffset;
    if (cdOff + 44 > dataoff + datasize) continue;

    final blobMagic = bd.getUint32(cdOff, Endian.big);
    if (blobMagic != csMagicCodeDirectory) continue;

    final cdLength = bd.getUint32(cdOff + 4, Endian.big);
    final hashOffset = bd.getUint32(cdOff + 16, Endian.big);
    final nCodeSlots = bd.getUint32(cdOff + 28, Endian.big);
    final codeLimit = bd.getUint32(cdOff + 32, Endian.big);
    final hashSize = bd.getUint8(cdOff + 36);
    final hashType = bd.getUint8(cdOff + 37);
    final pageSizeShift = bd.getUint8(cdOff + 39);

    if (hashType != csHashTypeSha256 || hashSize != 32) {
      continue;
    }
    final pageSize = pageSizeShift > 0 ? (1 << pageSizeShift) : codeLimit;
    final hashesStart = cdOff + hashOffset;
    if (hashesStart + nCodeSlots * 32 > cdOff + cdLength ||
        hashesStart + nCodeSlots * 32 > bytes.length) {
      continue;
    }

    for (var slot = 0; slot < nCodeSlots; slot++) {
      final pageStart = slot * pageSize;
      final pageEnd = math.min<int>(pageStart + pageSize, codeLimit);
      if (pageStart >= bytes.length ||
          pageEnd > bytes.length ||
          pageStart >= pageEnd) {
        break;
      }
      final digest = sha256(Uint8List.sublistView(bytes, pageStart, pageEnd));
      bytes.setRange(
        hashesStart + slot * 32,
        hashesStart + (slot + 1) * 32,
        digest,
      );
    }
  }
}

/// Synthesizes a well-formed 64-bit Mach-O `MH_DYLIB` or `MH_EXECUTE` stub binary.
///
/// Includes `__TEXT` and `__LINKEDIT` segments, `LC_ID_DYLIB` (for `MH_DYLIB`),
/// `LC_SYMTAB`, `LC_DYSYMTAB`, a deterministic content-derived `LC_UUID`,
/// `LC_BUILD_VERSION`, and `MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL` flags
/// so Apple tools (`codesign`, `otool`, `ld64`, `llvm-objdump`) accept it.
Uint8List generateStubMachO({
  required String arch,
  required int platform,
  required int minOs,
  required int sdkVersion,
  required String installName,
  int fileType = mhDylib,
}) {
  final (cputype, cpusubtype) = _stubCpuType(arch);

  // Page size: 16 KB (0x4000) for arm64, 4 KB (0x1000) for x86_64.
  final pageSize = arch == 'arm64' ? 0x4000 : 0x1000;

  final commands = _stubCommands(
    platform: platform,
    minOs: minOs,
    sdkVersion: sdkVersion,
    installName: installName,
    fileType: fileType,
    pageSize: pageSize,
  );

  var sizeofcmds = 0;
  for (final lc in commands) {
    sizeofcmds += lc.cmdsize;
  }

  final flags =
      mhNoundefs |
      mhDyldlink |
      mhTwolevel |
      (fileType == mhExecute ? mhPie : mhNoReexportedDylibs);

  final out = Uint8List(pageSize + _stubLinkeditFileSize);
  _writeStubHeader(
    out,
    (
      cputype: cputype,
      cpusubtype: cpusubtype,
      fileType: fileType,
      commandCount: commands.length,
      sizeofcmds: sizeofcmds,
      flags: flags,
    ),
  );

  var offset = mhHeaderSize64;
  var uuidDataOffset = -1;
  for (final lc in commands) {
    if (lc.cmd == lcUuid) {
      uuidDataOffset = offset + 8;
    }
    out.setRange(offset, offset + lc.cmdsize, lc.bytes);
    offset += lc.cmdsize;
  }

  // Standard Mach-O string table begins with a leading space and NUL byte.
  out[pageSize] = 0x20;
  out[pageSize + 1] = 0x00;

  // Compute deterministic UUID from the binary content (with UUID bytes zeroed),
  // formatted as an RFC 4122 v5 UUID (matching ld64 / ld64.lld).
  _stampStubUuid(out, uuidDataOffset);

  return out;
}

// 8-byte aligned empty string table (" \0" padded to 8 bytes) in the stub's
// __LINKEDIT.
const _stubLinkeditFileSize = 8;

/// The cputype/cpusubtype pair for a stub [arch].
(int, int) _stubCpuType(String arch) {
  switch (arch) {
    case 'arm64':
      return (cpuTypeArm64, cpuSubtypeArm64All);
    case 'x86_64':
      return (cpuTypeX86_64, cpuSubtypeX86_64All);
    default:
      throw ArgumentError.value(arch, 'arch', 'Expected "arm64" or "x86_64".');
  }
}

/// The stub's load commands: segments, symtabs, identity, UUID and version.
List<LoadCommand> _stubCommands({
  required int platform,
  required int minOs,
  required int sdkVersion,
  required String installName,
  required int fileType,
  required int pageSize,
}) {
  // LC_SEGMENT_64 (__TEXT) - 72 bytes (0 sections).
  final textSeg = buildLcSegment64((
    segname: '__TEXT',
    vmaddr: 0,
    vmsize: pageSize,
    fileoff: 0,
    filesize: pageSize,
    maxprot: 5, // VM_PROT_READ | VM_PROT_EXECUTE
    initprot: 5, // VM_PROT_READ | VM_PROT_EXECUTE
    nsects: 0,
    flags: 0,
  ));

  // LC_SEGMENT_64 (__LINKEDIT) - 72 bytes (0 sections).
  final linkeditSeg = buildLcSegment64((
    segname: '__LINKEDIT',
    vmaddr: pageSize,
    vmsize: pageSize,
    fileoff: pageSize,
    filesize: _stubLinkeditFileSize,
    maxprot: 1, // VM_PROT_READ
    initprot: 1, // VM_PROT_READ
    nsects: 0,
    flags: 0,
  ));

  // LC_SYMTAB and LC_DYSYMTAB pointing into __LINKEDIT.
  final symtab = buildLcSymtab(
    symoff: pageSize,
    nsyms: 0,
    stroff: pageSize,
    strsize: _stubLinkeditFileSize,
  );
  final dysymtab = buildLcDysymtab();
  final placeholderUuid = buildLcUuid(Uint8List(16));
  final buildVersion = buildLcBuildVersion(
    platform: platform,
    minos: minOs,
    sdk: sdkVersion,
  );

  return <LoadCommand>[
    textSeg,
    linkeditSeg,
    if (fileType == mhDylib && installName.isNotEmpty)
      buildLcIdDylib(installName),
    symtab,
    dysymtab,
    placeholderUuid,
    buildVersion,
    if (fileType == mhExecute) ...[
      buildLcRpath('@executable_path/Frameworks'),
      if (platform == platformMacos)
        buildLcRpath('@executable_path/../Frameworks'),
    ],
  ];
}

/// The Mach-O header fields written over a synthesized stub binary. Grouped
/// into a record so the header writer stays small.
typedef _StubHeader = ({
  int cputype,
  int cpusubtype,
  int fileType,
  int commandCount,
  int sizeofcmds,
  int flags,
});

/// Writes the 64-bit Mach-O header over [out].
void _writeStubHeader(Uint8List out, _StubHeader header) {
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, mhMagic64, Endian.little);
  bd.setUint32(4, header.cputype, Endian.little);
  bd.setUint32(8, header.cpusubtype, Endian.little);
  bd.setUint32(12, header.fileType, Endian.little);
  bd.setUint32(16, header.commandCount, Endian.little);
  bd.setUint32(20, header.sizeofcmds, Endian.little);
  bd.setUint32(24, header.flags, Endian.little);
  bd.setUint32(28, 0, Endian.little);
}

/// Stamps the content-derived UUID at [uuidDataOffset] (or skips when absent).
void _stampStubUuid(Uint8List out, int uuidDataOffset) {
  if (uuidDataOffset < 0) return;
  final digest = sha256(out);
  final uuid = Uint8List.fromList(digest.sublist(0, 16));
  uuid[6] = (uuid[6] & 0x0f) | 0x50;
  uuid[8] = (uuid[8] & 0x3f) | 0x80;
  out.setRange(uuidDataOffset, uuidDataOffset + 16, uuid);
}

/// Computes the 32-byte SHA-256 digest of [data].
Uint8List sha256(Uint8List data) => Uint8List.fromList(sha256lib.sha256(data));
