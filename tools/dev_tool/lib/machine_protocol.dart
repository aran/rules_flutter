/// JSON-RPC machine protocol for IDE integration.
///
/// When the dev tool is invoked with `--machine`, it speaks the same
/// protocol as `flutter run --machine` over stdin/stdout. This enables
/// VS Code, IntelliJ, and other IDEs to control the dev tool.
///
/// Events (tool → IDE):
///   daemon.connected   — daemon is ready (version info)
///   app.start          — app is launching
///   app.debugPort      — VM service URI available
///   app.webLaunchUrl   — where a web run's app is served, and whether this
///                        tool opened a browser on it. Upstream's event and
///                        upstream's `url`/`launched` fields
///                        (`web_device.dart:150`), with `appId` added the way
///                        upstream's daemon adds it to every `app.*`. It is
///                        the only announcement of that URL: the browser this
///                        tool launches is its own profile — often headless —
///                        so someone wanting to look at the page themselves has
///                        nowhere else to read the address.
///   app.devTools       — the DevTools URL for this app, once it can be
///                        served. Upstream's event and upstream's `uri` field.
///                        Under `--machine` this is the only way it is
///                        offered: the JSON log format strips the human `text`
///                        field by design, so a structured client would
///                        otherwise be told the URL existed and never told what
///                        it was.
///   app.started        — `main()` has begun running, or the app is paused
///                        before it under `--start-paused`. That is what
///                        upstream's daemon protocol means by this event and
///                        what we mean by it. It is not a claim that the app
///                        has painted or can be driven: on a physical device
///                        the two are a minute apart. A command issued in that
///                        window waits it out rather than failing — see
///                        `DeviceSession.drivable` — and the wait is reported
///                        as `app.progress` while it lasts.
///   app.log            — one line of the app's console output. `error` is
///                        true for lines from an error channel (the process's
///                        stderr, a VM-service `Stderr` event, `console.error`).
///                        In machine mode this is the *only* way app output is
///                        surfaced: writing it to raw stdout would interleave
///                        non-JSON text into this protocol stream.
///   app.progress       — build/reload progress updates
///   app.reloadResult   — the outcome of a reload nobody requested: the
///                        filesystem watcher picked up an edit, or a terminal
///                        user pressed a key. `params` is `{method, result}`,
///                        where `method` is the command it is the outcome of
///                        (`app.hotReload`, `app.restart`) and `result` is
///                        exactly the map that command's response would carry
///                        — so a client parses one shape either way. Emitted
///                        for failures too, since silence is otherwise
///                        indistinguishable from a dead watcher.
///   app.stop           — app has stopped
///
/// Commands (IDE → tool):
///   app.hotReload          — hot reload
///   app.restart            — hot restart. `fullRestart: false` asks for a
///                            reload through this command, which is what a
///                            `flutter run`-shaped client sends.
///   app.stop               — stop the app
///   daemon.shutdown        — shut down the dev tool
///
/// Plus the `app.*` agent surface — `app.tap`, `app.getText`,
/// `app.dumpWidgetTree`, `app.buildInfo` and the rest — registered by
/// `setUpAgentCommands` in `agent_command.dart`, which is the list to read
/// rather than a copy of it here that would drift.
///
/// This list is the registry, not a wish. Dispatch below hands every method to
/// the [CommandRunner], which refuses an unregistered one by name and says what
/// this run does offer — so a name documented here and registered nowhere is a
/// promise the tool breaks the moment a client takes it up.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_failure.dart';
import 'command_runner.dart';

/// Machine-readable JSON protocol handler.
class MachineProtocol {
  final bool enabled;
  final IOSink _output;
  final Stream<String>? _inputLines;
  final CommandRunner? _commandRunner;
  int _nextId = 0;
  StreamSubscription<String>? _subscription;

  MachineProtocol({
    required this.enabled,
    CommandRunner? commandRunner,
    IOSink? output,
    Stream<String>? inputLines,
  }) : _commandRunner = commandRunner,
       _output = output ?? stdout,
       _inputLines = inputLines;

  /// Version of the event and command contract, not of the tool.
  ///
  /// Bumped when a client would have to be changed. It tells a client which
  /// of these events and fields it can expect without probing for them — the
  /// `commands` field on `daemon.connected` and the `daemon.commandsChanged`
  /// event arrived at 2; at 3 a failed command answers with upstream's
  /// `{"id": …, "error": "<reason>"}` rather than a JSON-RPC `{code, message}`
  /// object, and an app-side refusal answers there rather than inside
  /// `result`.
  static const protocolVersion = 3;

