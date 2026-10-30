/// Whatever a reload withholds over a native edit, the action its advice names
/// works, does what the advice said it would, and leaves the tool agreeing
/// that it worked.
///
/// The reload and the restart decide from different evidence about one edit.
/// The reload asks [NativeLibsWatch] (stats of sources, contracts and the dev
/// build's libraries) and the patch builder (sources against its snapshot);
/// the restart asks [Relauncher], which compares the launched bundle itself.
/// An edit can move one and not the other — a declaration added to a header
/// moves the sources and the contract and, on Mach-O, not one bundled byte —
/// and where they disagree the tool can end up refusing every way forward.
///
/// So this drives all of them for real, over files a model build writes, and
/// asserts one property across a sequence of native edits rather than one
/// reply per case: a reload either lands cleanly, or its advice names an
/// action; that action does what the advice says; and a reload after it, over
/// the same tree, lands cleanly. In a run that launched the app the action is a
/// restart, which relaunches exactly when the code the app runs differs from
/// what the tree builds. In an `attach` run it is launching the app again,
/// and a restart — which it says cannot deliver the edit — must not.
/// Only bazel, the device and the builder's own judgement are modelled.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bazel_dev_tool/bazel.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/applied_versions.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/reload_orchestrator.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/session_reloader.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/source_uri_resolver.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/workspace.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:flutter_bazel_dev_tool/native_hot_patcher.dart';
import 'package:flutter_bazel_dev_tool/native_libs_fingerprint.dart';
import 'package:flutter_bazel_dev_tool/native_libs_relauncher.dart';
import 'package:flutter_bazel_dev_tool/native_libs_watch.dart';
import 'package:flutter_bazel_dev_tool/native_patch_delivery.dart';
import 'package:flutter_bazel_dev_tool/relaunch_outcome.dart';
import 'package:flutter_bazel_dev_tool/reload_pipeline.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/session_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

const _launched = '''
#include <stdint.h>
int32_t mul(int32_t a, int32_t b);
''';

const _body = '''
#include "mul.h"
int32_t mul(int32_t a, int32_t b) { return a * b; }
''';

/// Sixteen bytes that differ whenever [text] does, for all the texts here.
List<int> _digest(String text) {
  var hash = 0xcbf29ce484222325;
  final out = <int>[];
  for (var round = 0; round < 2; round++) {
    for (final byte in utf8.encode('$round$text')) {
      hash = ((hash ^ byte) * 0x100000001b3) & 0xffffffffffffffff;
    }
    for (var i = 0; i < 8; i++) {
      out.add((hash >> (8 * i)) & 0xff);
    }
  }
  return out;
}

/// A 64-bit Mach-O carrying only an `LC_UUID`, set to [digest].
Uint8List _machO(List<int> digest) {
  final bytes = ByteData(32 + 24);
  bytes.setUint32(0, 0xfeedfacf, Endian.little);
  bytes.setUint32(16, 1, Endian.little);
  bytes.setUint32(32, 0x1b, Endian.little);
  bytes.setUint32(36, 24, Endian.little);
  final out = bytes.buffer.asUint8List();
  out.setRange(40, 56, digest);
  return out;
}

/// The lines of [source] a compiler reads: what is left after comments and
/// blank lines.
String _code(String source) => [
  for (final line in const LineSplitter().convert(source))
    if (line.replaceFirst(RegExp(r'//.*'), '').trim() case final code
        when code.isNotEmpty)
      code,
].join('\n');

/// How the platform's linker treats the header. A declaration nothing defines
/// or calls leaves a Mach-O byte-identical; an ELF build here did not.
enum _Platform { machO, elf }

/// What the app declares about `libmul`.
enum _Library {
  /// A binding contract and a hot-patch builder, as `ffi_example` declares.
  patchable,

  /// A binding contract and no builder.
  contracted,

  /// Neither: every edit is one nothing can vouch for.
  undeclared,

  /// Neither, and no sources the build can name either — a library reached
  /// through a rule the source walk does not follow. Only its built bytes say
  /// it changed.
  sourceless,
}

class _World {
  final Directory tmp;
  final _Platform platform;
  final _Library library;

