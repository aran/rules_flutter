/// Shared test doubles for dev tool tests.
///
/// **The rule these are held to: a fake may answer less than the real thing,
/// but it may never answer in a shape the real thing cannot produce.**
///
/// A double that invents a shape hides the bug it was standing in for, so the
/// contract is asserted against both:
/// `vm_service_conformance_test.dart` runs one set of assertions over the real
/// `VmService` and [FakeVmService] alike. `VmService` needs only a
/// `Stream<String>` and a write callback, so the real client is instantiable
/// with no socket and no VM; where that is possible, a fake-only assertion is
/// a choice, not a constraint.
///
/// Instrumentation a fake adds for the test's benefit — counters, call logs,
/// gates, [FakeVmService.disposed] — is fine, and is not the same thing: it is
/// extra, out-of-band, and does not change how the double answers the code
/// under test.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/compiler.dart';
import 'package:flutter_bazel_dev_tool/mdns_vm_service_discovery.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';

/// A stand-in for the VM's devFS HTTP endpoint: decodes the `dev_fs_uri_b64`
/// header the way the VM does and writes the gzipped body under [root].
///
/// A real server rather than a stub, because the upload *is* the delivery. A
/// double that only recorded the call could not tell a devFS the engine can
/// actually open from one that was never written — and every reload the tool
/// performs on a device goes through this exact PUT.
class FakeDevFS {
  final HttpServer _server;

  /// Where uploads land: what the VM would call the devFS root.
  final Directory root;

  /// The status the next upload is answered with. A non-OK status is what a VM
  /// that would not take the bytes looks like from the client's side.
  int uploadStatus = HttpStatus.ok;

  FakeDevFS._(this._server, this.root);

  static Future<FakeDevFS> start(Directory root) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final devFS = FakeDevFS._(server, root);
    unawaited(server.forEach(devFS._handle));
    return devFS;
  }

  Future<void> _handle(HttpRequest request) async {
    final encoded = request.headers.value('dev_fs_uri_b64')!;
    final relative = utf8.decode(base64.decode(encoded));
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
    }
    if (uploadStatus == HttpStatus.ok) {
      File(p.join(root.path, relative))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(gzip.decode(bytes));
    }
    request.response.statusCode = uploadStatus;
    await request.response.close();
  }

  /// The `http://` URI a client connects to — and the same address it PUTs
  /// uploads at, exactly as on a real VM.
  Uri get serviceUri => Uri.parse('http://127.0.0.1:${_server.port}/');

  /// What `_createDevFS` answers with; assign to [FakeVmService.devFSUri].
  String get uri => Uri.directory(root.path).toString();

  /// The uploaded copy of [relative], where the engine would look for it.
  File fileAt(String relative) => File(p.join(root.path, relative));

  Future<void> close() => _server.close(force: true);
}

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

/// Decode the single machine-protocol message written to [sink].
///
/// The protocol wraps every message in a `[...]` array, so unwrapping is
/// two steps; doing it here keeps the assertion in the test about the
/// message rather than the envelope.
Map<String, dynamic> decodeSingleEvent(BufferSink sink) {
  final lines = sink.lines;
  if (lines.length != 1) {
    throw StateError(
      'expected exactly one protocol line, got ${lines.length}: '
      '$lines',
    );
  }
  return (json.decode(lines.single) as List).single as Map<String, dynamic>;
}

/// A controllable fake [Process] for testing.
class FakeProcess implements Process {
  final Completer<void> _stdoutAttached = Completer<void>();
  final Completer<void> _stderrAttached = Completer<void>();

  late final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>.broadcast(
        onListen: () {
          if (!_stdoutAttached.isCompleted) _stdoutAttached.complete();
        },
      );
  late final StreamController<List<int>> _stderrController =
      StreamController<List<int>>.broadcast(
        onListen: () {
          if (!_stderrAttached.isCompleted) _stderrAttached.complete();
        },
      );

  /// Whether something is currently reading this process's stdout / stderr.
  ///
  /// A real process blocks on write once an unread pipe fills, so "is anyone
  /// still draining this?" is the property a test needs to assert; a fake's
  /// in-memory controller would happily absorb output forever.
  bool get stdoutHasListener => _stdoutController.hasListener;
  bool get stderrHasListener => _stderrController.hasListener;

  /// Completes once the code under test is listening to both output streams.
  ///
  /// These are broadcast controllers, so anything emitted before a listener
  /// attaches is dropped. Await this instead of pumping the event queue a
  /// fixed number of times: a launch that does real I/O before subscribing
  /// (creating temp dirs, awaiting an install) takes an unpredictable number
  /// of turns to get there, which makes a pump-based barrier flaky.
  Future<void> get outputAttached =>
      Future.wait([_stdoutAttached.future, _stderrAttached.future]);
  final StringBuffer stdinBuffer = StringBuffer();
  final StreamController<String> _stdinLines =
      StreamController<String>.broadcast();
  final Completer<int> _exitCompleter = Completer<int>();

  /// Lines written to this process's stdin, as they are written.
  ///
  /// Lets a test script a request/response protocol — e.g. replying to the
  /// lldb commands the iOS device launch issues — rather than only asserting
  /// on [stdinBuffer] afterwards.
  Stream<String> get stdinLines => _stdinLines.stream;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  /// Thrown by every write to [stdin] when set.
  ///
  /// What a process whose pipe has closed under us does — a broken pipe is an
  /// `IOException`, not the `StateError` a closed `IOSink` raises, and the two
  /// arrive by different routes.
  Object? stdinWriteError;

