// Synthetic Native Assets demonstrator.
//
// At runtime this:
//   1. Calls a `@Native(assetId: ...)`-bound function from
//      "package:native_assets_synthetic/synthetic.dylib", a
//      `flutter_native_asset(link_mode = "dynamic_loading_bundle")`
//      contributed by the workspace's `:synthetic_native_asset_macos`
//      target. The VM resolves the asset id at first call through the
//      kernel's `--native-assets` manifest and dlopens the dylib from
//      the bundle's Frameworks slot.
//   2. Loads "package:native_assets_synthetic/blob.txt", a
//      `flutter_data_asset` bundled at
//      `flutter_assets/data/native_assets_synthetic/blob.txt`.
//   3. Renders both values in the UI. If either pipeline regresses,
//      the FFI call throws or the asset fails to load — the screen
//      blanks and the dev_tool screenshot e2e fails.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

// Asset ids resolve only at `@Native` bind time. Raw
// `DynamicLibrary.open('package:...')` does NOT consult the native-assets
// mapping — the Dart VM passes the literal string to dlopen on every
// platform — so an asset id is not a loadable path.
@Native<Int32 Function()>(
  symbol: 'synthetic_canary',
  assetId: 'package:native_assets_synthetic/synthetic.dylib',
)
external int _syntheticCanary();

void main() {
  runApp(const _SyntheticApp());
}

class _SyntheticApp extends StatelessWidget {
  const _SyntheticApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Native Assets Synthetic',
      home: const _Home(),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late final Future<_Result> _future = _resolve();

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
        'data/native_assets_synthetic/blob.txt',
      );
      blob = String.fromCharCodes(
        Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes),
      ).trim();
    } catch (e) {
      blob = 'error: $e';
    }

    return _Result(canary: canary, blob: blob);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Native Assets Synthetic')),
      body: FutureBuilder<_Result>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final r = snap.data!;
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('canary=${r.canary}', textScaler: const TextScaler.linear(1.4)),
                Text('blob=${r.blob}', textScaler: const TextScaler.linear(1.4)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Result {
  const _Result({required this.canary, required this.blob});
  final String canary;
  final String blob;
}
