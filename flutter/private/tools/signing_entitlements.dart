/// Writes the entitlements an Apple bundle is signed with against a
/// provisioning profile: the bundle's own, and the few keys Xcode takes from
/// the profile, and nothing else the profile grants.
///
/// rules_apple, given no entitlements, signs a bundle with the profile's
/// whole `Entitlements` dictionary, so an app with no capabilities of its own
/// gets every keychain group, push environment and associated domain the
/// profile allows. Given some, it adds only `application-identifier` and
/// `get-task-allow` from the profile. Xcode signs neither way. For each key
/// below, it signs the bundle with it when the profile grants it and the
/// bundle's own entitlements do not set it:
///
///   `application-identifier` (iOS) and `com.apple.application-identifier`
///       (macOS): the profile's prefix and the bundle id, written here as
///       `$(AppIdentifierPrefix)$(CFBundleIdentifier)` for rules_apple to
///       fill in. A wildcard profile grants `<prefix>.*`, which is not an
///       identifier: as one, it is also the bundle's default keychain group,
///       shared with every bundle signed that way.
///   `com.apple.developer.team-identifier`: the profile's value.
///   `beta-reports-active`: the profile's value. An App Store profile grants
///       it, and App Store Connect needs it for TestFlight.
///
/// `get-task-allow` is the profile's too, and rules_apple adds it already.
///
/// A profile is a CMS (PKCS #7) signed message whose content is an XML
/// property list. Its signature is not checked here, as rules_apple does not
/// check it either: codesign and the device do. A file that is the property
/// list itself, unsigned, is read as it is, as rules_apple reads one, so that
/// tests can use a profile with made-up identifiers.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart signing_entitlements.dart --profile <path> \
///       [--entitlements <path>] --output <path>
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'merge_plists.dart';

/// The keys whose value is the bundle's own identifier, when the profile
/// grants them.
const _identifierKeys = [
  'application-identifier',
  'com.apple.application-identifier',
];

/// The keys signed with the profile's value, when it grants them.
const _profileKeys = [
  'com.apple.developer.team-identifier',
  'beta-reports-active',
];

const _identifier =
    r'<string>$(AppIdentifierPrefix)$(CFBundleIdentifier)</string>';

// The DER encodings of the object identifiers of CMS signed data
// (1.2.840.113549.1.7.2) and of data (1.2.840.113549.1.7.1).
const _signedDataOid = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02];
const _dataOid = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01];

/// One DER element: its tag and where its contents lie in the bytes.
typedef _Element = ({int tag, int start, int end});

/// Reads DER elements from a profile's bytes.
class _Der {
  final Uint8List bytes;
  final String path;

  _Der(this.bytes, this.path);

  Never _fail(String detail) => throw PlistFormatException(
    'Cannot read the provisioning profile $path: $detail',
  );

  /// The element at [offset], which must lie before [limit] and have [tag].
  _Element read(int offset, int limit, int tag, String what) {
    if (offset + 2 > limit) _fail('it ends before its $what.');
    if (bytes[offset] != tag) {
      _fail(
        'its $what has the tag 0x${bytes[offset].toRadixString(16)}, '
        'expected 0x${tag.toRadixString(16)}.',
      );
    }
    var at = offset + 1;
    var length = bytes[at++];
    if (length == 0x80) {
      _fail('its $what has an indefinite length, which DER does not allow.');
    }
    if (length > 0x80) {
      final count = length - 0x80;
      if (count > 4 || at + count > limit) _fail('its $what has a bad length.');
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | bytes[at++];
      }
    }
    if (at + length > limit) _fail('its $what runs past its end.');
    return (tag: tag, start: at, end: at + length);
  }

  void expectOid(_Element oid, List<int> expected, String what) {
    final actual = bytes.sublist(oid.start, oid.end);
    if (actual.length != expected.length ||
        !Iterable.generate(actual.length)
            .every((i) => actual[i] == expected[i])) {
      _fail('its $what is not the one a provisioning profile has.');
    }
  }
}

