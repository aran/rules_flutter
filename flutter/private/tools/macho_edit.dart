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

// Mach-O 64-bit constants.
const int mhMagic64 = 0xfeedfacf;
const int mhHeaderSize64 = 32;

const int cpuArchAbi64 = 0x01000000;
const int cpuTypeX86_64 = 0x00000007 | cpuArchAbi64; // 0x01000007
const int cpuSubtypeX86_64All = 3;
const int cpuTypeArm64 = 0x0000000c | cpuArchAbi64; // 0x0100000c
const int cpuSubtypeArm64All = 0;

const int mhExecute = 0x2;
const int mhDylib = 0x6;
const int mhNoReexportedDylibs = 0x00100000;
const int mhPie = 0x00200000;

// Load command constants.
const int lcReqDyld = 0x80000000;
const int lcSymtab = 0x02;
const int lcDysymtab = 0x0b;
const int lcIdDylib = 0x0d;
const int lcSegment64 = 0x19;
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
      'Expected subcommand: "patch", "stub", "copy-assets", '
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
    case 'copy-assets':
      _runCopyAssets(rest);
    case 'assemble-macos-framework':
      _runAssembleMacosFramework(rest);
    case 'copy-files':
      _runCopyFiles(rest);
    default:
      _usageError(
        'Unknown subcommand "$subcommand". Expected "patch", "stub", '
        '"copy-assets", "assemble-macos-framework", or "copy-files".',
      );
  }
}

Never _usageError(String message) {
  stderr.writeln('macho_edit: $message');
  exit(64);
}

void _runPatch(List<String> args) {
  String? inputPath;
  String? outputPath;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? installName;
  final rpaths = <String>[];
  var allowNonMacho = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--input':
        if (++i >= args.length) _usageError('--input requires a value');
        inputPath = args[i];
      case '--output':
        if (++i >= args.length) _usageError('--output requires a value');
        outputPath = args[i];
      case '--platform':
        if (++i >= args.length) _usageError('--platform requires a value');
        platformName = args[i];
      case '--min-os':
        if (++i >= args.length) _usageError('--min-os requires a value');
        minOsStr = args[i];
      case '--sdk-version':
        if (++i >= args.length) _usageError('--sdk-version requires a value');
        sdkVersionStr = args[i];
      case '--install-name':
        if (++i >= args.length) _usageError('--install-name requires a value');
        installName = args[i];
      case '--rpath':
        if (++i >= args.length) _usageError('--rpath requires a value');
        for (final part in args[i].split(',')) {
          if (part.isNotEmpty) rpaths.add(part);
        }
      case '--allow-non-macho':
        allowNonMacho = true;
      default:
        _usageError('Unknown flag for patch: $arg');
    }
  }

  if (inputPath == null || outputPath == null) {
    _usageError('patch requires --input and --output');
  }

  final inputBytes = File(inputPath).readAsBytesSync();
  if (!isMachO64(inputBytes)) {
    if (allowNonMacho) {
      final outFile = File(outputPath);
      outFile.parent.createSync(recursive: true);
      outFile.writeAsBytesSync(inputBytes);
      return;
    }
    throw FormatException(
      'Input file "$inputPath" is not a 64-bit little-endian Mach-O binary.',
    );
  }

  int? platform;
  int? minOs;
  int? sdkVersion;
  if (platformName != null || minOsStr != null) {
    if (platformName == null || minOsStr == null) {
      _usageError('--platform and --min-os must be provided together');
    }
    platform = parsePlatform(platformName);
    minOs = parsePackedVersion(minOsStr);
    sdkVersion = sdkVersionStr != null
        ? parsePackedVersion(sdkVersionStr)
        : minOs;
  }

  final patched = patchMachO(
    inputBytes,
    platform: platform,
    minOs: minOs,
    sdkVersion: sdkVersion,
    installName: installName,
    rpaths: rpaths,
  );

  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(patched);
}

