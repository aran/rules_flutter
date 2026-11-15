// An app whose icons come from three different places, so a release build has
// to find each of them to keep it in the shipped icon font:
//
//  - `Icons.home`, drawn here;
//  - the icon of `platformIcon`, which `platform_icon_web.dart` and
//    `platform_icon_stub.dart` define differently, so which one this app
//    draws depends on the platform it is compiled for;
//  - `IconPlugin.shown`, set by a web plugin that nothing in this file
//    imports: only the generated plugin registrant reaches it.
//
// `Icons.ac_unit` is in none of them and must not be kept.
import 'package:material_ui/material_ui.dart';

import 'package:web_interop/platform_icon_stub.dart'
    if (dart.library.js_interop) 'package:web_interop/platform_icon_web.dart';

/// Runs the app.
void main() {
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        children: [
          const Icon(Icons.home),
          const Icon(platformIcon),
          Text(browserLanguage() ?? ''),
        ],
      ),
    ),
  );
}
