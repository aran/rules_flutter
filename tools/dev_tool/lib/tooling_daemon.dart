/// The Dart Tooling Daemon (DTD) a run registers its apps with.
///
/// DTD is how Dart's own tools find a running app without being handed its VM
/// service URI. The Dart MCP server lists DTDs with `dart tooling-daemon
/// --list` and reads the apps each one knows from its `ConnectedApp` service;
/// its `list_running_apps`, `hot_reload`, `hot_restart` and
/// `get_runtime_errors` tools act on what it finds there. DevTools reads the
/// same service.
///
/// `flutter run` gets a DTD from its DDS, which starts one and registers the
/// app's VM service with it (`dds_impl.dart`, `_startDDSServer`). This tool
/// runs DDS in process, where that path cannot work: DDS spawns DTD as an
/// isolate from a snapshot it looks for beside `Platform.resolvedExecutable`,
/// and under Bazel that is this AOT binary. So the run starts the toolchain's
/// `dart tooling-daemon` itself and registers each app's VM service, the call
/// DDS makes. One DTD serves every app of the run, so a client that finds it
/// finds them all.
///
/// Only the process that started a DTD can register apps with it: the call
/// needs the secret DTD prints at startup. That is why a run starts its own
/// rather than joining one it is told about, which is also what `flutter run`
/// does.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dtd/dtd.dart';
import 'package:logging/logging.dart';

import 'dev_tool_exception.dart';
import 'machine_protocol.dart';
import 'process_cpu_time.dart';
import 'teardown.dart';

/// Starts `dart tooling-daemon`. [workingDirectory] is recorded by DTD as its
/// workspace root, which `dart tooling-daemon --list` reports.
typedef ToolingDaemonSpawn = Future<Process> Function(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
});

/// The privileged call of DTD's `ConnectedApp` service this tool makes.
abstract interface class ConnectedAppRegistry {
  Future<void> registerVmService({
    required String uri,
    required String secret,
    String? name,
  });

  Future<void> close();
}

/// Connects to a DTD at a `ws://` URI.
typedef ConnectedAppConnector = Future<ConnectedAppRegistry> Function(Uri uri);

/// A `dart tooling-daemon` this tool started, and the connection that
/// registers apps with it.
class ToolingDaemon {
  /// The address clients connect to, as DTD announced it.
  final Uri uri;

  final String _secret;
  final Process _process;
  final ConnectedAppRegistry _registry;

  ToolingDaemon._(this.uri, this._secret, this._process, this._registry);

  /// Start a DTD with [dartExecutable] and wait for it to say where it is.
  ///
  /// `--machine` makes DTD print one JSON line,
  /// `{"tooling_daemon_details": {"uri": ..., "trusted_client_secret": ...}}`,
  /// which is the only place the secret appears. Throws [DevToolException]
  /// when DTD exits, or says nothing usable within [timeout], with what it
  /// wrote to stderr.
  static Future<ToolingDaemon> start({
    required String dartExecutable,
    required String workingDirectory,
    ToolingDaemonSpawn spawn = _spawn,
    ConnectedAppConnector connect = _connect,
    Duration timeout = const Duration(seconds: 30),
    CpuTimeReader cpuTime = readProcessCpuTime,
  }) async {
    final process = await spawn(dartExecutable, const [
      'tooling-daemon',
      '--machine',
    ], workingDirectory: workingDirectory);
    final stderrText = StringBuffer();
    // Drained for the process's whole life: an unread pipe that fills blocks
    // the daemon on its next write.
    process.stderr.transform(utf8.decoder).listen(stderrText.write);
    // Settled by whichever comes first: the details line, the process
    // exiting, or the timeout. The other two find it settled and do nothing.
    final details = Completer<({Uri uri, String secret})>();
    void fail(String why) {
      if (details.isCompleted) return;
      details.completeError(
        DevToolException(
          '`$dartExecutable tooling-daemon` $why${_stderrTail(stderrText)}',
        ),
      );
    }

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (details.isCompleted) return;
            if (_parseDetails(line) case final found?) details.complete(found);
          },
        );
    unawaited(
      process.exitCode.then(
        (code) => fail('exited with $code before saying where it listens'),
      ),
    );
    // The CPU time it used goes in the message: what tells a daemon that was
    // working, slowly, from one waiting on something.
    final timer = Timer(timeout, () async {
      if (details.isCompleted) return;
      String used;
      try {
        final cpu = await cpuTime(process.pid);
        used = ', using ${cpu.inMilliseconds}ms of CPU';
      } on ProcessCpuTimeException catch (e) {
        used = ' (its CPU time could not be read: ${e.message})';
      } catch (e) {
        // Any other failure too: this runs in a timer, where an error that
        // escapes is unhandled and ends the tool, and the timeout it reports
        // matters more than the figure.
        used = ' (its CPU time could not be read: $e)';
      }
      fail('did not say where it listens within ${timeout.inSeconds}s$used');
    });

    final ({Uri uri, String secret}) found;
    try {
      found = await details.future;
    } catch (_) {
      process.kill();
      rethrow;
    } finally {
      timer.cancel();
    }

    final ConnectedAppRegistry registry;
    try {
      registry = await connect(found.uri);
    } catch (e) {
      process.kill();
      throw DevToolException(
        'Started the Dart Tooling Daemon at ${found.uri} but could not '
        'connect to it: $e',
      );
    }
    return ToolingDaemon._(found.uri, found.secret, process, registry);
  }

  /// Add the app whose VM service is at [vmServiceWsUri] to DTD's connected
  /// apps, under [name].
  ///
  /// DTD dials the URI itself and drops the app when that connection closes,
  /// so nothing unregisters it: an app that ends, or a DDS that shuts down,
  /// leaves the list on its own.
  Future<void> registerVmService(Uri vmServiceWsUri, {required String name}) =>
      _registry.registerVmService(
        uri: vmServiceWsUri.toString(),
        secret: _secret,
        name: name,
      );

  /// Close the connection and stop the daemon.
  ///
  /// DTD's entry in `dart tooling-daemon --list` goes with the process: the
  /// listing drops a file whose process no longer holds its lock.
  Future<void> close() async {
    try {
      await _registry.close();
    } finally {
      _process.kill();
      await _process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _process.kill(ProcessSignal.sigkill);
          return _process.exitCode;
        },
      );
    }
  }

  static ({Uri uri, String secret})? _parseDetails(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (decoded case {
      'tooling_daemon_details': {
        'uri': final String uri,
        'trusted_client_secret': final String secret,
      },
    }) {
      return (uri: Uri.parse(uri), secret: secret);
    }
    return null;
  }

  static String _stderrTail(StringBuffer stderrText) {
    final text = stderrText.toString().trim();
    return text.isEmpty ? '' : '; it said:\n$text\n';
  }

  static Future<Process> _spawn(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) => Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );

  static Future<ConnectedAppRegistry> _connect(Uri uri) async =>
      _DtdRegistry(await DartToolingDaemon.connect(uri));
}

