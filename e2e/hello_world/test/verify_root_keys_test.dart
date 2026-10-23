/// Asserts the workspace-root asset key rule.
///
/// `//:root_keys_bundle` lives at the workspace root, which strips nothing:
/// the nested `//brand` package's `assets/brand.txt` keeps its
/// `brand/assets/brand.txt` key and the genrule output its `root_gen.txt`
/// key — exactly today's keys, so root bundles stay byte-identical.
///
/// Backed by data files (the bundle's `flutter_assets/` tree, copied into
/// the test's runfiles via `data = [":root_keys_bundle"]`). Hermetic like
/// `verify_pub_assets_test.dart`.
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
    // The data dep `//:root_keys_bundle` produces a tree artifact named
    // after the target, staged in the test's runfiles at the repo root.
    final path = Runfiles.create().rlocation('_main/root_keys_bundle');
    bundleDir = Directory(path);
    if (!bundleDir.existsSync()) {
      throw StateError('root_keys_bundle not found at runfiles path: $path');
    }
  });

  test('nested-package file keeps its repository-relative key', () {
    final asset = File('${bundleDir.path}/brand/assets/brand.txt');
    expect(asset.existsSync(), isTrue);
    expect(_assetText(asset), equals('brand asset\n'));
  });

  test('generated file keeps its repository-relative key', () {
    final asset = File('${bundleDir.path}/root_gen.txt');
    expect(asset.existsSync(), isTrue);
    expect(_assetText(asset), equals('root generated\n'));
  });

  test('AssetManifest.bin.json carries both keys verbatim', () {
    // Same decoding trick as verify_pub_assets_test.dart: the .bin.json
    // wrapper is base64-encoded StandardMessageCodec, whose string keys
    // appear as UTF-8 bytes inline in the binary.
    final wrapped = jsonDecode(
      File('${bundleDir.path}/AssetManifest.bin.json').readAsStringSync(),
    ) as String;
    final asString = utf8.decode(base64Decode(wrapped), allowMalformed: true);
    expect(asString, contains('brand/assets/brand.txt'));
    expect(asString, contains('root_gen.txt'));
    expect(asString, isNot(contains('bazel-out/')));
  });
}
