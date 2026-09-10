import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:flutter_bazel_dev_tool/web_module_server.dart';
import 'package:flutter_bazel_dev_tool/web_options.dart';
import 'package:test/test.dart';

import 'loopbacks.dart';
import 'tls_fixture.dart';

WebModuleServer serverWith({
  String? packageConfigPath,
  String? workspaceRoot,
  String buildOutputDir = '/nonexistent/web',
  String toolchainDir = '/nonexistent',
  bool nativeNullAssertions = true,
  String? flutterBootstrapJsPath,
  // What a DDC dev run resolves to: an ephemeral loopback port, plain HTTP,
  // no extra headers, and no cross-origin isolation.
  WebServerOptions options = const WebServerOptions(
    crossOriginIsolation: false,
  ),
}) => WebModuleServer(
  webToolchain: WebToolchainPaths(
    ddcOutlineDill: '$toolchainDir/ddc_outline.dill',
    librariesSpec: '$toolchainDir/libraries.json',
    dartSdkJs: '$toolchainDir/dart_sdk.js',
    ddcModuleLoaderJs: '$toolchainDir/ddc_module_loader.js',
    stackTraceMapperJs: '$toolchainDir/stack_trace_mapper.js',
    dartSdkRoot: '$toolchainDir/dart-sdk',
  ),
  buildOutputDir: buildOutputDir,
  entrypointFilename: 'web_entrypoint.dart',
  flutterBootstrapJsPath:
      flutterBootstrapJsPath ?? devBootstrapPath(buildOutputDir),
  dartExecutable: '/nonexistent/dart',
  workspaceRoot: workspaceRoot,
  packageConfigPath: packageConfigPath,
  nativeNullAssertions: nativeNullAssertions,
  options: options,
);

/// A scratch directory that outlives the test that made it by exactly one
/// teardown. Top level so the helpers below can reach it.
Directory tempDir() {
  final dir = Directory.systemTemp.createTempSync('web_module_server_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

/// A started server whose boot path is complete on disk.
///
/// [withProgram] decides whether a compile has landed. It is required rather
/// than defaulted because it selects between the two states the boot-chain
/// gate distinguishes, and a test that does not say which one it means is
/// asserting against whichever the default happens to be.
Future<WebModuleServer> bootableServer({required bool withProgram}) async {
  final dir = tempDir();
  writeBootFiles(dir.path);
  // The three files the server streams straight off the toolchain rather
  // than generating. Their content is irrelevant here; what matters is their
  // reachability under the name the bootstrap script uses.
  final toolchain = tempDir();
  for (final name in [
    'dart_sdk.js',
    'ddc_module_loader.js',
    'stack_trace_mapper.js',
  ]) {
    File('${toolchain.path}/$name').writeAsStringSync('// $name');
  }
  final server = serverWith(
    buildOutputDir: dir.path,
    toolchainDir: toolchain.path,
  );
  await server.start();
  addTearDown(server.stop);
  if (withProgram) {
    server.updateModules(
      writeCompile(dir, [
        Module(
          'main.lib.js',
          'main code',
          metadata: moduleMetadata('main', ['package:app/main.dart']),
        ),
      ]),
      full: true,
    );
  }
  return server;
}

/// A GET that reports what came back instead of asserting it succeeded.
///
/// [get] expects 200 — right for every caller that wants a body, wrong for
/// asserting the shape of a refusal.
Future<({int status, String body, String? cacheControl})> fetch(
  WebModuleServer server,
  String path,
) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(server.uri!.replace(path: path));
    final response = await request.close();
    // Awaited before the `finally` closes the client, for the reason [get]
    // records: a returned future races the force-close.
    final body = await response.transform(utf8.decoder).join();
    return (
      status: response.statusCode,
      body: body,
      cacheControl: response.headers.value('cache-control'),
    );
  } finally {
    client.close();
  }
}

/// Where a test's build put the bootstrap the dev server serves.
///
/// Beside the bundle rather than inside it, as the build declares it: the
/// bundle ships the release bootstrap under this name, and the dev loop's
/// names DDC output that bundle does not contain.
String devBootstrapPath(String buildOutputDir) =>
    '$buildOutputDir/dev_flutter_bootstrap.js';

/// Write both halves of the boot path a served page needs.
///
/// `flutter.js` because the build's bootstrap loads it by src, and the
/// bootstrap itself because the server does not generate one.
void writeBootFiles(String dirPath) {
  File('$dirPath/flutter.js').writeAsStringSync('// flutter.js');
  File(devBootstrapPath(dirPath)).writeAsStringSync(
    '// dev bootstrap\n_flutter.buildConfig = '
    '{"builds":[{"compileTarget":"dartdevc","mainJsPath":"main.dart.js"}]};',
  );
}

/// Never invoked: every case here throws before `Dwds.start` would reach for a
/// browser. Failing loudly rather than returning a stub keeps a regression that
/// *does* get this far from looking like a pass.
Future<Never> noChrome() async =>
    throw StateError('DWDS must not reach Chrome in these tests');

/// One module's slice of a DDC compile.
class Module {
  final String path;
  final String code;
  final String? sourceMap;
  final String? metadata;

  const Module(this.path, this.code, {this.sourceMap, this.metadata});
}

/// Write the artifacts a DDC compile leaves behind, the way the frontend
/// server writes them: one blob per kind plus a manifest of byte ranges into
/// them. Returns the dill path [WebModuleServer.updateModules] is given.
///
/// [writeMap] / [writeMetadata] withhold a blob the manifest still declares —
/// the compiler output that costs a module its source map or its libraries.
String writeCompile(
  Directory dir,
  List<Module> modules, {
  String dill = 'out.dill',
  bool writeMap = true,
  bool writeMetadata = true,
}) {
  final dillPath = '${dir.path}/$dill';
  final manifest = <String, Map<String, List<int>>>{};
  final sources = <int>[];
  final maps = <int>[];
  final metadata = <int>[];

  List<int> append(List<int> blob, String text) {
    final start = blob.length;
    blob.addAll(utf8.encode(text));
    return [start, blob.length];
  }

  for (final module in modules) {
    final sections = <String, List<int>>{'code': append(sources, module.code)};
    if (module.sourceMap != null) {
      sections['sourcemap'] = append(maps, module.sourceMap!);
    }
    if (module.metadata != null) {
      sections['metadata'] = append(metadata, module.metadata!);
    }
    manifest['/${module.path}'] = sections;
  }

  File('$dillPath.json').writeAsStringSync(json.encode(manifest));
  File('$dillPath.sources').writeAsBytesSync(sources);
  if (writeMap && maps.isNotEmpty) {
    File('$dillPath.map').writeAsBytesSync(maps);
  }
  if (writeMetadata && metadata.isNotEmpty) {
    File('$dillPath.metadata').writeAsBytesSync(metadata);
  }
  return dillPath;
}

/// The metadata DDC emits per module, cut down to the two fields the server
/// reads out of it.
String moduleMetadata(String name, List<String> libraries) => json.encode({
  'name': name,
  'libraries': [
    for (final uri in libraries) {'importUri': uri, 'name': uri},
  ],
});

Matcher throwsDevToolException(Matcher message) => throwsA(
  isA<DevToolException>().having((e) => e.message, 'message', message),
);

/// Something else on the port this run drew, on demand rather than by luck.
///
/// Interception is the kernel handing a connection to a listener this run does
/// not own: a wildcard bind is allowed to sit alongside something holding the
/// same port on one specific address, and every connection to that address goes
/// there instead. That the check *notices* that is settled by the cases above,
/// which squat a real port and let the real kernel route around this server.
///
/// What those cases cannot say is what a *search* does after the first draw.
/// A search only happens with `--web-port 0`, where the port is the kernel's to
/// choose: nothing can squat a port before it is drawn, and squatting the whole
/// ephemeral range to be sure of hitting it is 16k sockets for a probability.
/// On Linux the coexistence a squat depends on is refused outright (errno 98),
/// so a port held that way is not one a wildcard bind can
/// take at all — and a search that never sees an intercepted draw is a search
/// a squatting test would say nothing about there. (That the allocator
/// therefore skips such a port is inferred from the refusal, not separately
/// measured.)
///
/// So the one thing the kernel does during a real interception is arranged
/// instead: the check's connection arrives somewhere else. [decoyPort] is a
/// real HTTP server answering real bytes that are not the nonce. Everything
/// around it is the production path — real binds, real draws, the real check,
/// the real message. [probed] records the port each request asked about, in
/// order, which is what tells drawing again from trying the same port again.
class Squatter {
  /// Takes every connection: something answering across the whole ephemeral
  /// range, which is what a bounded search has to give up on.
  Squatter.everyPort(this.decoyPort) : _limit = null;

