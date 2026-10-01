/// Runs impellerc for one shader, falling back to the Impeller-only stages
/// when the SkSL stage cannot be compiled, as `flutter build` does.
///
/// Some GLSL that every Impeller backend accepts has no SkSL equivalent:
/// indexing a uniform array with a loop variable, for one. `flutter` retries
/// such a shader without `--sksl` and warns, so it builds and loads under
/// Impeller, and fails to load only where the app renders with Skia. This
/// does the same, unless `--require-sksl` makes the SkSL stage mandatory —
/// for a target that renders with Skia.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart compile_shader.dart --impellerc <path> --shader <path>
///       [--require-sksl] -- <impellerc arguments>
library;

import 'dart:io';

/// The arguments of the retry: [args] without `--sksl`, or null when there
/// is no retry to make — no `--sksl`, or nothing but `--sksl` to keep.
List<String>? withoutSksl(List<String> args) {
  if (!args.contains('--sksl')) return null;
  final rest = [
    for (final a in args)
      if (a != '--sksl') a,
  ];
  return rest.any((a) => a.startsWith('--runtime-stage-')) ? rest : null;
}

Future<void> main(List<String> argv) async {
  exit(await compileShader(argv, stderr));
}

/// Runs the compile [argv] describes, reporting to [err]; returns the exit
/// code.
Future<int> compileShader(List<String> argv, StringSink err) async {
  String? impellerc;
  String? shader;
  var requireSksl = false;
  var i = 0;
  for (; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--') {
      i++;
      break;
    } else if (a == '--impellerc' && i + 1 < argv.length) {
      impellerc = argv[++i];
    } else if (a == '--shader' && i + 1 < argv.length) {
      shader = argv[++i];
    } else if (a == '--require-sksl') {
      requireSksl = true;
    }
  }
  final args = argv.sublist(i);
  if (impellerc == null || shader == null || args.isEmpty) {
    err.writeln(
      'Usage: dart compile_shader.dart --impellerc <path> --shader <path> '
      '[--require-sksl] -- <impellerc arguments>',
    );
    return 2;
  }

  final first = await Process.run(impellerc, args);
  if (first.exitCode == 0) return 0;

  final retry = requireSksl ? null : withoutSksl(args);
  if (retry == null) {
    err
      ..write(first.stdout)
      ..write(first.stderr);
    if (requireSksl && withoutSksl(args) != null) {
      err.writeln(
        'Shader $shader does not compile for Skia (SkSL), and this target '
        'sets require_sksl_shaders, so it is an error rather than a warning.',
      );
    }
    return first.exitCode;
  }

  final second = await Process.run(impellerc, retry);
  if (second.exitCode != 0) {
    err
      ..write(first.stdout)
      ..write(first.stderr)
      ..writeln('Retried without --sksl, which failed too:')
      ..write(second.stdout)
      ..write(second.stderr);
    return second.exitCode;
  }
  err
    ..writeln(
      'warning: Shader $shader is incompatible with SkSL. It will not load '
      'when the app renders with Skia. The SkSL error:',
    )
    ..write(first.stdout)
    ..write(first.stderr);
  return 0;
}
