import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hello_world/common_widgets.dart';

void main() {
  runApp(const MyApp());
}

/// Root widget of the hello_world example, the fixture the dev-tool reload
/// and gesture end-to-end tests drive.
class MyApp extends StatelessWidget {
  /// Creates the hello_world example's root widget.
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

/// The example's only screen: a counter plus the keyed widgets the agent
/// end-to-end tests tap, type into, and read back.
class MyHomePage extends StatefulWidget {
  /// Creates the screen, showing [title] in the app bar.
  const MyHomePage({required this.title, super.key});

  /// Text shown in the app bar.
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
            // An app that never goes idle, on request.
            //
            // `CircularProgressIndicator` runs an `AnimationController` that
            // repeats forever, so a transient frame callback is registered for
            // as long as it is on screen and the agent surface's settle-wait
            // can never observe an idle frame. `settle: "false"` is the way
            // out, and `agent_e2e_test.dart` asserts both halves against this
            // widget.
            //
            // Behind a define because it is a property of the app under test,
            // not of the test: with it on screen unconditionally, every other
            // agent command in this workspace would time out.
            if (const bool.fromEnvironment('E2E_NEVER_SETTLES'))
              const CircularProgressIndicator(
                key: ValueKey('agent_never_settles'),
              ),
            // A control that is in the tree but not where a pointer can
            // reach it.
            //
            // Eight buttons in a 200px-wide horizontal scroll view: the first
            // is on screen, the last is laid out past x=900 in an 800-wide
            // window. Both are found by `ValueKey` and both have a rect, so
            // only the visible-bounds check separates them.
            // `agent_e2e_test.dart` asserts the refusal and the way through it.
            //
            // Behind a define for the same reason the spinner is: a clipped
            // toolbar is a property of the app under test, not of every test
            // in this workspace.
            // The same refusal's other branch: in the view, and covered.
            //
            // A button under an opaque overlay is on screen and has a rect a
            // pointer could reach — the event simply goes to whatever is on
            // top. That is where a tap ends up when a reported coordinate
            // lands in a different pane, and it reads nothing like the
            // off-screen case, so the message says which one it is and the
            // e2e exercises both.
            if (const bool.fromEnvironment('E2E_CLIPPED_TOOLBAR'))
              SizedBox(
                width: 200,
                height: 40,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ElevatedButton(
                        key: const ValueKey('covered_button'),
                        onPressed: _incrementCounter,
                        child: const Text('covered'),
                      ),
                    ),
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {},
                        child: const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),
            if (const bool.fromEnvironment('E2E_CLIPPED_TOOLBAR'))
              SizedBox(
                width: 200,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < 8; i++)
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: ElevatedButton(
                            key: ValueKey('toolbar_$i'),
                            onPressed: _incrementCounter,
                            child: Text('btn $i'),
                          ),
                        ),
                    ],
                  ),
                ),
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
