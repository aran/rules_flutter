/// Reading the headers of ELF shared objects: those an Android APK ships, and
/// those a Linux bundle carries.
library;

import 'dart:io';
import 'dart:typed_data';

/// The ELF `e_machine` values of Android ABI directories under `lib/`.
const elfMachineForAbi = <String, int>{
  'arm64-v8a': 0xb7, // EM_AARCH64
  'x86_64': 0x3e, // EM_X86_64
  'armeabi-v7a': 0x28, // EM_ARM
};

/// The bytes of an ELF file, and what its headers say.
///
/// A malformed file is reported as a return value (a message, or no value) and
/// not as a `RangeError`: a header pointing outside the file is a fact about
/// the input.
class ElfImage {
  /// Reads the file at [path].
  ElfImage.fromFile(File file) : this(file.readAsBytesSync());

  /// Wraps [bytes].
  ElfImage(this.bytes) : _data = ByteData.sublistView(bytes);

  /// The file's contents.
  final Uint8List bytes;

  final ByteData _data;

  /// An error message if this is not an ELF file whose `e_machine` is
  /// [expectedMachine], or null if it is.
  ///
  /// A Mach-O file is named as such: it is what a library built for the host
  /// and not for Android looks like.
  String? validate(int expectedMachine) {
    if (bytes.length < 20) {
      return 'file too small to be an ELF binary (${bytes.length} bytes)';
    }
    final isElf =
        bytes[0] == 0x7f &&
        bytes[1] == 0x45 &&
        bytes[2] == 0x4c &&
        bytes[3] == 0x46;
    if (!isElf) {
      final isMachO =
          bytes[0] == 0xcf &&
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

  /// The smallest `p_align` across the `PT_LOAD` segments, or an error
  /// message if the program headers cannot be read.
  ///
  /// This is what a 16KB-page device checks when it maps a library. A `.so`
  /// linked with `-Wl,-z,max-page-size=4096` loads on a 4KB device and is
  /// refused on a 16KB one, and nothing says so at build time: the APK builds,
  /// installs, and the app dies on launch.
  (int?, String?) minLoadAlignment() {
    // e_ident[EI_CLASS]: 1 = ELF32, 2 = ELF64. Android ships both —
    // armeabi-v7a and x86 are 32-bit.
    final is64 = bytes.length > 4 && bytes[4] == 2;
    const ptLoad = 1;
    final headerSize = is64 ? 64 : 52;
    if (bytes.length < headerSize) {
      return (
        null,
        'file is shorter than an ELF header (${bytes.length} bytes)',
      );
    }
    final phoff = is64
        ? _data.getUint64(0x20, Endian.little)
        : _data.getUint32(0x1c, Endian.little);
    final phentsize = _data.getUint16(is64 ? 0x36 : 0x2a, Endian.little);
    final phnum = _data.getUint16(is64 ? 0x38 : 0x2c, Endian.little);
    final entrySize = is64 ? 0x38 : 0x20;
    if (phentsize < entrySize) {
      return (
        null,
        'ELF program header entries are $phentsize bytes, too '
            'small to hold a p_align',
      );
    }
    if (phoff + phnum * phentsize > bytes.length) {
      return (null, 'ELF program headers run past the end of the file');
    }
    var min = -1;
    for (var i = 0; i < phnum; i++) {
      final off = phoff + i * phentsize;
      if (_data.getUint32(off, Endian.little) != ptLoad) continue;
      final align = is64
          ? _data.getUint64(off + 0x30, Endian.little)
          : _data.getUint32(off + 0x1c, Endian.little);
      if (min < 0 || align < min) min = align;
    }
    if (min < 0) return (null, 'no PT_LOAD segments to check alignment on');
    return (min, null);
  }

  /// The section names of a little-endian ELF file, or none if it has no
  /// section headers.
  List<String> sectionNames() => [for (final s in _sections()) s.name];

  /// What a library stripped as a Gradle build strips it
  /// (`llvm-strip --strip-unneeded`) would not have, or null if it has none
  /// of it: a symbol table (`.symtab`) or debug info (`.debug_*`). Its
  /// dynamic symbol table, which the loader reads, it keeps.
  String? unstrippedSections() {
    final kept = [
      for (final name in sectionNames())
        if (name == '.symtab' || name.startsWith('.debug_')) name,
    ];
    return kept.isEmpty ? null : 'it has ${kept.join(', ')}';
  }

  /// The API level the file was built against, from its `.note.android.ident`
  /// section (what clang writes for a target such as
  /// `aarch64-linux-android24`), or null if the file has no such note.
  ///
  /// A library that calls a libc function newer than its device's API level
  /// fails to load there, so this is the level the library demands of one.
  int? androidApiLevel() {
    for (final section in _sections()) {
      if (section.name != '.note.android.ident') continue;
      // A note: namesz, descsz, type, then the name and the descriptor, each
      // padded to 4 bytes. The descriptor starts with the API level.
      if (section.size < 12 || section.offset + section.size > bytes.length) {
        return null;
      }
      final namesz = _data.getUint32(section.offset, Endian.little);
      final descOffset = section.offset + 12 + ((namesz + 3) & ~3);
      if (descOffset + 4 > section.offset + section.size) return null;
      return _data.getUint32(descOffset, Endian.little);
    }
    return null;
  }

  /// The libraries a little-endian ELF file links (its `DT_NEEDED`, in
  /// order) and its `DT_RUNPATH`, from its `.dynamic` and `.dynstr`
  /// sections; null when it has neither.
  ({List<String> needed, String? runpath})? dynamicNames() {
    final sections = {for (final s in _sections()) s.name: s};
    final dynamic = sections['.dynamic'];
    final strings = sections['.dynstr'];
    if (dynamic == null || strings == null) return null;
    final is64 = bytes[4] == 2;
    final entrySize = is64 ? 16 : 8;
    int word(int offset) => is64
        ? _data.getUint64(offset, Endian.little)
        : _data.getUint32(offset, Endian.little);
    String string(int offset) {
      final start = strings.offset + offset;
      var end = start;
      while (bytes[end] != 0) {
        end++;
      }
      return String.fromCharCodes(bytes, start, end);
    }

    final needed = <String>[];
    String? runpath;
    for (
      var at = dynamic.offset;
      at + entrySize <= dynamic.offset + dynamic.size;
      at += entrySize
    ) {
      final tag = word(at);
      final value = word(at + entrySize ~/ 2);
      if (tag == 0) break; // DT_NULL
      if (tag == 1) needed.add(string(value)); // DT_NEEDED
      if (tag == 29) runpath = string(value); // DT_RUNPATH
    }
    return (needed: needed, runpath: runpath);
  }

  List<({String name, int offset, int size})> _sections() {
    // ELF32 (armeabi-v7a) and ELF64 differ in the width of the offsets and in
    // where the header fields sit.
    final is64 = bytes.length > 4 && bytes[4] == 2;
    final headerSize = is64 ? 0x40 : 0x34;
    if (bytes.length < headerSize) return const [];
    int word(int offset) => is64
        ? _data.getUint64(offset, Endian.little)
        : _data.getUint32(offset, Endian.little);
    final shoff = word(is64 ? 0x28 : 0x20);
    final shentsize = _data.getUint16(is64 ? 0x3a : 0x2e, Endian.little);
    final shnum = _data.getUint16(is64 ? 0x3c : 0x30, Endian.little);
    final shstrndx = _data.getUint16(is64 ? 0x3e : 0x32, Endian.little);
    if (shoff == 0 || shnum == 0) return const [];
    final offsetField = is64 ? 0x18 : 0x10;
    final sizeField = is64 ? 0x20 : 0x14;
    final names = word(shoff + shstrndx * shentsize + offsetField);
    String nameAt(int start) {
      var end = start;
      while (bytes[end] != 0) {
        end++;
      }
      return String.fromCharCodes(bytes, start, end);
    }

    return [
      for (var i = 0; i < shnum; i++)
        (
          name: nameAt(
            names + _data.getUint32(shoff + i * shentsize, Endian.little),
          ),
          offset: word(shoff + i * shentsize + offsetField),
          size: word(shoff + i * shentsize + sizeField),
        ),
    ];
  }
}
