/// Verifies the Android APK produced by flutter_android_app has the
/// expected structure: classes.dex, native libs, flutter_assets, and manifest.
///
/// APK is a zip file — we extract it to a temp dir and verify contents.
import 'dart:io';
import 'dart:typed_data';

/// Classes the Flutter engine's Android embedding requires at app runtime,
/// keyed by the artifact that provides them. One representative class per
/// artifact — if the class is not *defined* in the APK's dex files, that
/// runtime dependency is missing and the app will throw NoClassDefFoundError
/// on the corresponding engine code path.
///
/// The direct engine dependencies mirror the dependency list of Flutter's
/// official io.flutter:flutter_embedding_* Maven POM (what every Gradle-built
/// Flutter app ships). The profileinstaller chain arrives transitively via
/// lifecycle-runtime and runs in every app ~6s after launch via an
/// androidx.startup initializer, so its own closure must also be complete —
/// including the real com.google.guava:listenablefuture jar (guava's empty
/// placeholder version would leave AbstractResolvableFuture's superinterface
/// undefined).
const _requiredDexClasses = <String, String>{
  'androidx.core:core': 'Landroidx/core/content/ContextCompat;',
  'androidx.exifinterface:exifinterface':
      'Landroidx/exifinterface/media/ExifInterface;',
  'androidx.fragment:fragment': 'Landroidx/fragment/app/Fragment;',
  'androidx.lifecycle:lifecycle-common': 'Landroidx/lifecycle/Lifecycle;',
  'androidx.lifecycle:lifecycle-runtime':
      'Landroidx/lifecycle/LifecycleRegistry;',
  'androidx.tracing:tracing': 'Landroidx/tracing/Trace;',
  'androidx.window:window': 'Landroidx/window/layout/WindowInfoTracker;',
  'androidx.window:window-java':
      'Landroidx/window/java/layout/WindowInfoTrackerCallbackAdapter;',
  'com.getkeepsafe.relinker:relinker': 'Lcom/getkeepsafe/relinker/ReLinker;',
  'androidx.profileinstaller:profileinstaller (via lifecycle-runtime)':
      'Landroidx/profileinstaller/ProfileInstaller;',
  'androidx.concurrent:concurrent-futures (via profileinstaller)':
      'Landroidx/concurrent/futures/AbstractResolvableFuture;',
  'com.google.guava:listenablefuture (AbstractResolvableFuture supertype)':
      'Lcom/google/common/util/concurrent/ListenableFuture;',
};

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final apkPath = '$testSrcDir/$testWorkspace/app.apk';
  if (!File(apkPath).existsSync()) {
    stderr.writeln('APK not found at $apkPath');
    exit(1);
  }

  // Extract to temp directory (APK is a zip).
  final tmpDir = Directory.systemTemp.createTempSync('android_apk_test');
  try {
    final result =
        Process.runSync('unzip', ['-q', apkPath, '-d', tmpDir.path]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to extract APK: ${result.stderr}');
      exit(1);
    }

    var failed = false;

    void check(String description, String path) {
      final exists =
          FileSystemEntity.isDirectorySync(path) || File(path).existsSync();
      if (!exists) {
        stderr.writeln('FAIL: $description — not found: $path');
        failed = true;
      } else {
        print('OK: $description');
      }
    }

    // --- Structural checks ---

    check(
      'classes.dex exists',
      '${tmpDir.path}/classes.dex',
    );
    check(
      'libapp.so exists (arm64-v8a)',
      '${tmpDir.path}/lib/arm64-v8a/libapp.so',
    );
    check(
      'libflutter.so exists (arm64-v8a)',
      '${tmpDir.path}/lib/arm64-v8a/libflutter.so',
    );
    check(
      'libadd.so exists (arm64-v8a, from native_deps)',
      '${tmpDir.path}/lib/arm64-v8a/libadd.so',
    );
    check(
      'flutter_assets directory exists',
      '${tmpDir.path}/assets/flutter_assets',
    );
    check(
      'AssetManifest.bin exists',
      '${tmpDir.path}/assets/flutter_assets/AssetManifest.bin',
    );
    check(
      'FontManifest.json exists',
      '${tmpDir.path}/assets/flutter_assets/FontManifest.json',
    );
    check(
      'AndroidManifest.xml exists (binary format)',
      '${tmpDir.path}/AndroidManifest.xml',
    );

    // --- Binary format checks ---
    // Every native library in the APK must be an ELF shared object whose
    // machine type matches its ABI directory. Android's linker cannot load
    // anything else (a host-format Mach-O libapp.so crashes at startup with
    // "VM snapshot invalid"), so any other format is a hard failure.
    final libDir = Directory('${tmpDir.path}/lib');
    var checkedLibs = 0;
    if (libDir.existsSync()) {
      for (final abiDir in libDir.listSync().whereType<Directory>()) {
        final abi = abiDir.path.split('/').last;
        final expectedMachine = _elfMachineForAbi[abi];
        if (expectedMachine == null) {
          stderr.writeln('FAIL: unexpected ABI directory lib/$abi');
          failed = true;
          continue;
        }
        for (final lib in abiDir.listSync().whereType<File>()) {
          checkedLibs++;
          final name = 'lib/$abi/${lib.path.split('/').last}';
          final error = _validateElf(lib, expectedMachine);
          if (error != null) {
            stderr.writeln('FAIL: $name — $error');
            failed = true;
          } else {
            print('OK: $name is ELF (machine 0x'
                '${expectedMachine.toRadixString(16)}, correct for $abi)');
          }
        }
      }
    }
    if (checkedLibs == 0) {
      stderr.writeln('FAIL: no native libraries found under lib/');
      failed = true;
    }

    // --- Engine runtime class checks ---
    final definedClasses = <String>{};
    for (final dex in Directory(tmpDir.path)
        .listSync()
        .whereType<File>()
        .where((f) => RegExp(r'/classes\d*\.dex$').hasMatch(f.path))) {
      definedClasses.addAll(_definedClassDescriptors(dex));
    }
    if (definedClasses.isEmpty) {
      stderr.writeln('FAIL: no class definitions parsed from dex files');
      failed = true;
    }
    _requiredDexClasses.forEach((artifact, descriptor) {
      if (definedClasses.contains(descriptor)) {
        print('OK: $descriptor defined in dex ($artifact)');
      } else {
        stderr.writeln('FAIL: $descriptor not defined in any dex — '
            'runtime dependency $artifact is missing from the APK');
        failed = true;
      }
    });

    if (failed) {
      stderr.writeln('\nAPK contents:');
      _listRecursive(tmpDir.path, '');
      exit(1);
    }

    print('\nAll Android APK verification checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

/// ELF e_machine values by Android ABI directory name.
const _elfMachineForAbi = <String, int>{
  'arm64-v8a': 0xb7, // EM_AARCH64
  'x86_64': 0x3e, // EM_X86_64
};

/// Returns an error message if [file] is not an ELF shared object with the
/// given e_machine, or null if it is valid.
String? _validateElf(File file, int expectedMachine) {
  final bytes = file.readAsBytesSync();
  if (bytes.length < 20) {
    return 'file too small to be an ELF binary (${bytes.length} bytes)';
  }
  final isElf =
      bytes[0] == 0x7f && bytes[1] == 0x45 && bytes[2] == 0x4c && bytes[3] == 0x46;
  if (!isElf) {
    final isMachO =
        bytes[0] == 0xcf && bytes[1] == 0xfa && bytes[2] == 0xed && bytes[3] == 0xfe;
    if (isMachO) {
      return 'Mach-O binary (host format) — the build was not transitioned '
          'to an Android platform';
    }
    return 'not an ELF binary (magic: ${bytes.sublist(0, 4)})';
  }
  // e_machine: 2 bytes little-endian at offset 18.
  final machine = bytes[18] | (bytes[19] << 8);
  if (machine != expectedMachine) {
    return 'ELF machine 0x${machine.toRadixString(16)} does not match '
        'expected 0x${expectedMachine.toRadixString(16)}';
  }
  return null;
}

/// Parses a dex file and returns the descriptors of all classes it defines
/// (class_defs entries — not merely referenced types).
///
/// Dex layout (all offsets little-endian, per the Dalvik executable format):
/// the header locates the string_ids, type_ids, and class_defs tables. Each
/// class_def_item begins with a u4 index into type_ids; each type_id_item is
/// a u4 index into string_ids; each string_id_item is a u4 offset to string
/// data (uleb128 UTF-16 length followed by MUTF-8 bytes). Class descriptors
/// are ASCII, so MUTF-8 decoding reduces to reading until the NUL terminator.
Set<String> _definedClassDescriptors(File dexFile) {
  final bytes = dexFile.readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  const dexMagic = [0x64, 0x65, 0x78, 0x0a]; // "dex\n"
  for (var i = 0; i < dexMagic.length; i++) {
    if (bytes[i] != dexMagic[i]) {
      throw FormatException('${dexFile.path} is not a dex file');
    }
  }
  final stringIdsOff = data.getUint32(0x3c, Endian.little);
  final typeIdsOff = data.getUint32(0x44, Endian.little);
  final classDefsSize = data.getUint32(0x60, Endian.little);
  final classDefsOff = data.getUint32(0x64, Endian.little);

  String stringAt(int stringIdx) {
    var off = data.getUint32(stringIdsOff + 4 * stringIdx, Endian.little);
    // Skip the uleb128 UTF-16 length prefix.
    while (bytes[off] & 0x80 != 0) {
      off++;
    }
    off++;
    final end = bytes.indexOf(0, off);
    return String.fromCharCodes(bytes.sublist(off, end));
  }

  final descriptors = <String>{};
  for (var i = 0; i < classDefsSize; i++) {
    // class_def_item is 8 u4 fields; the first is the type_ids index.
    final typeIdx =
        data.getUint32(classDefsOff + 32 * i, Endian.little);
    final descriptorIdx =
        data.getUint32(typeIdsOff + 4 * typeIdx, Endian.little);
    descriptors.add(stringAt(descriptorIdx));
  }
  return descriptors;
}

void _listRecursive(String path, String indent) {
  final dir = Directory(path);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync()) {
    final name = entity.path.split('/').last;
    stderr.writeln('$indent$name');
    if (entity is Directory) {
      _listRecursive(entity.path, '$indent  ');
    }
  }
}
