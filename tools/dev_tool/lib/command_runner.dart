/// Serialized command dispatch for the dev tool.
///
/// All command sources (stdin machine protocol, HTTP control channel,
/// keyboard, file watcher) go through [CommandRunner] to ensure
/// serialization — the frontend server and VM service aren't safe for
/// concurrent access.
///
/// ## Bounded-handler contract
///
/// `CommandRunner` is `Pool(1)`-serialized: at most one handler runs at a
/// time, and the next handler does not start until the current one
/// completes. Strict whole-command serialization is the simplest
/// invariant to reason about for a developer-tool dispatch surface.
///
/// **Every handler registered with [register] must complete in finite
/// time.** This is not enforced by `CommandRunner` itself — there is no
/// acquisition timeout, no escape hatch. Safety comes from upstream:
/// every I/O the handler performs is itself bounded, so the handler
/// always returns. If a future handler relies on unbounded I/O (a network
/// request, a VM-service RPC, a process invocation), wrap that I/O in a
/// `.timeout(...)` *at its own boundary* — `AppInstance.applyKernel`,
/// `VmServiceReloadStrategy`'s per-device apply and `VmServiceClient.connect`
/// are the production examples — so the handler's completion is structurally
/// guaranteed. `connect` is on that list because it is where every other
/// VM-service call lands after a dropped connection: an untimed reconnect makes
/// every command that touches the client unbounded, whatever its own boundary
/// says.
///
/// The one exception is a compile. `FrontendServer` bounds its wait on the
/// compiler's idleness, not on wall time, so that a slow compile on a loaded
/// machine finishes; a compiler that loops without answering holds the pool
/// for as long as it runs.
///
/// Why no acquisition timeout? Because a deadline at the dispatch layer
/// would hide the real bug (an unbounded operation) and make concurrency
/// reasoning fragile. With every handler bounded, the pool is provably
/// free of deadlock and the contract is one short sentence: "every
/// command finishes."
///
/// ## Ending the run is not queued
///
/// "Finishes" can still mean minutes: a reload sent during startup waits for
/// the startup, and one behind a rebuild waits for the build. A command that
/// ends the run must not wait behind that, so it is registered with
/// `control: true` and runs at once, outside the pool. Once the run starts to
/// end ([CommandRunner.stopping]), every other command that is queued or
/// running is answered with [CommandFailure.shuttingDown] at that moment rather
/// than when its work would have finished, and a command sent after that is
/// refused the same way without being started.
import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pool/pool.dart';

import 'command_failure.dart';
import 'phase_log.dart';

/// Handler signature for a registered command.
typedef CommandHandler = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> params,
);

/// Told that a long-running command was received and, later, that it ended.
///
/// [id] pairs the two. Injected rather than reached for, so `CommandRunner`
/// stays ignorant of the machine protocol it usually reports through.
typedef CommandProgress = void Function(
  String method,
  Map<String, dynamic> params,
  String id, {
  required bool finished,
});

/// Serializes command execution through a single-resource pool.
///
/// Transports (MachineProtocol, HttpControlChannel, keyboard, file watcher)
/// all call [run] to execute commands. The pool ensures only one command
/// executes at a time.
final _logger = Logger('dev_tool.command_runner');

class CommandRunner {
  final _handlers = <String, CommandHandler>{};
  final _slow = <String>{};
  final _control = <String>{};
  final _pool = Pool(1);
  var _nextProgressId = 0;

  /// Reports the start and end of the commands registered as long-running.
  final CommandProgress? onProgress;

  /// Called when the set of commands a client can call has changed.
  ///
  /// Coalesced: a burst of registrations in one turn of the event loop
  /// produces one call, because `registerAgentCommands` registers eleven
  /// commands in a loop and eleven announcements would describe one moment.
  /// Silent when a registration replaces a handler without changing what a
  /// client sees — the WASM assembler shadows `app.restart` and
  /// `app.hotReload` with its own after launch, and that is not news to a
  /// caller.
  final void Function()? onCommandsChanged;

  /// The last surface announced, so a replacement that changes nothing a
  /// client could observe stays quiet.
  List<Map<String, Object>>? _announced;
  var _announcementScheduled = false;