void _runStub(List<String> args) {
  String? outputPath;
  String? arch;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? installName;
  var typeStr = 'dylib';

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--output':
        if (++i >= args.length) _usageError('--output requires a value');
        outputPath = args[i];
      case '--arch':
        if (++i >= args.length) _usageError('--arch requires a value');
        arch = args[i];
      case '--platform':
        if (++i >= args.length) _usageError('--platform requires a value');
        platformName = args[i];
      case '--min-os':
        if (++i >= args.length) _usageError('--min-os requires a value');
        minOsStr = args[i];
      case '--sdk-version':
        if (++i >= args.length) _usageError('--sdk-version requires a value');
        sdkVersionStr = args[i];
      case '--install-name':
        if (++i >= args.length) _usageError('--install-name requires a value');
        installName = args[i];
      case '--type':
        if (++i >= args.length) _usageError('--type requires a value');
        typeStr = args[i];
      default:
        _usageError('Unknown flag for stub: $arg');
    }
  }

  if (typeStr != 'dylib' && typeStr != 'execute') {
    _usageError('--type must be "dylib" or "execute", got "$typeStr"');
  }

  if (outputPath == null ||
      arch == null ||
      platformName == null ||
      minOsStr == null ||
      (typeStr == 'dylib' && installName == null)) {
    _usageError(
      'stub requires --output, --arch, --platform, --min-os, and --install-name',
    );
  }

  final platform = parsePlatform(platformName);
  final minOs = parsePackedVersion(minOsStr);
  final sdkVersion = sdkVersionStr != null
      ? parsePackedVersion(sdkVersionStr)
      : minOs;

  final bytes = generateStubMachO(
    arch: arch,
    platform: platform,
    minOs: minOs,
    sdkVersion: sdkVersion,
    installName: installName ?? '',
    fileType: typeStr == 'execute' ? mhExecute : mhDylib,
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

void _runCopyAssets(List<String> args) {
  String? srcPath;
  String? dstPath;
  String? kernelBlobPath;
  String? vmSnapshotPath;
  String? isolateSnapshotPath;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--src':
        if (++i >= args.length) _usageError('--src requires a value');
        srcPath = args[i];
      case '--dst':
        if (++i >= args.length) _usageError('--dst requires a value');
        dstPath = args[i];
      case '--kernel-blob':
        if (++i >= args.length) _usageError('--kernel-blob requires a value');
        kernelBlobPath = args[i];
      case '--vm-snapshot-data':
        if (++i >= args.length) {
          _usageError('--vm-snapshot-data requires a value');
        }
        vmSnapshotPath = args[i];
      case '--isolate-snapshot-data':
        if (++i >= args.length) {
          _usageError('--isolate-snapshot-data requires a value');
        }
        isolateSnapshotPath = args[i];
      default:
        _usageError('Unknown flag for copy-assets: $arg');
    }
  }

  if (srcPath == null || dstPath == null) {
    _usageError('copy-assets requires --src and --dst');
  }

  final dstDir = Directory(dstPath);
  _copyDirDereferencingSync(Directory(srcPath), dstDir);

  if (kernelBlobPath != null && kernelBlobPath.isNotEmpty) {
    File(kernelBlobPath).copySync('${dstDir.path}/kernel_blob.bin');
  }
  if (vmSnapshotPath != null && vmSnapshotPath.isNotEmpty) {
    File(vmSnapshotPath).copySync('${dstDir.path}/vm_snapshot_data');
  }
  if (isolateSnapshotPath != null && isolateSnapshotPath.isNotEmpty) {
    File(isolateSnapshotPath).copySync('${dstDir.path}/isolate_snapshot_data');
  }
}

void _createSymlinkReplacingSync(String linkPath, String target) {
  final link = Link(linkPath);
  if (FileSystemEntity.typeSync(linkPath, followLinks: false) !=
      FileSystemEntityType.notFound) {
    link.deleteSync();
  }
  link.createSync(target);
}

