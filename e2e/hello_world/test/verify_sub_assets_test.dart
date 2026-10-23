/// Asserts package-relative asset keys for a subpackage app bundle.
///
/// `//sub:sub_app` lives in Bazel package `//sub`, so its own
/// `assets/notice.txt` must be keyed relative to that package directory (not
/// prefixed with `sub/`): the nested `//sub/nested` package's `extra.txt`
/// arrives as `nested/extra.txt`, and the genrule output as `gen_notice.txt`.
/// The first-party `//brand` dependency's asset is keyed
/// `packages/brand/assets/brand.txt` — the flutter_tools key rule.
///
/// Backed by data files (the bundle's `flutter_assets/` tree, copied into
/// the test's runfiles via `data = ["//sub:sub_app"]`). Hermetic like
/// `verify_pub_assets_test.dart`: no `bazel build` from inside the test, no
/// host flutter SDK. The bundle structure alone proves the key computation.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Reads an asset's text with checkout line endings normalized away.
///
/// Git on Windows checks text fixtures out with CRLF and the bundle carries
/// bytes verbatim, so comparing raw bytes against an LF literal fails there.
/// Normalizing here keeps the assertion exact on every runner.
String _assetText(File file) =>
    file.readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  late Directory bundleDir;

  setUpAll(() {
    // The data dep `//sub:sub_app` produces a tree artifact
    // `sub_app_flutter_assets`, staged in the test's runfiles under the
    // target's package directory.
    final path = Runfiles.create().rlocation(
      '_main/sub/sub_app_flutter_assets',
    );
    bundleDir = Directory(path);
    if (!bundleDir.existsSync()) {
      throw StateError(
        'sub_app_flutter_assets not found at runfiles path: $path',
      );
    }
  });

  test('own asset is keyed relative to the sub package', () {
    final asset = File('${bundleDir.path}/assets/notice.txt');
    expect(asset.existsSync(), isTrue);
    expect(_assetText(asset), equals('sub notice\n'));
  });

  test('dependency asset lands at packages/brand/...', () {
    final asset = File('${bundleDir.path}/packages/brand/assets/brand.txt');
    expect(asset.existsSync(), isTrue);
    expect(_assetText(asset), equals('brand asset\n'));
  });

  test('nested-package file is keyed under the directory', () {
    final asset = File('${bundleDir.path}/nested/extra.txt');
    expect(asset.existsSync(), isTrue);
    expect(_assetText(asset), equals('nested extra\n'));
  });

  test('generated file is keyed by its repository-relative path', () {
    final asset = File('${bundleDir.path}/gen_notice.txt');
    expect(asset.existsSync(), isTrue);
    expect(_assetText(asset), equals('generated notice\n'));
  });

  test('AssetManifest.bin.json carries both package-relative keys', () {
    // Same decoding trick as verify_pub_assets_test.dart: the .bin.json
    // wrapper is base64-encoded StandardMessageCodec, whose string keys
    // appear as UTF-8 bytes inline in the binary.
    final wrapped = jsonDecode(
      File('${bundleDir.path}/AssetManifest.bin.json').readAsStringSync(),
    ) as String;
    final asString = utf8.decode(base64Decode(wrapped), allowMalformed: true);
    expect(asString, contains('assets/notice.txt'));
    expect(asString, contains('nested/extra.txt'));
    expect(asString, contains('gen_notice.txt'));
    expect(asString, contains('packages/brand/assets/brand.txt'));
    expect(asString, isNot(contains('sub/assets/notice.txt')));
    expect(asString, isNot(contains('bazel-out/')));
    expect(asString, isNot(contains('packages/sub_app/')));
  });
}
