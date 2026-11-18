/// Minimal ELF shared libraries for tests: the headers, `.dynstr`, `.dynsym`
/// and `.dynamic` a loader reads for the names a library links and where it
/// looks for them, and nothing else.
library;

import 'dart:typed_data';

/// An ELF shared library (little-endian, 64-bit unless [is64] is false) that
/// links [needed], is named [soname] and has [runpath] and [rpath] when
/// given. Each of [symbols] is a dynamic symbol of that name. With
/// [symbolInRunpath], one more symbol is named by the tail of [runpath] from
/// that index, as a linker that merges string tails stores it.
Uint8List elfLibrary({
  List<String> needed = const [],
  String? soname,
  String? runpath,
  String? rpath,
  List<String> symbols = const [],
  int? symbolInRunpath,
  bool is64 = true,
}) {
  final strings = BytesBuilder()..addByte(0);
  int add(String s) {
    final at = strings.length;
    strings
      ..add(s.codeUnits)
      ..addByte(0);
    return at;
  }

  final dynamic = <(int, int)>[];
  for (final name in needed) {
    dynamic.add((1, add(name)));
  }
  if (soname != null) dynamic.add((14, add(soname)));
  int? runpathAt;
  if (runpath != null) {
    runpathAt = add(runpath);
    dynamic.add((29, runpathAt));
  }
  if (rpath != null) dynamic.add((15, add(rpath)));
  final symbolNames = [
    0,
    for (final s in symbols) add(s),
    if (symbolInRunpath != null) runpathAt! + symbolInRunpath,
  ];
  final dynstr = strings.toBytes();

  final ehsize = is64 ? 64 : 52;
  final phentsize = is64 ? 56 : 32;
  final symsize = is64 ? 24 : 16;
  final dynsize = is64 ? 16 : 8;
  final shentsize = is64 ? 64 : 40;
  final phoff = ehsize;
  final strtab = phoff + 2 * phentsize;
  final symtab = strtab + dynstr.length;
  final dynoff = symtab + symbolNames.length * symsize;
  final dyncount = dynamic.length + 3; // + DT_STRTAB, DT_STRSZ, DT_NULL
  final shoff = dynoff + dyncount * dynsize;
  final total = shoff + 4 * shentsize;

  final data = ByteData(total);
  final bytes = data.buffer.asUint8List();
  const le = Endian.little;
  void word(int at, int v) =>
      is64 ? data.setUint64(at, v, le) : data.setUint32(at, v, le);

  bytes.setAll(0, [0x7f, 0x45, 0x4c, 0x46, is64 ? 2 : 1, 1, 1]);
  data.setUint16(16, 3, le); // ET_DYN
  data.setUint16(18, is64 ? 0x3e : 0x03, le);
  data.setUint32(20, 1, le);
  word(is64 ? 0x20 : 0x1c, phoff);
  word(is64 ? 0x28 : 0x20, shoff);
  data.setUint16(is64 ? 0x34 : 0x28, ehsize, le);
  data.setUint16(is64 ? 0x36 : 0x2a, phentsize, le);
  data.setUint16(is64 ? 0x38 : 0x2c, 2, le);
  data.setUint16(is64 ? 0x3a : 0x2e, shentsize, le);
  data.setUint16(is64 ? 0x3c : 0x30, 4, le);

  // One PT_LOAD maps the whole file at address 0, so an address is its
  // offset; PT_DYNAMIC points at .dynamic.
  void programHeader(int i, int type, int offset, int size) {
    final at = phoff + i * phentsize;
    data.setUint32(at, type, le);
    if (is64) {
      data.setUint64(at + 0x08, offset, le);
      data.setUint64(at + 0x10, offset, le);
      data.setUint64(at + 0x20, size, le);
      data.setUint64(at + 0x28, size, le);
    } else {
      data.setUint32(at + 0x04, offset, le);
      data.setUint32(at + 0x08, offset, le);
      data.setUint32(at + 0x10, size, le);
      data.setUint32(at + 0x14, size, le);
    }
  }

  programHeader(0, 1, 0, total);
  programHeader(1, 2, dynoff, dyncount * dynsize);

  bytes.setAll(strtab, dynstr);
  for (var i = 0; i < symbolNames.length; i++) {
    data.setUint32(symtab + i * symsize, symbolNames[i], le);
  }
  final entries = [...dynamic, (5, strtab), (10, dynstr.length), (0, 0)];
  for (var i = 0; i < entries.length; i++) {
    word(dynoff + i * dynsize, entries[i].$1);
    word(dynoff + i * dynsize + dynsize ~/ 2, entries[i].$2);
  }

  void sectionHeader(int i, int type, int offset, int size, int entsize) {
    final at = shoff + i * shentsize;
    data.setUint32(at + 4, type, le);
    word(at + (is64 ? 0x18 : 0x10), offset);
    word(at + (is64 ? 0x20 : 0x14), size);
    word(at + (is64 ? 0x38 : 0x24), entsize);
  }

  sectionHeader(1, 3, strtab, dynstr.length, 0);
  sectionHeader(2, 11, symtab, symbolNames.length * symsize, symsize);
  sectionHeader(3, 6, dynoff, dyncount * dynsize, dynsize);
  return bytes;
}
