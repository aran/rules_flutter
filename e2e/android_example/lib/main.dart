import 'package:android_example/native_add.dart';
import 'package:android_example/shared_counter.dart';
import 'package:flutter/material.dart';

void main() {
  // Counted once, before the first frame, so the log line and the screen agree.
  // `verify_android_app_test` reads this line back from logcat.
  final shared = sharedCount();
  debugPrint('android_example shared=$shared');
  runApp(MyApp(shared: shared));
}

/// Root widget of the Android example, which renders results computed by the
/// native libraries packaged into the APK.
class MyApp extends StatelessWidget {
  /// Creates the Android example's root widget.
  const MyApp({required this.shared, super.key});

  /// The shared counter after one bump through each of its two asset ids.
  final int shared;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Android Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('Android Example'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Hello from Flutter Android!',
                style: TextStyle(fontSize: 32),
              ),
              Text(
                'native add(19, 23) = ${nativeAdd(19, 23)}',
                style: const TextStyle(fontSize: 24),
              ),
              Text(
                'shared counter = $shared',
                style: const TextStyle(fontSize: 24),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