  /// Announce the command surface after it has changed.
  ///
  /// Wired to [CommandRunner.onCommandsChanged], which coalesces a burst of
  /// registrations into one call, so this is one event per moment the surface
  /// actually moves rather than one per `register`.
  void commandsChanged() {
    final runner = _commandRunner;
    if (runner == null) return;
    sendEvent('daemon.commandsChanged', {'commands': runner.describe()});
  }

  /// Start listening for commands on stdin.
  ///
  /// Also emits `daemon.connected` to signal readiness.
  void startListening() {
    if (!enabled) return;

    // Emit daemon.connected on startup.
    //
    // Carries the command surface, rather than leaving a client to ask for
    // it. A `--machine` client is the process that spawned this one, so it
    // reads stdout from the first byte and cannot miss this — there is no
    // late join and no reconnect. What it cannot do is *know to ask*, and a
    // discovery call it has to learn about from documentation is a worse
    // contract than one it is simply handed.
    //
    // Most of the surface is already here — `run` registers the reload,
    // lifecycle and agent commands before it starts listening, so a measured
    // web run reports 17 at this point. The rest still has to be announced:
    // the same run gained `app.setViewport` once Chrome was up, and a client
    // that read this list and stopped listening would not know about it.
    // Hence `daemon.commandsChanged`, which is a correctness requirement
    // rather than an optimisation.
    sendEvent('daemon.connected', {
      'version': '0.1.0',
      'protocolVersion': protocolVersion,
      'pid': pid,
      'commands': _commandRunner?.describe() ?? const [],
    });
    // What the client has just been told. Without this the first
    // `daemon.commandsChanged` restates the list above verbatim.
    _commandRunner?.markAnnounced();

    final lines =
        _inputLines ??
        stdin.transform(utf8.decoder).transform(const LineSplitter());
    _subscription = lines.listen(
      (line) async {
        try {
          final decoded = json.decode(line);
          // The Flutter machine protocol wraps commands in [...] arrays.
          final request =
              (decoded is List ? decoded.first : decoded)
                  as Map<String, dynamic>;
          final method = request['method'] as String?;
          final id = request['id'];
          final params = (request['params'] as Map<String, dynamic>?) ?? {};

          final runner = _commandRunner;
          if (method == null) {
            _sendError(id, 'No `method` field: nothing to run.');
          } else if (runner == null) {
            _sendError(id, 'This process registers no commands.');
          } else {
            try {
              // Dispatched without asking `hasCommand` first: the runner
              // refuses an unregistered method itself, with a message naming
              // what this run *does* offer. Checking here would produce a
              // second, barer message for the same condition.
              final result = await runner.run(method, params);
              _sendResponse(id, result);
            } on CommandFailure catch (e) {
              // The command's own no. Upstream's shape, so a client that
              // reads `error` off a `flutter run --machine` response reads
              // this one the same way.
              _sendError(id, e.message);
            } catch (e, stack) {
              _sendError(id, 'Internal error: $e', stack);
            }
          }
        } catch (e) {
          _sendError(null, 'Parse error: $e');
        }
      },
    );
  }

  /// Stop listening for commands on stdin.
  ///
  /// Releases the stdin subscription so the process can exit once the run
  /// is over — an uncancelled stdin listener keeps the VM alive forever.
  /// Safe to call from within a command handler: the in-progress handler
  /// (and its response) completes normally; only future input is ignored.
  Future<void> stopListening() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Send an event to the IDE.
  void sendEvent(String event, [Map<String, dynamic>? params]) {
    if (!enabled) return;
    _send({
      'event': event,
      if (params != null) 'params': params,
    });
  }

