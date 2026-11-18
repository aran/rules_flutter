import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../merge_plists.dart';
import '../signing_entitlements.dart';
import 'signed_profile_fixture.dart';

/// A profile's property list granting [entitlements], an XML fragment of
/// keys and values, with [extra] top-level entries.
String _profile(String entitlements, {String extra = ''}) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>ApplicationIdentifierPrefix</key>
	<array>
		<string>UNSIGNED00</string>
	</array>
	<key>Entitlements</key>
	<dict>
$entitlements
	</dict>
$extra
	<key>Version</key>
	<integer>1</integer>
</dict>
</plist>
''';

/// A CMS signed-data message carrying [xml], every constructed element of
/// it in BER's indefinite length (`30 80 … 00 00`), as older profiles are
/// signed. Its signer infos are an empty set, which nothing reads.
Uint8List _indefiniteProfile(String xml) {
  List<int> indefinite(int tag, List<int> contents) => [
    tag,
    0x80,
    ...contents,
    0x00,
    0x00,
  ];
  final plist = utf8.encode(xml);
  final length = plist.length;
  return Uint8List.fromList(
    indefinite(0x30, [
      0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02, //
      ...indefinite(0xa0, [
        ...indefinite(0x30, [
          0x02, 0x01, 0x01, // version
          0x31, 0x00, // digest algorithms
          ...indefinite(0x30, [
            0x06,
            0x09,
            0x2a,
            0x86,
            0x48,
            0x86,
            0xf7,
            0x0d,
            0x01,
            0x07,
            0x01,
            ...indefinite(0xa0, [
              0x04, 0x82, length >> 8, length & 0xff, ...plist, //
            ]),
          ]),
          ...indefinite(0x31, []), // signer infos
        ]),
      ]),
    ]),
  );
}

const _macProfile = '''
	<key>Platform</key>
	<array>
		<string>OSX</string>
	</array>''';

const _macDevices = '''
	<key>ProvisionedDevices</key>
	<array>
		<string>00000000-0000-0000-0000-000000000000</string>
	</array>''';

const _wildcardDevelopment = '''
		<key>application-identifier</key>
		<string>UNSIGNED00.*</string>
		<key>com.apple.developer.team-identifier</key>
		<string>UNSIGNED00</string>
		<key>get-task-allow</key>
		<true/>
		<key>keychain-access-groups</key>
		<array>
			<string>UNSIGNED00.*</string>
			<string>com.apple.token</string>
		</array>''';

const _appStore = '''
		<key>application-identifier</key>
		<string>UNSIGNED00.com.example.app</string>
		<key>beta-reports-active</key>
		<true/>
		<key>com.apple.developer.team-identifier</key>
		<string>UNSIGNED00</string>
		<key>get-task-allow</key>
		<false/>
		<key>keychain-access-groups</key>
		<array>
			<string>UNSIGNED00.*</string>
			<string>com.apple.token</string>
		</array>
		<key>aps-environment</key>
		<string>production</string>''';

const _macDevelopment = '''
		<key>com.apple.application-identifier</key>
		<string>UNSIGNED00.*</string>
		<key>com.apple.developer.team-identifier</key>
		<string>UNSIGNED00</string>
		<key>keychain-access-groups</key>
		<array>
			<string>UNSIGNED00.*</string>
		</array>''';

const _ownKeychainGroup = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>keychain-access-groups</key>
	<array>
		<string>\$(AppIdentifierPrefix)com.example.shared</string>
	</array>
</dict>
</plist>
''';

/// The keys and values of the entitlements written for [own] against a
/// profile granting [granted].
Map<String, String> _signed(
  String granted, {
  String? own,
  String extra = '',
}) => {
  for (final entry in parsePlist(
    signingEntitlements(
      profile: (path: 'profile', xml: _profile(granted, extra: extra)),
      own: own == null ? null : (path: 'own', xml: own),
    ),
    'output',
  ))
    entry.key: entry.rawValue.replaceAll(RegExp(r'\s+'), ''),
};

const _identifier =
    r'<string>$(AppIdentifierPrefix)$(CFBundleIdentifier)</string>';

