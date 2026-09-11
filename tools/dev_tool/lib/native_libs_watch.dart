/// What the running process's native libraries were when it started, and
/// whether the build a reload just ran has moved any of them.
///
/// A hot reload cannot deliver a native library. The process keeps every image
/// it has `dlopen`ed, so an increment compiled against a rebuilt library is
/// injected over the old machine code — and the two failure shapes that
/// produces are both silent. A body-only native edit leaves the generated Dart
/// byte-identical, so the reload finds nothing changed and reports success while
/// the app runs code from before the edit. A signature change reaches the app as
/// new bindings over an old library, where the first wrong byte count surfaces
/// as whatever the bridge's own codec says about a malformed request — a
/// sentence that names neither the library nor the reload.
///
/// So a reload has to ask, and it has to ask without a build of its own: a
/// rebuild of the app's *launch* configuration on every `r` would put a bundle
/// build on the instant path, which is the cost hot reload exists to avoid. The
/// way out is that the reload's own rebuild has already written these files. The
/// `flutter_application` target a codegen reload builds to regenerate its
/// sources declares the app's loose native libraries among its outputs, and
/// `_dev_config.json` carries that list, so the question is answered off the
/// files bazel just wrote.
///
/// Not the authority on replacing a process — that is `Relauncher`, which
/// compares the launched bundle itself and is the only thing that may swap a
/// process out. This watch is the same question asked where it is free, and it
/// answers about the build that ran rather than about the bundle on disk.
library;

import 'dart:io';

import 'native_libs_fingerprint.dart';

/// One library as the running process has it: the two facts a `stat` answers,
/// and the content token behind them.
class _Image {
  /// `size:mtime`, which is what bazel moves when it re-runs an action and
  /// leaves alone when it serves one from cache.
  final String stamp;

  /// The content token from [nativeLibsFingerprintOfFiles] — the authority, and
  /// read only when [stamp] has moved.
  final String content;

  const _Image(this.stamp, this.content);
}

class NativeLibsWatch {
  /// The native libraries `_dev_config.json` declared, absolute. Fixed for the
  /// life of the run: the list comes from the app's `native_deps`, and a change
  /// to *which* libraries an app bundles is a different build, not a reload.
  final List<String> libs;

  /// What [libs] were when the running process launched — the images it has
  /// mapped. Advanced only by [markLive], so a difference keeps being reported
  /// for as long as the process keeps running the old code.
  Map<String, _Image> _live;

  NativeLibsWatch._(this.libs, this._live);

  /// A watch over [libs], baselined at what they are on disk now.
  ///
  /// Called at assembly, which is after the launch and after the assembler's own
  /// build of the app target — and that build is where this baseline has a
  /// window. It reads the working tree, so a native source saved between the
  /// launch build and it is compiled into these files, and the baseline then
  /// describes code the running process never loaded. The reload after that sees
  /// nothing changed and injects, which is the failure this whole class exists
  /// to prevent, in the one window where it cannot see it.
  ///
  /// Left as a window rather than closed, because closing it costs what the
  /// design is built to avoid. The assembler's build cannot run before the app
  /// launches — its flags come out of the `dart_defines` the *running* app
  /// reports — and the only baseline that is exact without it is the launched
  /// bundle's own copy of the libraries, which lives in the app's launch
  /// configuration: comparing against it on a reload means rebuilding that
  /// configuration on every `r`, a bundle build on the instant path.
  ///
  /// It is also self-healing, which is what makes the trade bearable: a restart
  /// rebuilds the launch target and `Relauncher` compares the launched bundle
  /// itself, which is exact by construction, so the first `R` after the window
  /// relaunches the process and re-baselines this watch through [markLive].
  static Future<NativeLibsWatch> of(List<String> libs) async =>
      NativeLibsWatch._(libs, await _read(libs));

  /// The libraries whose bytes differ from the ones the running process
  /// launched with, or empty when it is still running what it loaded.
  ///
  /// Names them rather than answering yes: the reply a reload refuses with has
  /// to say which library went stale, or the reader is left to guess which of
  /// their native deps the message is about.
  ///
  /// Two stages, because this runs on every reload and a debug-build Rust or C++
  /// library is tens of megabytes — measured at 126ms to hash 20MB, against
  /// 33µs for a `stat`. A library bazel did not rewrite has the same size and
  /// mtime it had, and is never read: that is the Dart-only edit, and it stays
  /// free. Only a library the build actually re-ran an action for is read, and
  /// then its *contents* decide — a rebuild that produced identical bytes is not
  /// a change, and reporting one would withhold a reload that was safe.
  Future<List<String>> movedSinceLaunch() async {
    final restamped = <String, String>{};
    for (final lib in libs) {
      final stamp = await _stamp(lib);
      if (stamp != _live[lib]?.stamp) restamped[lib] = stamp;
    }
    if (restamped.isEmpty) return const [];

    final content = await nativeLibsFingerprintOfFiles(restamped.keys);
    final moved = <String>[];
    for (final entry in restamped.entries) {
      final lib = entry.key;
      if (content[lib] != _live[lib]?.content) {
        // Left un-advanced on purpose: the process still holds the old image,
        // so the next reload has to reach the same verdict. Only a new process
        // changes that, through [markLive].
        moved.add(lib);
      } else {
        // Rewritten with the bytes the app already has. Recording the new stamp
        // is what keeps this out of the hashing stage for the rest of the run.
        _live[lib] = _Image(entry.value, content[lib]!);
      }
    }
    return moved..sort();
  }

  /// Record that the process now runs the libraries on disk.
  ///
  /// Only a relaunch earns this, and for the same reason `Relauncher` advances
  /// its own fingerprint only after a successful swap: a build moves the files,
  /// and nothing but a new process moves what the app has loaded.
  Future<void> markLive() async => _live = await _read(libs);

  static Future<Map<String, _Image>> _read(List<String> libs) async {
    final content = await nativeLibsFingerprintOfFiles(libs);
    return {
      for (final lib in libs) lib: _Image(await _stamp(lib), content[lib]!),
    };
  }

  /// A file's size and mtime as one token. A path that is not there answers a
  /// stamp of its own rather than throwing: the throw belongs to the content
  /// read, which says which file the build declared and did not write.
  static Future<String> _stamp(String path) async {
    final stat = await File(path).stat();
    return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  }
}