  late final String workspace = p.join(tmp.path, 'ws');
  late final String execRoot = p.join(tmp.path, 'exec');
  late final String bundle = p.join(tmp.path, 'app.app');
  late final File header = File(p.join(workspace, 'native', 'mul.h'));
  late final File body = File(p.join(workspace, 'native', 'mul.c'));
  late final String devLib = p.join(execRoot, 'bazel-out/dev/bin/libmul.dylib');
  late final String builtLib = p.join(
    execRoot,
    'bazel-out/launch/bin/libmul.dylib',
  );

  _World(this.tmp, this.platform, this.library);

  /// The image a build of the tree produces now.
  Uint8List image() => _machO(
    _digest(
      [
        _code(body.readAsStringSync()),
        if (platform == _Platform.elf) _code(header.readAsStringSync()),
      ].join('\n--\n'),
    ),
  );

  /// The hot-patch aspect's build: the library in the launch configuration.
  Future<void> buildLibrary() async => File(builtLib).writeAsBytesSync(image());

  /// The launch target's build: that library, and the bundle that carries it.
  /// The dev build's library is written once, at launch: in an app that is not
  /// source-assembled nothing rebuilds it between commands.
  Future<bool> buildLaunch() async {
    await buildLibrary();
    File(p.join(bundle, 'libmul.dylib')).writeAsBytesSync(image());
    return true;
  }