  /// Completes when the run starts to end. See the library comment: from then
  /// on, every command but a control one is answered as shutting down.
  final Future<void>? stopping;
  var _stopped = false;

  /// One per wait in progress on [stopping], each removed when its wait ends.
  ///
  /// [stopping] itself is listened to once, here. A listener added to it per
  /// command would stay on it until the run ends: every reload and every
  /// `app.*` call of a run that lasts all day.
  final _stopWaits = <Completer<void>>{};

  CommandRunner({this.onProgress, this.onCommandsChanged, this.stopping}) {
    stopping?.then((_) {
      _stopped = true;
      for (final wait in [..._stopWaits]) {
        wait.complete();
      }
      _stopWaits.clear();
    });
  }

  /// Every command registered right now, sorted by name.
  ///
  /// Sorted so a client diffing two listings sees real changes rather than
  /// registration order, and carrying [longRunning] because that is what a
  /// caller needs to choose a timeout — the same fact `app.progress` is
  /// emitted from.
  List<Map<String, Object>> describe() => [
    for (final name in _handlers.keys.toList()..sort())
      {'name': name, 'longRunning': _slow.contains(name)},
  ];

  /// Whether [name] is a command this run offers.
  ///
  /// Asked where a structural absence and a transient one look alike: the
  /// `app.*` surface is registered for every run that has a VM service to reach
  /// and for none that does not, so its presence answers "will this app ever be
  /// askable" without anyone re-deriving it from the run's shape.
  bool knows(String name) => _handlers.containsKey(name);

  /// Record the current surface as already communicated.
  ///
  /// Called after `daemon.connected` carries the list, so the next
  /// announcement is only made if something has actually changed since. The
  /// alternative is a first `daemon.commandsChanged` that repeats what the
  /// connect event just said.
  void markAnnounced() => _announced = describe();

  /// Announce the surface once this turn, if it has actually moved.
  void _scheduleAnnouncement() {
    if (onCommandsChanged == null || _announcementScheduled) return;
    _announcementScheduled = true;
    scheduleMicrotask(() {
      _announcementScheduled = false;
      final current = describe();
      if (_announced != null && _sameSurface(_announced!, current)) return;
      _announced = current;
      onCommandsChanged!();
    });
  }

