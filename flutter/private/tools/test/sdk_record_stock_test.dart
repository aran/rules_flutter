import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

// The snapshot hash of the pinned release's Dart. It changes with the Flutter
// version this repository pins: update it with the pin. A release whose
// binaries hold a second hex constant that fits the scan fails this test
// instead of a user's build.
const _pinnedSnapshotHash = '6b959e9909a17b8e29b0663a6d99e646';

void main() {
  // The check over every stock artifact of one platform and mode: the engine,
  // the gen_snapshot (AOT modes), the platform kernel, the Dart SDK and its
  // runtime. They must agree, and on the pinned release's hash. The host's
  // are the macOS engine; iOS and Android are the engines a Mac cross-compiles
  // for, the Android hash read out of `libflutter.so` inside `flutter.jar`.
  const platforms = {
    'host': 'stock_record_%s_check',
    'ios': 'stock_record_ios_%s_check',
    'android_arm64': 'stock_record_android_arm64_%s_check',
    'android_x64': 'stock_record_android_x64_%s_check',
  };
  for (final MapEntry(key: platform, value: target) in platforms.entries) {
    for (final mode in ['debug', 'profile', 'release']) {
      test('the stock $platform $mode artifacts pass the check', () {
        final file = Runfiles.create().rlocation(
          '_main/flutter/private/tools/${target.replaceFirst('%s', mode)}/flutter_sdk.json',
        );
        final record =
            jsonDecode(File(file).readAsStringSync()) as Map<String, Object?>;
        expect(record['snapshot_hash'], _pinnedSnapshotHash);
        expect(record['kernel'], containsPair('format', isA<int>()));
        expect(record['sdk'], 'flutter');
        expect(record['framework'], containsPair('origin', 'release'));
        for (final piece in (record['engine'] as Map).values) {
          expect(piece, containsPair('origin', 'release'));
        }
      });
    }
  }
}
