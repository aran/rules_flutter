import 'package:fed/fed.dart';
import 'package:fed_alt/fed_alt.dart';
import 'package:flutter/widgets.dart';

/// An app over a federated plugin, `fed`, that depends on its second Android
/// implementation, `fed_alt`. Its APK is what
/// `verify_android_federated_test` checks.
void main() {
  runApp(const Text('$fed $fedAlt', textDirection: TextDirection.ltr));
}
