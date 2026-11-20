// Synthetic Native Assets demonstrator.
//
// At startup this:
//   1. Calls a `@Native(assetId: ...)`-bound function from
//      "package:native_assets_synthetic/synthetic.dylib", a
//      `dart_code_asset(link_mode = "dynamic_loading_bundle")`, the
//      `//package_assets/own_assets:synthetic_native_asset_macos`, which the
//      package's metadata owns. The VM resolves the asset id at first call
//      through the kernel's `--native-assets` manifest and dlopens the dylib
//      from the bundle's Frameworks slot.
//   2. Loads "package:native_assets_synthetic/blob.txt", a `dart_data_asset`
//      the package's metadata declares, bundled at
//      `flutter_assets/packages/native_assets_synthetic/blob.txt`.
//   3. Prints both values, which `:verify_macos_app_test` reads, and renders
//      them.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';

// Asset ids resolve only at `@Native` bind time. Raw
// `DynamicLibrary.open('package:...')` does NOT consult the native-assets
// mapping — the Dart VM passes the literal string to dlopen on every
// platform — so an asset id is not a loadable path.
@Native<Int32 Function()>(
  symbol: 'synthetic_canary',
  assetId: 'package:native_assets_synthetic/synthetic.dylib',
)
external int _syntheticCanary();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final result = await _resolve();
  // The app's report to `:verify_macos_app_test`.
  // ignore: avoid_print
  print('native_assets_synthetic canary=${result.canary} blob=${result.blob}');
  runApp(_SyntheticApp(result));
}

Future<_Result> _resolve() async {
  String canary;
  try {
    canary = '0x${_syntheticCanary().toRadixString(16)}';
  } catch (e) {
    canary = 'error: $e';
  }

  String blob;
  try {
    final ByteData data = await rootBundle.load(
      'packages/native_assets_synthetic/blob.txt',
    );
    blob = String.fromCharCodes(
      Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes),
    ).trim();
  } catch (e) {
    blob = 'error: $e';
  }

  return _Result(canary: canary, blob: blob);
}

class _SyntheticApp extends StatelessWidget {
  const _SyntheticApp(this.result);
  final _Result result;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Native Assets Synthetic',
      home: Scaffold(
        appBar: AppBar(title: const Text('Native Assets Synthetic')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'canary=${result.canary}',
                textScaler: const TextScaler.linear(1.4),
              ),
              Text(
                'blob=${result.blob}',
                textScaler: const TextScaler.linear(1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Result {
  const _Result({required this.canary, required this.blob});
  final String canary;
  final String blob;
}