  /// This process's stdin — one sink, not a new one per access.
  ///
  /// Measured on a real [Process]: `identical(p.stdin, p.stdin)` is true. It
  /// also has to be, now that a line is only complete once its terminator
  /// arrives: the half-written line lives on the sink, and a fresh sink per
  /// access would lose it between the two calls that wrote it.
  @override
  late final IOSink stdin = _FakeStdin(
    stdinBuffer,
    _stdinLines,
    () => stdinWriteError,
  );

  @override
  int get pid => 12345;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  /// Whether [kill] was called. A terminated compiler is the only guard that
  /// holds once its answers can no longer be trusted, so tests assert on it.
  bool killed = false;

  /// Every signal [kill] was sent, in order.
  ///
  /// [killed] answers "was it asked to stop", which cannot distinguish a
  /// SIGTERM that was enough from one that had to be escalated. Teardown's
  /// whole question is which of those happened.
  final List<ProcessSignal> signals = [];

  /// Take SIGTERM and keep running, the way a real wedged process does.
  ///
  /// A trapped SIGTERM is still delivered, so `kill()` returns **true** while
  /// `exitCode` stays pending; only SIGKILL completes it, with code **-9**. A
  /// fake whose `kill()` completes `exitCode` inline can therefore never fail a
  /// test that the real wire fails. Opt-in so the default kill→exit fakes are
  /// untouched.
  bool ignoresSigterm = false;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    killed = true;
    if (ignoresSigterm && signal == ProcessSignal.sigterm) return true;
    // Never inline: a real process exits some time after the signal, and code
    // that only works when `exitCode` is already complete on the next line
    // would pass here and hang in production.
    scheduleMicrotask(() {
      if (!_exitCompleter.isCompleted) {
        _exitCompleter.complete(signal == ProcessSignal.sigkill ? -9 : -1);
      }
    });
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

  /// End stdout only, leaving stderr open — the shape of a process that is
  /// still complaining after its normal output has finished.
  Future<void> closeStdout() => _stdoutController.close();
}

/// The stdin of a [FakeProcess]: every write method funnelled into one path.
///
/// Lines are derived from the characters written, never from *which* method
/// wrote them: a reader sees `write('x\n')` and `writeln('x')` identically, a
/// line split across two `write` calls arrives as a single line, and bytes
/// handed to `add` are just as much a line as either.
///
/// Emitting a line only from `writeln` would show a test driving
/// [FrontendServer] *no input at all*, because the compiler writes every
/// request through `write` — `_writeln` is `_write('$line\n')`
/// (`frontend_server.dart`). Only `quit` ever goes through `writeln`.
class _FakeStdin implements IOSink {
  final StringBuffer _buffer;
  final StreamController<String> _lines;
  final Object? Function() _throws;

  /// Characters written since the last newline.
  ///
  /// A pipe carries bytes, not lines: nothing is a line until its terminator
  /// has actually been written, however many calls that took.
  final StringBuffer _partial = StringBuffer();

  bool _closed = false;

  _FakeStdin(this._buffer, this._lines, this._throws);

  /// The single path every write takes.
  void _feed(String text) {
    // Two different failures, reached by two different routes — the code under
    // test tells them apart, so this must too. After `close()` every write
    // method on a real IOSink throws `StateError: StreamSink is closed`,
    // add / write / writeln / writeAll / writeCharCode alike. A process that
    // died under an *open* sink is the other case, and a broken pipe is an
    // IOException.
    if (_closed) throw StateError('StreamSink is closed');
    final error = _throws();
    if (error != null) throw error;

    _buffer.write(text);
    _partial.write(text);
    if (!text.contains('\n')) return;
    final parts = _partial.toString().split('\n');
    // Whatever follows the last newline is not a line yet.
    _partial
      ..clear()
      ..write(parts.removeLast());
    if (_lines.isClosed) return;
    parts.forEach(_lines.add);
  }

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => _feed(encoding.decode(data));

  @override
  void write(Object? object) => _feed('$object');

  @override
  void writeln([Object? object = '']) => _feed('$object\n');

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _feed(objects.join(separator));

