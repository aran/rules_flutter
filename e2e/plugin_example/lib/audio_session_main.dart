import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';

/// Shows what audio_session, built for this app's environment, answers.
///
/// With its record permission code, `recordPermission` answers with the
/// permission; without it, the plugin does not implement the call.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String record;
  try {
    record = (await AVAudioSession().recordPermission).name;
  } on Object catch (e) {
    record = '$e';
  }
  runApp(
    Center(
      child: Text('record: $record', textDirection: TextDirection.ltr),
    ),
  );
}
