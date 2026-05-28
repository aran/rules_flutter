/// Shared test doubles for dev tool tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/compiler.dart';
import 'package:vm_service/vm_service.dart';

/// An [IOSink] that captures output to a [StringBuffer].
class BufferSink implements IOSink {
  final StringBuffer buffer = StringBuffer();

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => buffer.write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future close() async {}

  @override
  Future get done => Future.value();

  @override
  Future flush() => Future.value();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  String toString() => buffer.toString();

  /// Lines written (splits on newline, drops trailing empty).
  List<String> get lines {
    final s = buffer.toString();
    if (s.isEmpty) return [];
    final l = s.split('\n');
    if (l.last.isEmpty) l.removeLast();
    return l;
  }
}

/// A controllable fake [Process] for testing.
class FakeProcess implements Process {
  final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _stderrController =
      StreamController<List<int>>.broadcast();
  final StringBuffer stdinBuffer = StringBuffer();
  final Completer<int> _exitCompleter = Completer<int>();

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  IOSink get stdin => _FakeStdin(stdinBuffer);

  @override
  int get pid => 12345;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(-1);
    return true;
  }

  /// Emit a line on stdout (appends a newline automatically).
  void emitStdout(String line) {
    _stdoutController.add(utf8.encode('$line\n'));
  }

  /// Emit raw data on stdout without appending a newline.
  void emitStdoutRaw(String data) {
    _stdoutController.add(utf8.encode(data));
  }

  /// Emit data on stderr.
  void emitStderr(String data) {
    _stderrController.add(utf8.encode(data));
  }

  /// Complete the process with the given exit code.
  void complete(int exitCode) {
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(exitCode);
    _stdoutController.close();
    _stderrController.close();
  }
}

class _FakeStdin implements IOSink {
  final StringBuffer _buffer;

  _FakeStdin(this._buffer);

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => _buffer.write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future close() async {}

  @override
  Future get done => Future.value();

  @override
  Future flush() => Future.value();

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);
}

/// A fake [VmService] for testing hot reload/restart.
class FakeVmService implements VmService {
  final List<IsolateRef> isolates;
  bool reloadSourcesCalled = false;
  bool callServiceExtensionCalled = false;
  String? lastExtensionMethod;
  String? lastIsolateId;
  bool reloadSuccess;
  bool throwOnReload;
  bool disposed = false;
  bool _killed = false;

  /// Base64 PNG data to return for `_flutter.screenshot` calls.
  String? screenshotData;

  /// If non-null, [reloadSources] awaits this gate before returning. Lets
  /// tests deterministically simulate a hung VM-service RPC.
  Completer<void>? reloadSourcesGate;

  /// If non-null, every [callServiceExtension] awaits this gate before
  /// returning.
  Completer<void>? callServiceExtensionGate;

  /// When true, [reloadSources] posts a `Flutter.Error` extension event —
  /// mirroring the framework reporting a build failure during the
  /// reassemble triggered by a reload/restart.
  bool emitFlutterErrorOnReload;

  /// The `renderedErrorText` carried by the simulated `Flutter.Error`.
  String flutterErrorText;

  final StreamController<Event> _extController =
      StreamController<Event>.broadcast();

  FakeVmService({
    this.isolates = const [],
    this.reloadSuccess = true,
    this.throwOnReload = false,
    this.screenshotData,
    this.reloadSourcesGate,
    this.callServiceExtensionGate,
    this.emitFlutterErrorOnReload = false,
    this.flutterErrorText = 'fake _CompileTimeError building MyApp',
  });

  @override
  Future<Success> streamListen(String streamId) async {
    _checkAlive('streamListen');
    return Success();
  }

  @override
  Future<Success> streamCancel(String streamId) async => Success();

  @override
  Stream<Event> get onExtensionEvent => _extController.stream;

  /// Simulate the underlying WebSocket dying.
  ///
  /// Mirrors what `package:vm_service` does to a real `VmService` after its
  /// `streamClosed` future completes — every subsequent RPC throws
  /// `RPCError(-32000, 'Service connection disposed')`.
  ///
  /// Named `simulateDisposed` to avoid colliding with `VmService.kill(...)`,
  /// which is an unrelated isolate-management RPC.
  void simulateDisposed() {
    _killed = true;
  }

  void _checkAlive(String method) {
    if (_killed) {
      throw RPCError(method, -32000, 'Service connection disposed');
    }
  }

  @override
  Future<VM> getVM() async {
    _checkAlive('getVM');
    return VM(
      isolates: isolates,
      name: 'fake_vm',
      architectureBits: 64,
      hostCPU: 'fake',
      operatingSystem: 'fake',
      targetCPU: 'fake',
      version: '3.0.0',
      pid: 12345,
      startTime: 0,
    );
  }

