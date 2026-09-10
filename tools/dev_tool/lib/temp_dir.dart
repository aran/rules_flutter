/// Temporary directories that go away when the work that needed them does.
///
/// The tool creates a scratch directory per device query, install, extraction,
/// browser launch and compiler start, and an abandoned one is not merely
/// untidy: a leftover Chrome profile is a real browser a later run can be
/// screenshotted against, so a stale app can produce a passing test.
///
/// Two shapes cover every site:
///
///  * [withTempDir] for a directory scoped to one operation — a JSON file a
///    subprocess writes and the caller reads back. The directory dies with the
///    call, whether it returns or throws.
///  * [createTempDir] plus [deleteTempDir] for a directory that has to outlive
///    the call that made it (an unpacked `.app` the run executes, a browser
///    profile, a compiler's output). The owner holds it in a field and deletes
///    it in its own teardown.
///
/// Deletion never fails a run: a directory already gone is the expected end
/// state, and anything else is reported and stepped over, since losing a
/// scratch directory is not worth failing an otherwise-good run over.
import 'dart:io';

import 'logging.dart';

final _logger = Logger('dev_tool.temp_dir');

/// Create a fresh temp directory named `<prefix><random>`.
///
/// Thin by design — it exists so every site pairs with [deleteTempDir] and a
/// grep for one finds the other.
Future<Directory> createTempDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

/// Delete [dir] and everything in it.
///
/// A directory that is already gone is silent: that is the outcome this
/// function is for. Anything else is reported with the path, because a
/// directory we could not remove is one that will still be there tomorrow.
Future<void> deleteTempDir(Directory dir) async {
  try {
    await dir.delete(recursive: true);
  } on PathNotFoundException {
    // Already gone.
  } on FileSystemException catch (e) {
    _logger.warning({
      'message': 'temp_dir_cleanup_failed',
      'text':
          'Could not remove the temporary directory ${dir.path}: '
          '${e.osError?.message ?? e.message}. It will stay on disk.',
      'path': dir.path,
      'error': '$e',
    });
  }
}

/// Run [body] against a fresh temp directory, removing it afterwards.
///
/// The directory is removed on the way out either way, so a subprocess that
/// fails leaves nothing behind.
Future<T> withTempDir<T>(
  String prefix,
  Future<T> Function(Directory dir) body,
) async {
  final dir = await createTempDir(prefix);
  try {
    return await body(dir);
  } finally {
    await deleteTempDir(dir);
  }
}
