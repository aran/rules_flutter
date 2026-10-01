import 'package:test/test.dart';

// Import the library directly.
import '../merge_android_manifests.dart';

/// The debug variant manifest exactly as `flutter create` emits it.
const _pristineOverlay = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- The INTERNET permission is required for development. Specifically,
         the Flutter tool needs it to communicate with the running application
         to allow setting breakpoints, to provide hot reload, etc.
    -->
    <uses-permission android:name="android.permission.INTERNET"/>
</manifest>
''';

/// A minimal but realistic main manifest (already `\${applicationName}`-
/// expanded, as the merge rule feeds it).
const _base = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="example"
        android:name="android.app.Application">
        <activity android:name=".MainActivity" android:exported="true"/>
    </application>
</manifest>
''';

String merge(String base, String overlay) => mergeManifests(
  baseXml: base,
  overlayXml: overlay,
  basePath: 'out/base/AndroidManifest.xml',
  overlayPath: 'android/app/src/debug/AndroidManifest.xml',
);

void main() {
  group('mergeManifests', () {
    test('inserts the overlay permission after the manifest open tag', () {
      final merged = merge(_base, _pristineOverlay);
      expect(
        merged,
        contains(
          '<uses-permission '
          'android:name="android.permission.INTERNET"/>',
        ),
      );
      // Inserted between the root open tag and <application>.
      final open = merged.indexOf('>');
      final permission = merged.indexOf('uses-permission');
      final application = merged.indexOf('<application');
      expect(permission, greaterThan(open));
      expect(permission, lessThan(application));
    });

    test('preserves every base byte outside the insertion', () {
      final merged = merge(_base, _pristineOverlay);
      final openTagEnd = _base.indexOf('>') + 1;
      expect(merged, startsWith(_base.substring(0, openTagEnd)));
      expect(merged, endsWith(_base.substring(openTagEnd)));
    });

    test('emits a provenance comment naming both input paths', () {
      final merged = merge(_base, _pristineOverlay);
      expect(merged, contains('out/base/AndroidManifest.xml'));
      expect(merged, contains('android/app/src/debug/AndroidManifest.xml'));
      expect(merged, contains('<!--'));
    });

    test('skips permissions the base already declares', () {
      const baseWithInternet = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <application android:label="example"/>
</manifest>
''';
      final merged = merge(baseWithInternet, _pristineOverlay);
      expect(
        'uses-permission'.allMatches(merged).length,
        1,
        reason: 'the base-declared permission must not be duplicated',
      );
    });

    test('dedups by android:name across element kinds', () {
      const baseSdk23 = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission-sdk-23 android:name="android.permission.INTERNET"/>
    <application android:label="example"/>
</manifest>
''';
      final merged = merge(baseSdk23, _pristineOverlay);
      expect('android.permission.INTERNET'.allMatches(merged).length, 1);
    });

    test('unions duplicate overlay permissions once', () {
      const overlay = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.INTERNET"/>
</manifest>
''';
      final merged = merge(_base, overlay);
      expect('android.permission.INTERNET'.allMatches(merged).length, 1);
    });

    test('carries uses-permission-sdk-23 through as sdk-23', () {
      const overlay = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission-sdk-23 android:name="android.permission.VIBRATE"/>
</manifest>
''';
      final merged = merge(_base, overlay);
      expect(
        merged,
        contains(
          '<uses-permission-sdk-23 '
          'android:name="android.permission.VIBRATE"/>',
        ),
      );
    });

    test('accepts an overlay with an XML declaration', () {
      final merged = merge(
        _base,
        '<?xml version="1.0" encoding="utf-8"?>\n$_pristineOverlay',
      );
      expect(merged, contains('android.permission.INTERNET'));
    });

    test('accepts non-self-closing empty permission elements', () {
      const overlay = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET">
    </uses-permission>
</manifest>
''';
      final merged = merge(_base, overlay);
      expect(merged, contains('android.permission.INTERNET'));
    });

    test('accepts an overlay contributing nothing, adding only provenance', () {
      const overlay = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
</manifest>
''';
      final merged = merge(_base, overlay);
      expect(merged, contains('android/app/src/debug/AndroidManifest.xml'));
      expect(merged, isNot(contains('uses-permission')));
    });

    group('rejects', () {
      void expectRejection(String overlay, List<String> messageParts) {
        Object? caught;
        try {
          merge(_base, overlay);
        } on FormatException catch (e) {
          caught = e;
        }
        expect(
          caught,
          isA<FormatException>(),
          reason: 'overlay must be rejected:\n$overlay',
        );
        final message = caught.toString();
        for (final part in messageParts) {
          expect(message, contains(part));
        }
        // Every rejection points at the escape hatch.
        expect(message, contains('debug_manifest'));
      }

      test('an overlay whose root is not <manifest>', () {
        expectRejection(
          '<resources></resources>',
          ['<resources>'],
        );
      });

      test('a non-xmlns attribute on the overlay root', () {
        expectRejection(
          '<manifest xmlns:android="http://schemas.android.com/apk/res/andro'
          'id" package="com.example"><uses-permission '
          'android:name="android.permission.INTERNET"/></manifest>',
          ['package'],
        );
      });

      test('an overlay element other than uses-permission', () {
        expectRejection(
          '<manifest xmlns:android="http://schemas.android.com/apk/res/andro'
          'id"><application android:label="x"/></manifest>',
          ['<application>'],
        );
      });

      test('an extra attribute on uses-permission', () {
        expectRejection(
          '<manifest xmlns:android="http://schemas.android.com/apk/res/andro'
          'id"><uses-permission android:name="android.permission.INTERNET" '
          'android:maxSdkVersion="18"/></manifest>',
          ['android:maxSdkVersion'],
        );
      });

      test('uses-permission without android:name', () {
        expectRejection(
          '<manifest xmlns:android="http://schemas.android.com/apk/res/andro'
          'id"><uses-permission/></manifest>',
          ['android:name'],
        );
      });

      test('text content inside the overlay', () {
        expectRejection(
          '<manifest xmlns:android="http://schemas.android.com/apk/res/andro'
          'id">stray text<uses-permission '
          'android:name="android.permission.INTERNET"/></manifest>',
          ['stray text'],
        );
      });

      test(r'a ${...} Gradle placeholder token', () {
        expectRejection(
          '<manifest xmlns:android="http://schemas.android.com/apk/res/andro'
          'id"><uses-permission android:name="\${internetPermission}"/>'
          '</manifest>',
          [r'${internetPermission}'],
        );
      });
    });

    test('rejects a base without a <manifest> root element', () {
      expect(
        () => merge('<resources/>', _pristineOverlay),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a self-closing base manifest root', () {
      expect(
        () => merge('<manifest xmlns:android="x"/>', _pristineOverlay),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('library permissions', () {
    String lift(
      Map<String, String> libraries, {
      String base = _base,
      Set<String> placeholders = const {},
    }) => mergeManifests(
      baseXml: base,
      basePath: 'out/base/AndroidManifest.xml',
      libraries: libraries,
      placeholders: placeholders,
    );

    const alerts = '''
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools"
    package="dev.example.alerts">
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"
        android:maxSdkVersion="32" tools:ignore="ProtectedPermissions"/>
    <uses-permission android:name="android.permission.READ_PHONE_STATE"
        tools:node="remove"/>
    <application>
        <receiver android:name=".AlertsReceiver" android:exported="false">
            <intent-filter>
                <action android:name="android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"/>
            </intent-filter>
        </receiver>
    </application>
</manifest>
''';

    test('lifts the permissions under the root, keeping android:*', () {
      final merged = lift({'alerts/AndroidManifest.xml': alerts});
      expect(
        merged,
        contains(
          '<uses-permission '
          'android:name="android.permission.POST_NOTIFICATIONS"/>',
        ),
      );
      expect(
        merged,
        contains(
          '<uses-permission '
          'android:name="android.permission.SCHEDULE_EXACT_ALARM" '
          'android:maxSdkVersion="32"/>',
        ),
      );
      expect(merged, isNot(contains('tools:ignore')));
    });

    test('skips a tools:node="remove" directive', () {
      final merged = lift({'alerts/AndroidManifest.xml': alerts});
      expect(merged, isNot(contains('READ_PHONE_STATE')));
    });

    test('takes nothing from below <application>', () {
      final merged = lift({'alerts/AndroidManifest.xml': alerts});
      expect(merged, isNot(contains('AlertsReceiver')));
    });

    test('skips what the base declares, and declares each name once', () {
      const base = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <application android:label="example"/>
</manifest>
''';
      const other = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
</manifest>
''';
      final merged = lift({
        'alerts/AndroidManifest.xml': alerts,
        'other/AndroidManifest.xml': other,
      }, base: base);
      expect('POST_NOTIFICATIONS'.allMatches(merged).length, 1);
      expect('SCHEDULE_EXACT_ALARM'.allMatches(merged).length, 1);
      // Needed at every SDK level by `other`, so maxSdkVersion goes.
      expect(merged, isNot(contains('maxSdkVersion')));
    });

    test('leaves the base untouched when no library adds anything', () {
      const empty = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"/>
''';
      expect(lift({'empty/AndroidManifest.xml': empty}), _base);
    });

    test('passes through a placeholder the build substitutes', () {
      // androidx.core's, verbatim.
      const core = r'''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"/>
</manifest>
''';
      expect(
        lift(
          {'core/AndroidManifest.xml': core},
          placeholders: {'applicationId'},
        ),
        contains(
          r'android:name="${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"',
        ),
      );
    });

    test(r'rejects a ${...} placeholder the build does not substitute', () {
      const placeholder = r'''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="${applicationId}.permission.C2D"/>
</manifest>
''';
      expect(
        () => lift({'p/AndroidManifest.xml': placeholder}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('p/AndroidManifest.xml'), contains('placeholder')),
          ),
        ),
      );
    });
  });
}
