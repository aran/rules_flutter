// Shows the motto the app's own link hook wrote into the bundle at
// `packages/own_hook/motto.txt`. A debug build runs no hook and has no such
// asset, so the app says so instead of failing.

import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';
import 'package:own_hook/src/motto.dart';

void main() {
  runApp(const MaterialApp(title: 'Own Hook', home: _Home()));
}

class _Home extends StatelessWidget {
  const _Home();

  Future<String> _linked() async {
    try {
      return await rootBundle.loadString('packages/own_hook/motto.txt');
    } catch (e) {
      return 'not linked: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FutureBuilder<String>(
          future: _linked(),
          builder: (context, snapshot) =>
              Text('$motto\n${snapshot.data ?? '...'}'),
        ),
      ),
    );
  }
}