  static bool _sameSurface(
    List<Map<String, Object>> a,
    List<Map<String, Object>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i]['name'] != b[i]['name']) return false;
      if (a[i]['longRunning'] != b[i]['longRunning']) return false;
    }
    return true;
  }

  /// Register a command handler for [method].
  ///
  /// [longRunning] marks a command whose start is worth announcing: a reload
  /// or a restart, which rebuild and recompile before they can answer. Without
  /// it their only communication is the response, so one that never finishes is
  /// indistinguishable from one that was never received. Short commands stay
  /// quiet; an event per `app.getText` would be noise.
  ///
  /// [control] marks a command that ends the run, or one app of it: it runs at
  /// once, beside whatever holds the queue, because waiting behind a reload is
  /// waiting on work the command is about to make pointless. Its handler must
  /// be safe to run concurrently with any other.
  void register(
    String method,
    CommandHandler handler, {
    bool longRunning = false,
    bool control = false,
  }) {
    _handlers[method] = handler;
    if (longRunning) {
      _slow.add(method);
    } else {
      _slow.remove(method);
    }
    if (control) {
      _control.add(method);
    } else {
      _control.remove(method);
    }
    _scheduleAnnouncement();
  }

  /// Execute [method] with [params], serialized through the pool.
  ///
  /// Throws [CommandFailure] if [method] is not registered — the same type
  /// every other refusal uses, so a transport renders one thing.
  Future<Map<String, dynamic>> run(
    String method,
    Map<String, dynamic> params,
  ) async {
    final handler = _handlers[method];
    if (handler == null) {
      // Names where the real list is, because absence here is often correct
      // rather than a typo: a command can be genuinely unavailable on this
      // device — `app.setViewport` exists only on a web run — and a bare
      // "unknown" reads as "no such feature" instead of "not on this run".
      throw CommandFailure.notFound(
        'Unknown command: $method. This run offers '
        '${_handlers.keys.toList()..sort()}. The current list is also on '
        '`GET /commands`, on `daemon.connected`, and on every '
        '`daemon.commandsChanged` event.',
      );
    }
    if (_control.contains(method)) return handler(params);
    if (_stopped) {
      throw CommandFailure.shuttingDown(
        'The run is shutting down, so $method was not run.',
      );
    }
    // Announced before the pool is requested, not after it is granted: a
    // command queued behind one that never finishes has also not started, and
    // that is exactly the state worth being able to see.
    final slow = _slow.contains(method);
    final report = slow ? onProgress : null;
    final id = 'cmd_${_nextProgressId++}';
    report?.call(method, params, id, finished: false);
    // Said in the log as well, because the event above is sent before this
    // command has the queue: a reload that is waiting behind a stuck command
    // and one that is slow to run are otherwise the same silence.
    final queued = Stopwatch()..start();
    final ahead = _active;
    if (slow && ahead != null) {
      logPhase(
        verb: method,
        phase: 'queue',
        event: 'waiting',
        text:
            '$method is waiting for the command queue: ${ahead.method} has '
            'been running for ${formatElapsed(ahead.since.elapsed)}',
      );
    }
    final request = _pool.request();
    final PoolResource resource;
    try {
      resource = await _orStopping(request);
    } on _Stopping {
      // Granted later to nobody; given straight back so the queue behind it
      // keeps moving for whatever still runs during the teardown.
      unawaited(request.then((r) => r.release()));
      report?.call(method, params, id, finished: true);
      throw CommandFailure.shuttingDown(
        'The run is shutting down, so $method was not run.',
      );
    }
    _active = (method: method, since: Stopwatch()..start());
    if (slow) {
      logPhase(
        verb: method,
        phase: 'queue',
        event: 'finished',
        text: '$method: queue acquired after ${formatElapsed(queued.elapsed)}',
        took: queued.elapsed,
      );
    }
    final work = handler(params);
    var abandoned = false;
    try {
      return await _orStopping(work);
    } on _Stopping {
      abandoned = true;
      // The handler goes on under the teardown and ends however the teardown
      // leaves it. Its ending is logged rather than left unhandled, and the
      // queue is released only then, so nothing overlaps it.
      _abandoned(method, work, resource);
      throw CommandFailure.shuttingDown(
        'The run is shutting down, so $method was abandoned before it '
        'finished.',
      );
    } finally {
      if (!abandoned) {
        _active = null;
        resource.release();
      }
      report?.call(method, params, id, finished: true);
    }
  }

  /// [work], unless the run starts to end first, in which case a [_Stopping].
  Future<T> _orStopping<T>(Future<T> work) {
    if (stopping == null) return work;
    if (_stopped) return Future.error(const _Stopping());
    // Sync, so the wait ends in the turn [stopping] completes, as a listener
    // on it directly would: a handler that the same shutdown answers must not
    // get its answer in first.
    final stop = Completer<void>.sync();
    _stopWaits.add(stop);
    return Future.any<T>([
      work,
      stop.future.then<T>((_) => throw const _Stopping()),
    ]).whenComplete(() => _stopWaits.remove(stop));
  }

  /// How many waits on [stopping] are in progress. For tests: it returns to
  /// zero whenever no command is waiting or running.
  int get pendingStopWaits => _stopWaits.length;

  void _abandoned(
    String method,
    Future<Map<String, dynamic>> work,
    PoolResource resource,
  ) {
    unawaited(
      work
          .then<void>(
            (_) {},
            onError: (Object e) => _logger.fine({
              'message': 'abandoned_command_ended',
              'text': '$method, abandoned at shutdown, ended with: $e',
              'error': '$e',
            }),
          )
          .whenComplete(() {
            _active = null;
            resource.release();
          }),
    );
  }

  /// The command holding the pool, and since when. Read by a command that has
  /// to wait, so its log can say what it is waiting for.
  ({String method, Stopwatch since})? _active;

  /// Whether [method] has a registered handler.
  bool hasCommand(String method) => _handlers.containsKey(method);
}

/// The run started to end while a command waited or ran. Private, so a
/// handler's own failure can never be mistaken for it.
class _Stopping implements Exception {
  const _Stopping();
}
