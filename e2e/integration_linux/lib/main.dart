import 'dart:async';

import 'package:flutter/material.dart';
import 'package:linux_greeting_plugin/linux_greeting_plugin.dart';

void main() {
  runApp(const CounterApp());
}

/// Root widget of the Linux integration test example app.
class CounterApp extends StatelessWidget {
  /// Creates the counter application widget.
  const CounterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Integration Linux Counter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const CounterHomePage(),
    );
  }
}

/// Counter screen displaying the tap count, bundled asset, and C++ greeting.
class CounterHomePage extends StatefulWidget {
  /// Creates the counter home page.
  const CounterHomePage({super.key});

  @override
  State<CounterHomePage> createState() => _CounterHomePageState();
}

class _CounterHomePageState extends State<CounterHomePage> {
  int _counter = 0;
  String _greeting = 'Loading...';

  @override
  void initState() {
    super.initState();
    unawaited(_loadGreeting());
  }

  Future<void> _loadGreeting() async {
    final greeting = await const LinuxGreetingPlugin().getGreeting();
    if (!mounted) {
      return;
    }
    setState(() {
      _greeting = greeting ?? 'Unknown greeting';
    });
  }

  void _increment() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Integration Linux Counter')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Image.asset(
              'assets/logo.png',
              key: const ValueKey<String>('app_logo'),
            ),
            Text(
              _greeting,
              key: const ValueKey<String>('plugin_greeting'),
            ),
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              key: const ValueKey<String>('counter_text'),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey<String>('increment_button'),
        onPressed: _increment,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
