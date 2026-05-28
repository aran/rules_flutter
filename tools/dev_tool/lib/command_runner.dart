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
/// `.timeout(...)` *at its own boundary* — `AppInstance.applyKernel` and
/// `Compiler.compileIncrement` are the production examples — so the
/// handler's completion is structurally guaranteed.
///
/// Why no acquisition timeout? Because a deadline at the dispatch layer
/// would hide the real bug (an unbounded operation) and make concurrency
/// reasoning fragile. With every handler bounded, the pool is provably
/// free of deadlock and the contract is one short sentence: "every
/// command finishes."
import 'package:pool/pool.dart';

/// Handler signature for a registered command.
typedef CommandHandler = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> params);

/// Serializes command execution through a single-resource pool.
///
/// Transports (MachineProtocol, HttpControlChannel, keyboard, file watcher)
/// all call [run] to execute commands. The pool ensures only one command
/// executes at a time.
class CommandRunner {
  final _handlers = <String, CommandHandler>{};
  final _pool = Pool(1);

  /// Register a command handler for [method].
  void register(String method, CommandHandler handler) {
    _handlers[method] = handler;
  }

  /// Execute [method] with [params], serialized through the pool.
  ///
  /// Throws [ArgumentError] if [method] is not registered.
  Future<Map<String, dynamic>> run(
      String method, Map<String, dynamic> params) async {
    final handler = _handlers[method];
    if (handler == null) {
      throw ArgumentError('Unknown command: $method');
    }
    final resource = await _pool.request();
    try {
      return await handler(params);
    } finally {
      resource.release();
    }
  }

  /// Whether [method] has a registered handler.
  bool hasCommand(String method) => _handlers.containsKey(method);

  /// All registered command method names.
  List<String> get registeredCommands => _handlers.keys.toList();
}
