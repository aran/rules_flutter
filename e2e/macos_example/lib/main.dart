import 'package:add_plugin/add_plugin.dart';
import 'package:flutter/material.dart';

void main() {
  final result = add(3, 4);

  runApp(MyApp(result: result));
}

/// Root widget of the macOS example, which displays a sum computed by the
/// bundled `add_plugin` FFI package rather than in Dart.
class MyApp extends StatelessWidget {
  /// Creates the macOS example's root widget showing [result].
  const MyApp({required this.result, super.key});

  /// The sum returned by the plugin's native `add`, rendered on screen.
  final int result;

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
