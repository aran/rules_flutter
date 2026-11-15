// An app that talks to the browser the way a real web app does: its own code
// imports `dart:js_interop`, `package:web` and `dart:ui_web`, none of which
// exist outside a web compile.
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:material_ui/material_ui.dart';
import 'package:web/web.dart' as web;

@JS('Math.max')
external JSNumber _max(JSNumber a, JSNumber b);

/// Runs the app.
void main() {
  final largest = _max(1.toJS, 2.toJS).toDartInt;
  final assetUrl = ui_web.assetManager.getAssetUrl('assets/message.txt');
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          // The one icon this app draws.
          const Icon(Icons.home),
          Text('${web.document.title} $largest $assetUrl'),
        ],
      ),
    ),
  );
}
