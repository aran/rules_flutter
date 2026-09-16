import 'dart:ffi';

import 'package:add_plugin/add_plugin.dart';
import 'package:flutter/material.dart';

/// `sub` from `libsub.dylib`, which the build produces in a subdirectory of
/// its package (`vendor/lib/`) rather than at the package root. Opened by bare
/// file name, so this resolves only if the bundle put the library directly in
/// `Contents/Frameworks/`.
final int Function(int, int) _sub = DynamicLibrary.open('libsub.dylib')
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'sub',
    );

void main() {
  final result = add(3, 4);
  final difference = _sub(7, 4);

  // verify_macos_app_test reads this line off the app's stdout: the proof that
  // both bundled native libraries loaded and answered.
  debugPrint('macos_example_native sum=$result difference=$difference');

  runApp(MyApp(result: result, difference: difference));
}

/// Root widget of the macOS example, which displays values computed by two
/// bundled native libraries rather than in Dart.
class MyApp extends StatelessWidget {
  /// Creates the macOS example's root widget showing [result] and
  /// [difference].
  const MyApp({required this.result, required this.difference, super.key});

  /// The sum returned by the plugin's native `add`, rendered on screen.
  final int result;

  /// The difference returned by the app's own native `sub`, rendered on
  /// screen.
  final int difference;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'macOS Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('macOS Example'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '3 + 4 = $result',
                style: const TextStyle(fontSize: 32),
              ),
              Text(
                '7 - 4 = $difference',
                style: const TextStyle(fontSize: 32),
              ),
              // Renders the E2E_MESSAGE dart-define (empty without one).
              // dart_defines_e2e_test asserts the value before AND after a
              // hot reload — the reload must not lose the define.
              const Text(
                '${String.fromEnvironment('E2E_MESSAGE')} v1',
                key: ValueKey('e2e_define_label'),
              ),
              // Renders a first-party asset, re-read on every build. That is
              // what makes an asset hot reload observable: the dev tool
              // rebuilds the bundle and evicts the changed archive path, and
              // the rebuild this triggers reads the new bytes.
              // asset_reload_e2e_test edits the file on disk and asserts the
              // text changes without the app restarting.
              FutureBuilder<String>(
                future: DefaultAssetBundle.of(
                  context,
                ).loadString('assets/message.txt'),
                builder: (context, snapshot) => Text(
                  snapshot.data?.trim() ?? '',
                  key: const ValueKey('e2e_asset_label'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
