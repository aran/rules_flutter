import 'package:flutter/material.dart';

/// A simple themed title widget, demonstrating flutter_library usage.
class AppTitle extends StatelessWidget {
  const AppTitle({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.headlineMedium,
    );
  }
}
