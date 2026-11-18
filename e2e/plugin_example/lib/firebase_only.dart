import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';

/// An app whose only Android plugins are FlutterFire's firebase_core and
/// cloud_firestore. It names their APIs so that both are linked; it calls
/// none, since the app has no Firebase project to connect to.
void main() {
  runApp(
    Text(
      '${Firebase.apps.length} ${FirebaseFirestore.instanceFor}',
      textDirection: TextDirection.ltr,
    ),
  );
}