  @override
  void writeCharCode(int charCode) => _feed(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future close() async => _closed = true;

  @override
  Future get done => Future.value();

  @override
  Future flush() => Future.value();
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

  /// Whether this connection is gone, by either route that ends one: an
  /// explicit [dispose] or a socket that closed under it ([simulateDisposed]).
  ///
  /// [disposed] cannot answer this. It records only that *someone called
  /// `dispose()` on this object* — out-of-band instrumentation the real
  /// `VmService` does not expose at all — whereas this is the wire-visible
  /// state both routes share, and the only thing a redial can actually ask
  /// about. The real client reaches the same place from either direction: its
  /// constructor wires the input stream's `onDone` straight to `dispose()`
  /// (`vm_service-15.2.0`:337), and both a closed input stream and an explicit
  /// dispose refuse every later RPC identically.
  bool get isGone => _killed;

  /// URI to answer `_createDevFS` with, or null to answer nothing — which is
  /// what a VM that refused to make one looks like.
  String? devFSUri;

  /// Base64 PNG data to return for `_flutter.screenshot` calls.
  String? screenshotData;

  /// If non-null, [reloadSources] awaits this gate before returning. Lets
  /// tests deterministically simulate a hung VM-service RPC.
  Completer<void>? reloadSourcesGate;

  /// If non-null, every [callServiceExtension] awaits this gate before
  /// returning.
  Completer<void>? callServiceExtensionGate;

  /// If non-null, every [callMethod] awaits this gate before returning.
  ///
  /// The `_flutter.*` half of [callServiceExtensionGate]: a hot restart is
  /// `_flutter.listViews` + `_flutter.runInView` and touches no `ext.` call at
  /// all, so nothing else can wedge it.
  Completer<void>? callMethodGate;

  /// When true, [reloadSources] posts a `Flutter.Error` extension event —
  /// mirroring the framework reporting a build failure during the
  /// reassemble triggered by a reload/restart.
  bool emitFlutterErrorOnReload;

  /// The `renderedErrorText` carried by the simulated `Flutter.Error`.
  String flutterErrorText;

  /// The name a `hotRestart` [callMethod] was issued under — bare, or the
  /// DDS-namespaced alias. Null until one is called. What proves the alias
  /// resolved off the `ServiceRegistered` event rather than being hardcoded.
  String? hotRestartMethod;

  /// If non-null, a `hotRestart` call throws this instead of succeeding.
  RPCError? hotRestartError;

  /// If non-null, a `hotRestart` call awaits this gate before returning. Lets
  /// a test drive DWDS's unbounded `waitForIsolateStarted` deterministically.
  Completer<void>? hotRestartGate;

  final StreamController<Event> _extController =
      StreamController<Event>.broadcast();
  final StreamController<Event> _stdoutController =
      StreamController<Event>.broadcast();
  final StreamController<Event> _stderrController =
      StreamController<Event>.broadcast();
  final StreamController<Event> _serviceController =
      StreamController<Event>.broadcast();
  final StreamController<Event> _isolateController =
      StreamController<Event>.broadcast();

  /// Stream IDs passed to [streamListen], in call order.
  final List<String> streamListens = [];

  /// Stream IDs for which [streamListen] should report
  /// `kStreamAlreadySubscribed` — what a real VM service does on re-subscribe.
  final Set<String> alreadySubscribedStreams = {};

  /// Stream IDs for which [streamListen] should fail with an unrelated error.
  final Set<String> failingStreams = {};

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
  Future<Success> streamListen(String streamId) {
    _checkAlive('streamListen');
    return _streamListen(streamId);
  }

  Future<Success> _streamListen(String streamId) async {
    streamListens.add(streamId);
    if (alreadySubscribedStreams.contains(streamId)) {
      throw RPCError('streamListen', 103, 'Stream already subscribed');
    }
    if (failingStreams.contains(streamId)) {
      throw RPCError('streamListen', 104, 'Stream cannot be subscribed');
    }
    return Success();
  }

  @override
  Future<Success> streamCancel(String streamId) async => Success();

  @override
  Stream<Event> get onExtensionEvent => _extController.stream;

  @override
  Stream<Event> get onServiceEvent => _serviceController.stream;

  @override
  Stream<Event> get onIsolateEvent => _isolateController.stream;

  /// Emit the `IsolateStart` a VM sends for a newly-spawned isolate — the
  /// second half of a restart rotating the root isolate.
  void emitIsolateStart(String id, {String name = 'main'}) {
    _isolateController.add(
      Event(
        kind: EventKind.kIsolateStart,
        isolate: IsolateRef(id: id, name: name, number: id),
        timestamp: 0,
      ),
    );
  }

  /// Emit the `ServiceExtensionAdded` a VM sends when the app calls
  /// `registerExtension` — the event DWDS synthesizes from DDC's
  /// `$emitRegisterEvent` (`proxy_service.dart:398-406`).
  void emitServiceExtensionAdded(String isolateId, String rpc) {
    _isolateController.add(
      Event(
        kind: EventKind.kServiceExtensionAdded,
        isolate: IsolateRef(id: isolateId, name: 'main', number: isolateId),
        extensionRPC: rpc,
        timestamp: 0,
      ),
    );
  }

  /// Emit the `Flutter.FirstFrame` the framework posts once it has built and
  /// sent its first frame.
  ///
  /// The event and the `didSendFirstFrameRasterizedEvent` query answer the same
  /// question from opposite directions, and a fake that can only do the query
  /// cannot stand in for the case that matters: a device whose VM answers no
  /// request at all until the app is up, so the event is the only thing that
  /// can arrive first.
  void emitFirstFrame({String kind = 'Flutter.FirstFrame'}) {
    _extController.add(
      Event(kind: EventKind.kExtension, extensionKind: kind, timestamp: 0),
    );
  }

  /// Emit the `IsolateExit` a VM sends when an isolate goes away.
  void emitIsolateExit(String id, {String name = 'main'}) {
    _isolateController.add(
      Event(
        kind: EventKind.kIsolateExit,
        isolate: IsolateRef(id: id, name: name, number: id),
        timestamp: 0,
      ),
    );
  }

  /// Emit the `ServiceRegistered` event DDS sends when a client registers a
  /// service, carrying the namespaced [method] the caller must actually use
  /// (dds `stream_manager.dart:49-60`).
  void emitServiceRegistered(String service, String method) {
    _serviceController.add(
      Event(
        kind: EventKind.kServiceRegistered,
        service: service,
        method: method,
        timestamp: 0,
      ),
    );
  }

  /// Emit the matching `ServiceUnregistered`.
  void emitServiceUnregistered(String service, String method) {
    _serviceController.add(
      Event(
        kind: EventKind.kServiceUnregistered,
        service: service,
        method: method,
        timestamp: 0,
      ),
    );
  }

  @override
  Stream<Event> get onStdoutEvent => _stdoutController.stream;

  @override
  Stream<Event> get onStderrEvent => _stderrController.stream;

  /// Emit a `Stdout` event carrying [text], encoded the way the VM does.
  void emitStdoutEvent(String text) {
    _stdoutController.add(_logEvent(EventKind.kWriteEvent, text));
  }

  /// Emit a `Stderr` event carrying [text].
  void emitStderrEvent(String text) {
    _stderrController.add(_logEvent(EventKind.kWriteEvent, text));
  }

  Event _logEvent(String kind, String text) => Event(
    kind: kind,
    timestamp: 0,
  )..bytes = base64.encode(utf8.encode(text));

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
    // A turn later, for the reason [dispose] defers it: this is the *same*
    // route. `package:vm_service` reaches `onDone` only from the end of
    // `dispose()`, and a closed input stream gets there by calling `dispose()`
    // — so a socket that dies cannot possibly complete `onDone` in the same
    // turn it stopped answering RPCs. Firing it inline here while [dispose]
    // defers it would make the two ways of dying disagree, and every
    // close-ordering test in the suite would run on the one the wire cannot
    // produce.
    unawaited(Future(_markDone));
  }

