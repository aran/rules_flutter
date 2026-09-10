import 'package:flutter/material.dart';

/// A simple themed title widget, demonstrating flutter_library usage.
class AppTitle extends StatelessWidget {
  /// Creates a title widget rendering [text] in the headline style.
  const AppTitle({required this.text, super.key});

  /// The string this widget renders.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.headlineMedium,
    );
  }
}