  void setUp() {
    header
      ..createSync(recursive: true)
      ..writeAsStringSync(_launched);
    body.writeAsStringSync(_body);
    Directory(bundle).createSync();
    File(devLib)
      ..createSync(recursive: true)
      ..writeAsBytesSync(image());
    File(builtLib).createSync(recursive: true);
    File(p.join(workspace, 'lib', 'main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
  }
}

/// The builder, modelled on `ffi_example`'s C one: a declaration the launched
/// image does not have needs a restart; a body edit is a patch.
class _Builder {
  final _World world;

  _Builder(this.world);

  Future<ProcessResult> run(
    String exe,
    List<String> args, {
    required String workingDirectory,
  }) async {
    final state = Directory(args[args.indexOf('--state') + 1]);
    final header = _code(world.header.readAsStringSync());
    final body = _code(world.body.readAsStringSync());
    String answer;
    if (args.first == 'snapshot') {
      File(p.join(state.path, 'header')).writeAsStringSync(header);
      File(p.join(state.path, 'body')).writeAsStringSync(body);
      answer = '{"status":"ok"}';
    } else if (File(p.join(state.path, 'header')).readAsStringSync() !=
        header) {
      answer = jsonEncode({
        'status': 'restart',
        'reasons': ['what native/mul.h declares changed since launch'],
      });
    } else if (File(p.join(state.path, 'body')).readAsStringSync() != body) {
      final out = args[args.indexOf('--out') + 1];
      final patch = File(p.join(out, 'libmul_patch.dylib'))
        ..writeAsStringSync(body);
      answer = jsonEncode({
        'status': 'patched',
        'file': patch.path,
        'functions': ['mul_body'],
      });
    } else {
      answer = '{"status":"unchanged"}';
    }
    return ProcessResult(1, 0, answer, '');
  }
}

class _Delivery extends NativePatchDelivery {
  @override
  String libraryLoadPath(String libraryFileName) => libraryFileName;

  @override
  Future<String> deliver({
    required String localFile,
    required String appDirectory,
    required String name,
  }) async => '$appDirectory/$name';
}

class _PatchTarget implements NativePatchTarget {
  @override
  String get appId => 'app1';

  @override
  final NativePatchDelivery delivery = _Delivery();

  @override
  Future<Map<String, dynamic>?> callExtension(
    String method,
    Map<String, String> args,
  ) async => switch (method) {
    'ext.rules_flutter.nativeSymbolAddress' => {'address': '0x1f00'},
    'ext.rules_flutter.nativePatchDirectory' => {'path': '/app/tmp'},
    'ext.rules_flutter.applyNativePatch' => {'applied': true},
    _ => {},
  };
}

/// A pipeline wired the way `NativePipelineAssembler` wires one, over [world],
/// for an app launched from the tree as it is now.
///
/// [launched] is whether the run launched the app. An `attach` run gets the
/// watch and nothing else: no relauncher, because it may not replace a
/// process it did not start, and no patcher, which is armed beside it.
Future<SessionHost> _assemble(_World world, {required bool launched}) async {
  final host = SessionHost(isMachine: false, logger: Logger('test.advice'));
  final pipeline = ReloadPipeline(host: host);
  host.registerReloadCommands(pipeline);
  final resolver = SourceUriResolver(
    workspaceRoot: world.workspace,
    sourcePackages: const [(name: 'app', libRoot: '')],
  );
  final workspace = Workspace(resolver: resolver);
  pipeline
    ..resolver = resolver
    ..workspaceView = workspace
    ..entrypoint = 'package:app/main.dart';
  final snap = workspace.snapshot();
  pipeline.appliedVersions.markApplied(snap, files: snap.fileUris.toSet());
  final app = FakeAppInstance(id: 'app1');
  final orchestrator = pipeline.orchestrator = ReloadOrchestrator(
    workspace: workspace,
    units: [
      SessionReloader(
        id: 'app1',
        compiler: FakeCompiler(),
        applied: AppliedVersions.from(pipeline.appliedVersions),
        app: app,
      ),
    ],
    entrypoint: 'package:app/main.dart',
  );

  await world.buildLaunch();
  final watch = await NativeLibsWatch.of(
    {
      world.devLib: [
        if (world.library case _Library.patchable || _Library.contracted)
          world.header.path,
      ],
    },
    sources: {
      world.devLib: [
        if (world.library != _Library.sourceless) ...[
          world.body.path,
          world.header.path,
        ],
      ],
    },
  );
  pipeline.nativeLibsVerdict = watch.verdict;

  if (!launched) {
    // What the assembler wires for a run with no relauncher: the dev build,
    // which writes the libraries the watch reads.
    pipeline.rebuildNativeLibs = () async {
      File(world.devLib).writeAsBytesSync(world.image());
      return true;
    };
    pipeline.ready.signalReady();
    return host;
  }

  NativeHotPatcher? patcher;
  if (world.library == _Library.patchable) {
    final manifest =
        File(
          p.join(world.execRoot, 'bazel-out/launch/bin/mul.hot_patch.json'),
        )..writeAsStringSync(
          jsonEncode({
            'version': 1,
            'library': 'bazel-out/launch/bin/libmul.dylib',
            'sources': ['native/mul.c', 'native/mul.h'],
            'command': ['builder'],
          }),
        );
    final armed = patcher = await NativeHotPatcher.arm(
      workspace: world.workspace,
      build: () async {
        await world.buildLibrary();
        return BazelAspectOutputs(
          exitCode: 0,
          files: [manifest.path, world.builtLib],
          executionRoot: world.execRoot,
          stderr: '',
        );
      },
      appFile: world.bundle,
      targets: () => [_PatchTarget()],
      logger: Logger('test.advice.patcher'),
      scratch: Directory(p.join(world.tmp.path, 'scratch'))..createSync(),
      runTool: _Builder(world).run,
    );
    pipeline
      ..patchNativeLibs = armed!.patchIfMoved
      ..patchableNativeLibs = (() => armed.libraries)
      ..markNativeLibsPatched = watch.markPatched
      ..reassembleNativePatched = armed.reassembleChanged;
  }

  final relauncher = Relauncher(
    appFile: world.bundle,
    rebuild: world.buildLaunch,
    // No session to swap: the device is what this does not model.
    sessions: <DeviceSession>[],
    protocol: MachineProtocol(enabled: false, commandRunner: CommandRunner()),
    orchestrator: orchestrator,
    assetsDir: '',
    logger: Logger('test.advice.relauncher'),
    liveFingerprint: await nativeLibsFingerprint(world.bundle),
    nativeLibs: watch,
    patchedLibs: patcher == null ? null : () => patcher!.livePatchedLibraries,
    catchUpPatcher: patcher == null
        ? null
        : ({required newProcess}) async {
            if (newProcess || await patcher!.sourcesMoved()) {
              await patcher!.rebaseline();
            }
          },
  );
  pipeline.relaunchIfNativeLibsChanged = () async {
    final outcome = await relauncher.relaunchIfNeeded();
    // What reconnecting to the replacement process does on a device.
    if (outcome is Relaunched) orchestrator.syncLiveApps([app]);
    return outcome;
  };
  pipeline.ready.signalReady();
  return host;
}

void main() {
  /// Edits made in order, each over the tree the one before left.
  final edits = <(String, void Function(_World))>[
    (
      'a body edit',
      (w) => w.body.writeAsStringSync(
        _body.replaceFirst('a * b', 'a * b + 1000'),
      ),
    ),
    ('the body edit undone', (w) => w.body.writeAsStringSync(_body)),
    (
      'a declaration added to the header',
      (w) => w.header.writeAsStringSync(
        '$_launched'
        'int32_t mul_twice(int32_t a);\n',
      ),
    ),
    (
      'a body edit over the edited header',
      (w) => w.body.writeAsStringSync(
        _body.replaceFirst('a * b', 'a * b + 2000'),
      ),
    ),
    (
      'a comment in the header',
      (w) => w.header.writeAsStringSync(
        '// Multiplies.\n${w.header.readAsStringSync()}',
      ),
    ),
    (
      'everything undone',
      (w) {
        w.header.writeAsStringSync(_launched);
        w.body.writeAsStringSync(_body);
      },
    ),
    (
      'a comment in the body',
      (w) => w.body.writeAsStringSync('// Multiplies.\n$_body'),
    ),
  ];

  for (final launched in [true, false]) {
    for (final platform in _Platform.values) {
      for (final library in _Library.values) {
        test('${launched ? 'launched' : 'attached'}, on ${platform.name}, a '
            '${library.name} library: the advice names an action that works', () async {
          final tmp = await Directory.systemTemp.createTemp('restart_advice_');
          addTearDown(() => tmp.delete(recursive: true));
          final world = _World(tmp, platform, library)..setUp();
          var host = await _assemble(world, launched: launched);

          // What the process runs, in the model's terms: the image it
          // launched from, or null while a patch has it on other code.
          Uint8List? running = world.image();

          Future<Map<String, dynamic>> run(String method) =>
              host.commandRunner.run(method, {});

          bool clean(Map<String, dynamic> reply) =>
              reply['succeeded'] == true &&
              !reply.containsKey('nativeLibsStale');

          void track(Map<String, dynamic> reply) {
            if (reply.containsKey('nativePatched')) running = null;
            if (reply.containsKey('nativeReverted')) running = world.image();
            if (reply['relaunched'] == true) running = world.image();
          }

          /// Hold [reply] to its advice: when it did not land, take the action
          /// it names, check that action does what it said, and require the
          /// tree to be delivered afterwards.
          Future<void> settle(
            String name,
            String verb,
            Map<String, dynamic> reply,
          ) async {
            if (clean(reply)) return;
            final advice = '${reply['message']}';
            if (advice.contains('Stop the app, launch it again')) {
              if (verb == 'reload') {
                // It says a restart cannot deliver the edit. Hold it to that.
                final restart = await run('app.restart');
                expect(
                  clean(restart),
                  isFalse,
                  reason:
                      'after $name, the advice said a restart cannot deliver '
                      'it, and the restart answered: ${restart['message']}',
                );
              }
              host = await _assemble(world, launched: launched);
              running = world.image();
            } else {
              expect(
                advice,
                contains('restart (R'),
                reason: 'after $name, the $verb named no action: $advice',
              );
              final restart = await run('app.restart');
              expect(
                clean(restart),
                isTrue,
                reason:
                    'after $name, the $verb advised a restart and the '
                    'restart answered: ${restart['message']}',
              );
              // It said a restart relaunches when the code the app runs
              // differs from what the tree builds, and restarts in place
              // otherwise.
              final differs =
                  running == null || !_sameBytes(running!, world.image());
              expect(
                restart['relaunched'] == true,
                differs,
                reason:
                    'after $name, the advice described the restart, and the '
                    'restart answered: ${restart['message']}',
              );
              track(restart);
            }
            final again = await run('app.hotReload');
            expect(
              clean(again),
              isTrue,
              reason:
                  'after $name and the action its advice named, a reload over '
                  'the same tree answered: ${again['message']}',
            );
          }

          for (final (name, edit) in edits) {
            edit(world);
            final reload = await run('app.hotReload');
            track(reload);
            await settle(name, 'reload', reload);

            // A reload runs no build, so it may miss what only a build shows.
            // A restart may not: when it says it delivered the tree, the app
            // runs what the tree builds.
            final restart = await run('app.restart');
            track(restart);
            if (clean(restart)) {
              expect(
                running != null && _sameBytes(running!, world.image()),
                isTrue,
                reason:
                    'after $name, a restart answered "${restart['message']}" '
                    'while the app runs native code the tree no longer builds',
              );
            } else {
              await settle(name, 'restart', restart);
            }
          }
        });
      }
    }
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
