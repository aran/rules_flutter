/// Runs a program as the leader of a new process group:
///
///     process_group_exec <program> [arguments...]
///
/// `flutter_bazel` starts every `bazel` command through this, so that one
/// signal to the command's group reaches everything the command is made of.
///
/// A `bazel` on `PATH` is usually bazelisk, which runs the real Bazel client as
/// a child and catches SIGINT and SIGTERM without passing them on: it counts on
/// a terminal signalling the whole foreground process group. A signal to
/// bazelisk's pid alone therefore stops nothing. Measured against bazelisk
/// 1.27, the build it had started ran to completion after the dev tool had
/// exited, and every bazel command in that workspace waited behind it for the
/// output base's lock. A signal to the group is what a terminal sends, and it
/// reaches the client the same way through bazelisk, through a `tools/bazel`
/// wrapper, or with nothing in front of it.
///
/// The group has to exist before the program starts, which is why this is a
/// process rather than an option on the spawn: `dart:io` cannot put a child it
/// starts into a group of its own, and a group joined any later would miss
/// whatever the program had already forked. So this makes its own group and
/// then *becomes* the program (`execvp`). The pid the caller holds is the
/// program's pid and the group's id, and the program's exit status and stdio
/// are the caller's directly, with nothing in between relaying them.
///
/// POSIX only: Windows has no process group a console process can be moved
/// into this way.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function(int pid, int pgid) _setpgid = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'setpgid',
    );

final int Function(Pointer<Uint8> file, Pointer<Pointer<Uint8>> argv) _execvp =
    _libc.lookupFunction<
      Int32 Function(Pointer<Uint8>, Pointer<Pointer<Uint8>>),
      int Function(Pointer<Uint8>, Pointer<Pointer<Uint8>>)
    >('execvp');

final Pointer<Void> Function(int size) _malloc = _libc
    .lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)
    >(
      'malloc',
    );

final Pointer<Uint8> Function(int errnum) _strerror = _libc
    .lookupFunction<
      Pointer<Uint8> Function(Int32),
      Pointer<Uint8> Function(int)
    >(
      'strerror',
    );

/// Where libc keeps `errno` for the calling thread. The accessor is named
/// differently on each libc, and those are the only two this runs on.
final Pointer<Int32> Function() _errnoLocation = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      Platform.isMacOS ? '__error' : '__errno_location',
    );

/// `ENOENT`, which has the same value on macOS and Linux.
const _enoent = 2;

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: process_group_exec <program> [arguments...]');
    exit(64); // EX_USAGE
  }

  if (_setpgid(0, 0) != 0) {
    final errno = _errnoLocation().value;
    stderr.writeln(
      'process_group_exec: could not give ${args.first} a process group of '
      'its own: ${_describe(errno)}',
    );
    exit(71); // EX_OSERR
  }

  final argv = _malloc(
    sizeOf<Pointer<Uint8>>() * (args.length + 1),
  ).cast<Pointer<Uint8>>();
  for (var i = 0; i < args.length; i++) {
    argv[i] = _cString(args[i]);
  }
  argv[args.length] = nullptr;

  // Returns only if the program could not be started.
  _execvp(argv[0], argv);
  final errno = _errnoLocation().value;
  stderr.writeln(
    'process_group_exec: could not run ${args.first}: ${_describe(errno)}',
  );
  // The statuses a shell reports for the same two failures.
  exit(errno == _enoent ? 127 : 126);
}

/// [value] as a NUL-terminated string in memory this process never frees:
/// it either becomes the program or exits.
Pointer<Uint8> _cString(String value) {
  final bytes = utf8.encode(value);
  final pointer = _malloc(bytes.length + 1).cast<Uint8>();
  pointer.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  return pointer;
}

String _describe(int errno) {
  final message = _strerror(errno);
  var length = 0;
  while (message[length] != 0) {
    length++;
  }
  return utf8.decode(message.asTypedList(length));
}
