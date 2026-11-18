import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';

/// The Flutter screen of the add-to-app module: firebase_core, whose Apple
/// side depends on firebase-ios-sdk, a remote Swift package, configures
/// Firebase and shows the project it answers with.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = await Firebase.initializeApp(
    options: const FirebaseOptions(
      // As Firebase checks a key: 39 characters, starting with `A`.
      apiKey: 'AIzaSyBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      appId: '1:123456789012:ios:0123456789abcdef012345',
      messagingSenderId: '123456789012',
      projectId: 'rules-flutter-e2e',
    ),
  );
  runApp(
    Center(
      child: Text(app.options.projectId, textDirection: TextDirection.ltr),
    ),
  );
}
