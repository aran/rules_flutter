import 'package:test/test.dart';

import '../artifact_list.dart';
import '../pinned_checksums.dart';

final _sha = 'a' * 64;
final _sha2 = 'b' * 64;

final _versionsBzl =
    '''
FLUTTER_VERSIONS = {
    "3.1.0": struct(
        engine_revision = "abc",
        source_sha256 = "$_sha",
    ),
    "3.2.0": struct(
        engine_revision = "def",
        dart_source_sha256 = "$_sha",
        source_sha256 = "$_sha2",
    ),
}

ARTIFACT_CHECKSUMS = {
    "3.1.0": {
        # Patched Dart SDK
        "flutter_patched_sdk.zip": "$_sha",
    },
    "3.2.0": {
        "ios/artifacts.zip": "$_sha2",
        "linux-x64/artifacts.zip": "$_sha",
    },
}
''';

void main() {
  group('artifacts', () {
    test('lists each path once', () {
      expect(artifacts.toSet().length, artifacts.length);
    });

    test('covers the profile-mode downloads', () {
      expect(
        artifacts,
        containsAll([
          'darwin-arm64-profile/artifacts.zip',
          'darwin-x64-profile/FlutterMacOS.framework.zip',
          'linux-arm64-profile/linux-arm64-flutter-gtk.zip',
          'windows-x64-profile/windows-x64-flutter.zip',
          'ios-profile/artifacts.zip',
          'android-arm-profile/artifacts.zip',
          'android-arm-profile/linux-x64.zip',
          'android-arm64-profile/artifacts.zip',
          'android-x64-profile/windows-x64.zip',
        ]),
      );
    });

    test('covers the downloads that once had no checksum', () {
      expect(
        artifacts,
        containsAll([
          'android-arm-release/artifacts.zip',
          'android-arm/artifacts.zip',
          'android-arm-release/darwin-x64.zip',
          'android-arm64-release/artifacts.zip',
          'android-x64/artifacts.zip',
          'android-arm64-release/darwin-x64.zip',
          'linux-arm64-release/linux-arm64-flutter-gtk.zip',
          'linux-arm64-debug/linux-arm64-flutter-gtk.zip',
        ]),
      );
    });
  });

  group('pinnedArtifactChecksums', () {
    test('reads only the requested version', () {
      expect(pinnedArtifactChecksums(_versionsBzl, '3.2.0'), {
        'ios/artifacts.zip': _sha2,
        'linux-x64/artifacts.zip': _sha,
      });
    });

    test('is empty for an unpinned version', () {
      expect(pinnedArtifactChecksums(_versionsBzl, '9.9.9'), isEmpty);
    });
  });

  group('pinnedSourceSha256', () {
    test('reads the requested version', () {
      expect(pinnedSourceSha256(_versionsBzl, '3.2.0'), _sha2);
    });

    test('is null for an unpinned version', () {
      expect(pinnedSourceSha256(_versionsBzl, '9.9.9'), isNull);
    });
  });

  group('pinnedDartSourceSha256', () {
    test('reads the Dart source checksum, not the Flutter one', () {
      expect(pinnedDartSourceSha256(_versionsBzl, '3.2.0'), _sha);
    });

    test('is null where none is recorded', () {
      expect(pinnedDartSourceSha256(_versionsBzl, '3.1.0'), isNull);
    });
  });

  group('iOS USB dependencies', () {
    test('reads the pins of IOS_USB_DEPENDENCIES', () {
      final pins = pinnedIosUsbDependencies('''
IOS_USB_DEPENDENCIES = {
    "libplist": struct(
        version = "cf58",
        sha256 = "$_sha",
    ),
    "libusbmuxd": struct(
        version = "19d6",
        sha256 = "$_sha2",
    ),
}
''');
      expect(pins, {
        'libplist': (version: 'cf58', sha256: _sha),
        'libusbmuxd': (version: '19d6', sha256: _sha2),
      });
    });

    test('formats the URL from the Starlark template', () {
      const bzl =
          '_IOS_USB_DEPENDENCY_TEMPLATE = "https://x/{name}/{version}/{name}.zip"\n';
      expect(
        iosUsbDependencyUrl(bzl, 'libplist', 'cf58'),
        'https://x/libplist/cf58/libplist.zip',
      );
    });

    test('refuses a file without the template', () {
      expect(
        () => iosUsbDependencyUrl('', 'libplist', 'cf58'),
        throwsStateError,
      );
    });
  });
}
