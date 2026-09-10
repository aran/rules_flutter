import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

/// Root widget of the iOS example: a greeting plus an asset read on every
/// build, which `asset_reload_e2e_test` uses to observe a re-delivered asset.
class MyApp extends StatelessWidget {
  /// Creates the iOS example's root widget.
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iOS Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('iOS Example'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Hello from Flutter iOS!',
                style: TextStyle(fontSize: 32),
              ),
              // Read on every build, so a re-delivered asset shows up without
              // restarting. asset_reload_e2e_test drives this.
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
