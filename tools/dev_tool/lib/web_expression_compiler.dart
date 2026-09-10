/// Compiling a debugger's Dart expression to JavaScript against the running
/// app.
///
/// When a debugger evaluates `widget.title` at a breakpoint, someone has to
/// compile that fragment against the program's real libraries and scopes. Only
/// the resident frontend server can: it is holding the compiled state of the
/// very program the browser is running. DWDS asks through this interface, and
/// this adapter is the one place the two vocabularies meet.
///
/// Without it DWDS has no compiler at all and every evaluation comes back as
/// an error, which is exactly what `--no-web-enable-expression-evaluation`
/// asks for — so this file's presence or absence *is* the flag.
library;

import 'dart:io';

import 'package:dwds/dwds.dart';

import 'frontend_server.dart';

/// DWDS's [ExpressionCompiler], answered by our resident frontend server.
///
/// The frontend server's answer is a file path, not a value: it writes the
/// compiled JavaScript — or, when the fragment does not compile, the error to
/// show in place of a value — and names the file on the protocol's result
/// line. Reading it here is what upstream's `WebExpressionCompiler` does too.
class FrontendServerExpressionCompiler implements ExpressionCompiler {
  final FrontendServer _server;

  FrontendServerExpressionCompiler(this._server);

  @override
  Future<ExpressionCompilationResult> compileExpressionToJs(
    String isolateId,
    String libraryUri,
    String scriptUri,
    int line,
    int column,
    Map<String, String> jsModules,
    Map<String, String> jsFrameValues,
    String moduleName,
    String expression,
  ) async {
    final result = await _server.compileExpressionToJs(
      libraryUri: libraryUri,
      scriptUri: scriptUri,
      line: line,
      column: column,
      jsModules: jsModules,
      jsFrameValues: jsFrameValues,
      moduleName: moduleName,
      expression: expression,
    );

    // No output file at all means the compiler never got to write one — it
    // was shutting down, or it had been terminated for going unanswered.
    // Distinct from "compiled, with errors", which has a file full of them.
    if (result.outputPath.isEmpty) {
      return ExpressionCompilationResult(
        'InternalError: the compiler did not answer a request to compile '
        "'$expression'"
        '${result.diagnostics.isEmpty ? '' : ': ${result.diagnostics}'}',
        true,
      );
    }

    final String output;
    try {
      output = File(result.outputPath).readAsStringSync();
    } on FileSystemException catch (e) {
      // The compiler named a file it did not write, or wrote somewhere
      // unreadable. Said plainly rather than surfaced as a raw exception out
      // of a debugger evaluation.
      return ExpressionCompilationResult(
        "InternalError: the compiler reported compiling '$expression' to "
        '${result.outputPath}, which could not be read (${e.osError ?? e}).',
        true,
      );
    }
    return ExpressionCompilationResult(output, !result.success);
  }

  /// Nothing to do: the resident compiler already holds the program's state
  /// and updates it on every recompile, so there are no module summaries for
  /// this adapter to load. Upstream's answer is the same constant.
  @override
  Future<bool> updateDependencies(Map<String, ModuleInfo> modules) async =>
      true;

  /// Nothing to do: the module format and experiments are already on the
  /// resident compiler's own command line, where they hold for every request
  /// it serves. Upstream's answer is the same no-op.
  @override
  Future<void> initialize(CompilerOptions options) async {}
}
