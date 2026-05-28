import 'package:flutter/material.dart';

import 'user.dart';

void main() {
  final user = User('Ada Lovelace', 36);
  runApp(CodegenApp(json: user.toJson()));
}

class CodegenApp extends StatelessWidget {
  const CodegenApp({super.key, required this.json});

  final Map<String, dynamic> json;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Codegen Example',
      home: Scaffold(
        body: Center(child: Text('$json')),
      ),
    );
  }
}