void _runAssembleMacosFramework(List<String> args) {
  String? binaryPath;
  String? infoPlistPath;
  String? assetsPath;
  String? outputDirPath;
  String? kernelBlobPath;
  String? vmSnapshotPath;
  String? isolateSnapshotPath;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--binary':
        if (++i >= args.length) _usageError('--binary requires a value');
        binaryPath = args[i];
      case '--info-plist':
        if (++i >= args.length) _usageError('--info-plist requires a value');
        infoPlistPath = args[i];
      case '--assets':
        if (++i >= args.length) _usageError('--assets requires a value');
        assetsPath = args[i];
      case '--output-dir':
        if (++i >= args.length) _usageError('--output-dir requires a value');
        outputDirPath = args[i];
      case '--kernel-blob':
        if (++i >= args.length) _usageError('--kernel-blob requires a value');
        kernelBlobPath = args[i];
      case '--vm-snapshot-data':
        if (++i >= args.length) {
          _usageError('--vm-snapshot-data requires a value');
        }
        vmSnapshotPath = args[i];
      case '--isolate-snapshot-data':
        if (++i >= args.length) {
          _usageError('--isolate-snapshot-data requires a value');
        }
        isolateSnapshotPath = args[i];
      default:
        _usageError('Unknown flag for assemble-macos-framework: $arg');
    }
  }

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
  final versionADir = Directory('${fwDir.path}/Versions/A');
  final resourcesDir = Directory('${versionADir.path}/Resources');
  final assetsDestDir = Directory('${resourcesDir.path}/flutter_assets');
  assetsDestDir.createSync(recursive: true);

  File(binaryPath).copySync('${versionADir.path}/App');
  File(infoPlistPath).copySync('${resourcesDir.path}/Info.plist');
  _copyDirDereferencingSync(Directory(assetsPath), assetsDestDir);

  if (kernelBlobPath != null && kernelBlobPath.isNotEmpty) {
    File(kernelBlobPath).copySync('${assetsDestDir.path}/kernel_blob.bin');
  }
  if (vmSnapshotPath != null && vmSnapshotPath.isNotEmpty) {
    File(vmSnapshotPath).copySync('${assetsDestDir.path}/vm_snapshot_data');
  }
  if (isolateSnapshotPath != null && isolateSnapshotPath.isNotEmpty) {
    File(
      isolateSnapshotPath,
    ).copySync('${assetsDestDir.path}/isolate_snapshot_data');
  }

  _createSymlinkReplacingSync('${fwDir.path}/Versions/Current', 'A');
  _createSymlinkReplacingSync('${fwDir.path}/App', 'Versions/Current/App');
  _createSymlinkReplacingSync(
    '${fwDir.path}/Resources',
    'Versions/Current/Resources',
  );
}

void _runCopyFiles(List<String> args) {
  String? outputDirPath;
  final positional = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--output-dir') {
      if (++i >= args.length) _usageError('--output-dir requires a value');
      outputDirPath = args[i];
    } else if (arg.startsWith('--')) {
      _usageError('Unknown flag for copy-files: $arg');
    } else {
      positional.add(arg);
    }
  }

  if (outputDirPath == null) {
    _usageError('copy-files requires --output-dir');
  }

  final outDir = Directory(outputDirPath)..createSync(recursive: true);
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
    File(srcPath).copySync('${outDir.path}/$destName');
  }
}