class _DtdRegistry implements ConnectedAppRegistry {
  final DartToolingDaemon _client;

  _DtdRegistry(this._client);

  @override
  Future<void> registerVmService({
    required String uri,
    required String secret,
    String? name,
  }) => _client.registerVmService(uri: uri, secret: secret, name: name);

  @override
  Future<void> close() => _client.close();
}

/// The name an app is registered under, in `flutter run`'s form
/// (`resident_runner.dart`): `Kind: Flutter - Device: <device> - Package:
/// <package>`. The package is the Bazel target, which is what names the app
/// here.
String dtdAppName({required String device, required String target}) =>
    'Kind: Flutter - Device: $device - Package: $target';

/// The one DTD of a run: started when the first app registers, stopped by the
/// run's teardown.
///
/// Each app it registers is announced the way `flutter run` announces it: an
/// `app.dtd` event for a `--machine` client, and, with `--print-dtd`, the line
/// "The Dart Tooling Daemon is available at: <uri>".
class RunToolingDaemon {
  final Future<ToolingDaemon> Function() _start;
  final Teardown _teardown;
  final MachineProtocol _protocol;
  final Logger _logger;
  final bool _printUri;

  Future<ToolingDaemon>? _daemon;

  RunToolingDaemon({
    required Future<ToolingDaemon> Function() start,
    required Teardown teardown,
    required MachineProtocol protocol,
    required Logger logger,
    required bool printUri,
  }) : _start = start,
       _teardown = teardown,
       _protocol = protocol,
       _logger = logger,
       _printUri = printUri;

  /// Register the app [appId] runs as, whose VM service is at
  /// [vmServiceWsUri], and announce the DTD. Answers the DTD's URI.
  ///
  /// Not fatal when it fails: the app runs, and every way to drive it but
  /// DTD's still works. Said as a warning naming what is lost, and answered
  /// with null.
  Future<Uri?> register({
    required String appId,
    required Uri vmServiceWsUri,
    required String name,
  }) async {
    if (_teardown.hasRun) return null;
    try {
      final daemon = await (_daemon ??= _startOwned());
      await daemon.registerVmService(vmServiceWsUri, name: name);
      announce(appId, daemon.uri);
      return daemon.uri;
    } catch (e) {
      _logger.warning({
        'message': 'dtd_register_failed',
        'text':
            'Could not register $appId with the Dart Tooling Daemon: $e. '
            'Tools that find apps through it, such as the Dart MCP server, '
            'will not see this one; its VM service is still at '
            '$vmServiceWsUri.',
        'appId': appId,
        'uri': vmServiceWsUri.toString(),
        'error': '$e',
      });
      return null;
    }
  }

  /// Announce [dtdUri] for [appId]: a DTD this run registered the app with,
  /// or one that something else started and registered it with, as DWDS's
  /// DDS does for a browser run.
  void announce(String appId, Uri dtdUri) {
    final record = {
      'message': 'dtd',
      'text': 'The Dart Tooling Daemon is available at: $dtdUri',
      'appId': appId,
      'uri': dtdUri.toString(),
    };
    if (_printUri) {
      _logger.info(record);
    } else {
      _logger.fine(record);
    }
    _protocol.appDtd(appId, dtdUri);
  }

  Future<ToolingDaemon> _startOwned() async {
    final daemon = await _start();
    // At once, before anything can fail: the daemon is a process that
    // outlives the tool if nothing stops it.
    await _teardown.add(daemon.close);
    _logger.fine({
      'message': 'dtd_started',
      'text': 'Started the Dart Tooling Daemon at ${daemon.uri}.',
      'uri': daemon.uri.toString(),
    });
    return daemon;
  }
}
