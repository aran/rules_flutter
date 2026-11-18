/// Property: a signed macOS app is signed with the entitlements Xcode signs it
/// with: its own, its `com.apple.application-identifier`, the profile's
/// `com.apple.developer.team-identifier`, and, for a development profile,
/// `com.apple.security.get-task-allow`, and nothing else of the provisioning
/// profile.
///
/// Both profiles grant the keychain group `UNSIGNED00.*`, which an app signed
/// with it as its own would share with every other app signed with that
/// profile. One is a Mac team wildcard development profile, which lists
/// devices and does not grant `get-task-allow`, the other a Mac App Store
/// profile for one App ID, which lists none.
///
/// The arguments are the entitlements files rules_apple hands to `codesign`,
/// one per app, each named after its app's target.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/signing.dart';
import 'package:runfiles/runfiles.dart';

const _team = 'UNSIGNED00';
const _sandbox = 'com.apple.security.app-sandbox';
const _taskAllow = 'com.apple.security.get-task-allow';

/// Each app's target, and the entitlements it must be signed with.
const _expected = <String, Map<String, Object?>>{
  // Development, no entitlements of its own.
  'signing_plain_app': {
    'com.apple.application-identifier': '$_team.com.example.flutterapp.signing',
    'com.apple.developer.team-identifier': _team,
    _taskAllow: true,
  },
  // Development, with the sandbox its own file asks for.
  'signing_sandbox_app': {
    'com.apple.application-identifier':
        '$_team.com.example.flutterapp.signing.sandbox',
    'com.apple.developer.team-identifier': _team,
    _sandbox: true,
    _taskAllow: true,
  },
  // Distribution: the profile lists no devices, so no get-task-allow.
  'signing_store_app': {
    'com.apple.application-identifier':
        '$_team.com.example.flutterapp.signing.store',
    'com.apple.developer.team-identifier': _team,
    _sandbox: true,
  },
};

String _show(Object? value) =>
    value is List ? '[${value.join(', ')}]' : '$value';

bool _same(Object? a, Object? b) => _show(a) == _show(b);

/// The target an entitlements file belongs to: rules_apple names it
/// `<bundle target>_entitlements.entitlements`, and flutter_macos_app names its
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
