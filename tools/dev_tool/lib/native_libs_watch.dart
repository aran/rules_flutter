/// What the running process's native libraries were when it started, whether a
/// build has moved them since, and whether the bindings about to be injected are
/// still ones those libraries can serve.
///
/// A hot reload cannot deliver a native library. The process keeps every image it
/// has `dlopen`ed, so the code in a rebuilt library is simply not reachable from
/// the running app — and the two failure shapes that produced were both silent. A
/// body-only native edit leaves the generated Dart byte-identical, so the reload
/// found nothing changed and reported success while the app ran code from before
/// the edit. A signature change reached the app as new bindings over an old
/// library, where the first wrong byte count surfaced as whatever the bridge's own
/// codec says about a malformed request — a sentence naming neither the library
/// nor the reload.
///
/// So a reload has to ask, and it has to ask without a build of its own: a rebuild
/// of the app's *launch* configuration on every `r` would put a bundle build on
/// the instant path, which is the cost hot reload exists to avoid. The way out is
/// that the reload's own rebuild has already written these files. The
/// `flutter_application` target a codegen reload builds to regenerate its sources
/// declares the app's loose native libraries among its outputs, and
/// `_dev_config.json` carries that list, so the question is answered off the files
/// bazel just wrote.
///
/// ## Two questions, not one
///
/// "Did the library move" is the cheap question and the wrong one to answer with.
/// Once a rebuild has moved a library, the running process can never have its
/// code — that much is settled — but the increment is only *dangerous* if the
/// bindings changed with it. A build says which by declaring a binding contract
/// (see `flutter_native_library`): files whose bytes decide what the generated
/// Dart may call and how it encodes a call. Equal bytes mean the old image can
/// still serve the new increment, so it is delivered and the stale machine code
/// is reported. Changed bytes, or no contract at all, mean it cannot be known to
/// be safe, and nothing is compiled or sent.
///
/// Nothing here parses a contract. Its bytes are the whole of the protocol, which
/// is what keeps this file free of any knowledge about any particular bridge.
///
/// ## Not the authority on replacing a process
///
/// That is `Relauncher`, which compares the launched bundle itself and is the only
/// thing that may swap a process out. This watch answers about the build that ran
/// rather than about the bundle on disk.
library;

import 'dart:io';

import 'native_libs_fingerprint.dart';
import 'native_libs_verdict.dart';

export 'native_libs_verdict.dart';

/// One file as the running process has it: the two facts a `stat` answers, and
/// the content token behind them.
class _Image {
  /// `size:mtime`, which is what bazel moves when it re-runs an action and leaves
  /// alone when it serves one from cache.
  final String stamp;

  /// The content token from [nativeLibsFingerprintOfFiles] — the authority, and
  /// read only when [stamp] has moved.
  final String content;

  const _Image(this.stamp, this.content);
}

class NativeLibsWatch {
  /// Every native library the app bundles, each mapped to the files its bindings
  /// were generated from — empty for a library whose build declared no contract,
  /// which is every app that has not asked for the faster reload.
  ///
  /// Fixed for the life of the run: both lists come from the app's build, and a
  /// change to *which* libraries an app bundles is a different build, not a
  /// reload.
  final Map<String, List<String>> contracts;

  /// What every watched file was when the running process launched — the images
  /// it has mapped, and the contracts they were generated from. Advanced only by
  /// [markLive], so a difference keeps being reported for as long as the process
  /// keeps running the old code.
  Map<String, _Image> _live;

  NativeLibsWatch._(this.contracts, this._live);

  /// A watch over [contracts], baselined at what those files are on disk now.
  ///
  /// Called at assembly, which is after the launch and after the assembler's own
  /// build of the app target — and that build is where this baseline has a window.
  /// It reads the working tree, so a native source saved between the launch build
  /// and it is compiled into these files, and the baseline then describes code the
  /// running process never loaded. The reload after that sees nothing changed and
  /// injects, which is the failure this whole class exists to prevent, in the one
  /// window where it cannot see it.
  ///
  /// Left as a window rather than closed, because closing it costs what the design
  /// is built to avoid. The assembler's build cannot run before the app launches —
  /// its flags come out of the `dart_defines` the *running* app reports — and the
  /// only baseline that is exact without it is the launched bundle's own copy of
  /// the libraries, which lives in the app's launch configuration: comparing
  /// against it on a reload means rebuilding that configuration on every `r`, a
  /// bundle build on the instant path.
  ///
  /// It is also self-healing, which is what makes the trade bearable: a restart
  /// rebuilds the launch target and `Relauncher` compares the launched bundle
  /// itself, which is exact by construction, so the first `R` after the window
  /// relaunches the process and re-baselines this watch through [markLive].
  static Future<NativeLibsWatch> of(
    Map<String, List<String>> contracts,
  ) async => NativeLibsWatch._(contracts, await _read(_allFiles(contracts)));

