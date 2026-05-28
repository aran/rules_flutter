import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'common_widgets.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hello World',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Hello World'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  int _longPressCount = 0;
  int _doubleTapCount = 0;
  final _agentEchoController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _agentEchoController.addListener(() => setState(() {}));
  }

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
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
            AppTitle(text: '$_counter'),
            // Icon from cupertino_icons (a pub package shipping its own
            // font via flutter.fonts) — verifies that pub-package fonts
            // make it into the bundle and render correctly.
            const Icon(CupertinoIcons.heart, size: 48),
            Text(
              'count: $_counter',
              key: const ValueKey('agent_test_label'),
            ),
            ElevatedButton(
              key: const ValueKey('agent_test_button'),
              onPressed: _incrementCounter,
              child: const Text('Increment (agent)'),
            ),
            SizedBox(
              width: 200,
              child: TextField(
                key: const ValueKey('agent_test_field'),
                controller: _agentEchoController,
              ),
            ),
            Text(
              'echo: ${_agentEchoController.text}',
              key: const ValueKey('agent_test_echo'),
            ),
            GestureDetector(
              key: const ValueKey('agent_gesture_box'),
              onLongPress: () => setState(() => _longPressCount++),
              onDoubleTap: () => setState(() => _doubleTapCount++),
              child: Container(
                width: 200,
                height: 40,
                color: Colors.amber,
                alignment: Alignment.center,
                child: Text(
                  'gestures: lp=$_longPressCount dt=$_doubleTapCount',
                  key: const ValueKey('agent_gesture_label'),
                ),
              ),
            ),
            SizedBox(
              height: 80,
              width: 200,
              child: ListView.builder(
                key: const ValueKey('agent_test_list'),
                itemCount: 50,
                itemExtent: 24,
                itemBuilder: (ctx, i) => Text(
                  'item $i',
                  key: ValueKey('agent_test_list_item_$i'),
                ),
              ),
            ),
            ElevatedButton(
              key: const ValueKey('agent_nav_button'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: Center(
                      child: Text(
                        'detail page',
                        key: ValueKey('agent_nav_detail'),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('Navigate'),
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
