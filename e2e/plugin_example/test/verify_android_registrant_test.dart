/// Verifies an app's Android registrant registers the plugin of
/// `kotlin_only_plugin`: `plugin_app`'s, or the one `REGISTRANT` names.
///
/// Property: a `path` package with no Bazel build, named in
/// `flutter_pub.from_lock(build_from_pubspec = ...)`, is built from its
/// pubspec as a plugin from pub.dev is: its `pluginClass` and `package` reach
/// the app, and the generated registrant adds the plugin to the engine. A
/// plugin that compiled into the app but was never registered would never
/// answer its channel. `kotlin_plugin_user_app` reaches the plugin only
/// through a package with nothing of Flutter's, which must not drop it.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

void main() {
  final registrant = File(
    requireRunfile(
      '${Platform.environment['REGISTRANT'] ?? 'plugin_android_registrant'}'
      '/io/flutter/plugins/GeneratedPluginRegistrant.java',
      what: 'The generated Android registrant',
    ),
  ).readAsStringSync();

  const registration = 'new com.example.kotlin_only_plugin.KotlinOnlyPlugin()';
  if (!registrant.contains(registration)) {
    stderr.writeln(
      'The Android registrant does not register KotlinOnlyPlugin '
      '(expected `$registration`):\n$registrant',
    );
    exit(1);
  }
  stdout.writeln('The Android registrant registers KotlinOnlyPlugin.');
}
