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
/// Why no acquisition timeout? Because a deadline at the dispatch layer
/// would hide the real bug (an unbounded operation) and make concurrency
/// reasoning fragile. With every handler bounded, the pool is provably
/// free of deadlock and the contract is one short sentence: "every
/// command finishes."
import 'dart:async';

import 'package:pool/pool.dart';

import 'command_failure.dart';

/// Handler signature for a registered command.
typedef CommandHandler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params);

/// Told that a long-running command was received and, later, that it ended.
///
/// [id] pairs the two. Injected rather than reached for, so `CommandRunner`
/// stays ignorant of the machine protocol it usually reports through.
typedef CommandProgress =
    void Function(
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
class CommandRunner {
  final _handlers = <String, CommandHandler>{};
  final _slow = <String>{};
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

  CommandRunner({this.onProgress, this.onCommandsChanged});

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
  void register(
    String method,
    CommandHandler handler, {
    bool longRunning = false,
  }) {
    _handlers[method] = handler;
    if (longRunning) {
      _slow.add(method);
    } else {
      _slow.remove(method);
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
    // Announced before the pool is requested, not after it is granted: a
    // command queued behind one that never finishes has also not started, and
    // that is exactly the state worth being able to see.
    final report = _slow.contains(method) ? onProgress : null;
    final id = 'cmd_${_nextProgressId++}';
    report?.call(method, params, id, finished: false);
    final resource = await _pool.request();
    try {
      return await handler(params);
    } finally {
      resource.release();
      report?.call(method, params, id, finished: true);
    }
  }

  /// Whether [method] has a registered handler.
  bool hasCommand(String method) => _handlers.containsKey(method);
}
