@Tags(['e2e'])
library;

import 'package:test/test.dart';

import 'digest_probe.dart';

/// Fetches of rules_flutter's repositories that are NOT given a usable digest.
///
/// **The property:** every byte rules_flutter downloads is checked against a
/// digest that was pinned for it, so a repository declared with a missing,
/// blank or malformed digest fails its fetch, naming the artifact and the
/// digest, instead of downloading whatever the URL serves.
///
/// ## Why this is the right property
///
/// An empty `sha256` is not an error to Bazel; it is "do not check". Every
/// archive here comes from a bucket or a tag that is not ours, so a check that
/// can be turned off by a gap in a table is a check that fails open: a Flutter
/// version added without its checksums, a mistyped artifact path, an attribute
/// nobody set. Upstream's own tool pins its engine artifacts in `engine.stamp`
/// and refuses a download whose hash differs, and Bazel's documentation tells
/// rule authors to give every `download` a `sha256` so the result is
/// reproducible and can be cached by content. Nothing legitimate needs an
/// unpinned fetch: the digests of everything we download are in
/// `flutter/private/versions.bzl`, and the pub lock records the digest of every
/// hosted archive.
///
/// It is not "every fetch must check the *table*". A repository rule takes its
/// digest as an attribute, and the caller may fill it any way it likes; what
/// must hold is that no path through a rule reaches the network without one.
///
/// ## How it is observed
///
/// See `digest_probe.dart`. A fetch with a digest is served from a local
/// distdir; one without goes to the network, where the fake engine revision or
/// Flutter version answers 404 (or, for a hosted pub package, from `file://`,
/// where it simply succeeds). A refusal is therefore a failed fetch whose
/// output names the digest and the artifact; a 404, or a success, is the
/// fetch having gone ahead without one.
///
/// The control for each case is in `digest_pinned_e2e_test.dart`: the same
/// repository with a correct digest fetches.
void main() {
  late Probe fetcher;

  final archive = zipOf({'sky_engine/lib/a.dart': '// a', 'a.txt': 'a'});
  final digest = sha256Hex(archive);
  const revision = fakeEngineRevision;

  // The sources of the fetches that have a digest in these cases.
  final archives = {
    for (final name in [
      'artifacts.zip',
      'windows-x64-flutter.zip',
      'flutter-cpp-client-wrapper.zip',
      'flutter-web-sdk.zip',
    ])
      name: archive,
  };

  final pubArchive = tarGzOf({
    'pubspec.yaml':
        'name: sample\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n',
    'lib/sample.dart': 'const x = 1;\n',
  });
  late String pubBase;

  /// What each case fetches that must be refused, by repository name. The
  /// value is a name the refusal has to mention.
  final cases = <String, String>{};

  ProbeRepo add(String artifact, ProbeRepo repo) {
    cases[repo.name] = artifact;
    return repo;
  }

  /// A package's repositories, of which the last is its source repository:
  /// the one fetched.
  List<ProbeRepo> addPackage(String artifact, List<ProbeRepo> repos) {
    cases[repos.last.name] = artifact;
    return repos;
  }

  const profilePath = 'android-arm64-profile/artifacts.zip';

  setUpAll(() async {
    pubBase = await servePubArchive('sample', '1.0.0', pubArchive);

    fetcher = await probe(
      archives: archives,
      repos: [
        add(
          'sky_engine.zip',
          ProbeRepo('sky_blank', 'flutter_sky_engine_repo', {
            'engine_revision': str(revision),
            'sha256': str(''),
          }),
        ),
        add(
          'sky_engine.zip',
          ProbeRepo('sky_unset', 'flutter_sky_engine_repo', {
            'engine_revision': str(revision),
          }),
        ),
        // Malformed: Bazel only ever compares a digest with the bytes, so
        // without a check of its own the fetch gets as far as the request.
        add(
          'sky_engine.zip',
          ProbeRepo('sky_short', 'flutter_sky_engine_repo', {
            'engine_revision': str(revision),
            'sha256': str(digest.substring(0, 40)),
          }),
        ),
        add(
          'sky_engine.zip',
          ProbeRepo('sky_nonhex', 'flutter_sky_engine_repo', {
            'engine_revision': str(revision),
            'sha256': str('z' * 64),
          }),
        ),
        add(
          profilePath,
          ProbeRepo('profile_blank', 'flutter_profile_repo', {
            'engine_revision': str(revision),
            'downloads': strDict({profilePath: ''}),
            'sha256s': strDict({profilePath: ''}),
            'build_file_content': str(''),
          }),
        ),
        add(
          profilePath,
          ProbeRepo('profile_unlisted', 'flutter_profile_repo', {
            'engine_revision': str(revision),
            'downloads': strDict({profilePath: ''}),
            'build_file_content': str(''),
          }),
        ),
        add(
          'android-arm64-release/artifacts.zip',
          ProbeRepo('android_release_blank', 'flutter_android_engine_repo', {
            'engine_revision': str(revision),
            'android_arch': str('arm64'),
            'debug_sha256': str(digest),
          }),
        ),
        add(
          'android-arm64/artifacts.zip',
          ProbeRepo('android_debug_blank', 'flutter_android_engine_repo', {
            'engine_revision': str(revision),
            'android_arch': str('arm64'),
            'release_sha256': str(digest),
          }),
        ),
        add(
          'ios-release/artifacts.zip',
          ProbeRepo('ios_release_blank', 'flutter_ios_engine_repo', {
            'engine_revision': str(revision),
            'mode': str('release'),
          }),
        ),
        add(
          'ios/artifacts.zip',
          ProbeRepo('ios_debug_blank', 'flutter_ios_engine_repo', {
            'engine_revision': str(revision),
            'mode': str('debug'),
          }),
        ),
        add(
          'linux-x64-release/linux-x64-flutter-gtk.zip',
          ProbeRepo('desktop_linux_blank', 'flutter_desktop_engine_repo', {
            'engine_revision': str(revision),
            'target_os': str('linux'),
            'target_arch': str('x64'),
          }),
        ),
        add(
          'windows-x64-release/windows-x64-flutter.zip',
          ProbeRepo('desktop_windows_blank', 'flutter_desktop_engine_repo', {
            'engine_revision': str(revision),
            'target_os': str('windows'),
            'target_arch': str('x64'),
            'cpp_wrapper_sha256': str(digest),
          }),
        ),
        add(
          'windows-x64/flutter-cpp-client-wrapper.zip',
          ProbeRepo('desktop_wrapper_blank', 'flutter_desktop_engine_repo', {
            'engine_revision': str(revision),
            'target_os': str('windows'),
            'target_arch': str('x64'),
            'sha256': str(digest),
          }),
        ),
        add(
          'android-arm64-release/darwin-x64.zip',
          ProbeRepo(
            'cross_blank',
            'flutter_cross_compilation_repo',
            {
              'engine_revision': str(revision),
              'host_platform': str('darwin-arm64'),
              'target_platform': str('android-arm64'),
            },
          ),
        ),
        // The web SDK repository fetches two archives; the second is the Dart
        // SDK, which it has no digest attribute for.
        add(
          'dart-sdk',
          ProbeRepo('web_sdk_second_archive', 'flutter_web_sdk_repo', {
            'engine_revision': str(revision),
            'host': str('linux-x64'),
            'sha256': str(digest),
          }),
        ),
        add(
          'flutter-web-sdk.zip',
          ProbeRepo('web_sdk_blank', 'flutter_web_sdk_repo', {
            'engine_revision': str(revision),
            'host': str('linux-x64'),
          }),
        ),
        add(
          'sysroot',
          ProbeRepo('sysroot_blank', 'flutter_linux_sysroot_repo', {
            'target_arch': str('x64'),
            'sha256': str(''),
          }),
        ),
        add(
          '$fakeFlutterVersion.tar.gz',
          ProbeRepo('dev_root_blank', 'flutter_dev_root_repo', {
            'flutter_version': str(fakeFlutterVersion),
            'sha256': str(''),
          }),
        ),
        add(
          '$fakeFlutterVersion.tar.gz',
          ProbeRepo('gen_l10n_blank', 'flutter_gen_l10n_repo', {
            'flutter_version': str(fakeFlutterVersion),
            'sha256': str(''),
          }),
        ),
        add(
          '$fakeFlutterVersion.tar.gz',
          ProbeRepo('sdk_package_blank', 'flutter_framework_package', {
            'flutter_version': str(fakeFlutterVersion),
            'sha256': str(''),
          }),
        ),
        ...addPackage(
          '$fakeFlutterVersion.tar.gz',
          sdkSourcePackage(
            'sdk_source_blank',
            package: 'integration_test',
            sha256: '',
            packages: ['integration_test'],
          ),
        ),
        // A hosted pub package is served from file://, so an unpinned fetch
        // of it does not fail at all.
        ...addPackage(
          'sample',
          hostedPubPackage(
            'pub_blank_explicit',
            package: 'sample',
            version: '1.0.0',
            sha256: '',
            baseUrl: pubBase,
          ),
        ),
      ],
    );
  });

  /// A fetch that must be refused: it fails, and says why, naming the
  /// artifact.
  void refused(String repo, {required String property}) {
    test('$repo: $property', () async {
      final result = await fetcher.fetch(repo);
      expect(
        result.succeeded,
        isFalse,
        reason:
            'the fetch went ahead with no digest to check it against\n$result',
      );
      expect(
        result.namesTheDigest,
        isTrue,
        reason:
            'the fetch failed, but not for want of a digest: it should say '
            'the digest is missing or malformed\n$result',
      );
      expect(
        result.output,
        contains(cases[repo]),
        reason: 'the refusal should name the artifact\n$result',
      );
    });
  }

  group('a blank, unset or malformed digest fails the fetch before it fetches, '
      'naming the artifact', () {
    for (final repo in [
      'sky_blank',
      'sky_unset',
      'sky_short',
      'sky_nonhex',
      'profile_blank',
      'profile_unlisted',
      'android_release_blank',
      'android_debug_blank',
      'ios_release_blank',
      'ios_debug_blank',
      'desktop_linux_blank',
      'desktop_windows_blank',
      'desktop_wrapper_blank',
      'cross_blank',
      'web_sdk_blank',
      'sysroot_blank',
      'dev_root_blank',
      'gen_l10n_blank',
      'sdk_package_blank',
      'sdk_source_blank',
      'pub_blank_explicit',
    ]) {
      refused(repo, property: 'is refused');
    }
  });

  test(
    'web_sdk_second_archive: the Dart SDK the web SDK repo unpacks is pinned '
    'too, or not fetched',
    () async {
      // Given a digest for the web SDK archive itself, the repository goes on
      // to fetch the Dart SDK, for which it has no digest at all. Either it
      // refuses that fetch, naming the digest, or it does not make it.
      final result = await fetcher.fetch('web_sdk_second_archive');
      if (result.succeeded) {
        fail(
          'the web SDK repo fetched a Dart SDK that nothing verifies\n$result',
        );
      }
      expect(result.namesTheDigest, isTrue, reason: '$result');
      expect(result.output, contains('dart-sdk'), reason: '$result');
    },
  );
}
