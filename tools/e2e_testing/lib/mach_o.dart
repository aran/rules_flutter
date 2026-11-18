/// Looking for symbols in a built Mach-O binary.
library;

import 'dart:io';

/// A Mach-O binary, queried with `nm`.
class MachO {
  /// The binary at [path].
  const MachO(this.path);

  /// The binary's file path.
  final String path;

  /// Whether the binary lists a symbol containing [name]. Swift names are
  /// mangled around the type name, so this matches by substring.
  ///
  /// A file `nm` cannot read, which is any file that is not a Mach-O binary,
  /// has no symbols.
  bool hasSymbolContaining(String name) {
    final result = Process.runSync('nm', [path]);
    return result.exitCode == 0 && result.stdout.toString().contains(name);
  }

  /// How many times the binary defines the symbol [name] (`nm -U`), exactly
  /// as named: one copy of a library linked in defines each of its symbols
  /// once.
  int definitionsOf(String name) {
    final result = Process.runSync('nm', ['-U', '-j', path]);
    if (result.exitCode != 0) return 0;
    return result.stdout
        .toString()
        .split('\n')
        .where((line) => line == name)
        .length;
  }
}

/// What `nm -a` lists for a Mach-O binary, counted by kind.
class SymbolCounts {
  /// Counts the entries of [nmAllOutput], the output of `nm -a`.
  ///
  /// A line is `<address> <type> <name>`, or `<type> <name>` for an undefined
  /// symbol. A type is one letter: upper case for an external symbol, lower
  /// case for a local one. A debugging (stab) entry has the type `-`.
  factory SymbolCounts.parse(String nmAllOutput) {
    var local = 0;
    var stabs = 0;
    var external = 0;
    for (final line in nmAllOutput.split('\n')) {
      final tokens = line.trim().split(RegExp(r'\s+'));
      if (tokens.length < 2) continue;
      final type = tokens[0].length == 1 ? tokens[0] : tokens[1];
      if (type == '-') {
        stabs++;
      } else if (type.length == 1 && type.toLowerCase() != type.toUpperCase()) {
        if (type == type.toLowerCase()) {
          local++;
        } else {
          external++;
        }
      }
    }
    return SymbolCounts._(local: local, stabs: stabs, external: external);
  }

  const SymbolCounts._({
    required this.local,
    required this.stabs,
    required this.external,
  });

  /// Local symbols: the names of non-exported functions and data.
  final int local;

  /// Debugging-map entries (`N_FUN`, `N_OSO` ...), which `strip -S` removes.
  final int stabs;

  /// External symbols, defined or undefined.
  final int external;

  @override
  String toString() => '$local local, $stabs stab, $external external';
}

/// Symbol-table and identity queries on a Mach-O binary or a `.dSYM` bundle.
extension MachOInspection on MachO {
  /// What `nm -a` lists for the binary.
  ///
  /// Throws a [StateError] if `nm` cannot read the file.
  SymbolCounts symbolCounts() {
    final result = Process.runSync('nm', ['-a', path]);
    if (result.exitCode != 0) {
      throw StateError('nm -a $path failed: ${result.stderr}');
    }
    return SymbolCounts.parse(result.stdout.toString());
  }

  /// The UUIDs `dwarfdump --uuid` reads from the binary or `.dSYM` bundle:
  /// one per architecture. A crash report names the UUID of the binary that
  /// crashed, and a dSYM symbolicates it only if the UUIDs are equal.
  ///
  /// Throws a [StateError] if `dwarfdump` cannot read the file.
  Set<String> uuids() {
    final result = Process.runSync('xcrun', ['dwarfdump', '--uuid', path]);
    if (result.exitCode != 0) {
      throw StateError('dwarfdump --uuid $path failed: ${result.stderr}');
    }
    return {
      for (final match in RegExp(
        r'^UUID: ([0-9A-F-]+)',
        multiLine: true,
      ).allMatches(result.stdout.toString()))
        match.group(1)!,
    };
  }

  /// The binary's install name (`LC_ID_DYLIB`), which a binary that links the
  /// dylib records and the dynamic linker looks it up by.
  ///
  /// Throws a [StateError] if `otool` cannot read the file or it has no single
  /// install name.
  String installName() {
    final result = Process.runSync('otool', ['-D', path]);
    if (result.exitCode != 0) {
      throw StateError('otool -D $path failed: ${result.stderr}');
    }
    // The first line names the file, and each architecture adds one more.
    final names = result.stdout
        .toString()
        .split('\n')
        .skip(1)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet();
    if (names.length != 1) {
      throw StateError('$path has no single install name: $names');
    }
    return names.single;
  }

  /// The libraries the binary links (`LC_LOAD_DYLIB` and its kin), by the
  /// names the dynamic linker looks them up by. `otool -L` lists a dylib's own
  /// install name among them, which is left out.
  ///
  /// Throws a [StateError] if `otool` cannot read the file.
  Set<String> linkedLibraries() {
    final result = Process.runSync('otool', ['-L', path]);
    if (result.exitCode != 0) {
      throw StateError('otool -L $path failed: ${result.stderr}');
    }
    // A line naming the file, for each architecture, ends in `:`; each other
    // is `<name> (compatibility version …, current version …)`.
    final listed = {
      for (final line in result.stdout.toString().split('\n'))
        if (line.trim().isNotEmpty && !line.endsWith(':'))
          line.trim().split(' (compatibility').first,
    };
    final own = Process.runSync('otool', ['-D', path]).stdout.toString();
    return listed.difference({
      for (final line in own.split('\n'))
        if (line.trim().isNotEmpty && !line.endsWith(':')) line.trim(),
    });
  }
}
