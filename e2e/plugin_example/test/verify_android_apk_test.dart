/// Verifies the plugin_example Android APK packages every plugin's native
/// pieces — most importantly `libdartjni.so`, the C support library of
/// `package:jni` that jnigen-based plugins (path_provider_android >= 2.3)
/// load via `System.loadLibrary("dartjni")` in a static initializer. If the
/// library is missing, plugin registration aborts wholesale at startup with
/// an UnsatisfiedLinkError.
///
/// APK is a zip file — we extract it to a temp dir and verify contents.
import 'dart:io';
import 'dart:typed_data';

/// Classes the plugin closure requires at runtime, keyed by what ships them.
/// One representative class per source — if the class is not *defined* in
/// the APK's dex files, that piece is missing and the corresponding plugin
/// code path throws NoClassDefFoundError.
///
/// All listed classes are covered by keep rules (the registrant references
/// the plugin classes; package:jni's consumer-rules.pro keeps
/// com.github.dart_lang.jni.**), so their descriptors survive R8 renaming.
/// Dependencies without keep rules (e.g. kotlinx-coroutines) are
/// obfuscated by R8 and can't be asserted by name — R8 already fails the
/// build if a class referenced from a kept class is absent.
const _requiredDexClasses = <String, String>{
  'package:jni android/src (plugin class)':
      'Lcom/github/dart_lang/jni/JniPlugin;',
  'package:jni java/src (Gradle srcDirs — shared JNI support classes)':
      'Lcom/github/dart_lang/jni/PortContinuation;',
  'package:jni java/src (proxy support)':
      'Lcom/github/dart_lang/jni/PortProxyBuilder;',
  'package:jni_flutter android/src (plugin class)':
      'Lcom/github/dart_lang/jni_flutter/JniFlutterPlugin;',
};

/// Native libraries every plugin_example APK must carry for arm64-v8a.
const _requiredNativeLibs = <String, String>{
  'AOT-compiled Dart code': 'lib/arm64-v8a/libapp.so',
  'Flutter engine': 'lib/arm64-v8a/libflutter.so',
  'package:jni C support library (System.loadLibrary("dartjni"))':
      'lib/arm64-v8a/libdartjni.so',
};

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final apkPath = '$testSrcDir/$testWorkspace/plugin_android.apk';
  if (!File(apkPath).existsSync()) {
    stderr.writeln('APK not found at $apkPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('plugin_apk_test');
  try {
    final result =
        Process.runSync('unzip', ['-q', apkPath, '-d', tmpDir.path]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to extract APK: ${result.stderr}');
      exit(1);
    }

    var failed = false;

    // --- Native library presence ---
    _requiredNativeLibs.forEach((description, path) {
      if (File('${tmpDir.path}/$path').existsSync()) {
        print('OK: $path ($description)');
      } else {
        stderr.writeln('FAIL: $path not found — $description');
        failed = true;
      }
    });

    // --- Binary format checks ---
    // Every native library in the APK must be an ELF shared object whose
    // machine type matches its ABI directory; Android's linker cannot load
    // anything else.
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

    // --- Plugin runtime class checks ---
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
    _requiredDexClasses.forEach((source, descriptor) {
      if (definedClasses.contains(descriptor)) {
        print('OK: $descriptor defined in dex ($source)');
      } else {
        stderr.writeln('FAIL: $descriptor not defined in any dex — '
            '$source is missing from the APK');
        failed = true;
      }
    });

    // --- Plugin resource + manifest merge checks (record_android) ---
    // record_android ships android/src/main/res/drawable/ic_mic.xml and a
    // library manifest declaring RECORD_AUDIO. Both must survive into the
    // APK: the resource entry name lands in resources.arsc's key string
    // pool, and the permission lands in the merged binary
    // AndroidManifest.xml (strings there are UTF-16 in binary XML).
    final arsc = File('${tmpDir.path}/resources.arsc');
    if (_fileContainsString(arsc, 'ic_mic')) {
      print('OK: resources.arsc defines ic_mic '
          "(record_android's drawable merged)");
    } else {
      stderr.writeln("FAIL: ic_mic not found in resources.arsc — "
          "record_android's res/ was dropped");
      failed = true;
    }
    final mergedManifest = File('${tmpDir.path}/AndroidManifest.xml');
    if (_fileContainsString(
        mergedManifest, 'android.permission.RECORD_AUDIO')) {
      print('OK: merged AndroidManifest.xml declares RECORD_AUDIO '
          "(record_android's library manifest merged)");
    } else {
      stderr.writeln('FAIL: RECORD_AUDIO not found in the merged '
          "AndroidManifest.xml — record_android's manifest did not merge");
      failed = true;
    }

    if (failed) {
      stderr.writeln('\nAPK contents:');
      _listRecursive(tmpDir.path, '');
      exit(1);
    }

    print('\nAll plugin_example APK verification checks passed.');
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
  final isElf = bytes[0] == 0x7f &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4c &&
      bytes[3] == 0x46;
  if (!isElf) {
    final isMachO = bytes[0] == 0xcf &&
        bytes[1] == 0xfa &&
        bytes[2] == 0xed &&
        bytes[3] == 0xfe;
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
    final typeIdx = data.getUint32(classDefsOff + 32 * i, Endian.little);
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

/// Whether [file] contains [needle] encoded as either UTF-8 or UTF-16LE.
/// Binary Android artifacts mix both: aapt2 emits UTF-8 string pools in
/// resources.arsc but UTF-16 in binary XML.
bool _fileContainsString(File file, String needle) {
  if (!file.existsSync()) return false;
  final bytes = file.readAsBytesSync();
  final utf8Needle = needle.codeUnits;
  final utf16Needle = <int>[];
  for (final unit in needle.codeUnits) {
    utf16Needle
      ..add(unit & 0xff)
      ..add(unit >> 8);
  }
  return _containsSublist(bytes, utf8Needle) ||
      _containsSublist(bytes, utf16Needle);
}

bool _containsSublist(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
