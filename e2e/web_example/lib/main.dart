import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

/// Root widget of the web example, served by the bundle `flutter_web_app`
/// builds.
class MyApp extends StatelessWidget {
  /// Creates the web example's root widget.
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Web Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Web Example'),
    );
  }
}

/// The example's only screen: a counter, rendered once the engine boots.
class MyHomePage extends StatefulWidget {
  /// Creates the counter screen, showing [title] in the app bar.
  const MyHomePage({required this.title, super.key});

  /// Text shown in the app bar.
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  final _keysController = TextEditingController();
  String _submitted = '';

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  void dispose() {
    _keysController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            // Read on every build, so an edit to the file shows up once the
            // dev tool evicts the framework's cached copy. asset_reload_e2e
            // edits it mid-run and asserts the new text reaches the page.
            FutureBuilder<String>(
              future: DefaultAssetBundle.of(
                context,
              ).loadString('assets/message.txt'),
              builder: (context, snapshot) => Text(
                snapshot.data?.trim() ?? '',
                key: const ValueKey('e2e_asset_label'),
              ),
            ),
            // Typed into with real browser key events by
            // press_key_e2e_test.dart. What Enter submitted is shown twice:
            // as text, for app.getText on the DDC dev loop, and as one
            // magenta square per character, for a screenshot on --wasm,
            // which has no VM service to read text through.
            SizedBox(
              width: 240,
              child: TextField(
                key: const ValueKey('keys_field'),
                controller: _keysController,
                onSubmitted: (value) => setState(() => _submitted = value),
              ),
            ),
            Text(
              'submitted: $_submitted',
              key: const ValueKey('keys_submitted'),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _submitted.length; i++)
                  const Padding(
                    padding: EdgeInsets.all(4),
                    child: ColoredBox(
                      color: Color(0xFFFF00FF),
                      child: SizedBox.square(dimension: 16),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
