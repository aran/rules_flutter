/// Every `bzl_library` in rules_flutter lists, as direct `deps`, the libraries
/// of every file its sources `load()`, and nothing else.
///
/// Stardoc and other consumers of `bzl_library` follow `load()` statements
/// through the transitive `.bzl` files of a target's deps. A dep that is left
/// out works for as long as another target pulls the file in, and fails
/// without warning when that changes. See `bzl_library_deps.dart` for the
/// property and what it reads.
///
/// The BUILD files and `.bzl` files are the `bzl_library_inputs` filegroup of
/// each package that declares a `bzl_library`; a package that gains its first
/// one must be added to this test's data (BUILD.bazel) and to the list below.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../bzl_library_deps.dart';

/// Loads of other repositories that a library named for the file does not
/// cover. Each entry is an upstream gap; drop it when upstream closes it.
const _exceptions = ExternalExceptions(
  // The library that holds the file is named otherwise.
  library: {
    '@rules_android//providers:providers.bzl':
        '@rules_android//providers:providers_bzl',
    '@rules_java//java/common:java_common.bzl':
        '@rules_java//java/common:common',
    '@rules_java//java/common:java_info.bzl': '@rules_java//java/common:common',
    '@rules_java//java/common:proguard_spec_info.bzl':
        '@rules_java//java/common:proguard_spec_info_bzl',
    '@rules_java//java:java_import.bzl': '@rules_java//java:core_rules',
    '@rules_java//java:java_library.bzl': '@rules_java//java:core_rules',
  },
  // No library a dependent may use holds the file.
  noLibrary: {
    '@platforms//host:constraints.bzl':
        'platforms declares no bzl_library for host/constraints.bzl',
    '@rules_android//android:rules.bzl':
        'rules_android declares no bzl_library for android/rules.bzl',
    '@rules_android//rules:utils.bzl':
        'rules_android\'s library for rules/utils.bzl is visible to its own '
        'packages only',
    '@rules_apple//apple/internal:framework_import_support.bzl':
        'rules_apple\'s library for apple/internal/framework_import_support.bzl '
        'is not visible outside rules_apple',
    '@rules_apple//apple/internal:resources.bzl':
        'rules_apple\'s library for apple/internal/resources.bzl is not '
        'visible outside rules_apple',
    '@rules_apple//apple/internal/aspects:resource_aspect.bzl':
        'rules_apple\'s library for apple/internal/aspects/resource_aspect.bzl '
        'is not visible outside rules_apple',
    '@rules_kotlin//kotlin:android.bzl':
        'rules_kotlin declares no bzl_library for kotlin/android.bzl',
    '@rules_kotlin//kotlin:core.bzl':
        'rules_kotlin declares no bzl_library for kotlin/core.bzl',
  },
);

void main() {
  final runfiles = Runfiles.create(
    sourceRepository: Platform.environment['RUNFILES_SOURCE_REPO'] ?? '',
  );
  final rlocations = (Platform.environment['BZL_LIBRARY_INPUTS'] ?? '')
      .split(' ')
      .where((p) => p.isNotEmpty)
      .toList();

  // rlocation paths are `<repo>/<package>/<file>`.
  final texts = <String, String>{};
  final packages = <String>{};
  for (final rlocation in rlocations) {
    final path = rlocation.substring(rlocation.indexOf('/') + 1);
    texts[path] = File(runfiles.rlocation(rlocation)).readAsStringSync();
    if (path.endsWith('BUILD.bazel')) {
      packages.add(path.substring(0, path.length - '/BUILD.bazel'.length));
    }
  }

  final libraries = [
    for (final package in packages)
      ...bzlLibrariesOf(package, texts['$package/BUILD.bazel']!),
  ];

  test('the walk found the bzl_library targets', () {
    // Guards the guard: an empty walk would pass everything below.
    expect(
      packages,
      containsAll([
        'flutter',
        'flutter/private',
        'flutter/pub',
        'flutter/ext/go_router',
      ]),
    );
    expect(libraries.length, greaterThan(100));
  });

  test('every bzl_library lists exactly the libraries its sources load', () {
    final problems = checkBzlLibraries(
      libraries,
      readBzl: (file) =>
          texts['${file.pkg}/${file.name}'] ??
          (throw StateError('not an input of this test')),
      exceptions: _exceptions,
    );
    if (problems.isNotEmpty) {
      // One line each, whole: a matcher's failure message cuts a long list.
      fail(
        'A bzl_library depends on the library of each file it loads, '
        'directly: add the missing deps, drop the unneeded ones.\n'
        '${problems.join('\n')}',
      );
    }
  });
}
