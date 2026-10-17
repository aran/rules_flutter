/// Android application bundling tool for `flutter_android_bundle`.
///
/// Replaces shell actions with hermetic Dart commands:
///   - `native-libs-jar`: Validates that every native library is an ELF binary
///     matching the target Android ABI's `e_machine`, then packages all
///     `lib/<abi>/<basename>=<src>` entries into the output `.jar` via `zipper`.
///   - `empty-jar`: Writes a minimal valid 22-byte empty ZIP (End of Central
///     Directory record) for debug/JIT builds with no native libraries.
///   - `debug-assets`: Copies the `flutter_assets` tree (dereferencing
///     symlinks), `kernel_blob.bin`, and optional `vm_snapshot_data` /
///     `isolate_snapshot_data` into the debug assets directory.
library;

import 'dart:io';
import 'dart:typed_data';

/// Minimal valid 22-byte ZIP file (End of Central Directory record with zero
/// entries), identical to the output of `zip` on an empty archive.
const List<int> emptyJarBytes = <int>[
  0x50,
  0x4b,
  0x05,
  0x06,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
];

/// Validates that [bytes] (at least the first 20 bytes of [path]) begins with
/// an ELF header whose little-endian `e_machine` at offset 18 matches
/// [wantMachine].
void validateAndroidElf(
  List<int> bytes, {
  required String path,
  required int wantMachine,
  required String abi,
}) {
  if (bytes.length < 20 ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4c ||
      bytes[3] != 0x46) {
    throw FormatException(
      'ERROR: $path is not an ELF binary. Android ($abi) cannot load it.',
    );
  }
  final machine = bytes[18] | (bytes[19] << 8);
  if (machine != wantMachine) {
    throw FormatException(
      'ERROR: $path has ELF machine $machine; $abi requires $wantMachine.',
    );
  }
}

/// Writes the 22-byte empty ZIP/JAR to [outputPath].
void writeEmptyJar(String outputPath) {
  final file = File(outputPath);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(emptyJarBytes, flush: true);
}

/// Validates each `lib/<abi>/<name>=<src>` entry in [entries] as an ELF shared
/// object for [abi] ([wantMachine]) and packages them into [outputPath] using
/// [zipperPath].
Future<void> packageNativeLibsJar({
  required String outputPath,
  required String abi,
  required int wantMachine,
  required String zipperPath,
  required List<String> entries,
}) async {
  if (entries.isEmpty) {
    writeEmptyJar(outputPath);
    return;
  }

  for (final spec in entries) {
    final eq = spec.indexOf('=');
    if (eq <= 0 || eq == spec.length - 1) {
      throw ArgumentError.value(
        spec,
        'entries',
        'expected <jar_entry>=<source_path>',
      );
    }
    final srcPath = spec.substring(eq + 1);
    final raf = File(srcPath).openSync();
    final Uint8List header;
    try {
      header = raf.readSync(20);
    } finally {
      raf.closeSync();
    }
    validateAndroidElf(
      header,
      path: srcPath,
      wantMachine: wantMachine,
      abi: abi,
    );
  }

  File(outputPath).parent.createSync(recursive: true);
  final zipArgs = <String>['cC', outputPath, ...entries];
  final result = await Process.run(zipperPath, zipArgs);
  if (result.exitCode != 0) {
    throw ProcessException(
      zipperPath,
      zipArgs,
      '${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }
}

/// Copies [assetsDir] (dereferencing symlinks) into [outputDir] and adds
/// `kernel_blob.bin` plus optional `vm_snapshot_data` and
/// `isolate_snapshot_data`.
void assembleDebugAssets({
  required String assetsDir,
  required String outputDir,
  required String kernelPath,
  String? vmSnapshotPath,
  String? isolateSnapshotPath,
}) {
  final outDir = Directory(outputDir)..createSync(recursive: true);
  _copyDirectoryDereferencingLinks(Directory(assetsDir), outDir);
  File(kernelPath).copySync('$outputDir/kernel_blob.bin');
  if (vmSnapshotPath != null && vmSnapshotPath.isNotEmpty) {
    File(vmSnapshotPath).copySync('$outputDir/vm_snapshot_data');
  }
  if (isolateSnapshotPath != null && isolateSnapshotPath.isNotEmpty) {
    File(isolateSnapshotPath).copySync('$outputDir/isolate_snapshot_data');
  }
}

void _copyDirectoryDereferencingLinks(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  final entities = src.listSync(recursive: false, followLinks: true)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entities) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final dstPath = '${dst.path}/$name';
    if (entity is File) {
      entity.copySync(dstPath);
    } else if (entity is Directory) {
      _copyDirectoryDereferencingLinks(entity, Directory(dstPath));
    } else if (entity is Link) {
      final resolved = entity.resolveSymbolicLinksSync();
      if (FileSystemEntity.isDirectorySync(resolved)) {
        _copyDirectoryDereferencingLinks(
          Directory(resolved),
          Directory(dstPath),
        );
      } else {
        File(resolved).copySync(dstPath);
      }
    }
  }
}