/// Returns true if [bytes] begins with a 64-bit little-endian Mach-O header.
bool isMachO64(Uint8List bytes) {
  if (bytes.length < mhHeaderSize64) return false;
  final bd = ByteData.sublistView(bytes);
  return bd.getUint32(0, Endian.little) == mhMagic64;
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
  var minOffset = totalLength;

  void consider(int offset, int size) {
    if (offset > 0 && size > 0 && offset < minOffset) {
      minOffset = offset;
    }
  }

  for (final lc in commands) {
    final bd = ByteData.sublistView(lc.bytes);
    switch (lc.cmd) {
      case lcSegment64:
        if (lc.bytes.length >= 72) {
          final fileoff = bd.getUint64(40, Endian.little);
          final filesize = bd.getUint64(48, Endian.little);
          final nsects = bd.getUint32(64, Endian.little);
          if (fileoff > 0 && filesize > 0) {
            consider(fileoff, filesize);
          }
          // Inspect each section_64 (80 bytes each starting at offset 72).
          for (var s = 0; s < nsects; s++) {
            final sectOff = 72 + s * 80;
            if (sectOff + 80 <= lc.bytes.length) {
              final sSize = bd.getUint64(sectOff + 40, Endian.little);
              final sOffset = bd.getUint32(sectOff + 48, Endian.little);
              consider(sOffset, sSize);
            }
          }
        }
      case lcSymtab:
        if (lc.bytes.length >= 24) {
          consider(
            bd.getUint32(8, Endian.little),
            bd.getUint32(12, Endian.little) * 16,
          );
          consider(
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
          consider(
            bd.getUint32(8, Endian.little),
            bd.getUint32(12, Endian.little),
          );
        }
    }
  }
  return minOffset;
}

/// Patches a 64-bit Mach-O binary in memory and recomputes its embedded
/// `LC_CODE_SIGNATURE` SHA-256 page hashes if present.
Uint8List patchMachO(
  Uint8List inputBytes, {
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? installName,
  List<String> rpaths = const [],
}) {
  if (!isMachO64(inputBytes)) {
    throw const FormatException('Not a 64-bit little-endian Mach-O binary.');
  }
  final bdIn = ByteData.sublistView(inputBytes);
  final oldSizeofcmds = bdIn.getUint32(20, Endian.little);
  final originalCommands = parseLoadCommands(inputBytes);
  final maxLoadCommandEnd = _findFirstPayloadOffset(
    originalCommands,
    inputBytes.length,
  );

  final updatedCommands = <LoadCommand>[];
  var wroteBuildVersion = false;
  var wroteIdDylib = false;
  final existingRpaths = <String>{};
  LoadCommand? codeSigCommand;

  for (final lc in originalCommands) {
    // Strip legacy LC_VERSION_MIN_* commands when setting LC_BUILD_VERSION.
    if (platform != null &&
        (lc.cmd == lcVersionMinMacosx ||
            lc.cmd == lcVersionMinIphoneos ||
            lc.cmd == lcVersionMinTvos ||
            lc.cmd == lcVersionMinWatchos)) {
      continue;
    }

    if (lc.cmd == lcBuildVersion && platform != null && minOs != null) {
      if (!wroteBuildVersion) {
        updatedCommands.add(
          buildLcBuildVersion(
            platform: platform,
            minos: minOs,
            sdk: sdkVersion ?? minOs,
          ),
        );
        wroteBuildVersion = true;
      }
      continue;
    }

    if (lc.cmd == lcIdDylib && installName != null) {
      if (!wroteIdDylib) {
        int timestamp = 2;
        int currentVersion = 0x00010000;
        int compatibilityVersion = 0x00010000;
        if (lc.bytes.length >= 24) {
          final lcBd = ByteData.sublistView(lc.bytes);
          timestamp = lcBd.getUint32(12, Endian.little);
          currentVersion = lcBd.getUint32(16, Endian.little);
          compatibilityVersion = lcBd.getUint32(20, Endian.little);
        }
        updatedCommands.add(
          buildLcIdDylib(
            installName,
            timestamp: timestamp,
            currentVersion: currentVersion,
            compatibilityVersion: compatibilityVersion,
          ),
        );
        wroteIdDylib = true;
      }
      continue;
    }

    if (lc.cmd == lcRpath && lc.bytes.length >= 12) {
      final lcBd = ByteData.sublistView(lc.bytes);
      final pathOffset = lcBd.getUint32(8, Endian.little);
      existingRpaths.add(_readLcString(lc.bytes, pathOffset));
      updatedCommands.add(lc);
      continue;
    }

    // Hold LC_CODE_SIGNATURE so any newly added load commands are placed
    // before LC_CODE_SIGNATURE (matching ld64 / vtool conventions).
    if (lc.cmd == lcCodeSignature && codeSigCommand == null) {
      codeSigCommand = lc;
      continue;
    }

    updatedCommands.add(lc);
  }

  if (platform != null && minOs != null && !wroteBuildVersion) {
    updatedCommands.add(
      buildLcBuildVersion(
        platform: platform,
        minos: minOs,
        sdk: sdkVersion ?? minOs,
      ),
    );
  }

  if (installName != null && !wroteIdDylib) {
    updatedCommands.add(buildLcIdDylib(installName));
  }

  for (final rpath in rpaths) {
    if (existingRpaths.add(rpath)) {
      updatedCommands.add(buildLcRpath(rpath));
    }
  }

  if (codeSigCommand != null) {
    updatedCommands.add(codeSigCommand);
  }

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

/// Synthesizes a minimal valid 64-bit Mach-O `MH_DYLIB` or `MH_EXECUTE` stub binary.
Uint8List generateStubMachO({
  required String arch,
  required int platform,
  required int minOs,
  required int sdkVersion,
  required String installName,
  int fileType = mhDylib,
}) {
  final int cputype;
  final int cpusubtype;
  switch (arch) {
    case 'arm64':
      cputype = cpuTypeArm64;
      cpusubtype = cpuSubtypeArm64All;
    case 'x86_64':
      cputype = cpuTypeX86_64;
      cpusubtype = cpuSubtypeX86_64All;
    default:
      throw ArgumentError.value(arch, 'arch', 'Expected "arm64" or "x86_64".');
  }

  // Page size: 16 KB (0x4000) for arm64, 4 KB (0x1000) for x86_64.
  final pageSize = arch == 'arm64' ? 0x4000 : 0x1000;

  // LC_SEGMENT_64 (__TEXT) - 72 bytes (0 sections).
  final textSeg = Uint8List(72);
  final textBd = ByteData.sublistView(textSeg);
  textBd.setUint32(0, lcSegment64, Endian.little);
  textBd.setUint32(4, 72, Endian.little);
  final segNameBytes = ascii.encode('__TEXT');
  textSeg.setRange(8, 8 + segNameBytes.length, segNameBytes);
  textBd.setUint64(24, 0, Endian.little); // vmaddr
  textBd.setUint64(32, pageSize, Endian.little); // vmsize
  textBd.setUint64(40, 0, Endian.little); // fileoff
  textBd.setUint64(48, pageSize, Endian.little); // filesize
  textBd.setUint32(56, 5, Endian.little); // maxprot = R|X
  textBd.setUint32(60, 5, Endian.little); // initprot = R|X
  textBd.setUint32(64, 0, Endian.little); // nsects = 0
  textBd.setUint32(68, 0, Endian.little); // flags = 0

  final buildVersion = buildLcBuildVersion(
    platform: platform,
    minos: minOs,
    sdk: sdkVersion,
  );

  final commands = <LoadCommand>[
    LoadCommand(lcSegment64, textSeg),
    if (fileType == mhDylib && installName.isNotEmpty)
      buildLcIdDylib(installName),
    buildVersion,
    if (fileType == mhExecute)
      buildLcRpath(
        platform == platformMacos
            ? '@executable_path/../Frameworks'
            : '@executable_path/Frameworks',
      ),
  ];

  var sizeofcmds = 0;
  for (final lc in commands) {
    sizeofcmds += lc.cmdsize;
  }

  final out = Uint8List(pageSize);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, mhMagic64, Endian.little);
  bd.setUint32(4, cputype, Endian.little);
  bd.setUint32(8, cpusubtype, Endian.little);
  bd.setUint32(12, fileType, Endian.little);
  bd.setUint32(16, commands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(
    24,
    fileType == mhExecute ? mhPie : mhNoReexportedDylibs,
    Endian.little,
  );
  bd.setUint32(28, 0, Endian.little);

  var offset = mhHeaderSize64;
  for (final lc in commands) {
    out.setRange(offset, offset + lc.cmdsize, lc.bytes);
    offset += lc.cmdsize;
  }

  return out;
}

// Pure-Dart FIPS 180-4 SHA-256 implementation.
const List<int> _sha256K = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

int _rotr32(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xffffffff;

/// Computes the 32-byte SHA-256 digest of [data].
Uint8List sha256(Uint8List data) {
  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final bitLength = data.length * 8;
  // Message + 0x80 + zero padding + 8-byte big-endian bit length.
  final paddedLength = ((data.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(paddedLength);
  padded.setRange(0, data.length, data);
  padded[data.length] = 0x80;
  final paddedBd = ByteData.sublistView(padded);
  paddedBd.setUint64(paddedLength - 8, bitLength, Endian.big);

  final w = Uint32List(64);

  for (var chunkOffset = 0; chunkOffset < paddedLength; chunkOffset += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = paddedBd.getUint32(chunkOffset + i * 4, Endian.big);
    }
    for (var i = 16; i < 64; i++) {
      final w15 = w[i - 15];
      final s0 = _rotr32(w15, 7) ^ _rotr32(w15, 18) ^ (w15 >>> 3);
      final w2 = w[i - 2];
      final s1 = _rotr32(w2, 17) ^ _rotr32(w2, 19) ^ (w2 >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (h + s1 + ch + _sha256K[i] + w[i]) & 0xffffffff;
      final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
    h5 = (h5 + f) & 0xffffffff;
    h6 = (h6 + g) & 0xffffffff;
    h7 = (h7 + h) & 0xffffffff;
  }

  final digest = Uint8List(32);
  final digestBd = ByteData.sublistView(digest);
  digestBd.setUint32(0, h0, Endian.big);
  digestBd.setUint32(4, h1, Endian.big);
  digestBd.setUint32(8, h2, Endian.big);
  digestBd.setUint32(12, h3, Endian.big);
  digestBd.setUint32(16, h4, Endian.big);
  digestBd.setUint32(20, h5, Endian.big);
  digestBd.setUint32(24, h6, Endian.big);
  digestBd.setUint32(28, h7, Endian.big);
  return digest;
}
