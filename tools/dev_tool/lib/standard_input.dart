/// This process's standard input, read so that reaching its end leaves
/// descriptor 0 open.
///
/// `dart:io`'s `stdin` closes descriptor 0 when its input ends. On macOS and
/// Linux that breaks the processes started afterwards: `Process.start` makes
/// a pipe for the child's stdin, the pipe can take the lowest free descriptor,
/// which is now 0, and the child then starts with descriptor 0 closed (seen
/// with `lsof` on the child). `adb` is the one that shows it: with no stdin,
/// every `adb` command fails with "daemon not running … could not install
/// *smartsocket* listener: Address already in use", whatever server is
/// running.
///
/// Input ends early for any run that is not typed at: a script, a CI job or
/// an agent starting the tool with stdin at `/dev/null`, or a `--machine`
/// client that closes its end. The run carries on after that (see
/// `runInteractiveSession`) and goes on starting processes: an Android run's
/// next `adb`, its ABI query or its teardown's, would fail.
///
/// Off Windows, the input is therefore read here, on an isolate of its own
/// with `poll` and `read`, which never close the descriptor. Windows hands a
/// child explicit handles rather than numbered descriptors, so `stdin` is
/// read there as it is.
///
/// Putting `/dev/null` back on descriptor 0 once the input has ended does not
/// do instead: `dart:io` announces the end before its close of descriptor 0
/// has run, and a close that runs after the `dup2` takes the `/dev/null` with
/// it (measured: one run in thirty with a piped stdin).
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// The process's standard input, one subscription for the whole process.
///
/// One reader at a time takes it: the machine protocol or the keyboard loop.
/// A second listen throws, rather than two readers splitting the input.
final Stream<List<int>> standardInput = Platform.isWindows
    ? stdin
    : _descriptorZero();

/// The reader, and the pipe that tells it to stop.
///
/// A run that ends well cancels this stream and returns from `main`, and the
/// VM then stops every other isolate and waits for each before the process
/// ends. It stops an isolate only while it runs Dart, never inside a native
/// call, so a reader still blocked on descriptor 0 would keep the process up
/// until something more was typed. So the reader waits in `poll` on the pipe
/// too, and cancelling the stream writes to the pipe: the reader returns from
/// `poll` and ends on its own.
Stream<List<int>> _descriptorZero() {
  final input = ReceivePort();
  late final ({int read, int write}) wake;
  late final StreamController<List<int>> controller;

  void finish() {
    input.close();
    _close(wake.write);
  }

  controller = StreamController<List<int>>(
    onListen: () {
      wake = _wakePipe();
      input.listen((message) {
        switch (message) {
          case Uint8List bytes:
            controller.add(bytes);
          case String error:
            controller.addError(StdinException(error));
            finish();
            controller.close();
          default:
            finish();
            controller.close();
        }
      });
      Isolate.spawn(
        _readDescriptorZero,
        (output: input.sendPort, wake: wake.read),
        debugName: 'standard input',
      );
    },
    onCancel: () {
      if (controller.isClosed) return;
      final byte = _malloc(1).cast<Uint8>()..value = 1;
      _write(wake.write, byte, 1);
      finish();
    },
  );
  return controller.stream;
}

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function(int fd, Pointer<Uint8> buffer, int count) _read = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('read');

final int Function(int fd, Pointer<Uint8> buffer, int count) _write = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('write');

final int Function(int fd) _close = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

final int Function(Pointer<Int32> fds) _pipe = _libc
    .lookupFunction<
      Int32 Function(Pointer<Int32>),
      int Function(Pointer<Int32>)
    >(
      'pipe',
    );

final int Function(int fd, int command, int argument) _fcntl = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, Int32),
      int Function(int, int, int)
    >('fcntl');

/// `nfds_t` is `unsigned int` on macOS and `unsigned long` on Linux. Passed
/// as the wider of the two, the count arrives whole in either.
final int Function(Pointer<_PollFd> fds, int count, int timeout) _poll = _libc
    .lookupFunction<
      Int32 Function(Pointer<_PollFd>, UnsignedLong, Int32),
      int Function(Pointer<_PollFd>, int, int)
    >('poll');

final Pointer<Void> Function(int size) _malloc = _libc
    .lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)
    >('malloc');

/// Where libc keeps `errno` for the calling thread, as `process_group_exec`
/// finds it.
final Pointer<Int32> Function() _errnoLocation = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      Platform.isMacOS ? '__error' : '__errno_location',
    );

/// `struct pollfd`, the same on macOS and Linux.
final class _PollFd extends Struct {
  @Int32()
  external int fd;

  @Int16()
  external int events;

  @Int16()
  external int revents;
}

// The same values on macOS and Linux.
const _pollIn = 0x1;
const _pollNval = 0x20;
const _eintr = 4;
const _setDescriptorFlags = 2; // F_SETFD
const _closeOnExec = 1; // FD_CLOEXEC

/// What one `read` takes at most: a key, an escape sequence, a protocol line.
const _chunk = 4096;

/// A pipe for [_descriptorZero]'s wake-up, which no child inherits.
({int read, int write}) _wakePipe() {
  final fds = _malloc(2 * sizeOf<Int32>()).cast<Int32>();
  if (_pipe(fds) != 0) {
    throw StdinException(
      'Could not make a pipe to stop the standard input reader with '
      '(errno ${_errnoLocation().value})',
    );
  }
  for (final fd in [fds[0], fds[1]]) {
    _fcntl(fd, _setDescriptorFlags, _closeOnExec);
  }
  return (read: fds[0], write: fds[1]);
}

/// Sends each chunk of descriptor 0 to `output`, then null at its end, or a
/// message saying why it could not be read; and returns, sending nothing, when
/// `wake` becomes readable.
///
/// `poll` first, so that a descriptor someone made non-blocking (`dart:io`
/// does, for a pipe it wraps) is waited on rather than read empty. A closed
/// descriptor 0 (`POLLNVAL`) is input that has ended.
void _readDescriptorZero(({SendPort output, int wake}) arguments) {
  final (:output, :wake) = arguments;
  final buffer = _malloc(_chunk).cast<Uint8>();
  final fds = _malloc(2 * sizeOf<_PollFd>()).cast<_PollFd>();
  try {
    while (true) {
      for (final (i, fd) in [(0, 0), (1, wake)]) {
        fds[i]
          ..fd = fd
          ..events = _pollIn
          ..revents = 0;
      }
      if (_poll(fds, 2, -1) < 0) {
        final errno = _errnoLocation().value;
        if (errno == _eintr) continue;
        output.send('poll on standard input failed (errno $errno)');
        return;
      }
      if (fds[1].revents != 0) return;
      if (fds[0].revents & _pollNval != 0) {
        output.send(null);
        return;
      }
      final count = _read(0, buffer, _chunk);
      if (count > 0) {
        output.send(Uint8List.fromList(buffer.asTypedList(count)));
      } else if (count == 0) {
        output.send(null);
        return;
      } else {
        final errno = _errnoLocation().value;
        if (errno == _eintr) continue;
        output.send('read of standard input failed (errno $errno)');
        return;
      }
    }
  } finally {
    _close(wake);
  }
}
