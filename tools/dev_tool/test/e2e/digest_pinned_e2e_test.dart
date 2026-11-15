@Tags(['e2e'])
library;

import 'dart:convert';

import 'package:test/test.dart';

import 'digest_probe.dart';

/// Fetches of rules_flutter's repositories that are given a digest.
///
/// The property (with `digest_missing_e2e_test.dart`, its other half): every
/// byte a repository fetches is checked against a digest that was pinned for
/// it. This half is the cases where one *was* given:
///
///  * a correct digest fetches, with no network (the control: it shows the
///    refusals in the other file are about the digest and not about the
///    harness);
///  * a wrong digest, or one that is not a SHA-256 at all, fails the fetch.
///    (Bazel does not check a digest's shape: it compares it with the bytes
///    it fetched and refuses a mismatch, so a malformed one can never be
///    satisfied. Refusing it *before* any request, naming the digest, is
///    `digest_missing_e2e_test.dart`.)
///
/// These pass today, because Bazel itself enforces a digest it is handed.
/// They stay as the floor under whatever rules_flutter adds in front of that.
void main() {
  late Probe fetcher;

  // `gen_snapshot` is there because the cross-compilation repo checks that the
  // archive it unpacked holds one.
  final archive = zipOf({
    'sky_engine/lib/a.dart': '// a',
    'a.txt': 'a',
    'gen_snapshot': '',
  });
  final digest = sha256Hex(archive);

  // The web SDK repo also fetches the Dart SDK of whichever host it runs on,
  // and strips its leading `dart-sdk/`.
  final dartSdk = zipOf({'dart-sdk/version': '1'});
  final dartSdkDigest = sha256Hex(dartSdk);
  const hostPlatforms = [
    'darwin-arm64',
    'darwin-x64',
    'linux-arm64',
    'linux-x64',
    'windows-x64',
  ];
  final wrongDigest = '0' * 64;
  const revision = fakeEngineRevision;

  // A Flutter SDK package is fetched from the source tarball of a release.
  final flutterSource = tarGzOf({
    'flutter-$fakeFlutterVersion/packages/integration_test/pubspec.yaml':
        'name: integration_test\nenvironment:\n  sdk: ^3.0.0\n',
    'flutter-$fakeFlutterVersion/packages/integration_test/lib/a.dart':
        'const x = 1;\n',
  });

  // One archive under each file name the rules ask for. Bazel serves a
  // download that names a digest from the distdir by file name.
  final archives = {
    for (final name in [
      'sky_engine.zip',
      'artifacts.zip',
      'linux-x64-flutter-gtk.zip',
      'windows-x64-flutter.zip',
      'flutter-cpp-client-wrapper.zip',
      'darwin-x64.zip',
      'flutter-web-sdk.zip',
    ])
      name: archive,
    for (final host in hostPlatforms) 'dart-sdk-$host.zip': dartSdk,
    '$fakeFlutterVersion.tar.gz': flutterSource,
  };

  final pubArchive = tarGzOf({
    'pubspec.yaml':
        'name: sample\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n',
    'lib/sample.dart': 'const x = 1;\n',
  });
  final pubDigest = sha256Hex(pubArchive);
  late String pubBase;

  setUpAll(() async {
    expect(
      sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      reason: 'the test\'s own SHA-256 is wrong',
    );

    pubBase = await servePubArchive('sample', '1.0.0', pubArchive);

    List<ProbeRepo> pub(String name, String d) => hostedPubPackage(
      name,
      package: 'sample',
      version: '1.0.0',
      sha256: d,
      baseUrl: pubBase,
    );
    ProbeRepo profile(String name, String d) =>
        ProbeRepo(name, 'flutter_profile_repo', {
          'engine_revision': str(revision),
          'downloads': strDict({'android-arm64-profile/artifacts.zip': ''}),
          'sha256s': strDict({'android-arm64-profile/artifacts.zip': d}),
          'build_file_content': str(''),
        });

    fetcher = await probe(
      archives: archives,
      repos: [
        ProbeRepo('sky_ok', 'flutter_sky_engine_repo', {
          'engine_revision': str(revision),
          'sha256': str(digest),
        }),
        profile('profile_ok', digest),
        ProbeRepo('android_ok', 'flutter_android_engine_repo', {
          'engine_revision': str(revision),
          'android_arch': str('arm64'),
          'release_sha256': str(digest),
          'debug_sha256': str(digest),
        }),
        ProbeRepo('ios_ok', 'flutter_ios_engine_repo', {
          'engine_revision': str(revision),
          'mode': str('release'),
          'sha256': str(digest),
        }),
        ProbeRepo('ios_debug_ok', 'flutter_ios_engine_repo', {
          'engine_revision': str(revision),
          'mode': str('debug'),
          'sha256': str(digest),
        }),
        ProbeRepo('desktop_linux_ok', 'flutter_desktop_engine_repo', {
          'engine_revision': str(revision),
          'target_os': str('linux'),
          'target_arch': str('x64'),
          'sha256': str(digest),
        }),
        ProbeRepo('desktop_windows_ok', 'flutter_desktop_engine_repo', {
          'engine_revision': str(revision),
          'target_os': str('windows'),
          'target_arch': str('x64'),
          'sha256': str(digest),
          'cpp_wrapper_sha256': str(digest),
        }),
        ProbeRepo('cross_ok', 'flutter_cross_compilation_repo', {
          'engine_revision': str(revision),
          'host_platform': str('darwin-arm64'),
          'target_platform': str('android-arm64'),
          'gen_snapshot_sha256': str(digest),
        }, bzl: 'flutter_cross_repo'),
        ProbeRepo('web_sdk_ok', 'flutter_web_sdk_repo', {
          'engine_revision': str(revision),
          'sha256': str(digest),
          'dart_sdk_sha256s': strDict({
            for (final host in hostPlatforms) host: dartSdkDigest,
          }),
        }),
        ...pub('pub_ok', pubDigest),
        ...sdkSourcePackage(
          'sdk_source_ok',
          package: 'integration_test',
          sha256: sha256Hex(flutterSource),
          packages: ['integration_test'],
        ),
        // A digest that is a SHA-256 but not these bytes'.
        ProbeRepo('sky_wrong', 'flutter_sky_engine_repo', {
          'engine_revision': str(revision),
          'sha256': str(wrongDigest),
        }),
        ...pub('pub_wrong', wrongDigest),
        // Not a SHA-256 at all: too short, not hex, an SRI string.
        for (final (name, bad) in _malformed(digest))
          ProbeRepo('sky_$name', 'flutter_sky_engine_repo', {
            'engine_revision': str(revision),
            'sha256': str(bad),
          }),
        for (final (name, bad) in _malformed(pubDigest))
          ...pub('pub_$name', bad),
      ],
    );
  });

  group('a correct digest fetches, offline', () {
    for (final name in [
      'sky_ok',
      'profile_ok',
      'android_ok',
      'ios_ok',
      'ios_debug_ok',
      'desktop_linux_ok',
      'desktop_windows_ok',
      'cross_ok',
      'web_sdk_ok',
      'pub_ok',
      'sdk_source_ok',
    ]) {
      test(name, () async {
        final result = await fetcher.fetch(name);
        expect(result.succeeded, isTrue, reason: '$result');
      });
    }
  });

  group('a digest that does not match the bytes fails the fetch', () {
    for (final name in ['sky_wrong', 'pub_wrong']) {
      test(name, () async {
        final result = await fetcher.fetch(name);
        expect(
          result.succeeded,
          isFalse,
          reason: 'fetched with a wrong digest',
        );
      });
    }
  });

  group(
    'a digest that is not a SHA-256 fails the fetch',
    () {
      for (final (name, _) in _malformed(digest)) {
        for (final prefix in ['sky', 'pub']) {
          test('${prefix}_$name', () async {
            final result = await fetcher.fetch('${prefix}_$name');
            expect(
              result.succeeded,
              isFalse,
              reason: 'fetched with a malformed digest',
            );
          });
        }
      }
    },
  );
}

List<(String, String)> _malformed(String good) => [
  ('short', good.substring(0, 40)),
  ('nonhex', 'z' * 64),
  ('sri', 'sha256-${'A' * 43}='),
];
