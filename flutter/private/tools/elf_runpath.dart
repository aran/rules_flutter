/// The runpath of a shared library a Linux bundle carries.
///
/// A Linux bundle carries its code assets side by side in `lib/`, and one that
/// links another finds it there only through a runpath entry of `$ORIGIN`,
/// the directory the library itself was loaded from. Upstream's build hooks
/// (`native_toolchain_c`) link every Linux library with `-Wl,-rpath,$ORIGIN`
/// for this reason. A library Bazel links records instead where its
/// dependencies sit in the build tree, `$ORIGIN/_solib_k8/...` and the like,
/// which name nothing in a bundle.
///
/// [bundledRunpath] gives the bundle's copy of a library its runpath: the
/// entries relative to `$ORIGIN` (where the build tree had the library's
/// dependencies) become one `$ORIGIN`, and every other entry stays. The
/// shorter string is written over the old one in `.dynstr`, so nothing in the
/// file moves.
///
/// The tool has no package dependencies and runs with the bare Dart SDK.
library;

import 'dart:typed_data';

const _dtNull = 0;
const _dtNeeded = 1;
const _dtStrtab = 5;
const _dtStrsz = 10;
const _dtSoname = 14;
const _dtRpath = 15;
const _dtRunpath = 29;

/// The dynamic tags whose value is an offset into `.dynstr`.
const _stringTags = {
  _dtNeeded,
  _dtSoname,
  _dtRpath,
  _dtRunpath,
  0x6ffffefa, // DT_CONFIG
  0x6ffffefb, // DT_DEPAUDIT
  0x6ffffefc, // DT_AUDIT
  0x7ffffffd, // DT_AUXILIARY
  0x7fffffff, // DT_FILTER
};

const _ptLoad = 1;
const _ptDynamic = 2;
const _shtDynsym = 11;
const _shtVerdef = 0x6ffffffd;
const _shtVerneed = 0x6ffffffe;

/// A runpath entry that names a directory relative to the library's own:
/// where the build tree put the library's dependencies, in a build.
bool _relativeToOrigin(String entry) =>
    entry == r'$ORIGIN' ||
    entry == r'${ORIGIN}' ||
    entry.startsWith(r'$ORIGIN/') ||
    entry.startsWith(r'${ORIGIN}/');

/// [runpath] as a bundle needs it: every entry relative to `$ORIGIN` replaced
/// by one `$ORIGIN`, where the first of them was, and the others kept. A
/// runpath with no such entry is returned as it is.
String bundleRunpath(String runpath) {
  final entries = runpath.split(':');
  if (!entries.any(_relativeToOrigin)) return runpath;
  final kept = <String>[];
  var origin = false;
  for (final entry in entries) {
    if (!_relativeToOrigin(entry)) {
      kept.add(entry);
    } else if (!origin) {
      kept.add(r'$ORIGIN');
      origin = true;
    }
  }
  return kept.join(':');
}

/// What an ELF shared library's dynamic section says, and where.
final class ElfDynamic {
  ElfDynamic._(this._bytes, this._data, this._endian, this._is64);

  /// Reads [bytes], an ELF shared library; [path] names it in errors.
  factory ElfDynamic.read(Uint8List bytes, String path) {
    if (bytes.length < 0x34 ||
        bytes[0] != 0x7f ||
        bytes[1] != 0x45 ||
        bytes[2] != 0x4c ||
        bytes[3] != 0x46) {
      throw FormatException('$path is not an ELF file');
    }
    final is64 = switch (bytes[4]) {
      1 => false,
      2 => true,
      final c => throw FormatException('$path: unknown ELF class $c'),
    };
    final endian = switch (bytes[5]) {
      1 => Endian.little,
      2 => Endian.big,
      final d => throw FormatException('$path: unknown ELF data encoding $d'),
    };
    final elf = ElfDynamic._(bytes, ByteData.sublistView(bytes), endian, is64)
      .._path = path;
    elf._parse();
    return elf;
  }