  @override
  Future<ReloadReport> reloadSources(
    String isolateId, {
    bool? force,
    bool? pause,
    String? rootLibUri,
    String? packagesUri,
  }) async {
    _checkAlive('reloadSources');
    reloadSourcesCalled = true;
    lastIsolateId = isolateId;
    if (reloadSourcesGate != null) await reloadSourcesGate!.future;
    _checkAlive('reloadSources'); // gate may have outlived the connection
    if (throwOnReload) {
      throw RPCError('reloadSources', 100, 'Reload failed');
    }
    if (emitFlutterErrorOnReload) {
      // Real Flutter reports a build failure during the reassemble-driven
      // rebuild, before that frame's Flutter.Frame. Emitting here keeps
      // that ordering (Error before the reassemble-scheduled Frame).
      _extController.add(Event(
        kind: EventKind.kExtension,
        extensionKind: 'Flutter.Error',
        extensionData:
            ExtensionData.parse({'renderedErrorText': flutterErrorText}),
        timestamp: 0,
      ));
    }
    return ReloadReport(success: reloadSuccess);
  }

  /// Track extension call args.
  Map<String, dynamic>? lastExtensionArgs;

  /// Simulated toggle state per extension method.
  final Map<String, bool> _toggleState = {};

  @override
  Future<Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    _checkAlive(method);
    callServiceExtensionCalled = true;
    lastExtensionMethod = method;
    lastIsolateId = isolateId;
    lastExtensionArgs = args;
    if (callServiceExtensionGate != null) {
      await callServiceExtensionGate!.future;
      _checkAlive(method);
    }

    // Mirror real Flutter: reassemble triggers a rebuilt frame whose
    // `Flutter.Frame` timing event is posted *after* the reassemble RPC
    // response (i.e. a later turn here), so it lands after the client's
    // apply() returns — the success terminator for `_applyAndVerify`.
    if (method == 'ext.flutter.reassemble') {
      Future<void>(() {
        if (!_extController.isClosed) {
          _extController.add(Event(
            kind: EventKind.kExtension,
            extensionKind: 'Flutter.Frame',
            extensionData: ExtensionData.parse({'number': 1}),
            timestamp: 0,
          ));
        }
      });
    }

    // Return screenshot data if available.
    if (method == '_flutter.screenshot' && screenshotData != null) {
      return Response()..json = {'screenshot': screenshotData};
    }

    // Simulate toggle behavior: if args has 'enabled', update state.
    if (args != null && args.containsKey('enabled')) {
      _toggleState[method] = args['enabled'] == 'true';
    }

    // Return current state for toggle reads.
    final enabled = _toggleState[method] ?? false;
    final response = Response()
      ..json = {'enabled': enabled.toString()};
    return response;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _extController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
        '${invocation.memberName} not implemented in FakeVmService');
  }
}

/// Captured arguments from a single [FakeCompiler.compileIncrement] call.
class RecompileCall {
  final String entrypoint;
  final Set<String> invalidated;
  RecompileCall(this.entrypoint, this.invalidated);
}

/// In-memory [Compiler] for orchestrator tests.
///
/// `nextOutcome` is the result of the next compile call. If `pendingResult`
/// is set, the call awaits it before returning — useful for mid-pipeline
/// race tests.
class FakeCompiler implements Compiler {
  CompileOutcome nextOutcome = const CompileSucceeded('/tmp/delta.dill');

  /// If non-null, [compileIncrement] / [compileFull] await this completer
  /// before returning [nextOutcome]. Lets tests hold a compile open.
  Completer<void>? pendingResult;

  final List<RecompileCall> recompileCalls = [];
  final List<String> fullCompileCalls = [];

  int commitCount = 0;
  int rollbackCount = 0;
  int shutdownCount = 0;

  @override
  Future<CompileOutcome> compileIncrement({
    required Set<String> invalidated,
    required String entrypoint,
  }) async {
    recompileCalls.add(RecompileCall(entrypoint, invalidated));
    if (pendingResult != null) await pendingResult!.future;
    return nextOutcome;
  }

  @override
  Future<CompileOutcome> compileFull({required String entrypoint}) async {
    fullCompileCalls.add(entrypoint);
    if (pendingResult != null) await pendingResult!.future;
    return nextOutcome;
  }

  @override
  Future<void> commit() async {
    commitCount++;
  }

  @override
  Future<void> rollback() async {
    rollbackCount++;
  }

  @override
  Future<void> shutdown() async {
    shutdownCount++;
  }
}

/// Captured arguments from a single [FakeAppInstance.applyKernel] call.
class ApplyCall {
  final String dillPath;
  final ApplyMode mode;
  ApplyCall(this.dillPath, this.mode);
}

/// In-memory [AppInstance] for orchestrator tests. Configurable per-call
/// outcome; records every call.
class FakeAppInstance implements AppInstance {
  @override
  final String id;

  /// Outcome to return from the next `applyKernel`. Defaults to [Applied].
  ApplyOutcome nextOutcome = const Applied();

  /// If non-null, [applyKernel] awaits this completer before returning.
  /// Lets tests deterministically simulate a slow/hung device.
  Completer<void>? gate;

  final List<ApplyCall> calls = [];

  FakeAppInstance({required this.id});

  @override
  Future<ApplyOutcome> applyKernel(
    String dillPath, {
    required ApplyMode mode,
  }) async {
    calls.add(ApplyCall(dillPath, mode));
    if (gate != null) await gate!.future;
    return nextOutcome;
  }
}
