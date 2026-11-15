import 'package:flutter/widgets.dart';
import 'package:greeting/greeting.dart';

void main() {
  runApp(const GreeterApp());
}

/// Shows the greeting once it has loaded.
///
/// Widgets alone, not Material: Flutter's Material widgets are the pub
/// package `material_ui`, which depends on `intl`, and this workspace
/// replaces `intl` with a fork that has only what the greeting uses.
class GreeterApp extends StatelessWidget {
  /// Creates the app.
  const GreeterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: FutureBuilder<String>(
          future: Greeting.text(),
          builder: (context, snapshot) {
            final text = snapshot.data;
            if (text == null) {
              return const SizedBox.shrink();
            }
            return Text(text, key: const ValueKey('greeting'));
          },
        ),
      ),
    );
  }
}