  final Uint8List _bytes;
  final ByteData _data;
  final Endian _endian;
  final bool _is64;
  late final String _path;

  late final int _strtab;
  late final int _strsz;

  /// The libraries it links, by the names it records for them.
  final List<String> needed = [];

  /// Its `DT_RUNPATH` and `DT_RPATH`, by tag, each with the offset of its
  /// string in `.dynstr`.
  final Map<int, int> _paths = {};

  /// Every offset into `.dynstr` the file refers to.
  final Set<int> _references = {};

  /// Its `DT_RUNPATH`, or null.
  String? get runpath =>
      _paths.containsKey(_dtRunpath) ? _string(_paths[_dtRunpath]!) : null;

  /// Its `DT_RPATH`, or null.
  String? get rpath =>
      _paths.containsKey(_dtRpath) ? _string(_paths[_dtRpath]!) : null;

  int _u16(int at) => _data.getUint16(at, _endian);
  int _u32(int at) => _data.getUint32(at, _endian);
  int _word(int at) =>
      _is64 ? _data.getUint64(at, _endian) : _data.getUint32(at, _endian);

  void _require(bool holds, String what) {
    if (!holds) throw FormatException('$_path: $what');
  }

  String _string(int offset) {
    _require(offset < _strsz, 'a string offset past the end of .dynstr');
    final start = _strtab + offset;
    var end = start;
    while (end < _strtab + _strsz && _bytes[end] != 0) {
      end++;
    }
    _require(end < _strtab + _strsz, 'a string in .dynstr runs past its end');
    return String.fromCharCodes(_bytes, start, end);
  }

  void _parse() {
    final phoff = _word(_is64 ? 0x20 : 0x1c);
    final shoff = _word(_is64 ? 0x28 : 0x20);
    final phentsize = _u16(_is64 ? 0x36 : 0x2a);
    final phnum = _u16(_is64 ? 0x38 : 0x2c);
    final shentsize = _u16(_is64 ? 0x3a : 0x2e);
    final shnum = _u16(_is64 ? 0x3c : 0x30);
    _require(
      phoff + phnum * phentsize <= _bytes.length,
      'program headers run past the end of the file',
    );

    final loads = <({int vaddr, int offset, int size})>[];
    int? dynamicOffset;
    int? dynamicSize;
    for (var i = 0; i < phnum; i++) {
      final at = phoff + i * phentsize;
      final type = _u32(at);
      final offset = _word(at + (_is64 ? 0x08 : 0x04));
      final vaddr = _word(at + (_is64 ? 0x10 : 0x08));
      final filesz = _word(at + (_is64 ? 0x20 : 0x10));
      if (type == _ptLoad) {
        loads.add((vaddr: vaddr, offset: offset, size: filesz));
      } else if (type == _ptDynamic) {
        dynamicOffset = offset;
        dynamicSize = filesz;
      }
    }
    _require(dynamicOffset != null, 'no dynamic section');
    _require(
      dynamicOffset! + dynamicSize! <= _bytes.length,
      'the dynamic section runs past the end of the file',
    );

    final entrySize = _is64 ? 16 : 8;
    int? strtabAddress;
    int? strsz;
    final strings = <(int, int)>[];
    for (
      var at = dynamicOffset;
      at + entrySize <= dynamicOffset + dynamicSize;
      at += entrySize
    ) {
      final tag = _word(at);
      final value = _word(at + entrySize ~/ 2);
      if (tag == _dtNull) break;
      if (tag == _dtStrtab) strtabAddress = value;
      if (tag == _dtStrsz) strsz = value;
      if (_stringTags.contains(tag)) strings.add((tag, value));
    }
    _require(strtabAddress != null && strsz != null, 'no DT_STRTAB/DT_STRSZ');
    final load = loads.where(
      (l) => l.vaddr <= strtabAddress! && strtabAddress < l.vaddr + l.size,
    );
    _require(load.isNotEmpty, 'DT_STRTAB is in no loaded segment');
    _strtab = load.first.offset + (strtabAddress! - load.first.vaddr);
    _strsz = strsz!;
    _require(
      _strtab + _strsz <= _bytes.length,
      '.dynstr runs past the end of the file',
    );

    for (final (tag, offset) in strings) {
      _references.add(offset);
      switch (tag) {
        case _dtNeeded:
          needed.add(_string(offset));
        case _dtRpath || _dtRunpath:
          _paths[tag] = offset;
      }
    }

    // What else names a string in .dynstr: the dynamic symbols and the
    // version records. Their sections are found by the section headers,
    // which every linker writes.
    _require(
      shnum > 0 && shoff + shnum * shentsize <= _bytes.length,
      'no section headers, which are needed to find what names a string in '
      '.dynstr',
    );
    for (var i = 0; i < shnum; i++) {
      final at = shoff + i * shentsize;
      final type = _u32(at + 4);
      final offset = _word(at + (_is64 ? 0x18 : 0x10));
      final size = _word(at + (_is64 ? 0x20 : 0x14));
      _require(
        type != _shtDynsym && type != _shtVerdef && type != _shtVerneed ||
            offset + size <= _bytes.length,
        'section $i runs past the end of the file',
      );
      switch (type) {
        case _shtDynsym:
          final entsize = _word(at + (_is64 ? 0x38 : 0x24));
          _require(entsize > 0, '.dynsym has no entry size');
          for (var s = offset; s + entsize <= offset + size; s += entsize) {
            _references.add(_u32(s)); // st_name
          }
        case _shtVerneed:
          var record = offset;
          while (true) {
            final count = _u16(record + 2);
            _references.add(_u32(record + 4)); // vn_file
            var aux = record + _u32(record + 8);
            for (var a = 0; a < count; a++) {
              _references.add(_u32(aux + 8)); // vna_name
              final next = _u32(aux + 12);
              if (next == 0) break;
              aux += next;
            }
            final next = _u32(record + 12);
            if (next == 0) break;
            record += next;
          }
        case _shtVerdef:
          var record = offset;
          while (true) {
            final count = _u16(record + 6);
            var aux = record + _u32(record + 12);
            for (var a = 0; a < count; a++) {
              _references.add(_u32(aux)); // vda_name
              final next = _u32(aux + 4);
              if (next == 0) break;
              aux += next;
            }
            final next = _u32(record + 16);
            if (next == 0) break;
            record += next;
          }
      }
    }
  }

