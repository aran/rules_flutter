import 'package:material_ui/material_ui.dart';

/// Runs the counter app.
void main() {
  runApp(const CounterApp());
}

/// An app with one number and a button that adds one to it.
class CounterApp extends StatelessWidget {
  /// Creates the counter app.
  const CounterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: CounterPage());
  }
}

/// The counter's one page.
class CounterPage extends StatefulWidget {
  /// Creates the page.
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('$_count', key: const ValueKey('count'))),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('increment'),
        onPressed: () => setState(() => _count++),
        child: const Icon(Icons.add),
      ),
    );
  }
}
