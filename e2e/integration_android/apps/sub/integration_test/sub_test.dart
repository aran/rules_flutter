/// Proves package-relative asset keys inside the Android bundle.
///
/// `//apps/sub:sub_test` lives in Bazel package `//apps/sub`: its own
/// `assets/sub.txt` must load at `assets/sub.txt` (relative to the listing
/// package), and the first-party `//libs/brand` dependency's asset at
/// `packages/brand/assets/brand.txt`. On the pre-fix keying (raw
/// `File.short_path`) both lookups throw because the bundle carries
/// `apps/sub/assets/sub.txt` and `libs/brand/assets/brand.txt` instead.
///
/// The same package-relative rule covers the target's own `shaders`:
/// `shaders/sub.frag` must load as `shaders/sub.frag`, which is where
/// `FragmentProgram.fromAsset` looks for it.
library;

import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sub/main.dart';

/// Loads an asset's text with checkout line endings normalized away.
///
/// Git on Windows checks text fixtures out with CRLF and the bundle carries
/// bytes verbatim, so comparing raw bytes against an LF literal fails there.
/// Normalizing here keeps the assertion exact on every runner.
Future<String> _assetText(String key) async =>
    (await rootBundle.loadString(key)).replaceAll('\r\n', '\n');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('subpackage and brand assets resolve at package-relative keys', (
    tester,
  ) async {
    await tester.pumpWidget(const SubApp());
    await tester.pumpAndSettle();

    expect(find.text('Sub Brand'), findsOneWidget);

    expect(await _assetText('assets/sub.txt'), equals('sub asset\n'));
    expect(
      await _assetText('packages/brand/assets/brand.txt'),
      equals('brand asset\n'),
    );
  });

  testWidgets('subpackage shader loads at its package-relative key', (
    tester,
  ) async {
    await tester.pumpWidget(const SubApp());
    await tester.pumpAndSettle();

    final program = await FragmentProgram.fromAsset('shaders/sub.frag');
    expect(program.fragmentShader(), isNotNull);
  });
}