  /// Takes the first connection only: one held port, which a search is meant
  /// to move past.
  Squatter.onePort(this.decoyPort) : _limit = 1;

  /// The real server this takes connections to.
  final int decoyPort;

  /// How many connections to take, or null for all of them.
  final int? _limit;

  /// The port of every request the check made, in order: one entry per
  /// request, so `[p]` is a single attempt and `[p, p]` is a second one on the
  /// same port.
  final List<int> probed = [];

  /// The subset of [probed] this took, so a case can say the interception it
  /// is about really happened. Without it a squatter that diverted nothing
  /// would still leave two entries in [probed] on a host whose `localhost` is
  /// two addresses — one attempt, checked twice — and read as a redraw.
  final List<int> taken = [];

  /// Run [body] with every [HttpClient] it makes pointed through this.
  R run<R>(R Function() body) =>
      HttpOverrides.runZoned(body, createHttpClient: _client);

  HttpClient _client(SecurityContext? context) =>
      _SquattedClient(_realClients.createHttpClient(context), this);

  /// Where a request for [url] actually goes.
  Uri _route(Uri url) {
    probed.add(url.port);
    if (_limit != null && probed.length > _limit) return url;
    taken.add(url.port);
    return url.replace(
      host: InternetAddress.loopbackIPv4.address,
      port: decoyPort,
    );
  }
}

/// Real clients, built the way `HttpClient()` builds them with no override in
/// place. Through the base class rather than the constructor because the
/// constructor would find this file's own override and wrap a wrapper, forever
/// (`_http/http.dart`: `HttpClient()` reads `HttpOverrides.current`).
final _realClients = _RealHttpClients();

class _RealHttpClients extends HttpOverrides {}

/// A client whose connections a [Squatter] may take.
///
/// Only what the reachability check uses is implemented; anything else throws
/// rather than answering something plausible.
class _SquattedClient implements HttpClient {
  _SquattedClient(this._inner, this._squatter);

  final HttpClient _inner;
  final Squatter _squatter;

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _inner.getUrl(_squatter._route(url));

  @override
  void close({bool force = false}) => _inner.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  /// Structured records at WARNING and above, in order.
  ///
  /// The tool's diagnostics go through the logger so a `LOG_FORMAT=json`
  /// consumer can read them; these assertions read the same records it would.
  List<Map<String, dynamic>> captureLogs() {
    final records = <Map<String, dynamic>>[];
    final subscription = Logger.root.onRecord.listen((record) {
      if (record.level >= Level.WARNING && record.object is Map) {
        records.add(Map<String, dynamic>.from(record.object as Map));
      }
    });
    addTearDown(subscription.cancel);
    return records;
  }

  group('WebModuleServer.initDwds', () {
    test('refuses to start with no package config', () {
      expect(
        () => serverWith().initDwds(chromeConnection: noChrome),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains('package_config.json'),
          ),
        ),
      );
    });