  /// Complete [onDone], as the real `VmService` does at the end of `dispose()`.
  ///
  /// Both a socket close and an explicit `dispose()` reach it there — the
  /// constructor wires the input stream's `onDone` to `dispose` — so both of
  /// this fake's ways of dying have to complete it, or a test would be
  /// simulating a connection state the wire cannot produce.
  void _markDone() {
    if (!_onDone.isCompleted) _onDone.complete();
  }

  final Completer<void> _onDone = Completer<void>();

  @override
  Future<void> get onDone => _onDone.future;

  /// Refuse an RPC on a connection that is gone, the way the real client does.
  ///
  /// Called from a *non-async* wrapper on every RPC, so the throw reaches the
  /// caller synchronously. That is not a detail: `VmService._call` is an
  /// ordinary `Future`-returning method, not an `async` one, and every endpoint
  /// is `Future<X> foo() => _call('foo')` (`vm_service-15.2.0`:1426, :1948),
  /// so a disposed connection throws *out of the call itself* rather than
  /// returning a rejected future: `svc.getVM()` on a disposed service throws
  /// before it can return anything to assign.
  ///
  /// An `async` fake could only ever produce a rejected future — a shape the
  /// wire cannot produce — which silently converts a synchronous throw the
  /// caller never guarded into one an enclosing `await` politely catches.
  ///
  /// The code is -32000 (`kServerError`), *not* the -32010
  /// `RPCErrorKind.kConnectionDisposed` the same enum defines: that constant
  /// exists but no code path in the package uses it for this. Both routes to a
  /// dead connection — explicit `dispose()` and a closed input stream — answer
  /// -32000, and `_isConnectionDisposed` keys on that code plus the message.
  void _checkAlive(String method) {
    if (_killed) {
      throw RPCError(method, -32000, 'Service connection disposed');
    }
  }

  @override
  Future<VM> getVM() {
    _checkAlive('getVM');
    return _getVM();
  }

