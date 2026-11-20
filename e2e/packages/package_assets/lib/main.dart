// Shows the index of glyphs this app constructs, which `glyphs`' link hook
// writes from the compiler's recorded uses and the release bundle carries at
// `packages/glyphs/glyphs/index.json`. A debug build runs no hook and has no
// index, so the app says so instead of failing.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:glyphs/glyphs.dart';
import 'package:material_ui/material_ui.dart';

const _favourite = Glyph('star');

void main() {
  runApp(const _App());
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(title: 'Package Assets', home: _Home());
  }
}

class _Home extends StatelessWidget {
  const _Home();

  Future<String> _index() async {
    try {
      final names = jsonDecode(
        await rootBundle.loadString('packages/glyphs/glyphs/index.json'),
      );
      return 'index: $names';
    } catch (e) {
      return 'no index: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FutureBuilder<String>(
          future: _index(),
          builder: (context, snapshot) => Text(
            '$_favourite ${const Glyph('heart')}\n${snapshot.data ?? '...'}',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
