import 'dart:developer' as developer;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:greeting_plugin/greeting_plugin.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plugin Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const _Home(),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  Future<_PluginResults>? _results;

  @override
  void initState() {
    super.initState();
    _results = _resolve();
  }

  Future<_PluginResults> _resolve() async {
    final appName = await _safe(() async {
      final info = await PackageInfo.fromPlatform();
      return info.appName;
    });

    final documentsPath = kIsWeb
        ? 'web: not supported'
        : await _safe(() async => (await getApplicationDocumentsDirectory()).path);

    final tempPath = kIsWeb
        ? 'web: not supported'
        : await _safe(() async => (await getTemporaryDirectory()).path);

    final launchOk = await _safe(() async {
      final canLaunch = await canLaunchUrl(Uri.parse('https://flutter.dev'));
      return canLaunch ? 'launch ok' : 'launch denied';
    });

    // audio_session uses the SwiftPM-canonical Sources/<pkg>/include/<pkg>/
    // public-header layout with bare-basename `#import "AudioSessionPlugin.h"`,
    // exercising the include-path wiring in flutter_apple_plugin_library.
    // Web has no implementation; surface a sentinel.
    final audioSession = kIsWeb
        ? 'web: not supported'
        : await _safe(() async {
            await AudioSession.instance;
            return 'audio ok';
          });

    final results = _PluginResults(
      appName: appName,
      documentsPath: documentsPath,
      tempPath: tempPath,
      launchOk: launchOk,
      audioSession: audioSession,
    );

    // Emit a single line so e2e tests (Playwright + the macOS verifier) can
    // assert on the resolved plugin outputs without needing semantics-tree
    // access.
    final summary =
        'plugin_example_results greeting=${GreetingPlugin.greeting} | '
        'appName=$appName | documentsPath=$documentsPath | '
        'tempPath=$tempPath | launchOk=$launchOk | '
        'audioSession=$audioSession';
    developer.log(summary, name: 'plugin_example');
    debugPrint(summary);

    return results;
  }

  Future<String> _safe(Future<String> Function() body) async {
    try {
      return await body();
    } catch (e) {
      return 'error: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Plugin Example'),
      ),
      body: FutureBuilder<_PluginResults>(
        future: _results,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('snapshot error: ${snapshot.error}'),
            );
          }
          final r = snapshot.data!;
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Row(label: 'greeting', value: GreetingPlugin.greeting),
                _Row(label: 'appName', value: r.appName),
                _Row(label: 'documentsPath', value: r.documentsPath),
                _Row(label: 'tempPath', value: r.tempPath),
                _Row(label: 'launchOk', value: r.launchOk),
                _Row(label: 'audioSession', value: r.audioSession),
                // Plain keyed Text for the agent getText e2e (SelectableText
                // rich spans aren't readable through ext.rules_flutter.getText).
                Text(
                  r.documentsPath,
                  key: const ValueKey('e2e_documents_path'),
                  style: const TextStyle(fontSize: 8),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PluginResults {
  const _PluginResults({
    required this.appName,
    required this.documentsPath,
    required this.tempPath,
    required this.launchOk,
    required this.audioSession,
  });

  final String appName;
  final String documentsPath;
  final String tempPath;
  final String launchOk;
  final String audioSession;
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            TextSpan(
              text: value,
              // data-testid-style attribute via semantics so playwright/web
              // tests can locate this row by its label.
            ),
          ],
        ),
        semanticsLabel: '$label: $value',
      ),
    );
  }
}