  Future<VM> _getVM() async {
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
  }) {
    _checkAlive('reloadSources');
    return _reloadSources(isolateId);
  }

  Future<ReloadReport> _reloadSources(String isolateId) async {
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
      _extController.add(
        Event(
          kind: EventKind.kExtension,
          extensionKind: 'Flutter.Error',
          extensionData: ExtensionData.parse({
            'renderedErrorText': flutterErrorText,
          }),
          timestamp: 0,
        ),
      );
    }
    return ReloadReport(success: reloadSuccess);
  }

  /// Track extension call args.
  Map<String, dynamic>? lastExtensionArgs;

  /// Every `callServiceExtension`, in call order.
  ///
  /// `lastExtensionArgs` cannot answer questions about a sequence, and an
  /// asset reload is a sequence: one evict per changed archive path, then a
  /// reassemble. A test that can only see the last call cannot tell an evict
  /// of three assets from an evict of one.
  final List<({String method, Map<String, dynamic>? args})> extensionCalls = [];

  /// Every `callMethod`, in call order — the non-`ext.` half of the same
  /// picture (`_flutter.setAssetBundlePath`, `_flutter.reloadAssetFonts`).
  final List<({String method, String? isolateId, Map<String, dynamic>? args})>
  methodCalls = [];

  /// Simulated toggle state per extension method.
  final Map<String, bool> _toggleState = {};

  /// Errors [callServiceExtension] throws instead of answering, by method.
  ///
  /// This is what an app *refusing* looks like from the client side. A handler
  /// that returns `ServiceExtensionResponse.error` — every `_err` in
  /// `agent_extensions/agent.dart`, so every "no widget matched" and every
  /// `waitFor` timeout — crosses the VM service as a JSON-RPC error, and
  /// `package:vm_service` completes the call with a throw rather than a
  /// response. A fake that can only answer cannot stand in for that.
  final Map<String, RPCError> extensionErrors = {};

  /// The payload [callServiceExtension] answers with, by method. Lets one fake
  /// be told apart from another by what its app says.
  final Map<String, Map<String, dynamic>> extensionResponses = {};

  @override
  Future<Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) {
    _checkAlive(method);
    return _callServiceExtension(method, isolateId, args);
  }

  Future<Response> _callServiceExtension(
    String method,
    String? isolateId,
    Map<String, dynamic>? args,
  ) async {
    callServiceExtensionCalled = true;
    lastExtensionMethod = method;
    lastIsolateId = isolateId;
    lastExtensionArgs = args;
    extensionCalls.add((method: method, args: args));
    if (callServiceExtensionGate != null) {
      await callServiceExtensionGate!.future;
      _checkAlive(method);
    }
    // After the gate, because the gate stands in for an isolate that cannot
    // answer at all: a paused app owes no reply, not even a refusal, and a
    // throw ahead of the gate would let the wedged call complete.
    if (extensionErrors[method] case final error?) throw error;
    if (extensionResponses[method] case final body?) {
      return Response()..json = {...body};
    }

    // Mirror real Flutter: reassemble triggers a rebuilt frame whose
    // `Flutter.Frame` timing event is posted *after* the reassemble RPC
    // response (i.e. a later turn here), so it lands after the client's
    // apply() returns — the success terminator for `_applyAndVerify`.
    if (method == 'ext.flutter.reassemble') {
      Future<void>(() {
        if (!_extController.isClosed) {
          _extController.add(
            Event(
              kind: EventKind.kExtension,
              extensionKind: 'Flutter.Frame',
              extensionData: ExtensionData.parse({'number': 1}),
              timestamp: 0,
            ),
          );
        }
      });
    }

    if (method == '_createDevFS' && devFSUri != null) {
      return Response()..json = {'uri': devFSUri};
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
    final response = Response()..json = {'enabled': enabled.toString()};
    return response;
  }

  /// Errors [callMethod] throws instead of answering, by method — the
  /// `_flutter.*` half of [extensionErrors].
  ///
  /// The engine answers its own failures this way: an unroutable call gets
  /// `-32000 "Service protocol could not handle or find a handler for the
  /// requested method."`, and a shell that is going down gets
  /// `-32000 "Service protocol unavailable."` (`runtime/service_protocol.cc`).
  final Map<String, RPCError> methodErrors = {};

  /// The views `_flutter.listViews` reports, in order, each paired with the
  /// isolate at the same index in [isolates].
  ///
  /// More than one is the multi-window case. The engine registers one
  /// service-protocol handler per shell and answers `listViews` from all of
  /// them (`runtime/service_protocol.cc`), so a restart is a loop over views
  /// and can fail partway through it.
  List<String> viewIds = const ['view-1'];

  /// Errors `_flutter.runInView` throws instead of restarting, by view id.
  ///
  /// The engine's own failures, verbatim: a shell that refused the
  /// configuration answers `-32000 "Could not run configuration in engine."`
  /// (`shell/common/shell.cc`), and a view whose shell has gone answers
  /// `-32000 "Service protocol could not handle or find a handler for the
  /// requested method."` — the code a disposed connection uses, which is why
  /// the client tells them apart by message.
  final Map<String, RPCError> runInViewErrors = {};

  /// The view ids `_flutter.runInView` (hot restart's main re-run) was called
  /// for, in order.
  final List<String> runInViewCalls = [];

  /// True once any view was restarted.
  bool get runInViewCalled => runInViewCalls.isNotEmpty;

  /// The `pauseEvent.kind` [getIsolate] reports.
  ///
  /// Defaults to running (not paused) so hotRestart proceeds straight to
  /// runInView without resuming.
  String pauseKind = EventKind.kResume;

  /// Extension RPCs [getIsolate] reports as registered.
  ///
  /// Defaults to the framework's own, because this fake stands in for a
  /// running Flutter app and a running Flutter app has them. An empty default
  /// would make every fake an app whose framework never came up, which no test
  /// means. Clear it to model the startup window, where the app is up and the
  /// framework is not yet.
  List<String> extensionRPCs = const [
    'ext.flutter.evict',
    'ext.flutter.reassemble',
  ];

  /// If non-null, [getIsolate] fails with this instead of answering.
  ///
  /// A VM that refuses the read while staying otherwise connected — the case
  /// every `catch` around a `getIsolate` stands in for. [simulateDisposed]
  /// cannot reach it: it takes the whole connection down, so it cannot tell
  /// "this RPC failed" from "the connection is gone", and those lead different
  /// places.
  RPCError? getIsolateError;

  /// If non-null, [getIsolate] awaits this before answering or failing.
  ///
  /// Holds the read open across an isolate rotation, which is the only way to
  /// reach the window where a failed `getIsolate` describes an isolate the
  /// client has already stopped targeting.
  Completer<void>? getIsolateGate;

  /// The isolate ids [getIsolate] was asked about, in order.
  ///
  /// Recorded on entry, ahead of [getIsolateGate], so a read that is held open
  /// and never answered still counts — that is exactly what a caller which
  /// bounded the read and moved on leaves behind, and counting it is the only
  /// way to tell "asked and abandoned" from "never asked".
  final List<String> getIsolateCalls = [];

  @override
  Future<Isolate> getIsolate(String isolateId) async {
    _checkAlive('getIsolate');
    getIsolateCalls.add(isolateId);
    if (getIsolateGate != null) {
      await getIsolateGate!.future;
      _checkAlive('getIsolate'); // the gate may have outlived the connection
    }
    if (getIsolateError case final error?) throw error;
    return _getIsolate(isolateId);
  }

  Future<Isolate> _getIsolate(String isolateId) async {
    return Isolate(
      id: isolateId,
      pauseEvent: Event(kind: pauseKind, timestamp: 0),
      extensionRPCs: [...extensionRPCs],
    );
  }

  @override
  Future<Response> callMethod(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) {
    _checkAlive(method);
    return _callMethod(method, isolateId, args);
  }

  Future<Response> _callMethod(
    String method,
    String? isolateId,
    Map<String, dynamic>? args,
  ) async {
    methodCalls.add((method: method, isolateId: isolateId, args: args));
    if (callMethodGate != null) {
      await callMethodGate!.future;
      _checkAlive(method); // the gate may have outlived the connection
    }
    if (methodErrors[method] case final error?) throw error;
    // DWDS's hot restart, reachable bare or under a DDS namespace (`s0.`).
    // Without this branch the fall-through below would answer an empty
    // Response, making every restart pass while recording nothing.
    if (method == 'hotRestart' || method.endsWith('.hotRestart')) {
      hotRestartMethod = method;
      if (hotRestartGate != null) await hotRestartGate!.future;
      _checkAlive(method); // the gate may have outlived the connection
      if (hotRestartError != null) throw hotRestartError!;
      return Response()..json = Success().toJson();
    }
    if (method == '_flutter.listViews') {
      return Response()
        ..json = {
          'views': [
            for (var i = 0; i < viewIds.length; i++)
              {
                'type': 'FlutterView',
                'id': viewIds[i],
                if (i < isolates.length) 'isolate': {'id': isolates[i].id},
              },
          ],
        };
    }
    if (method == '_flutter.runInView') {
      final viewId = args?['viewId'] as String?;
      if (runInViewErrors[viewId] case final error?) throw error;
      runInViewCalls.add(viewId ?? '<no viewId>');
      // Mirror real Flutter: a build failure during the restarted frame posts
      // Flutter.Error before that frame's Flutter.Frame.
      if (emitFlutterErrorOnReload) {
        _extController.add(
          Event(
            kind: EventKind.kExtension,
            extensionKind: 'Flutter.Error',
            extensionData: ExtensionData.parse({
              'renderedErrorText': flutterErrorText,
            }),
            timestamp: 0,
          ),
        );
      }
      // The restarted isolate renders a frame after runInView returns.
      Future<void>(() {
        if (!_extController.isClosed) {
          _extController.add(
            Event(
              kind: EventKind.kExtension,
              extensionKind: 'Flutter.Frame',
              extensionData: ExtensionData.parse({'number': 1}),
              timestamp: 0,
            ),
          );
        }
      });
      return Response()..json = {};
    }
    return Response()..json = {};
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    // Synchronously, before the first await: the real `VmService.dispose()`
    // sets `_disposed = true` as its opening statement and only then awaits
    // its stream cancel and dispose handler (`vm_service-15.2.0`:1915-1919),
    // so an RPC issued *during* a dispose already throws: a `getVM()` from
    // inside a `disposeHandler`, which runs before dispose()'s own future
    // completes, throws -32000. A fake that stays answerable
    // across its own teardown lets code that talks to a connection it has
    // already torn down pass here, which is the shape the wire cannot produce.
    _killed = true;
    // A turn later, not inline: the real client's `onDone` listener runs
    // *after* the caller's own continuation of `dispose()` has finished — the
    // service field is already null and the connect attempt has already moved
    // on. A fake that fires it inline lets a
    // client which reads that state to tell a hang-up from a death pass here
    // and re-dial a connection the wire had already torn down.
    unawaited(Future(_markDone));
    await _extController.close();
    await _stdoutController.close();
    await _stderrController.close();
    await _serviceController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '${invocation.memberName} not implemented in FakeVmService',
    );
  }
}