    test('names the file when the package config is missing', () {
      const missing = '/nonexistent/package_config.json';
      expect(
        () => serverWith(
          packageConfigPath: missing,
        ).initDwds(chromeConnection: noChrome),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains(missing),
          ),
        ),
      );
    });

    test('names the file when the package config is malformed', () async {
      final dir = await Directory.systemTemp.createTemp('web_module_server_');
      addTearDown(() => dir.delete(recursive: true));
      final config = File('${dir.path}/package_config.json');
      await config.writeAsString('{ this is not json');

      await expectLater(
        () => serverWith(
          packageConfigPath: config.path,
        ).initDwds(chromeConnection: noChrome),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains(config.path),
          ),
        ),
      );
    });

    test('exposes no connectedApps stream until DWDS starts', () {
      // The run wires its VM service off this stream. A `null` here makes
      // `run_command` skip the whole wiring block without a word.
      expect(serverWith().connectedApps, isNull);
    });
  });

  // A silent `return` or a skipped module here is a page that 404s its way to
  // a blank screen, or an edit that reports as reloaded and is not on screen —
  // with the tool saying nothing either way.
  group('WebModuleServer.updateModules', () {
    test('ends the run when the compile wrote no manifest', () {
      final dir = tempDir();

      expect(
        () => serverWith().updateModules('${dir.path}/out.dill', full: true),
        throwsDevToolException(contains('${dir.path}/out.dill.json')),
      );
    });

    test('ends the run when the compile wrote no module bytes', () {
      final dir = tempDir();
      File('${dir.path}/out.dill.json').writeAsStringSync('{}');

      expect(
        () => serverWith().updateModules('${dir.path}/out.dill', full: true),
        throwsDevToolException(contains('${dir.path}/out.dill.sources')),
      );
    });

    test('names the manifest when it does not parse', () {
      final dir = tempDir();
      File('${dir.path}/out.dill.json').writeAsStringSync('{ not json');
      File('${dir.path}/out.dill.sources').writeAsStringSync('');

      expect(
        () => serverWith().updateModules('${dir.path}/out.dill', full: true),
        throwsDevToolException(contains('out.dill.json')),
      );
    });

    test('ends the run when the first compile produced no modules', () {
      final dir = tempDir();
      final dill = writeCompile(dir, []);

      expect(
        () => serverWith().updateModules(dill, full: true),
        throwsDevToolException(
          allOf(
            contains('no modules'),
            contains('$dill.json'),
          ),
        ),
      );
    });

    test('reports a truncated sources file instead of dropping the module', () {
      final dir = tempDir();
      final dill = writeCompile(dir, [const Module('main.lib.js', 'code')]);
      // The manifest still claims bytes that are no longer there.
      File('$dill.sources').writeAsStringSync('co');

      expect(
        () => serverWith().updateModules(dill, full: true),
        throwsDevToolException(
          allOf(
            contains('main'),
            contains('$dill.sources'),
            contains('truncated'),
          ),
        ),
      );
    });

    test('reports a manifest entry with no byte range', () {
      final dir = tempDir();
      final dill = '${dir.path}/out.dill';
      File('$dill.json').writeAsStringSync(
        json.encode({
          '/main.lib.js': {'code': 'all'},
        }),
      );
      File('$dill.sources').writeAsStringSync('code');

      expect(
        () => serverWith().updateModules(dill, full: true),
        throwsDevToolException(
          allOf(
            contains('main'),
            contains('byte range'),
          ),
        ),
      );
    });

    test(
      'reports a source map the manifest declares and the compile omitted',
      () {
        final dir = tempDir();
        final dill = writeCompile(
          dir,
          [const Module('main.lib.js', 'code', sourceMap: '{"version":3}')],
          writeMap: false,
        );

        expect(
          () => serverWith().updateModules(dill, full: true),
          throwsDevToolException(
            allOf(
              contains('$dill.map'),
              contains('main'),
            ),
          ),
        );
      },
    );

    test('reports metadata the manifest declares and the compile omitted', () {
      final dir = tempDir();
      final dill = writeCompile(
        dir,
        [
          Module(
            'main.lib.js',
            'code',
            metadata: moduleMetadata('main', ['package:app/main.dart']),
          ),
        ],
        writeMetadata: false,
      );

      expect(
        () => serverWith().updateModules(dill, full: true),
        throwsDevToolException(
          allOf(
            contains('$dill.metadata'),
            contains('main'),
          ),
        ),
      );
    });

    test('names the module whose metadata is not JSON', () {
      // Swallowed, this costs that module its library list and
      // `$dartReloadModifiedModules` skips it — the edit reloads, the screen
      // does not change. DWDS then chokes on the same bytes with no module
      // named.
      final dir = tempDir();
      final dill = writeCompile(dir, [
        const Module('widgets.lib.js', 'code', metadata: 'not json'),
      ]);

      expect(
        () => serverWith().updateModules(dill, full: true),
        throwsDevToolException(
          allOf(
            contains('widgets'),
            contains('$dill.metadata'),
          ),
        ),
      );
    });

    test('names the module whose metadata is not the shape DDC emits', () {
      // Valid JSON, wrong shape. The `as` casts that read these fields would
      // report it as a TypeError naming neither the module nor the file.
      final dir = tempDir();
      final dill = writeCompile(dir, [
        Module(
          'widgets.lib.js',
          'code',
          metadata: json.encode({'name': 'widgets', 'libraries': 'main'}),
        ),
      ]);

      expect(
        () => serverWith().updateModules(dill, full: true),
        throwsDevToolException(
          allOf(
            contains('widgets'),
            contains('$dill.metadata'),
            contains('not an array'),
          ),
        ),
      );
    });

    test(
      'warns once, naming them, for modules that came back with no metadata',
      () {
        final logs = captureLogs();
        final dir = tempDir();
        final dill = writeCompile(dir, [
          Module(
            'main.lib.js',
            'main code',
            metadata: moduleMetadata('main', ['package:app/main.dart']),
          ),
          const Module('widgets.lib.js', 'widget code'),
          const Module('theme.lib.js', 'theme code'),
        ]);

        serverWith().updateModules(dill, full: true);

        expect(logs, hasLength(1));
        expect(logs.single['message'], 'ddc_modules_without_metadata');
        expect(logs.single['modules'], ['widgets', 'theme']);
        expect(logs.single['text'], contains('Hot reload'));
        expect(logs.single['text'], isNot(contains('main.lib.js')));
      },
    );

    test(
      'serves the modules a compile produced, and reloads name libraries',
      () async {
        final logs = captureLogs();
        final dir = tempDir();
        writeBootFiles(dir.path);
        final server = serverWith(buildOutputDir: dir.path);
        await server.start();
        addTearDown(server.stop);

        final first = writeCompile(dir, [
          Module(
            'main.lib.js',
            'first code',
            sourceMap: '{"version":3,"file":"main"}',
            metadata: moduleMetadata('main', ['package:app/main.dart']),
          ),
        ], dill: 'out.dill');
        server.updateModules(first, full: true);

        expect(await get(server, '/main.lib.js'), 'first code');
        expect(
          await server.sourceMapContents('main.lib.js.map'),
          '{"version":3,"file":"main"}',
        );
        // Empty until a reload has something to reload: DWDS fetches it on hot
        // reload and reloads every module listed.
        expect(await get(server, '/reloaded_sources.json'), '[]');

        final second = writeCompile(dir, [
          Module(
            'main.lib.js',
            'second code',
            metadata: moduleMetadata('main', ['package:app/main.dart']),
          ),
        ], dill: 'incremental.dill');
        server.updateModules(second, full: false);

        expect(await get(server, '/main.lib.js'), 'second code');
        final reloaded =
            json.decode(await get(server, '/reloaded_sources.json')) as List;
        expect(reloaded, hasLength(1));
        expect((reloaded.single as Map)['module'], 'main');
        expect((reloaded.single as Map)['libraries'], [
          'package:app/main.dart',
        ]);
        expect(logs, isEmpty);
      },
    );

    // The merge contract `updateModules` documents. An incremental compile
    // only contains what changed, so everything it leaves out must keep
    // serving what the last compile put there. The two-compile case above
    // recompiles the *same* module, which a server that simply replaced its
    // whole module map would also pass; only a compile that touches a
    // different module can tell the two apart. Getting this wrong is a reload
    // that 404s every untouched module — a working page turning blank on an
    // edit to one file.
    test('keeps modules an incremental compile left out', () async {
      final dir = tempDir();
      writeBootFiles(dir.path);
      final server = serverWith(buildOutputDir: dir.path);
      await server.start();
      addTearDown(server.stop);

      server.updateModules(
        writeCompile(dir, [
          Module(
            'main.lib.js',
            'main code',
            metadata: moduleMetadata('main', ['package:app/main.dart']),
          ),
          Module(
            'other.lib.js',
            'other code',
            metadata: moduleMetadata('other', ['package:app/other.dart']),
          ),
        ], dill: 'out.dill'),
        full: true,
      );

      expect(await get(server, '/main.lib.js'), 'main code');
      expect(await get(server, '/other.lib.js'), 'other code');

      // An edit to other.dart alone: only that module comes back.
      server.updateModules(
        writeCompile(dir, [
          Module(
            'other.lib.js',
            'other code v2',
            metadata: moduleMetadata('other', ['package:app/other.dart']),
          ),
        ], dill: 'incremental.dill'),
        full: false,
      );

      expect(await get(server, '/other.lib.js'), 'other code v2');
      expect(
        await get(server, '/main.lib.js'),
        'main code',
        reason: 'the untouched module must still serve its original bytes',
      );

      // And only the recompiled module is listed for reload — relisting the
      // untouched one would re-evaluate a library the edit never changed.
      final reloaded =
          json.decode(await get(server, '/reloaded_sources.json')) as List;
      expect(reloaded.map((e) => (e as Map)['module']), ['other']);
    });

    // The non-empty check covers reloads too, not just the first compile where
    // an empty manifest means a page that 404s to a blank screen. On a reload
    // the same emptiness is quieter and no less wrong: a recompile only happens
    // once something is known to have changed, so nothing coming back means
    // the invalidated libraries never reached the compiler —
    // `reloaded_sources.json` lists nothing, `$dartReloadModifiedModules`
    // reloads nothing, and the reload reports success over an unchanged page.
    test('ends a reload whose recompile produced no modules', () {
      final dir = tempDir();
      final server = serverWith();
      server.updateModules(
        writeCompile(
          dir,
          [const Module('main.lib.js', 'code')],
          dill: 'out.dill',
        ),
        full: true,
      );

      expect(
        () => server.updateModules(
          writeCompile(dir, [], dill: 'incremental.dill'),
          full: false,
        ),
        throwsDevToolException(
          allOf(
            contains('recompiled nothing'),
            contains('${dir.path}/incremental.dill.json'),
          ),
        ),
      );
    });
  });

  // The generated bootstrap scripts (`web_bootstrap.dart`) name the files the
  // browser will ask for, and this server decides what those names resolve to.
  // Neither half can be checked alone: `web_bootstrap_test.dart` can only
  // re-type its own literals, and the routing here is a list of string
  // comparisons that looks correct against any set of names. A rename on one
  // side is a 404 mid-boot — a blank page with the real cause in the browser
  // console, which no Dart test would ever see. So the assertion is that the
  // page can actually walk the chain: fetch a script, take the names *it*
  // references, and fetch those.
  group('the boot chain the generated scripts describe', () {
    /// Every `"…"` and `'…'` string literal in [script] that names a file the
    /// browser would fetch.
    ///
    /// Must start with a word character: the scripts also carry bare suffixes
    /// like `".lib.js"`, which the stack-trace mapper strips off a URL rather
    /// than fetching.
    ///
    /// A future filename containing a `-` would fall outside this and be
    /// walked over silently, which is what the `containsAll` guard below is
    /// for — extend it alongside any new generated script.
    Set<String> referencedFiles(String script) => RegExp(
      r'''["'](\w[\w./]*\.(?:js|json))["']''',
    ).allMatches(script).map((m) => m.group(1)!).toSet();

    test('every file main.dart.js pulls in is served', () async {
      final server = await bootableServer(withProgram: true);
      final referenced = referencedFiles(await get(server, '/main.dart.js'));

      // Guard the guard: a regex that matched nothing would make this test
      // pass against a server that serves none of them.
      expect(
        referenced,
        containsAll([
          'dart_sdk.js',
          'main_module.bootstrap.js',
          'ddc_module_loader.js',
          'stack_trace_mapper.js',
          'reloaded_sources.json',
        ]),
      );

      for (final file in referenced) {
        await get(server, '/$file');
      }
    });

    test('the handoff from main_module.bootstrap.js is served too', () async {
      final server = await bootableServer(withProgram: true);
      final referenced = referencedFiles(
        await get(server, '/main_module.bootstrap.js'),
      );
      expect(referenced, contains('on_load_end_bootstrap.js'));
      for (final file in referenced) {
        await get(server, '/$file');
      }
    });

    test('flutter_bootstrap.js names a main script that is served', () async {
      final server = await bootableServer(withProgram: true);
      final script = await get(server, '/flutter_bootstrap.js');
      expect(script, contains('"mainJsPath":"main.dart.js"'));
      await get(server, '/main.dart.js');
    });
  });

  group('WebModuleServer merged metadata', () {
    // DWDS re-reads this artifact on EVERY bootstrap request — it replaces its
    // `MetadataProvider` per request (dwds strategy.dart:179-181) and embeds
    // the module list it derives into the served body (`_ddcLoaderSetup`,
    // ddc_library_bundle.dart:189-224). The DDC loader then loads exactly that
    // list and nothing else.
    //
    // So this artifact is not bookkeeping: it IS what a fresh page boots. It
    // has to merge the way the module and metadata stores beside it do —
    // replaced wholesale on every compile, it would describe only the module
    // the last hot reload recompiled, and a page refreshed after that boots
    // one script instead of the program.
    String? name(String metadata) =>
        (json.decode(metadata) as Map)['name'] as String?;

    List<String?> modulesIn(String? merged) => [
      for (final line in (merged ?? '').split('\n'))
        if (line.isNotEmpty) name(line),
    ];

    String compile(Directory dir, List<String> names, {required String dill}) =>
        writeCompile(dir, [
          for (final n in names)
            Module(
              '$n.lib.js',
              '$n code',
              metadata: moduleMetadata(n, ['package:app/$n.dart']),
            ),
        ], dill: dill);

    test('an incremental compile still describes the whole program', () async {
      final dir = tempDir();
      writeBootFiles(dir.path);
      final server = serverWith(buildOutputDir: dir.path);
      await server.start();
      addTearDown(server.stop);

      server.updateModules(
        compile(dir, ['main', 'other'], dill: 'full.dill'),
        full: true,
      );
      server.updateModules(
        compile(dir, ['other'], dill: 'delta.dill'),
        full: false,
      );

      expect(
        modulesIn(
          await server.metadataContents('main_module.ddc_merged_metadata'),
        ),
        containsAll(['main', 'other']),
        reason:
            'a page booting after this reload loads exactly the modules named '
            'here — dropping the untouched one strands the app',
      );
    });

    test('a full compile forgets a module it no longer produces', () async {
      // The other direction, and the reason a delta merge is not enough on its
      // own: a module deleted from the program must not linger in the list a
      // fresh boot loads, or the page fetches a script the server no longer
      // has.
      final dir = tempDir();
      writeBootFiles(dir.path);
      final server = serverWith(buildOutputDir: dir.path);
      await server.start();
      addTearDown(server.stop);

      server.updateModules(
        compile(dir, ['main', 'gone'], dill: 'first.dill'),
        full: true,
      );
      server.updateModules(
        compile(dir, ['main'], dill: 'second.dill'),
        full: true,
      );

      expect(
        modulesIn(
          await server.metadataContents('main_module.ddc_merged_metadata'),
        ),
        ['main'],
      );
    });
  });

  group('WebModuleServer boot-chain gate', () {
    // The three generated scripts that carry a page from `flutter.js` to a
    // running program. `main_module.bootstrap.js` is also where DWDS injects
    // its client, at the marker the generated body opens with — so serving
    // these before a program exists is what puts a debugger client on a page
    // that has nothing to debug.
    const bootChain = [
      'main.dart.js',
      'main_module.bootstrap.js',
      'on_load_end_bootstrap.js',
    ];

    test('refuses every boot script until a program is held', () async {
      final server = await bootableServer(withProgram: false);
      for (final path in bootChain) {
        expect(
          (await fetch(server, '/$path')).status,
          HttpStatus.serviceUnavailable,
          reason: 'GET /$path before any compile landed',
        );
      }
    });

    test('the refusal says which state the server is in', () async {
      final server = await bootableServer(withProgram: false);
      // Named rather than matched loosely: a bare 503 tells a developer their
      // page is blank, not why, and this is the one response they will see
      // while a first compile is failing.
      final body = (await fetch(server, '/main.dart.js')).body;
      expect(body, contains('no program'));
      expect(body, contains('compile'));
    });

    test('serves every boot script once a program is held', () async {
      final server = await bootableServer(withProgram: true);
      for (final path in bootChain) {
        expect(
          (await fetch(server, '/$path')).status,
          HttpStatus.ok,
          reason: 'GET /$path after a compile landed',
        );
      }
    });

    test('a refused boot script is never cached', () async {
      // Without this the refusal outlives the state that justified it: a
      // pinned `--web-port` puts the next run on the same origin, and a
      // cached 503 would blank a page whose server is healthy.
      final server = await bootableServer(withProgram: false);
      for (final path in bootChain) {
        expect(
          (await fetch(server, '/$path')).cacheControl,
          'no-store',
          reason: 'GET /$path before any compile landed',
        );
      }
    });

    test('a served boot script is never cached either', () async {
      final server = await bootableServer(withProgram: true);
      for (final path in bootChain) {
        expect(
          (await fetch(server, '/$path')).cacheControl,
          'no-store',
          reason: 'GET /$path after a compile landed',
        );
      }
    });

    test('a refusal is not quietly satisfied from the build output', () async {
      // The trap this gate is one `if` away from. `main.dart.js` is a real
      // name in a release bundle, and the handler's last arm serves anything
      // it finds in the build output directory. A gate that skipped its
      // branch instead of answering would hand the browser a compiled page
      // that renders correctly and has no hot reload at all — the failure this
      // gate exists to make impossible.
      final dir = tempDir();
      writeBootFiles(dir.path);
      File('${dir.path}/main.dart.js').writeAsStringSync('// release bundle');
      final server = serverWith(buildOutputDir: dir.path);
      await server.start();
      addTearDown(server.stop);

      final response = await fetch(server, '/main.dart.js');
      expect(response.status, HttpStatus.serviceUnavailable);
      expect(response.body, isNot(contains('release bundle')));
    });
  });

  group('WebModuleServer.start', () {
    test('refuses to start without flutter.js', () {
      final dir = tempDir();
      // The other half of the boot path is there, so this is about flutter.js
      // and not about whichever check happens to run first.
      File(devBootstrapPath(dir.path)).writeAsStringSync('// bootstrap');

      expect(
        () => serverWith(buildOutputDir: dir.path).start(),
        throwsDevToolException(
          allOf(
            contains('${dir.path}/flutter.js'),
            contains('blank'),
          ),
        ),
      );
    });

    // The dev loop does not write a bootstrap of its own — it serves the one
    // the build substituted from this target's template. A build that produced
    // none leaves the page with nothing to boot, and the browser reports that
    // as a blank tab.
    test("refuses to start without the build's flutter_bootstrap.js", () {
      final dir = tempDir();
      File('${dir.path}/flutter.js').writeAsStringSync('// flutter.js');

      expect(
        () => serverWith(buildOutputDir: dir.path).start(),
        throwsDevToolException(
          allOf(
            contains(devBootstrapPath(dir.path)),
            contains('blank'),
          ),
        ),
      );
    });
  });

  group('WebModuleServer asset requests', () {
    test('logs the failure behind a 500', () async {
      final logs = captureLogs();
      final dir = tempDir();
      writeBootFiles(dir.path);
      final server = serverWith(buildOutputDir: dir.path);
      await server.start();
      addTearDown(server.stop);

      // A rebuild replacing the output tree mid-run. The browser would
      // otherwise be the only party that knows, and it renders a failed
      // bootstrap as a blank page. A plain 404 here would be that silence,
      // which is why the bootstrap is read by name rather than served as a
      // static file.
      File(devBootstrapPath(dir.path)).deleteSync();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(
        server.uri!.replace(path: '/flutter_bootstrap.js'),
      );
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.internalServerError);
      expect(logs, hasLength(1));
      expect(logs.single['message'], 'asset_request_failed');
      expect(logs.single['path'], 'flutter_bootstrap.js');
      expect(logs.single['text'], contains(devBootstrapPath(dir.path)));
    });

    test('a missing asset is still a 404, not a report', () async {
      final logs = captureLogs();
      final dir = tempDir();
      writeBootFiles(dir.path);
      final server = serverWith(buildOutputDir: dir.path);
      await server.start();
      addTearDown(server.stop);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(
        server.uri!.replace(path: '/favicon.ico'),
      );
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.notFound);
      expect(logs, isEmpty);
    });

    test(
      'main_module.bootstrap.js carries the build\'s null assertions',
      () async {
        // The dev loop generates this script rather than serving the build's,
        // so this is the only path by which a build's
        // `native_null_assertions = False` can reach the page; hardcoding it
        // on here would silently put it back.
        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        Future<String> mainModuleFrom(bool nativeNullAssertions) async {
          final dir = tempDir();
          writeBootFiles(dir.path);
          final server = serverWith(
            buildOutputDir: dir.path,
            nativeNullAssertions: nativeNullAssertions,
          );
          await server.start();
          addTearDown(server.stop);
          // A program first: the boot chain is withheld until one lands, and
          // what this asserts is what the generated script says, not when it
          // becomes reachable.
          server.updateModules(
            writeCompile(dir, [
              Module(
                'main.lib.js',
                'main code',
                metadata: moduleMetadata('main', ['package:app/main.dart']),
              ),
            ]),
            full: true,
          );
          final request = await client.getUrl(
            server.uri!.replace(path: '/main_module.bootstrap.js'),
          );
          final response = await request.close();
          return response.transform(utf8.decoder).join();
        }

        expect(
          await mainModuleFrom(false),
          contains('nativeNonNullAsserts: false'),
        );
        // Both directions: a server that always said `false` would pass the
        // case above and break every default build.
        expect(
          await mainModuleFrom(true),
          contains('nativeNonNullAsserts: true'),
        );
      },
    );
  });

  group('contentTypeFor', () {
    test('names every type the dev loop serves', () {
      // The one table both web servers answer from. Values are asserted
      // exactly: a drifted string here is a script the browser refuses to
      // run or a wasm module instantiateStreaming rejects.
      expect(contentTypeFor('index.html'), 'text/html');
      expect(contentTypeFor('main.dart.js'), 'application/javascript');
      expect(contentTypeFor('main.dart.mjs'), 'application/javascript');
      expect(contentTypeFor('main.dart.wasm'), 'application/wasm');
      expect(contentTypeFor('manifest.json'), 'application/json');
      expect(contentTypeFor('styles.css'), 'text/css');
      expect(contentTypeFor('favicon.png'), 'image/png');
      expect(contentTypeFor('favicon.ico'), 'image/x-icon');
      expect(contentTypeFor('fonts/MaterialIcons-Regular.otf'), 'font/otf');
      expect(contentTypeFor('assets/message.txt'), 'text/plain');
      expect(contentTypeFor('main.dart.js.map'), 'application/json');
      expect(contentTypeFor('foo.lib.js.metadata'), 'application/json');
    });

    test('an unknown extension is explicitly binary', () {
      // The deliberate default, not an accident: everything else a built
      // bundle contains is fetched by the engine, which ignores the type.
      expect(
        contentTypeFor('assets/AssetManifest.bin'),
        'application/octet-stream',
      );
      expect(contentTypeFor('assets/NOTICES.Z'), 'application/octet-stream');
      expect(contentTypeFor('no_extension'), 'application/octet-stream');
    });
  });

  group('StaticWebServer', () {
    Future<HttpClientResponse> getPath(Uri base, String pathAndQuery) async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(Uri.parse('$base$pathAndQuery'));
      final response = await request.close();
      addTearDown(() => response.drain<void>().catchError((_) {}));
      return response;
    }

    Future<StaticWebServer> serveBundle(
      Directory root, {
      WebServerOptions options = const WebServerOptions(
        crossOriginIsolation: false,
      ),
    }) async {
      final server = StaticWebServer(rootPath: root.path, options: options);
      await server.start();
      addTearDown(server.stop);
      return server;
    }

    test('serves index.html at the root', () async {
      final dir = tempDir();
      File('${dir.path}/index.html').writeAsStringSync('<html></html>');
      final server = await serveBundle(dir);

      final response = await getPath(server.uri!, '/');
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.value('content-type'), 'text/html');
    });

    test('answers every file from the one MIME table', () async {
      final dir = tempDir();
      final files = [
        'index.html',
        'main.dart.mjs',
        'main.dart.wasm',
        'styles.css',
        'assets/message.txt',
        'assets/fonts/MaterialIcons-Regular.otf',
        'assets/AssetManifest.bin',
      ];
      for (final path in files) {
        File('${dir.path}/$path')
          ..createSync(recursive: true)
          ..writeAsStringSync('content of $path');
      }
      final server = await serveBundle(dir);

      for (final path in files) {
        final response = await getPath(server.uri!, '/$path');
        expect(response.statusCode, HttpStatus.ok, reason: 'GET /$path');
        expect(
          response.headers.value('content-type'),
          contentTypeFor(path),
          reason: 'GET /$path',
        );
      }
    });

    test('a missing file is a 404', () async {
      final dir = tempDir();
      final server = await serveBundle(dir);

      final response = await getPath(server.uri!, '/no_such_file.js');
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('a path outside the bundle is refused', () async {
      // Tested at the function, not over HTTP: dart:io's HTTP server
      // collapses `..` segments (even `%2e%2e`-encoded ones) before a
      // handler runs, so a wire-level request cannot exercise this check —
      // an HTTP assertion here would pass with the check deleted.
      final dir = tempDir();
      Directory('${dir.path}/bundle').createSync();
      File('${dir.path}/secret.txt').writeAsStringSync('secret');

      final response = serveFileWithin('${dir.path}/bundle', '../secret.txt');
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('exposes its HttpServer so a launch can own its lifetime', () async {
      final dir = tempDir();
      final server = await serveBundle(dir);
      expect(server.server, isNotNull);
      expect(server.uri!.port, server.server!.port);
    });
  });

  group('what the serving options do on the wire', () {
    // Every case here goes through a real bind and a real HTTP request
    // against BOTH servers, because "honoured on the DDC path and silently
    // dropped on the static one" is the failure these options exist to make
    // impossible.

    /// Bring both web servers up on [options] over the same bundle, and
    /// return their base URLs.
    Future<List<Uri>> bothServers(
      Directory dir, {
      required WebServerOptions options,
    }) async {
      final moduleServer = serverWith(
        buildOutputDir: dir.path,
        options: options,
      );
      await moduleServer.start();
      addTearDown(moduleServer.stop);
      final staticServer = StaticWebServer(
        rootPath: dir.path,
        options: options,
      );
      await staticServer.start();
      addTearDown(staticServer.stop);
      return [moduleServer.uri!, staticServer.uri!];
    }

    Directory bundle() {
      final dir = tempDir();
      writeBootFiles(dir.path);
      File('${dir.path}/styles.css').writeAsStringSync('body {}');
      return dir;
    }

    /// GET [url] and read it to the end, so the response is never left
    /// half-consumed on the socket.
    Future<({HttpClientResponse response, String body})> get(
      Uri url, {
      bool acceptAnyCert = false,
    }) async {
      final client = HttpClient();
      if (acceptAnyCert) {
        client.badCertificateCallback = (_, __, ___) => true;
      }
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(url)).close();
      return (
        response: response,
        body: await response.transform(utf8.decoder).join(),
      );
    }

    test(
      'isolation headers are on both servers when asked, off when not',
      () async {
        final dir = bundle();
        for (final isolated in [true, false]) {
          final bases = await bothServers(
            dir,
            options: WebServerOptions(crossOriginIsolation: isolated),
          );
          for (final base in bases) {
            final r = await get(base.replace(path: '/styles.css'));
            expect(r.response.statusCode, HttpStatus.ok, reason: '$base');
            expect(
              r.response.headers.value('content-type'),
              'text/css',
              reason: '$base',
            );
            expect(
              r.response.headers.value('cross-origin-opener-policy'),
              isolated ? 'same-origin' : isNull,
              reason: 'isolated=$isolated via $base',
            );
            expect(
              r.response.headers.value('cross-origin-embedder-policy'),
              isolated ? 'credentialless' : isNull,
              reason: 'isolated=$isolated via $base',
            );
          }
        }
      },
    );

    test('generated responses carry them too, not just files', () async {
      // The module server answers `flutter_bootstrap.js` from memory rather
      // than from the bundle. A header mechanism that only covered file
      // responses would isolate the assets and not the document.
      final dir = bundle();
      final moduleServer = serverWith(
        buildOutputDir: dir.path,
        options: const WebServerOptions(crossOriginIsolation: true),
      );
      await moduleServer.start();
      addTearDown(moduleServer.stop);

      final r = await get(
        moduleServer.uri!.replace(path: '/flutter_bootstrap.js'),
      );
      expect(r.response.statusCode, HttpStatus.ok);
      expect(
        r.response.headers.value('content-type'),
        contentTypeFor('flutter_bootstrap.js'),
      );
      expect(
        r.response.headers.value('cross-origin-opener-policy'),
        'same-origin',
      );
      expect(
        r.response.headers.value('cross-origin-embedder-policy'),
        'credentialless',
      );
    });

    test('a fixed port is the port both servers bind', () async {
      // Bound one at a time — two servers cannot hold one port. The proof the
      // flag took effect is the socket, not the options object.
      final dir = bundle();
      // A port that was free a moment ago, taken the same way the servers
      // take theirs so the address family cannot differ.
      final probe = StaticWebServer(
        rootPath: dir.path,
        options: const WebServerOptions(crossOriginIsolation: false),
      );
      final port = (await probe.start()).port;
      await probe.stop();

      final options = WebServerOptions(crossOriginIsolation: false, port: port);
      final moduleServer = serverWith(
        buildOutputDir: dir.path,
        options: options,
      );
      expect((await moduleServer.start()).port, port);
      await moduleServer.stop();

      final staticServer = StaticWebServer(
        rootPath: dir.path,
        options: options,
      );
      expect((await staticServer.start()).port, port);
      await staticServer.stop();
    });

    test(
      'a port already taken fails naming it, and does not pick another',
      () async {
        // Upstream retries four times onto whatever it can get. A fixed port
        // exists because something else expects the server there, so silently
        // moving would answer a question nobody asked.
        final dir = bundle();
        final holder = StaticWebServer(
          rootPath: dir.path,
          options: const WebServerOptions(crossOriginIsolation: false),
        );
        final port = (await holder.start()).port;
        addTearDown(holder.stop);
        final options = WebServerOptions(
          crossOriginIsolation: false,
          port: port,
        );

        await expectLater(
          serverWith(buildOutputDir: dir.path, options: options).start(),
          throwsDevToolException(
            allOf(
              contains('$port'),
              contains('--web-port'),
            ),
          ),
        );
        await expectLater(
          StaticWebServer(rootPath: dir.path, options: options).start(),
          throwsDevToolException(contains('$port')),
        );
      },
    );

    // `localhost` is not one address, it is two — 127.0.0.1 and ::1 — and the
    // URL these servers publish says `localhost`. A client resolving that name
    // chooses between the two families itself, so a server that binds one of
    // them is only reachable by half its own URL, and the other half belongs
    // to whatever else on the machine happens to hold that port number.
    //
    // Not hypothetical: `adb` keeps dozens of listening sockets on 127.0.0.1
    // in the ephemeral range. A dev server bound to ::1 that draws one of those
    // numbers sends every `localhost` client that picks IPv4 to adb, which
    // accepts the connection and closes it without a byte.
    test('every address localhost resolves to answers this server', () async {
      final dir = bundle();
      final bases = await bothServers(
        dir,
        options: const WebServerOptions(crossOriginIsolation: false),
      );
      final addresses = await InternetAddress.lookup(defaultHostname);
      expect(addresses, isNotEmpty);

      for (final base in bases) {
        for (final address in addresses) {
          final r = await get(
            base.replace(host: address.address, path: '/styles.css'),
          );
          expect(
            r.response.statusCode,
            HttpStatus.ok,
            reason: '$base over ${address.address}',
          );
          expect(r.body, 'body {}', reason: '$base over ${address.address}');
        }
      }
    });

    // The other half of owning the name: a port free on one loopback family
    // and held on the other is not a port this server can serve `localhost`
    // on. Taking the free family instead is the silent interception above,
    // dressed as a successful start — the run reports it is serving at
    // http://localhost:PORT while every client that resolves to the held
    // family reaches the other process.
    test(
      'a port held on either loopback family is refused, not half-bound',
      () async {
        final dir = bundle();
        // Both families where the host has both, and only the one it has where
        // it has one — the tool is right to serve `localhost` on a single family
        // when that is all this machine can assign, and a decoy on an address
        // that cannot be bound at all is a case about the machine.
        final loopbacks = await assignableLoopbacks();
        expect(loopbacks, isNotEmpty);
        for (final held in loopbacks) {
          // A port this server could really have served on — free on *both*
          // loopback families, taken the way it takes its own. Letting the decoy
          // pick the port instead only proves it is free on the decoy's family:
          // the other one may be held by something already (adb holds dozens of
          // 127.0.0.1 ports), and then the refusal below is about that process
          // rather than about the decoy, and nothing here is under test.
          final probe = StaticWebServer(
            rootPath: dir.path,
            options: const WebServerOptions(crossOriginIsolation: false),
          );
          final port = (await probe.start()).port;
          await probe.stop();

          final decoy = await HttpServer.bind(held, port);
          addTearDown(() => decoy.close(force: true));
          final options = WebServerOptions(
            crossOriginIsolation: false,
            port: port,
          );

          await expectLater(
            serverWith(buildOutputDir: dir.path, options: options).start(),
            throwsDevToolException(contains('$port')),
            reason: 'held on ${held.address}',
          );
          await expectLater(
            StaticWebServer(rootPath: dir.path, options: options).start(),
            throwsDevToolException(contains('$port')),
            reason: 'held on ${held.address}',
          );

          // And the refused start gave back whatever it had taken. With the
          // decoy on ::1 the bind had already taken 127.0.0.1 before it found
          // out, and an attempt that gives up without letting that one go holds
          // the very port the next attempt needs — the same leak the
          // `--web-header` case below is about, reached by a different route.
          //
          // Asked by *being* that next attempt: with the decoy gone, the same
          // named port has to start. Binding the other family instead would only
          // ask about a family this host may not have, and would say nothing
          // about the one it does.
          await decoy.close(force: true);
          final next = StaticWebServer(rootPath: dir.path, options: options);
          await next.start();
          await next.stop();
        }
      },
    );

    // `--web-hostname any` publishes `http://localhost:PORT` — [displayHost]
    // is `localhost`, because `any` is not a name a browser resolves. So the
    // wildcard has to answer everything that name resolves to, or the URL the
    // run prints leads somewhere this server is not. A bind of 0.0.0.0 alone
    // leaves ::1 to whatever else wants it — the same defect one family over.
    test(
      'every address the "any" URL resolves to answers this server',
      () async {
        final dir = bundle();
        final bases = await bothServers(
          dir,
          options: const WebServerOptions(
            crossOriginIsolation: false,
            hostname: anyHostname,
          ),
        );
        final addresses = await InternetAddress.lookup(defaultHostname);
        expect(addresses, isNotEmpty);

        for (final base in bases) {
          expect(base.host, defaultHostname);
          for (final address in addresses) {
            final r = await get(
              base.replace(host: address.address, path: '/styles.css'),
            );
            expect(
              r.response.statusCode,
              HttpStatus.ok,
              reason: '$base over ${address.address}',
            );
            expect(r.body, 'body {}', reason: '$base over ${address.address}');
          }
        }
      },
    );

    // The wildcard's own failure mode, and the reason it needs a check the
    // other hostnames do not: a wildcard bind is allowed to succeed on a port
    // something else already holds more specifically, and the kernel then
    // routes every loopback connection to that other process. The server
    // reports itself up, prints its URL, and receives nothing.
    //
    // The assertion is the contract — "a start that returns is a server the
    // published URL reaches" — not the mechanism, because the mechanism is not
    // the same everywhere: on macOS the second bind succeeds and the decoy
    // takes the traffic, so this is caught by the reachability check after the
    // bind; on Linux the kernel refuses the wildcard bind outright
    // (EADDRINUSE) and it is caught by the bind. Either
    // way the run ends naming the port, which is what a caller can rely on.
    test(
      'a wildcard bind that does not own its port is refused, not silent',
      () async {
        final dir = bundle();
        // A port this server could really have served on — free on both loopback
        // families, taken the way it takes its own. Letting the decoy pick it
        // would only prove it was free on the decoy's family.
        final probe = StaticWebServer(
          rootPath: dir.path,
          options: const WebServerOptions(crossOriginIsolation: false),
        );
        final port = (await probe.start()).port;
        await probe.stop();

        // Answers, and answers wrongly — a well-behaved HTTP server on the port
        // this run wanted. adb, the squatter this exists for, closes the
        // connection without a byte, which any check would notice; a decoy
        // that returns a clean 200 is the case that only a check reading what
        // came back can tell from success.
        final decoy = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        addTearDown(() => decoy.close(force: true));
        decoy.listen((r) {
          r.response
            ..statusCode = HttpStatus.ok
            ..write('the decoy answered');
          r.response.close();
        });

        final options = WebServerOptions(
          crossOriginIsolation: false,
          hostname: anyHostname,
          port: port,
        );
        // Both platform paths end the same way — `Free port $port`, the advice a
        // single named draw ends with — and neither may end the way a *search*
        // does, because a named port is one draw and describing five would be
        // describing draws this run never made. Naming the port is not enough on
        // its own to say that: every branch of both messages carries the port
        // number, so a bare `contains('$port')` holds whichever one was taken.
        final refusedNamingThePort = throwsDevToolException(
          allOf(
            contains('Free port $port'),
            isNot(contains('All 5 ports')),
          ),
        );
        await expectLater(
          serverWith(buildOutputDir: dir.path, options: options).start(),
          refusedNamingThePort,
        );
        await expectLater(
          StaticWebServer(rootPath: dir.path, options: options).start(),
          refusedNamingThePort,
        );

        // And the refused start gave the socket back. A wildcard bind succeeds
        // on this kernel even against the decoy, so a start that gives up
        // without closing it holds the port for the rest of the process — the
        // one port the next attempt was told to use.
        //
        // Asked by *being* that next attempt: with the decoy gone, the same
        // named port has to start. Binding ::1 beside the wildcard would ask
        // nothing, twice over: a host with no IPv6 cannot run it at all, and
        // where it can, BSD permits a specific address beside a wildcard, so it
        // succeeds whether or not the socket was given back.
        await decoy.close(force: true);
        final next = StaticWebServer(rootPath: dir.path, options: options);
        await next.start();
        await next.stop();
      },
    );

    /// A [Squatter] backed by a real server that answers, and answers wrongly.
    ///
    /// A 200 with a body of its own is the case only a check that reads what
    /// came back can tell from success — adb, the squatter this exists for,
    /// closes the connection without a byte, which is easier to notice, not
    /// harder.
    Future<Squatter> squatterTaking({required bool everyPort}) async {
      final decoy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => decoy.close(force: true));
      decoy.listen((request) {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('the decoy answered');
        request.response.close();
      });
      return everyPort
          ? Squatter.everyPort(decoy.port)
          : Squatter.onePort(decoy.port);
    }

    /// What a run drawing its own port asks for and gets: no hostname of its
    /// own, no fixed port.
    const wildcard = WebServerOptions(
      crossOriginIsolation: false,
      hostname: anyHostname,
    );

    // `--web-port 0` asks for any *free* port, and a port whose traffic the
    // kernel hands to somebody else is not free — so the answer is another
    // draw, not the end of the run.
    test('a wildcard draws again past a port it turns out not to own', () async {
      final dir = bundle();
      final squatter = await squatterTaking(everyPort: false);
      final server = StaticWebServer(rootPath: dir.path, options: wildcard);
      final uri = await squatter.run(server.start);
      addTearDown(server.stop);

      // The interception this is about really happened...
      expect(squatter.taken, hasLength(1));
      // ...and the check carried on past it, which is a second draw: an
      // attempt stops at the first address that does not answer it, so every
      // request after the one that was taken belongs to a later attempt.
      expect(squatter.probed.length, greaterThan(1));
      // ...and what it published is the port it went on to check. Not
      // *another* port: the kernel is free to hand back the one just released,
      // and a run that verified the port it returns is the whole promise.
      expect(uri.port, squatter.probed.last);
      // Observed health rather than a returned value: the URL this run prints
      // serves the bundle.
      final r = await get(uri.replace(path: '/styles.css'));
      expect(r.response.statusCode, HttpStatus.ok);
      expect(r.body, 'body {}');
    });

    // The other half of the same decision, and the one with a user's
    // expectation behind it: a named port is where something else is waiting
    // for this server. Answering with a different port would be the silent
    // move this tool exists not to make.
    test(
      'a named port that is intercepted fails naming it, and is not redrawn',
      () async {
        final dir = bundle();
        // A port that was free a moment ago, taken the way the servers take
        // theirs so the address family cannot differ.
        final free = StaticWebServer(
          rootPath: dir.path,
          options: const WebServerOptions(crossOriginIsolation: false),
        );
        final port = (await free.start()).port;
        await free.stop();

        final squatter = await squatterTaking(everyPort: true);
        await expectLater(
          squatter.run(
            () => StaticWebServer(
              rootPath: dir.path,
              options: WebServerOptions(
                crossOriginIsolation: false,
                hostname: anyHostname,
                port: port,
              ),
            ).start(),
          ),
          throwsDevToolException(
            allOf(
              // Named, with what to do about it — and not the message a search
              // ends with, which would be describing draws this run never made.
              contains('Free port $port'),
              contains('--web-port'),
              isNot(contains('All 5 ports')),
            ),
          ),
        );
        // The whole of what it did: one attempt, on the port it was given.
        expect(squatter.probed, [port]);
      },
    );

    // Five consecutive intercepted draws is not bad luck, and a sixth is not
    // the answer: something on the host is answering across the range, and
    // saying so is what a caller can act on. `HttpMultiServer._loopback`'s own
    // number, for its own version of this search.
    test(
      'a wildcard search gives up after five draws rather than running on',
      () async {
        final dir = bundle();
        final squatter = await squatterTaking(everyPort: true);
        await expectLater(
          squatter.run(
            () =>
                StaticWebServer(rootPath: dir.path, options: wildcard).start(),
          ),
          throwsDevToolException(
            allOf(
              contains('All 5 ports'),
              // Not the named-port message: nobody chose these ports, so "free
              // port N" is advice about a port this run drew for itself.
              isNot(contains('Free port')),
            ),
          ),
        );
        // Bounded, and bounded there: one request per attempt, because each
        // attempt stops at the first address that does not answer.
        expect(squatter.probed, hasLength(5));
      },
    );

    test('custom headers reach the wire on both servers', () async {
      final dir = bundle();
      final bases = await bothServers(
        dir,
        options: const WebServerOptions(
          crossOriginIsolation: false,
          headers: {'X-Custom-Header': 'a value', 'X-Second': 'two'},
        ),
      );
      for (final base in bases) {
        final r = await get(base.replace(path: '/styles.css'));
        expect(
          r.response.headers.value('x-custom-header'),
          'a value',
          reason: '$base',
        );
        expect(r.response.headers.value('x-second'), 'two', reason: '$base');
      }
    });

    test('a custom header cannot retype an asset', () async {
      // The response's own headers win over the server's defaults, so a
      // `--web-header Content-Type=…` is inert where the handler typed the
      // response — which is every asset. Middleware applied after the handler
      // would have broken every MIME type in the bundle instead.
      final dir = bundle();
      final bases = await bothServers(
        dir,
        options: const WebServerOptions(
          crossOriginIsolation: false,
          headers: {'Content-Type': 'text/plain'},
        ),
      );
      for (final base in bases) {
        final r = await get(base.replace(path: '/styles.css'));
        expect(
          r.response.headers.value('content-type'),
          'text/css',
          reason: '$base',
        );
      }
    });

    test('X-Frame-Options is not sent, so the app can be embedded', () async {
      // dart:io adds `SAMEORIGIN` to every response by itself, which is why
      // an app served by this tool could not be put in an iframe. Upstream
      // removes it; so does this. A run that wants it back says
      // `--web-header X-Frame-Options=SAMEORIGIN`.
      final dir = bundle();
      final bases = await bothServers(
        dir,
        options: const WebServerOptions(crossOriginIsolation: false),
      );
      for (final base in bases) {
        final r = await get(base.replace(path: '/styles.css'));
        expect(
          r.response.headers.value('x-frame-options'),
          isNull,
          reason: '$base',
        );
      }

      final withHeader = await bothServers(
        dir,
        options: const WebServerOptions(
          crossOriginIsolation: false,
          headers: {'X-Frame-Options': 'SAMEORIGIN'},
        ),
      );
      for (final base in withHeader) {
        final r = await get(base.replace(path: '/styles.css'));
        expect(
          r.response.headers.value('x-frame-options'),
          'SAMEORIGIN',
          reason: '$base',
        );
      }
    });

    test('TLS serves the bundle over https on both servers', () async {
      // A real handshake against a real certificate: the proof is a body
      // fetched over TLS, not an `isSecure` getter.
      final dir = bundle();
      final tls = writeTestCertificate(dir);
      final options = WebServerOptions(
        crossOriginIsolation: false,
        tlsCertPath: tls.certPath,
        tlsCertKeyPath: tls.keyPath,
      );
      final bases = await bothServers(dir, options: options);
      for (final base in bases) {
        expect(base.scheme, 'https', reason: '$base');
        final r = await get(
          base.replace(path: '/styles.css'),
          acceptAnyCert: true,
        );
        expect(r.response.statusCode, HttpStatus.ok, reason: '$base');
        expect(r.body, 'body {}', reason: '$base');
      }
    });

    // The wildcard's reachability check has to speak the scheme the server
    // serves, and it dials each address numerically — so it meets a
    // self-signed certificate issued for `localhost` while asking for
    // `127.0.0.1` or `::1`. It accepts any certificate for exactly that
    // reason, and identifies the server by the nonce instead. A check that
    // insisted on the certificate would refuse every TLS run on this hostname.
    test(
      'TLS on "any" serves the bundle rather than failing its own check',
      () async {
        final dir = bundle();
        final tls = writeTestCertificate(dir);
        final options = WebServerOptions(
          crossOriginIsolation: false,
          hostname: anyHostname,
          tlsCertPath: tls.certPath,
          tlsCertKeyPath: tls.keyPath,
        );
        final bases = await bothServers(dir, options: options);
        for (final base in bases) {
          expect(base.scheme, 'https', reason: '$base');
          expect(base.host, defaultHostname, reason: '$base');
          final r = await get(
            base.replace(path: '/styles.css'),
            acceptAnyCert: true,
          );
          expect(r.response.statusCode, HttpStatus.ok, reason: '$base');
          expect(r.body, 'body {}', reason: '$base');
        }
      },
    );

    test('an unusable certificate fails naming the flag', () async {
      final dir = bundle();
      final tls = writeTestCertificate(dir);
      await expectLater(
        StaticWebServer(
          rootPath: dir.path,
          options: WebServerOptions(
            crossOriginIsolation: false,
            tlsCertPath: '${dir.path}/not-a-cert.pem',
            tlsCertKeyPath: tls.keyPath,
          ),
        ).start(),
        throwsDevToolException(contains('--web-tls-cert-path')),
      );
      await expectLater(
        StaticWebServer(
          rootPath: dir.path,
          options: WebServerOptions(
            crossOriginIsolation: false,
            tlsCertPath: tls.certPath,
            tlsCertKeyPath: '${dir.path}/not-a-key.pem',
          ),
        ).start(),
        throwsDevToolException(contains('--web-tls-cert-key-path')),
      );
    });

    test('a header dart:io refuses gives back the port it had taken', () async {
      // `defaultResponseHeaders` validates several names and values itself,
      // and it does so *after* the bind. A throw that walked out of here
      // would leave the socket held by a server nobody has a handle to — and
      // with `--web-port` that is the exact port the next attempt needs.
      final dir = bundle();
      final probe = StaticWebServer(
        rootPath: dir.path,
        options: const WebServerOptions(crossOriginIsolation: false),
      );
      final port = (await probe.start()).port;
      await probe.stop();

      // A value dart:io will not take: a header value cannot contain a
      // newline, and it is `defaultResponseHeaders` that says so — after the
      // bind.
      final options = WebServerOptions(
        crossOriginIsolation: false,
        port: port,
        headers: const {'X-Bad': 'one\ntwo'},
      );
      await expectLater(
        StaticWebServer(rootPath: dir.path, options: options).start(),
        throwsDevToolException(
          allOf(contains('--web-header'), contains('X-Bad')),
        ),
      );

      // The proof it was given back: the same port binds again.
      final after = StaticWebServer(
        rootPath: dir.path,
        options: WebServerOptions(crossOriginIsolation: false, port: port),
      );
      expect((await after.start()).port, port);
      await after.stop();
    });

    test('a hostname that does not resolve fails naming the flag', () async {
      final dir = bundle();
      await expectLater(
        StaticWebServer(
          rootPath: dir.path,
          options: const WebServerOptions(
            crossOriginIsolation: false,
            hostname: 'no-such-host.invalid',
          ),
        ).start(),
        throwsDevToolException(
          allOf(
            contains('--web-hostname'),
            contains('no-such-host.invalid'),
          ),
        ),
      );
    });

    test('"any" binds every interface and still reports localhost', () async {
      final dir = bundle();
      final server = StaticWebServer(
        rootPath: dir.path,
        options: const WebServerOptions(
          crossOriginIsolation: false,
          hostname: anyHostname,
        ),
      );
      final uri = await server.start();
      addTearDown(server.stop);

      expect(uri.host, 'localhost');
      // A wildcard, and — where the host has IPv6 — the dual-stack one, so
      // that the `localhost` this URL names is answered on both families
      // rather than on whichever one `any` happened to pick.
      expect(
        server.server!.address.address,
        anyOf(InternetAddress.anyIPv6.address, InternetAddress.anyIPv4.address),
      );
      // And it really answers there.
      final r = await get(uri.replace(path: '/styles.css'));
      expect(r.response.statusCode, HttpStatus.ok);
    });
  });

  group('WebModuleServer.dartSourceContents', () {
    test('says so once when a source lookup fails', () async {
      final logs = captureLogs();
      final dir = tempDir();
      final config = File('${dir.path}/package_config.json')
        ..writeAsStringSync('{ this is not json');
      final server = serverWith(
        workspaceRoot: dir.path,
        packageConfigPath: config.path,
      );

      // DWDS asks for the same source on every debugger view; the condition
      // that breaks the lookup breaks all of them.
      expect(await server.dartSourceContents('packages/app/main.dart'), isNull);
      expect(await server.dartSourceContents('packages/app/main.dart'), isNull);

      expect(logs, hasLength(1));
      expect(logs.single['message'], 'dart_source_lookup_failed');
      expect(logs.single['path'], 'packages/app/main.dart');
      expect(logs.single['text'], contains(config.path));
    });

    test('a source that simply is not there is not a failure', () async {
      final logs = captureLogs();
      final dir = tempDir();
      final config = File('${dir.path}/package_config.json')
        ..writeAsStringSync(json.encode({'configVersion': 2, 'packages': []}));
      final server = serverWith(
        workspaceRoot: dir.path,
        packageConfigPath: config.path,
      );

      expect(await server.dartSourceContents('packages/app/main.dart'), isNull);
      expect(logs, isEmpty);
    });
  });

  // Which of the build's two `package_config.json`s this server may be handed
  // — the pair a `flutter_web_bundle` emits in debug, whose `rootUri`s differ
  // for a source-assembled (codegen) app. The run picks by name
  // (`DevConfig.buildPackageConfig`); these say what the wrong pick costs, so
  // the reason survives the next person who finds two files with the same
  // suffix and reaches for whichever comes first.
  group('WebModuleServer.dartSourceContents package config shapes', () {
    /// A one-package config at `<dir>/package_config.json` with [rootUri].
    File writeConfig(Directory dir, String rootUri) =>
        File('${dir.path}/package_config.json')..writeAsStringSync(
          json.encode({
            'configVersion': 2,
            'packages': [
              {'name': 'app', 'rootUri': rootUri, 'packageUri': 'lib/'},
            ],
          }),
        );

    test('the build config resolves a package: URI to its source', () async {
      final logs = captureLogs();
      final dir = tempDir();
      // What the build config points at: the assembled `.pkgsrcs` copy, named
      // by an ordinary relative rootUri.
      Directory('${dir.path}/app.pkgsrcs/lib').createSync(recursive: true);
      File(
        '${dir.path}/app.pkgsrcs/lib/main.dart',
      ).writeAsStringSync('void main() {}');

      final server = serverWith(
        workspaceRoot: dir.path,
        packageConfigPath: writeConfig(dir, 'app.pkgsrcs').path,
      );

      expect(
        await server.dartSourceContents('packages/app/main.dart'),
        'void main() {}',
      );
      expect(logs, isEmpty);
    });

    test('the dev config resolves it to no source at all', () async {
      final logs = captureLogs();
      final dir = tempDir();
      // The source really is there, and reachable — this is not a missing
      // file. It is unreachable *through this config*.
      Directory('${dir.path}/lib').createSync();
      File('${dir.path}/lib/main.dart').writeAsStringSync('void main() {}');

      final server = serverWith(
        workspaceRoot: dir.path,
        // `generate_dev_package_config` writes exactly this for a
        // source-assembled package: `<filesystemScheme>:///<lib_root>`. The
        // frontend_server resolves it via `--filesystem-root`; nothing that
        // wants a file path can.
        packageConfigPath: writeConfig(dir, 'org-dartlang-app:///').path,
      );

      expect(await server.dartSourceContents('packages/app/main.dart'), isNull);
      expect(logs, hasLength(1));
      expect(logs.single['message'], 'dart_source_lookup_failed');
      expect(logs.single['error'], contains('org-dartlang-app'));
    });
  });
}

/// GET [path] from [server] as text.
Future<String> get(WebModuleServer server, String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(server.uri!.replace(path: path));
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok, reason: 'GET $path');
    // Awaited here, not returned: `return <future>` lets the `finally` below
    // force-close the client while the body is still arriving, which fails as
    // `HttpException: Connection closed while receiving data` on whichever
    // request happens to lose the race.
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}