void main() {
  group('profilePlist', () {
    test('reads the property list a signed profile carries', () {
      expect(profilePlist(signedProfile, 'profile'), signedProfileXml);
    });

    test('reads an unsigned property list as it is', () {
      final xml = _profile(_wildcardDevelopment);
      expect(profilePlist(utf8.encode(xml), 'profile'), xml);
    });

    test('refuses a message that is not signed data', () {
      final bytes = Uint8List.fromList(signedProfile);
      // The last byte of the content type: signed data (…7.2) becomes
      // enveloped data (…7.3).
      bytes[14] = 0x03;
      expect(
        () => profilePlist(bytes, 'profile'),
        throwsA(
          isA<PlistFormatException>().having(
            (e) => e.message,
            'message',
            contains('content type'),
          ),
        ),
      );
    });

    test('reads a profile signed with indefinite lengths', () {
      final xml = _profile(_wildcardDevelopment);
      expect(profilePlist(_indefiniteProfile(xml), 'profile'), xml);
    });

    test('refuses an indefinite length with no end of contents', () {
      final bytes = _indefiniteProfile(_profile(_wildcardDevelopment));
      expect(
        () => profilePlist(bytes.sublist(0, bytes.length - 2), 'profile'),
        throwsA(
          isA<PlistFormatException>().having(
            (e) => e.message,
            'message',
            contains('no end of contents'),
          ),
        ),
      );
    });

    test('refuses a primitive element with an indefinite length', () {
      final bytes = Uint8List.fromList([0x30, 0x80, 0x06, 0x80, 0x00, 0x00]);
      expect(
        () => profilePlist(bytes, 'profile'),
        throwsA(
          isA<PlistFormatException>().having(
            (e) => e.message,
            'message',
            contains('primitive and has an indefinite length'),
          ),
        ),
      );
    });

    test('refuses a truncated profile', () {
      expect(
        () => profilePlist(signedProfile.sublist(0, 100), 'profile'),
        throwsA(isA<PlistFormatException>()),
      );
    });
  });

  group('signingEntitlements', () {
    test('an app with none gets its identifier and the team, not the '
        "profile's keychain group", () {
      expect(_signed(_wildcardDevelopment), {
        'application-identifier': _identifier,
        'com.apple.developer.team-identifier': '<string>UNSIGNED00</string>',
      });
    });

    test('an App Store profile adds beta-reports-active, and nothing it '
        'grants that the app does not ask for', () {
      expect(_signed(_appStore), {
        'application-identifier': _identifier,
        'beta-reports-active': '<true/>',
        'com.apple.developer.team-identifier': '<string>UNSIGNED00</string>',
      });
    });

    test("an app's own entitlements are kept", () {
      expect(_signed(_appStore, own: _ownKeychainGroup), {
        'keychain-access-groups': r'<array><string>$(AppIdentifierPrefix)com.example.shared</string></array>',
        'application-identifier': _identifier,
        'beta-reports-active': '<true/>',
        'com.apple.developer.team-identifier': '<string>UNSIGNED00</string>',
      });
    });

    test('an application identifier the app sets wins', () {
      const own = '''
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>UNSIGNED00.com.example.other</string>
</dict>
</plist>
''';
      expect(
        _signed(_wildcardDevelopment, own: own)['application-identifier'],
        '<string>UNSIGNED00.com.example.other</string>',
      );
    });

    test('a Mac development profile signs get-task-allow, which it does '
        'not grant', () {
      expect(_signed(_macDevelopment, extra: _macProfile + _macDevices), {
        'com.apple.application-identifier': _identifier,
        'com.apple.developer.team-identifier': '<string>UNSIGNED00</string>',
        'com.apple.security.get-task-allow': '<true/>',
      });
    });

    test("a Mac development profile keeps the app's own entitlements, and "
        'its get-task-allow', () {
      const own = '''
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.get-task-allow</key>
	<false/>
</dict>
</plist>
''';
      expect(
        _signed(_macDevelopment, own: own, extra: _macProfile + _macDevices),
        {
          'com.apple.security.app-sandbox': '<true/>',
          'com.apple.security.get-task-allow': '<false/>',
          'com.apple.application-identifier': _identifier,
          'com.apple.developer.team-identifier': '<string>UNSIGNED00</string>',
        },
      );
    });

    test('a Mac profile that lists no devices signs no get-task-allow', () {
      expect(_signed(_macDevelopment, extra: _macProfile).keys, [
        'com.apple.application-identifier',
        'com.apple.developer.team-identifier',
      ]);
    });

    test('a Mac profile gets the Mac application identifier key', () {
      expect(_signed(_macDevelopment), {
        'com.apple.application-identifier': _identifier,
        'com.apple.developer.team-identifier': '<string>UNSIGNED00</string>',
      });
    });

    test('reads a signed profile end to end', () {
      final entries = parsePlist(
        signingEntitlements(
          profile: (
            path: 'profile',
            xml: profilePlist(signedProfile, 'profile'),
          ),
          own: null,
        ),
        'output',
      );
      expect(entries.map((e) => e.key), [
        'application-identifier',
        'com.apple.developer.team-identifier',
      ]);
    });

    test('refuses a profile that grants nothing', () {
      expect(
        () => signingEntitlements(
          profile: (
            path: 'profile',
            xml: '<plist version="1.0"><dict></dict></plist>',
          ),
          own: null,
        ),
        throwsA(
          isA<PlistFormatException>().having(
            (e) => e.message,
            'message',
            contains('grants no Entitlements'),
          ),
        ),
      );
    });
  });
}