/// The property list a provisioning profile's [bytes] carry. [path] names the
/// profile in an error.
String profilePlist(Uint8List bytes, String path) {
  const xmlDeclaration = '<?xml';
  if (bytes.length >= xmlDeclaration.length &&
      ascii.decode(
            bytes.sublist(0, xmlDeclaration.length),
            allowInvalid: true,
          ) ==
          xmlDeclaration) {
    return utf8.decode(bytes);
  }

  // ContentInfo ::= SEQUENCE { contentType OID, [0] EXPLICIT SignedData }
  // SignedData ::= SEQUENCE { version, digestAlgorithms SET,
  //     encapContentInfo SEQUENCE { eContentType OID,
  //         [0] EXPLICIT OCTET STRING }, ... }   (RFC 5652)
  final der = _Der(bytes, path);
  final info = der.read(0, bytes.length, 0x30, 'content info');
  final type = der.read(info.start, info.end, 0x06, 'content type');
  der.expectOid(type, _signedDataOid, 'content type');
  final explicit = der.read(type.end, info.end, 0xa0, 'signed data');
  final signedData = der.read(
    explicit.start,
    explicit.end,
    0x30,
    'signed data',
  );
  final version = der.read(signedData.start, signedData.end, 0x02, 'version');
  final digests = der.read(
    version.end,
    signedData.end,
    0x31,
    'digest algorithms',
  );
  final content = der.read(digests.end, signedData.end, 0x30, 'content');
  final contentType = der.read(
    content.start,
    content.end,
    0x06,
    'content type',
  );
  der.expectOid(contentType, _dataOid, 'signed content type');
  final wrapped = der.read(
    contentType.end,
    content.end,
    0xa0,
    'signed content',
  );
  final plist = der.read(wrapped.start, wrapped.end, 0x04, 'signed content');
  return utf8.decode(bytes.sublist(plist.start, plist.end));
}

/// The entitlements a bundle with [own] entitlements (none when null) is
/// signed with against the profile whose property list is [profile].
String signingEntitlements({
  required ({String path, String xml}) profile,
  required ({String path, String xml})? own,
}) {
  final root = parsePlist(profile.xml, profile.path);
  final granted = root.where((e) => e.key == 'Entitlements').firstOrNull;
  if (granted == null) {
    throw PlistFormatException(
      'The provisioning profile ${profile.path} grants no Entitlements.',
    );
  }
  final grants = {
    for (final entry in parsePlist(
      '<plist>${granted.rawValue}</plist>',
      '${profile.path} (Entitlements)',
    ))
      entry.key: entry.rawValue,
  };
  final fromProfile = [
    for (final key in _identifierKeys)
      if (grants.containsKey(key)) PlistEntry(key, _identifier),
    for (final key in _profileKeys)
      if (grants[key] case final value?) PlistEntry(key, value),
  ];
  return renderPlist(
    mergeEntries(
      baseEntries: own == null ? [] : parsePlist(own.xml, own.path),
      basePath: own?.path ?? '<none>',
      additions: [(profile.path, fromProfile)],
      mode: MergeMode.supplement,
    ),
  );
}

void main(List<String> args) {
  String? profilePath;
  String? entitlementsPath;
  String? outputPath;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--profile' && i + 1 < args.length) {
      profilePath = args[++i];
    } else if (args[i] == '--entitlements' && i + 1 < args.length) {
      entitlementsPath = args[++i];
    } else if (args[i] == '--output' && i + 1 < args.length) {
      outputPath = args[++i];
    } else {
      stderr.writeln('Unrecognized argument: ${args[i]}');
      exit(1);
    }
  }
  if (profilePath == null || outputPath == null) {
    stderr.writeln(
      'Usage: dart signing_entitlements.dart --profile <path> '
      '[--entitlements <path>] --output <path>',
    );
    exit(1);
  }

  final String entitlements;
  try {
    entitlements = signingEntitlements(
      profile: (
        path: profilePath,
        xml: profilePlist(File(profilePath).readAsBytesSync(), profilePath),
      ),
      own: entitlementsPath == null
          ? null
          : (
              path: entitlementsPath,
              xml: plistXml(
                File(entitlementsPath).readAsBytesSync(),
                entitlementsPath,
              ),
            ),
    );
  } on PlistFormatException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  File(outputPath).writeAsStringSync(entitlements);
}