  /// Send app.start event.
  ///
  /// [supportsRestart] is what an IDE reads to decide whether to offer a
  /// restart button at all. A profile-mode web run — which has no VM service,
  /// no DWDS and no reload strategy — must not advertise a restart that could
  /// only ever answer with an error. Upstream computes the same field as
  /// `enableHotReload && device.supportsHotRestart` (`daemon.dart:850`); this
  /// is the intent of the run, decided before anything is launched, with
  /// `hotReloadReady` covering the narrower case of a pipeline that was meant
  /// to exist and then failed to come up.
  ///
  /// [directory] is the Bazel workspace this run is driving, which is what
  /// upstream means by the field (it sends `projectDirectory`). Not
  /// `Directory.current.path`: under `bazel run` — the documented way to start
  /// this tool — that is the tool's own runfiles tree, not the user's project.
  ///
  /// [launchMode] is `run` or `attach`, so an attach does not describe itself
  /// as a launch.
  ///
  /// [mode] is upstream's vocabulary — `debug`, `profile`, `release` — and is
  /// omitted when the tool does not know it. `attach` is the case: it connects
  /// to an app someone else started, so the mode is the app's fact and not
  /// this run's. Omitted rather than guessed, because a client reading a
  /// wrong `mode` has no way to find out it is wrong.
  void appStart(
    String appId,
    String deviceName, {
    required bool supportsRestart,
    required String directory,
    required String launchMode,
    String? mode,
  }) {
    sendEvent('app.start', {
      'appId': appId,
      'deviceId': deviceName,
      'directory': directory,
      'supportsRestart': supportsRestart,
      'launchMode': launchMode,
      if (mode != null) 'mode': mode,
    });
  }

  /// Send app.debugPort event.
  ///
  /// `port` is upstream's field and the one a client that only wants to dial
  /// the service reads, rather than leaving it to be parsed back out of
  /// `wsUri`.
  void appDebugPort(String appId, Uri wsUri, Uri? baseUri) {
    sendEvent('app.debugPort', {
      'appId': appId,
      'port': (baseUri ?? wsUri).port,
      'wsUri': wsUri.toString(),
      if (baseUri != null) 'baseUri': baseUri.toString(),
    });
  }

  /// Send app.webLaunchUrl event — where a web run's app is served.
  ///
  /// [launched] is upstream's field: whether this tool opened a browser on the
  /// URL, as opposed to leaving it for the user to open. Always true here —
  /// `WebDevice` launches Chrome as part of launching the app, and a failure
  /// to do so fails the launch — but sent rather than assumed, because a
  /// client reading upstream's protocol has no other way to learn it and the
  /// field is where it would look.
  void appWebLaunchUrl(String appId, String url, {required bool launched}) {
    sendEvent('app.webLaunchUrl', {
      'appId': appId,
      'url': url,
      'launched': launched,
    });
  }

  /// Send app.devTools event — where DevTools is serving this app.
  void appDevTools(String appId, String uri) {
    sendEvent('app.devTools', {'appId': appId, 'uri': uri});
  }

  /// Send app.started event.
  void appStarted(String appId) {
    sendEvent('app.started', {'appId': appId});
  }

  /// Send app.log event.
  void appLog(String appId, String log, {bool error = false}) {
    sendEvent('app.log', {
      'appId': appId,
      'log': log,
      'error': error,
    });
  }

  /// Send app.progress event with paired start/finish IDs.
  ///
  /// Use [progressId] to pair start and finish events. If null, a new ID is
  /// generated (for backward compatibility).
  ///
  /// [appId] is null for a command that addressed no particular app — a
  /// watcher-driven or keyboard-driven reload, which goes to all of them. The
  /// key is then **omitted**, not sent as `''`: an empty string reads as an
  /// appId that went missing, and no app has ever had that id. Progress is
  /// announced before the dispatch pool is entered, deliberately, so the
  /// resolved app list does not exist yet and cannot be reported here — the
  /// resolved set arrives with the result instead, as `appIds`.
  void appProgress(
    String? appId,
    String message, {
    bool finished = false,
    String? progressId,
  }) {
    final id = progressId ?? 'progress_${_nextId++}';
    sendEvent('app.progress', {
      if (appId != null) 'appId': appId,
      'id': id,
      'message': message,
      'finished': finished,
    });
  }

  /// Send app.stop event.
  void appStop(String appId) {
    sendEvent('app.stop', {'appId': appId});
  }

  void _sendResponse(dynamic id, Map<String, dynamic> result) {
    _send({'id': id, 'result': result});
  }

  /// Upstream's error response: `{id, error, trace}`, where `error` is a
  /// string.
  ///
  /// A JSON-RPC `{code, message}` object is not what a `flutter run --machine`
  /// client expects: upstream's own DAP renders whatever arrives with
  /// `'$error'`, so an object comes out as a Dart map literal in the UI.
  void _sendError(dynamic id, String message, [StackTrace? trace]) {
    _send({
      'id': id,
      'error': message,
      if (trace != null) 'trace': '$trace',
    });
  }

  void _send(Map<String, dynamic> message) {
    _output.writeln('[${json.encode(message)}]');
  }
}
