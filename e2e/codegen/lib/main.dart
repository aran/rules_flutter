import 'package:dep_lib/catalog.dart';
import 'package:dep_part/settings.dart';
import 'package:flutter/material.dart';

import 'user.dart';

void main() {
  runApp(const CodegenApp(user: User('Ada Lovelace', 36)));
}

class CodegenApp extends StatelessWidget {
  const CodegenApp({super.key, required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    // Render generated output from the app package (user.g.dart `part`), a
    // dependency's generated `part` (dep_part settings.g.dart) and a
    // dependency's generated imported library (dep_lib catalog.g.dart), all in
    // build() so a regenerated `.g.dart` in any of them is observable on a hot
    // reload.
    const settings = Settings('dark');
    const catalog = Catalog('demo');
    return MaterialApp(
      title: 'Codegen Example',
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${user.toJson()}'),
              Text('${settings.toJson()}'),
              Text('fields:${catalog.fieldSummary}'),
            ],
          ),
        ),
      ),
    );
  }
}