  /// What this command may do about the native libraries — see [NativeLibsVerdict].
  ///
  /// Two stages, because this runs on every reload and a debug-build Rust or C++
  /// library is tens of megabytes — measured at 126ms to hash 20MB, against 33µs
  /// for a `stat`. A file bazel did not rewrite has the same size and mtime it had
  /// and is never read: that is the Dart-only edit, and it stays free. Only a file
  /// the build actually re-ran an action for is read, and then its *contents*
  /// decide — a rebuild that produced identical bytes is not a change, and
  /// reporting one would withhold a reload that was safe.
  Future<NativeLibsVerdict> verdict() async {
    final movedContracts = await _moved(_allContracts);
    if (movedContracts.isNotEmpty) {
      // Named by library rather than by contract file alone: the reader's first
      // question is which of their native deps this is about, and a generator's
      // output path answers it less well than the library's own name.
      return NativeBindingsMoved(
        libs: [
          for (final entry in contracts.entries)
            if (entry.value.any(movedContracts.contains)) entry.key,
        ]..sort(),
        contracts: movedContracts,
      );
    }

    final movedLibs = await _moved(contracts.keys);
    if (movedLibs.isEmpty) return const NativeLibsCurrent();

    final unverifiable = [
      for (final lib in movedLibs)
        if (contracts[lib]!.isEmpty) lib,
    ];
    // Unknown beats known-safe: one library whose bindings nothing describes is
    // enough to make the whole increment unsafe to inject, however many of its
    // neighbours declared a contract.
    if (unverifiable.isNotEmpty) return NativeLibsUnverifiable(unverifiable);
    return NativeCodeStale(movedLibs);
  }

  /// Record that the process now runs the on-disk code of the libraries named
  /// [fileNames] — a native hot patch delivered it without a new process.
  ///
  /// Their contracts are not advanced: a patch is only delivered when the
  /// bindings did not move, so there is nothing about them to record.
  Future<void> markPatched(Set<String> fileNames) async {
    final patched = [
      for (final library in contracts.keys)
        if (fileNames.contains(library.split('/').last)) library,
    ];
    if (patched.isEmpty) return;
    _live = {..._live, ...await _read(patched)};
  }

  /// Record that the process now runs the libraries on disk.
  ///
  /// Only a relaunch earns this, and for the same reason `Relauncher` advances its
  /// own fingerprint only after a successful swap: a build moves the files, and
  /// nothing but a new process moves what the app has loaded.
  Future<void> markLive() async => _live = await _read(_allFiles(contracts));

  Iterable<String> get _allContracts =>
      contracts.values.expand((files) => files);

  static Iterable<String> _allFiles(Map<String, List<String>> contracts) => [
    ...contracts.keys,
    ...contracts.values.expand((files) => files),
  ];

  /// The watched files among [paths] whose bytes differ from the ones the running
  /// process launched with.
  ///
  /// A file whose stamp matched is never read. A file whose stamp moved but whose
  /// bytes did not has its stamp recorded, which is what keeps it out of the
  /// hashing stage for the rest of the run; a file that really moved is left
  /// un-advanced on purpose, so the next command reaches the same verdict. Only a
  /// new process changes that, through [markLive].
  Future<List<String>> _moved(Iterable<String> paths) async {
    final restamped = <String, String>{};
    for (final path in paths) {
      final stamp = await _stamp(path);
      if (stamp != _live[path]?.stamp) restamped[path] = stamp;
    }
    if (restamped.isEmpty) return const [];

    final content = await nativeLibsFingerprintOfFiles(restamped.keys);
    final moved = <String>[];
    for (final entry in restamped.entries) {
      final path = entry.key;
      if (content[path] != _live[path]?.content) {
        moved.add(path);
      } else {
        _live[path] = _Image(entry.value, content[path]!);
      }
    }
    return moved..sort();
  }

  static Future<Map<String, _Image>> _read(Iterable<String> paths) async {
    final content = await nativeLibsFingerprintOfFiles(paths);
    return {
      for (final path in paths)
        path: _Image(await _stamp(path), content[path]!),
    };
  }

  /// A file's size and mtime as one token. A path that is not there answers a
  /// stamp of its own rather than throwing: the throw belongs to the content read,
  /// which says which file the build declared and did not write.
  static Future<String> _stamp(String path) async {
    final stat = await File(path).stat();
    return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  }
}
