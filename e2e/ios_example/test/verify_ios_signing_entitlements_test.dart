/// Property: a signed iOS app is signed with the entitlements Xcode signs it
/// with: its own, its `application-identifier`, and the profile's
/// `com.apple.developer.team-identifier`, `beta-reports-active` and
/// `get-task-allow` where the profile grants them, and nothing else of the
/// provisioning profile.
///
/// Xcode signs a capability-less app with exactly these keys, development
/// and App Store distribution alike, and an app with an entitlements file with
/// these keys and the file's.
///
/// Both profiles grant the keychain group `UNSIGNED00.*`, which an app signed
/// with it as its own would share with every other app signed with that
/// profile. One is a team wildcard development profile, the other an App
/// Store distribution profile for one explicit App ID, which grants
/// `beta-reports-active` and no `get-task-allow`.
///
/// The arguments are the entitlements files rules_apple hands to `codesign`,
/// one per app, each named after its app's target.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/signing.dart';
import 'package:runfiles/runfiles.dart';

const _team = 'UNSIGNED00';
const _sharedGroup = '$_team.com.rulesflutter.ios.example.shared';

/// Each app's target, and the entitlements it must be signed with.
const _expected = <String, Map<String, Object?>>{
  // Development, no entitlements file, as `flutter create` leaves an app.
  'signing_plain_app_device': {
    'application-identifier': '$_team.com.rulesflutter.ios.example.signing',
    'com.apple.developer.team-identifier': _team,
    'get-task-allow': true,
  },
  // Development, its own file asks for one keychain group, which it keeps.
  'signing_keychain_app_device': {
    'application-identifier':
        '$_team.com.rulesflutter.ios.example.signing.keychain',
    'com.apple.developer.team-identifier': _team,
    'get-task-allow': true,
    'keychain-access-groups': [_sharedGroup],
  },
  // App Store distribution, no entitlements file.
  'signing_store_plain_app_device': {
    'application-identifier':
        '$_team.com.rulesflutter.ios.example.signing.store',
    'beta-reports-active': true,
    'com.apple.developer.team-identifier': _team,
    'get-task-allow': false,
  },
  // App Store distribution, its own keychain group.
  'signing_store_keychain_app_device': {
    'application-identifier':
        '$_team.com.rulesflutter.ios.example.signing.store',
    'beta-reports-active': true,
    'com.apple.developer.team-identifier': _team,
    'get-task-allow': false,
    'keychain-access-groups': [_sharedGroup],
  },
};

String _show(Object? value) =>
    value is List ? '[${value.join(', ')}]' : '$value';

bool _same(Object? a, Object? b) => _show(a) == _show(b);

/// The target an entitlements file belongs to: rules_apple names it
/// `<bundle target>_entitlements.entitlements`, and flutter_ios_app names its
/// bundle `__<target>_app`.
String _target(String path) {
  final name = path.split('/').last;
  final match = RegExp(r'^__(.+)_app_entitlements\.entitlements$')
      .firstMatch(name);
  return match?.group(1) ?? path;
}

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final check = BundleCheck();
  final byTarget = <String, Entitlements>{
    for (final path in args)
      _target(path): Entitlements.parse(
        File(runfiles.rlocation(path)).readAsStringSync(),
      ),
  };

  check.expect(
    'each app has one entitlements file',
    condition: _same(
      byTarget.keys.toList()..sort(),
      _expected.keys.toList()..sort(),
    ),
    detail: 'found ${byTarget.keys.join(', ')}',
  );
  for (final MapEntry(key: target, value: expected) in _expected.entries) {
    final actual = byTarget[target]?.values;
    if (actual == null) continue;
    final keys = {...expected.keys, ...actual.keys}.toList()..sort();
    check.expect(
      '$target is signed with exactly ${expected.keys.join(', ')}',
      condition: keys.every((k) => _same(actual[k], expected[k])),
      detail: [
        for (final k in keys)
          if (!_same(actual[k], expected[k]))
            '$k is ${_show(actual[k])}, expected ${_show(expected[k])}',
      ].join('; '),
    );
  }
  check.finish('Each app is signed with the entitlements Xcode signs it with.');
}