/// A [VmServiceClient] connector that serves [service] while it is alive and
/// refuses once it is gone.
///
/// `(_) async => fake` — serving the *same* object on every dial — is the shape
/// to avoid, and it is not a shortcut but a fiction: the real connector
/// (`vmServiceConnectUri`) either completes a **fresh, live** connection or
/// throws. It can never hand back one that has already been disposed.
///
/// The client believes it, and the belief is expensive. [VmServiceClient] wires
/// `_watchForClose` to every connection it publishes; re-publishing a corpse
/// subscribes to an `onDone` that has *already* completed, so the watcher fires
/// at once, redials, gets the same corpse, and fires again, without end.
///
/// Refusing is what dialling a VM service that is gone actually does, and it
/// lets the client reach the conclusion it is written to reach — the dial
/// throws, `_reconnect` drops the dead service, and the app is reported gone.
Future<VmService> Function(String) connectorFor(FakeVmService service) =>
    (_) async {
      if (service.isGone) {
        throw const SocketException('Connection refused');
      }
      return service;
    };

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

  /// One entry per [compileFull], carrying what the caller declared changed.
  /// A restart re-reads the tree regardless, but the set is recorded so a test
  /// can assert the restart path still hands it down — it is what the real
  /// compiler's `reset` + `recompile` sends on the wire.
  final List<RecompileCall> fullCompileCalls = [];

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
  Future<CompileOutcome> compileFull({
    required String entrypoint,
    required Set<String> invalidated,
  }) async {
    fullCompileCalls.add(RecompileCall(entrypoint, invalidated));
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

/// One compiled library as it exists in some kernel image.
///
/// [own] is the library's own source version. [inlined] is the version of each
/// library whose *contents* this one compiled into itself — a `const` from
/// another library, the case that makes a byte-unchanged file stale. Two images
/// of the same library differ when either half differs, which is exactly what
/// a per-file source-version record cannot express.
class LibImage {
  final int own;
  final Map<String, int> inlined;
  const LibImage({required this.own, this.inlined = const {}});

  @override
  bool operator ==(Object other) =>
      other is LibImage &&
      other.own == own &&
      other.inlined.length == inlined.length &&
      other.inlined.entries.every((e) => inlined[e.key] == e.value);

  @override
  int get hashCode => Object.hash(own, inlined.length);

  @override
  String toString() => inlined.isEmpty ? 'v$own' : 'v$own(inlined: $inlined)';
}

/// The one source tree every compiler in a test reads — the analogue of disk.
///
/// Separate from the compilers on purpose: production has one filesystem and N
/// frontend_servers, each with its own accepted baseline, and what this models
/// lives precisely in that asymmetry.
class FakeSourceTree {
  /// Current source version of each library, by `package:` URI.
  final Map<String, int> versions = {};

  /// `lib -> the libraries whose contents it inlines`. An edit to a library in
  /// this set changes the *compiled output* of the key, without changing the
  /// key's own source bytes.
  final Map<String, Set<String>> inlines = {};

  /// Every delta any compiler has emitted, by dill path. Shared so a test can
  /// reconstruct what an app is running from the dills it applied, whichever
  /// compiler produced them.
  final Map<String, Map<String, LibImage>> deltaByDill = {};

  int _dillSeq = 0;

  /// Register a library at version 1, optionally inlining from [inlinesFrom].
  void add(String uri, {Set<String> inlinesFrom = const {}}) {
    versions[uri] = 1;
    if (inlinesFrom.isNotEmpty) inlines[uri] = {...inlinesFrom};
  }

  /// Change [uri]'s source bytes.
  void edit(String uri) => versions[uri] = (versions[uri] ?? 0) + 1;

  /// The libraries whose compiled output depends on [uri]'s contents,
  /// transitively. [uri] itself is not included.
  Set<String> dependentsOf(String uri) {
    final found = <String>{};
    final queue = <String>[uri];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final entry in inlines.entries) {
        if (entry.value.contains(current) && found.add(entry.key)) {
          queue.add(entry.key);
        }
      }
    }
    return found;
  }

  /// [uri] compiled against the tree as it stands now.
  LibImage imageOf(String uri) => LibImage(
    own: versions[uri]!,
    inlined: {
      for (final dep in inlines[uri] ?? const <String>{}) dep: versions[dep]!,
    },
  );

  String recordDelta(Map<String, LibImage> emitted) {
    final path = '/tmp/fake_delta_${_dillSeq++}.dill';
    deltaByDill[path] = emitted;
    return path;
  }
}

