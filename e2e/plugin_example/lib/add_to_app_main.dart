/// The Flutter screen a native host app built by Xcode embeds: the module of
/// `//:add_to_app_module`, packaged as xcframeworks.
///
/// It calls one plugin of each kind the packaging handles, and shows and logs
/// what each answered: a Swift plugin built from its Package.swift
/// (url_launcher), Objective-C ones (package_info_plus, audio_session), one
/// mixing both (mixed_plugin), and one reached through a code asset
/// (path_provider).
library;

import 'package:audio_session/audio_session.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mixed_plugin/mixed_plugin.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const _Module());

class _Module extends StatelessWidget {
  const _Module();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Add-to-app',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    home: const _Results(),
  );
}

class _Results extends StatefulWidget {
  const _Results();

  @override
  State<_Results> createState() => _ResultsState();
}

class _ResultsState extends State<_Results> {
  late final Future<Map<String, String>> _results = _resolve();

  static Future<String> _safe(Future<String> Function() body) async {
    try {
      return await body();
    } on Exception catch (e) {
      return 'error: $e';
    }
  }

  Future<Map<String, String>> _resolve() async {
    final results = {
      'mixed': await _safe(
        () async => await MixedPlugin.greeting() ?? 'no answer',
      ),
      'appName': await _safe(
        () async => (await PackageInfo.fromPlatform()).appName,
      ),
      'launch': await _safe(
        () async => await canLaunchUrl(Uri.parse('https://flutter.dev'))
            ? 'launch ok'
            : 'launch denied',
      ),
      'prefs': await _safe(() async {
        final stored = DateTime.now().millisecondsSinceEpoch.toString();
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString('add_to_app', stored);
        return preferences.getString('add_to_app') == stored
            ? 'roundtrip ok'
            : 'mismatch';
      }),
      'audio': await _safe(() async {
        await AudioSession.instance;
        return 'audio ok';
      }),
      'documents': await _safe(
        () async => (await getApplicationDocumentsDirectory()).path.isNotEmpty
            ? 'path ok'
            : 'empty path',
      ),
    };
    final summary = [
      for (final e in results.entries) '${e.key}=${e.value}',
    ].join(' | ');
    debugPrint('add_to_app_results $summary');
    return results;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Flutter in a native app')),
    body: FutureBuilder<Map<String, String>>(
      future: _results,
      builder: (context, snapshot) {
        final results = snapshot.data;
        if (results == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            for (final entry in results.entries)
              ListTile(title: Text(entry.key), subtitle: Text(entry.value)),
          ],
        );
      },
    ),
  );
}
