/// The dev tool's side of `flutter_native_library.hot_patch`: what a patch
/// builder declares, and how it is asked for a patch.
///
/// A process can never replace a library it has `dlopen`ed, but it can load a
/// second one and send calls there. Building that second library is the
/// language's business — which functions changed, how they reach the state the
/// running copy already holds, whether an edit can be delivered at all — and
/// none of it is known here. What is known here is when to ask and what to do
/// with the answer, and that boundary is this file: a manifest the build writes,
/// a command it names, and one JSON line back.
///
/// Nothing in this file parses a patch or looks inside a library.
library;

import 'dart:convert';
import 'dart:io';

import 'dev_tool_exception.dart';

/// The one file a `hot_patch` target builds that the dev tool looks for by name.
const hotPatchManifestSuffix = '.hot_patch.json';

/// The exported function a patchable library loads a patch through.
///
/// Its address in the running process is what anchors a patch: the patch
/// builder reads where the symbol sits in the library on disk, and the
/// difference is where the whole image was loaded.
const hotPatchApplySymbol = 'flutter_hot_patch_apply';

/// What a `hot_patch` target's manifest declares.
class NativeHotPatchManifest {
  /// Where the manifest itself was read from, for diagnostics.
  final String path;

  /// The library this builder patches, as an execution-root-relative path to
  /// the file its build wrote.
  final String library;

  /// Workspace-relative files whose edit can change [library].
  ///
  /// What a hot reload stats to decide whether to ask for a patch at all, so a
  /// Dart-only edit costs no bazel.
  final List<String> sources;

  /// The patch builder's argv, execution-root-relative, run from the execution
  /// root.
  final List<String> command;

  const NativeHotPatchManifest({
    required this.path,
    required this.library,
    required this.sources,
    required this.command,
  });

  /// Read the manifest at [path], or say which field of it is wrong.
  ///
  /// Every field is checked here rather than where it is used: a manifest is
  /// read once at launch, and a mistake in one should stop that, naming the file,
  /// rather than surface as a patch that fails to build on some later reload.
  static NativeHotPatchManifest parse(String path, String text) {
    Never bad(String what) => throw DevToolException(
      'The hot patch manifest $path $what. It is written by the target a '
      '`flutter_native_library` names as `hot_patch`; see that attribute for '
      'the format.',
    );

    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      bad('is not JSON (${e.message})');
    }
    if (json is! Map<String, Object?>) bad('is not a JSON object');
    // Named, because promotion does not reach into the closure below.
    final Map<String, Object?> fields = json;
    if (fields['version'] != 1) {
      bad(
        'declares version ${jsonEncode(fields['version'])}, and this dev tool '
        'reads version 1',
      );
    }
    final library = fields['library'];
    if (library is! String || library.isEmpty) {
      bad('has no `library` path');
    }
    List<String> strings(String field, {required bool nonEmpty}) {
      final value = fields[field];
      if (value is! List || value.any((v) => v is! String || v.isEmpty)) {
        bad('has a `$field` that is not a list of non-empty strings');
      }
      if (nonEmpty && value.isEmpty) bad('has an empty `$field`');
      return value.cast<String>();
    }

    return NativeHotPatchManifest(
      path: path,
      library: library,
      sources: strings('sources', nonEmpty: true),
      command: strings('command', nonEmpty: true),
    );
  }
}

/// What a patch builder said about one library.
sealed class PatchBuilderAnswer {
  const PatchBuilderAnswer();
}

/// Nothing in the library's code differs from what the process launched with.
final class PatchUnchanged extends PatchBuilderAnswer {
  const PatchUnchanged();
}

/// A patch was built, and [file] is it.
final class PatchBuilt extends PatchBuilderAnswer {
  /// The patch, on this machine.
  final String file;

  /// What the patch replaces, in the builder's own words — for the reply, never
  /// interpreted.
  final List<String> functions;

  const PatchBuilt({required this.file, required this.functions});
}

/// The edit cannot be delivered into the running process.
final class PatchNeedsRestart extends PatchBuilderAnswer {
  /// Sentences naming what changed and why a patch cannot carry it, shown to
  /// the user verbatim.
  final List<String> reasons;

  const PatchNeedsRestart(this.reasons);
}

/// The builder could not build a patch: a compile error, or the builder itself
/// broke.
final class PatchFailed extends PatchBuilderAnswer {
  final String message;

  const PatchFailed(this.message);
}

/// Runs a process to completion from [workingDirectory].
typedef PatchToolRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
    });

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) => Process.run(executable, arguments, workingDirectory: workingDirectory);

/// The patch builder one manifest names.
class NativePatchTool {
  final NativeHotPatchManifest manifest;