  /// Writes [value] over the string of [tag] in place, padded with NULs.
  void _rewrite(int tag, String value) {
    final offset = _paths[tag]!;
    final old = _string(offset);
    _require(
      value.length <= old.length,
      'the new ${tag == _dtRunpath ? 'DT_RUNPATH' : 'DT_RPATH'} is longer '
      'than the old one',
    );
    // A linker may store one string as the tail of another; writing over
    // this one would change that one too.
    final shared = _references.where(
      (r) => r > offset && r < offset + old.length,
    );
    _require(
      shared.isEmpty,
      'the string of its ${tag == _dtRunpath ? 'DT_RUNPATH' : 'DT_RPATH'} '
      'is shared with another, so it cannot be rewritten in place',
    );
    final start = _strtab + offset;
    for (var i = 0; i < old.length; i++) {
      _bytes[start + i] = i < value.length ? value.codeUnitAt(i) : 0;
    }
  }
}

/// [bytes], an ELF shared library a Linux bundle carries, with its runpath
/// as [bundleRunpath] has it: the same bytes when that changes nothing, a
/// copy with the strings rewritten otherwise. [path] names it in errors.
Uint8List bundledRunpath(Uint8List bytes, String path) {
  final copy = Uint8List.fromList(bytes);
  final elf = ElfDynamic.read(copy, path);
  var changed = false;
  for (final tag in [_dtRunpath, _dtRpath]) {
    final offset = elf._paths[tag];
    if (offset == null) continue;
    final old = elf._string(offset);
    final updated = bundleRunpath(old);
    if (updated == old) continue;
    elf._rewrite(tag, updated);
    changed = true;
  }
  return changed ? copy : bytes;
}