/// A [Compiler] that models the one CFE behaviour this design turns on:
/// **dependents are recomputed relative to the compiler's own accepted state.**
///
/// Verified against the real frontend_server before being written down:
///
///  * An explicitly invalidated URI is re-emitted even when its content is
///    byte-identical to what this compiler already accepted.
///  * Invalidating a URI whose content *changed since this compiler's accepted
///    state* also re-emits the libraries that inline from it.
///  * Invalidating a URI whose content already matches the accepted state does
///    **not** re-emit those dependents — the compiler believes they are current.
///
/// That last rule is why a shared compiler cannot serve independently-targeted
/// apps: once one app's reload is accepted, no later invalidation can make the
/// compiler re-derive the dependents a lagging app never received, and no
/// per-file source-version record can even name them.
class DependencyFakeCompiler implements Compiler {
  final FakeSourceTree tree;

  /// This compiler's committed baseline — what it believes its app is running.
  final Map<String, LibImage> accepted = {};

  Map<String, LibImage>? _pending;

  final List<RecompileCall> recompileCalls = [];
  final List<RecompileCall> fullCompileCalls = [];
  int commitCount = 0;
  int rollbackCount = 0;
  int shutdownCount = 0;

  DependencyFakeCompiler(this.tree);

  /// Accept the whole tree as this compiler's starting baseline, the way an
  /// assembled session begins after its initial compile.
  void seedFromTree() {
    accepted
      ..clear()
      ..addAll({
        for (final uri in tree.versions.keys) uri: tree.imageOf(uri),
      });
  }

