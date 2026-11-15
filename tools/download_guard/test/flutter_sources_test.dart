/// No download in rules_flutter's own repository rules can fetch bytes it has
/// not checked against a pinned digest.
///
/// The property: every `repository_ctx.download*` call in `//flutter` passes a
/// `sha256`, and that value can never be the empty string, whether because it
/// is written as one or because it is a lookup that defaults to one. An empty
/// digest turns Bazel's check off without a word, so a table entry that is
/// missing, or a version nobody added to the table, would download unverified
/// bytes. A missing digest has to stop the fetch instead.
///
/// The sources are found by walking every `.bzl` under `//flutter` that the
/// BUILD file hands this test, so a download added to any of them is checked
/// without being listed here. What the digests *contain* is
/// `//flutter/tests:download_digests_test`; what a fetch *does* with a missing
/// one is `tools/dev_tool/test/e2e/digest_missing_e2e_test.dart`.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../download_sites.dart';

void main() {
  final runfiles = Runfiles.create(
    sourceRepository: Platform.environment['RUNFILES_SOURCE_REPO'] ?? '',
  );
  final paths = (Platform.environment['BZL_SOURCES'] ?? '')
      .split(' ')
      .where((p) => p.isNotEmpty)
      .toList();

  final sites = <DownloadSite>[];
  for (final rlocation in paths) {
    final text = File(runfiles.rlocation(rlocation)).readAsStringSync();
    final file = rlocation.substring(rlocation.indexOf('/') + 1);
    sites.addAll(findDownloadSites(file, text));
  }

  test('the walk found the repository rules', () {
    // Guards the guard: an empty walk would pass everything below.
    final files = sites.map((s) => s.file).toSet();
    expect(
      files,
      containsAll([
        'flutter/private/repositories.bzl',
        'flutter/private/flutter_web_sdk_repo.bzl',
        'flutter/private/flutter_source_files.bzl',
        'flutter/private/flutter_framework_package.bzl',
      ]),
    );
    expect(sites.length, greaterThan(15));
  });

  test('every download site checks the bytes against a non-empty digest', () {
    final unpinned = [
      for (final s in sites)
        if (s.problem != null) '${s.where}: ${s.problem}',
    ];
    expect(
      unpinned,
      isEmpty,
      reason:
          'These calls can download bytes that nothing verifies. A digest '
          'must come from a pinned table or attribute, and a missing one must '
          'fail the fetch naming the artifact.',
    );
  });

  test('every download site passes its digest through pinned()', () {
    // `pinned` (flutter/private/pinned.bzl) refuses a missing or malformed
    // digest before any request is made. A site that hands an attribute or a
    // table lookup straight to the download would fetch unchecked whenever
    // that value happens to be unset. A call to rules_dart's
    // `fetch_pub_archive`, which refuses a missing digest itself, counts as
    // pinned when it is loaded from rules_dart and given a `sha256`.
    final unchecked = [
      for (final s in sites)
        if (!s.isPinned) '${s.where}: ${s.digest ?? 'no sha256'}',
    ];
    expect(
      unchecked,
      isEmpty,
      reason:
          'Wrap the digest: sha256 = pinned("<artifact>", <digest>), so a '
          'missing one fails the fetch naming the artifact. (A hosted pub '
          'package goes through fetch_pub_archive from '
          '@rules_dart//dart/pub:pub_lock_package.bzl, with a sha256.)',
    );
  });
}