/// Dispatches the CLI arguments for `android_bundle.dart`.
Future<void> runAndroidBundle(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError(
      'Expected subcommand: "native-libs-jar", "empty-jar", or "debug-assets".',
    );
  }
  final subcommand = args.first;
  final rest = args.sublist(1);
  switch (subcommand) {
    case 'native-libs-jar':
      await _runNativeLibsJar(rest);
    case 'empty-jar':
      _runEmptyJar(rest);
    case 'debug-assets':
      _runDebugAssets(rest);
    default:
      throw ArgumentError('Unknown subcommand: $subcommand');
  }
}

Future<void> _runNativeLibsJar(List<String> args) async {
  String? output;
  String? abi;
  int? machine;
  String? zipper;
  final entries = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--output':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --output');
        }
        output = args[++i];
      case '--abi':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --abi');
        }
        abi = args[++i];
      case '--machine':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --machine');
        }
        machine = int.parse(args[++i]);
      case '--zipper':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --zipper');
        }
        zipper = args[++i];
      default:
        if (arg.startsWith('--')) {
          throw ArgumentError('Unknown option for native-libs-jar: $arg');
        }
        entries.add(arg);
    }
  }

  if (output == null || abi == null || machine == null || zipper == null) {
    throw ArgumentError(
      'Usage: android_bundle.dart native-libs-jar --output <jar> --abi <abi> '
      '--machine <machine> --zipper <zipper> [<entry=src>...]',
    );
  }

  await packageNativeLibsJar(
    outputPath: output,
    abi: abi,
    wantMachine: machine,
    zipperPath: zipper,
    entries: entries,
  );
}

void _runEmptyJar(List<String> args) {
  String? output;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--output') {
      if (i + 1 >= args.length) {
        throw ArgumentError('Missing value for --output');
      }
      output = args[++i];
    } else {
      throw ArgumentError('Unknown option for empty-jar: $arg');
    }
  }
  if (output == null) {
    throw ArgumentError('Usage: android_bundle.dart empty-jar --output <jar>');
  }
  writeEmptyJar(output);
}

void _runDebugAssets(List<String> args) {
  String? assetsDir;
  String? outputDir;
  String? kernel;
  String? vmSnapshot;
  String? isolateSnapshot;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (i + 1 >= args.length) {
      throw ArgumentError('Missing value for $arg');
    }
    switch (arg) {
      case '--assets-dir':
        assetsDir = args[++i];
      case '--output-dir':
        outputDir = args[++i];
      case '--kernel':
        kernel = args[++i];
      case '--vm-snapshot':
        vmSnapshot = args[++i];
      case '--isolate-snapshot':
        isolateSnapshot = args[++i];
      default:
        throw ArgumentError('Unknown option for debug-assets: $arg');
    }
  }

  if (assetsDir == null || outputDir == null || kernel == null) {
    throw ArgumentError(
      'Usage: android_bundle.dart debug-assets --assets-dir <dir> '
      '--output-dir <dir> --kernel <file> '
      '[--vm-snapshot <file>] [--isolate-snapshot <file>]',
    );
  }

  assembleDebugAssets(
    assetsDir: assetsDir,
    outputDir: outputDir,
    kernelPath: kernel,
    vmSnapshotPath: vmSnapshot,
    isolateSnapshotPath: isolateSnapshot,
  );
}

Future<void> main(List<String> args) async {
  try {
    await runAndroidBundle(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  } on ArgumentError catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}