  /// Bazel's execution root, which the manifest's paths are relative to.
  final String executionRoot;

  final PatchToolRunner _run;

  NativePatchTool({
    required this.manifest,
    required this.executionRoot,
    PatchToolRunner? run,
  }) : _run = run ?? _runProcess;

  /// Record what the running process launched with, into [stateDirectory].
  ///
  /// Throws [DevToolException] when the builder cannot: without a baseline no
  /// later patch can say what changed, and a run that pretended otherwise would
  /// fail on the first native edit instead of at launch. A builder refuses when
  /// the library cannot be patched soundly at all — built without its patch
  /// routing, or without the debug information its checks read — and its own
  /// sentence says which.
  Future<void> snapshot(String stateDirectory) async {
    final ProcessResult result;
    try {
      result = await _invoke(['snapshot', '--state', stateDirectory]);
    } on ProcessException catch (e) {
      throw DevToolException(
        'The hot patch builder for ${manifest.library} could not be started, '
        'so native edits in this run need a hot restart: ${e.message}',
      );
    }
    final answer = _statusLine(result.stdout as String);
    if (result.exitCode == 0 && answer?['status'] == 'ok') return;
    final message = answer?['status'] == 'failed' ? answer!['message'] : null;
    throw DevToolException(
      'The hot patch builder for ${manifest.library} could not record the '
      'launched library, so native edits in this run need a hot restart.\n'
      '${message is String ? message : _said(result)}',
    );
  }

  /// Ask for a patch against the baseline in [stateDirectory], for a process
  /// that loaded [hotPatchApplySymbol] at [applyAddress], written into
  /// [outputDirectory].
  ///
  /// Never throws for anything the builder did: a builder that exits non-zero or
  /// answers with something other than one of its four statuses is
  /// [PatchFailed], carrying what it printed.
  Future<PatchBuilderAnswer> patch({
    required String stateDirectory,
    required int applyAddress,
    required String outputDirectory,
  }) async {
    final ProcessResult result;
    try {
      result = await _invoke([
        'patch',
        '--state',
        stateDirectory,
        '--symbol',
        '$hotPatchApplySymbol=0x${applyAddress.toRadixString(16)}',
        '--out',
        outputDirectory,
      ]);
    } on ProcessException catch (e) {
      return PatchFailed(
        'The hot patch builder for ${manifest.library} could not be started: '
        '${e.message}',
      );
    }
    final answer = _statusLine(result.stdout as String);
    final parsed = answer == null ? null : _parse(answer);
    if (parsed is PatchFailed || result.exitCode == 0 && parsed != null) {
      return parsed!;
    }
    return PatchFailed(
      'The hot patch builder for ${manifest.library} '
      '${result.exitCode == 0 ? 'answered with no status' : 'exited ${result.exitCode}'}.'
      '\n${_said(result)}',
    );
  }

  Future<ProcessResult> _invoke(List<String> arguments) {
    final [executable, ...prefix] = manifest.command;
    return _run(executable, [
      ...prefix,
      ...arguments,
    ], workingDirectory: executionRoot);
  }

  PatchBuilderAnswer? _parse(Map<String, Object?> json) {
    List<String>? strings(Object? value) =>
        value is List && value.every((v) => v is String)
        ? value.cast<String>()
        : null;
    switch (json['status']) {
      case 'unchanged':
        return const PatchUnchanged();
      case 'patched':
        final file = json['file'];
        final functions = strings(json['functions'] ?? const []);
        if (file is! String || file.isEmpty || functions == null) return null;
        return PatchBuilt(file: file, functions: functions);
      case 'restart':
        final reasons = strings(json['reasons']);
        if (reasons == null || reasons.isEmpty) return null;
        return PatchNeedsRestart(reasons);
      case 'failed':
        final message = json['message'];
        if (message is! String) return null;
        return PatchFailed(message);
    }
    return null;
  }

  /// The builder's answer: the last line of its stdout, when that line is a
  /// JSON object. Anything it printed before is progress, and stderr is
  /// diagnostics — neither is the answer.
  static Map<String, Object?>? _statusLine(String output) {
    final lines = const LineSplitter()
        .convert(output)
        .where((l) => l.trim().isNotEmpty);
    if (lines.isEmpty) return null;
    try {
      final json = jsonDecode(lines.last);
      return json is Map<String, Object?> ? json : null;
    } on FormatException {
      return null;
    }
  }

  static String _said(ProcessResult result) {
    final out = (result.stdout as String).trim();
    final err = (result.stderr as String).trim();
    return [
      if (out.isNotEmpty) 'stdout:\n$out',
      if (err.isNotEmpty) 'stderr:\n$err',
      if (out.isEmpty && err.isEmpty) '(it printed nothing)',
    ].join('\n');
  }
}