  @override
  Future<CompileOutcome> compileIncrement({
    required Set<String> invalidated,
    required String entrypoint,
  }) async {
    recompileCalls.add(RecompileCall(entrypoint, invalidated));
    final emitted = <String, LibImage>{};
    for (final uri in invalidated) {
      if (!tree.versions.containsKey(uri)) continue;
      emitted[uri] = tree.imageOf(uri);
      // Only a library that moved *relative to this compiler's baseline* drags
      // its dependents along, which is what this fake models.
      if (accepted[uri]?.own != tree.versions[uri]) {
        for (final dependent in tree.dependentsOf(uri)) {
          emitted[dependent] = tree.imageOf(dependent);
        }
      }
    }
    _pending = {...accepted, ...emitted};
    return CompileSucceeded(tree.recordDelta(emitted));
  }

  @override
  Future<CompileOutcome> compileFull({
    required String entrypoint,
    required Set<String> invalidated,
  }) async {
    fullCompileCalls.add(RecompileCall(entrypoint, invalidated));
    final emitted = {
      for (final uri in tree.versions.keys) uri: tree.imageOf(uri),
    };
    _pending = {...emitted};
    return CompileSucceeded(tree.recordDelta(emitted));
  }

  @override
  Future<void> commit() async {
    commitCount++;
    final pending = _pending;
    if (pending != null) {
      accepted
        ..clear()
        ..addAll(pending);
    }
    _pending = null;
  }

  @override
  Future<void> rollback() async {
    rollbackCount++;
    _pending = null;
  }

  @override
  Future<void> shutdown() async {
    shutdownCount++;
  }
}

/// What [app] is actually running: its launch image, with every kernel it
/// applied folded in.
///
/// A hot restart replaces the image outright (the app re-reads a full dill); a
/// hot reload overlays the delta onto what was already there. Reading this is
/// how a test sees a stale library that no source-version record can flag.
Map<String, LibImage> liveImageOf(
  FakeAppInstance app, {
  required FakeSourceTree tree,
  required Map<String, LibImage> launchedWith,
}) {
  var image = {...launchedWith};
  for (final call in app.calls) {
    final delta = tree.deltaByDill[call.dillPath] ?? const <String, LibImage>{};
    image = call.mode == ApplyMode.hotRestart
        ? {...delta}
        : {...image, ...delta};
  }
  return image;
}

/// Hands out [FakeMDnsClient]s and counts them.
///
/// Discovery builds a fresh client per query attempt, so "answer on the Nth
/// attempt" — the property that proves retransmission works — is a fact about
/// the factory, not about any one client. Pass [call] as the
/// `MDnsClientFactory`.
class FakeMDnsClientFactory {
  /// Records handed to each client, by `(ResourceRecordType, name)`.
  final Map<(int, String), List<ResourceRecord>> records;

  /// Thrown from [MDnsClient.start], for the denied-permission path.
  final Object? startError;

  /// Number of leading attempts that answer with nothing.
  final int silentAttempts;

  final clients = <FakeMDnsClient>[];

  FakeMDnsClientFactory({
    Map<(int, String), List<ResourceRecord>>? records,
    this.startError,
    this.silentAttempts = 0,
  }) : records = records ?? const {};

  MDnsClient call() {
    final client = FakeMDnsClient(
      records: clients.length < silentAttempts ? const {} : records,
      startError: startError,
    );
    clients.add(client);
    return client;
  }
}

/// An [MDnsClient] that answers from a canned record set.
///
/// Records are keyed the way the real client's cache is — by the query's
/// resource-record type and fully-qualified name — so a test describes an
/// advertisement the same way a responder does: one PTR under the service
/// type, and SRV/TXT/A records under the instance name.
class FakeMDnsClient implements MDnsClient {
  final Map<(int, String), List<ResourceRecord>> records;
  final Object? startError;

  bool started = false;
  bool stopped = false;

  FakeMDnsClient({
    Map<(int, String), List<ResourceRecord>>? records,
    this.startError,
  }) : records = records ?? const {};

  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {
    if (startError != null) throw startError!;
    started = true;
  }

  @override
  void stop() => stopped = true;

  @override
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    final matches =
        records[(query.resourceRecordType, query.fullyQualifiedName)] ??
        const <ResourceRecord>[];
    return Stream.fromIterable(matches.whereType<T>());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '${invocation.memberName} not implemented in FakeMDnsClient',
    );
  }
}

/// A `_dartVmService._tcp` advertisement, as a responder would answer it.
///
/// Returns the record map [FakeMDnsClient] expects.
Map<(int, String), List<ResourceRecord>> dartVmServiceRecords({
  required String instance,
  required String host,
  required int port,
  String? authCode,
  List<String> addresses = const [],
}) {
  const validUntil = 1 << 40;
  final service = '$instance.$dartVmServiceMdnsName';
  return {
    (ResourceRecordType.serverPointer, dartVmServiceMdnsName): [
      PtrResourceRecord(dartVmServiceMdnsName, validUntil, domainName: service),
    ],
    (ResourceRecordType.service, service): [
      SrvResourceRecord(
        service,
        validUntil,
        target: host,
        port: port,
        priority: 0,
        weight: 0,
      ),
    ],
    if (authCode != null)
      (ResourceRecordType.text, service): [
        TxtResourceRecord(service, validUntil, text: 'authCode=$authCode'),
      ],
    if (addresses.isNotEmpty)
      (ResourceRecordType.addressIPv4, host): [
        for (final a in addresses)
          IPAddressResourceRecord(
            host,
            validUntil,
            address: InternetAddress(a),
          ),
      ],
  };
}
