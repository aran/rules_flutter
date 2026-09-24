/// "Now", read off the clock the filesystem stamps files with.
///
/// Every "was this saved before the build?" cutoff compares a file's mtime
/// with an instant taken before the build started, so that instant has to come
/// from the same clock. `DateTime.now()` does not: Linux stamps mtimes from a
/// coarse kernel clock that lags the wall clock by up to a scheduler tick, so a
/// file written just after `now()` can carry a stamp from before it, and the
/// save is then recorded as already delivered.
library;

import 'dart:io';

import '../temp_dir.dart';

/// The mtime of a file written now, as the filesystem stamps it.
///
/// Compare later mtimes against this with `isBefore`: a file written after
/// this call is never stamped before its result, and one stamped *equal* to it
/// is ambiguous and has to be treated as written after — that costs a rebuild
/// of content already delivered, where the other reading loses an edit.
///
/// The marker goes in the system temp directory, not beside the sources, so
/// taking a cutoff never looks like an edit to the watchers. That relies on
/// the two filesystems stamping from the same clock at the same resolution; a
/// source tree on a filesystem that stores coarser stamps (HFS+'s whole
/// seconds, FAT's two) is not covered.
Future<DateTime> fileClockNow() =>
    withTempDir('flutter_bazel_clock_', (dir) async {
      final marker = File('${dir.path}${Platform.pathSeparator}now');
      await marker.writeAsString('');
      return (await marker.stat()).modified;
    });
