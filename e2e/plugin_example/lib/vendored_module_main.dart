/// The Flutter screen of `//:vendored_module`, whose plugin links a prebuilt
/// dynamic framework: it shows the greeting that framework returns.
library;

import 'package:flutter/widgets.dart';
import 'package:vendored_plugin/vendored_plugin.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final greeting = await VendoredPlugin.greeting();
  runApp(
    Center(
      child: Text('$greeting', textDirection: TextDirection.ltr),
    ),
  );
}
