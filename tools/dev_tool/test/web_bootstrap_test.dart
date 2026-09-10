import 'package:flutter_bazel_dev_tool/web_bootstrap.dart';
import 'package:test/test.dart';

void main() {
  group('generateSyntheticMainDart', () {
    test('runs the app entrypoint through bootstrapEngine', () {
      final source = generateSyntheticMainDart(
        appEntrypoint: 'package:app/main.dart',
      );
      expect(source, contains("import 'package:app/main.dart' as entrypoint;"));
      expect(source, contains('ui_web.bootstrapEngine('));
      expect(source, isNot(contains('registerPlugins:')));
    });

    test('imports and calls the plugin registrant when there is one', () {
      final source = generateSyntheticMainDart(
        appEntrypoint: 'package:app/main.dart',
        pluginRegistrantEntrypoint: 'web_plugin_registrant.dart',
      );
      expect(
        source,
        contains("import 'web_plugin_registrant.dart' as pluginRegistrant;"),
      );
      expect(source, contains('pluginRegistrant.registerPlugins();'));
    });

    // The agent extensions have to be registered on the way in, not from
    // inside `runApp`: `bootstrapEngine` does not return until the app is up,
    // and an agent driving a `-d chrome` run acts as soon as `app.started`
    // arrives. Registering first is also what DDC's own gating allows — DWDS
    // defers `main()` until its injected client is connected, so `$dwdsVersion`
    // and `$emitRegisterEvent` are already on the global by the time any line
    // of this file runs.
    group('agent extensions', () {
      test('are registered before the engine bootstraps', () {
        final source = generateSyntheticMainDart(
          appEntrypoint: 'package:app/main.dart',
          agentExtensionsEntrypoint: 'agent_extensions.dart',
        );
        expect(
          source,
          contains("import 'agent_extensions.dart' as agentExtensions;"),
        );
        final registerAt = source.indexOf(
          'agentExtensions.registerRulesFlutterAgentExtensions()',
        );
        final bootstrapAt = source.indexOf('ui_web.bootstrapEngine(');
        expect(registerAt, greaterThan(-1));
        expect(registerAt, lessThan(bootstrapAt));
      });

      test('are absent when the build staged none', () {
        final source = generateSyntheticMainDart(
          appEntrypoint: 'package:app/main.dart',
        );
        expect(source, isNot(contains('agentExtensions')));
      });

      test('coexist with the plugin registrant', () {
        final source = generateSyntheticMainDart(
          appEntrypoint: 'package:app/main.dart',
          pluginRegistrantEntrypoint: 'web_plugin_registrant.dart',
          agentExtensionsEntrypoint: 'agent_extensions.dart',
        );
        expect(source, contains('pluginRegistrant.registerPlugins();'));
        expect(
          source,
          contains('agentExtensions.registerRulesFlutterAgentExtensions();'),
        );
      });
    });
  });

  // `dartDevEmbedder.runMain` is keyed by app name, and the loader registers
  // modules under the name the *bootstrap* script computed. The two scripts
  // derive it separately from the same entrypoint, so they can drift apart —
  // and a runMain against an unregistered name is a page that loads every
  // module and then runs nothing.
  group('DDC bootstrap scripts', () {
    test('agree on the app name they derive from the entrypoint', () {
      const entrypoint = 'web_entrypoint.dart';
      const appName = 'org-dartlang-app:/$entrypoint';
      expect(
        generateDDCBootstrapScript(entrypoint: entrypoint),
        contains(appName),
      );
      expect(
        generateDDCMainModuleScript(entrypoint: entrypoint),
        contains(appName),
      );
    });

    test('the loader stages the SDK and the main module, in that order', () {
      final script = generateDDCBootstrapScript(entrypoint: 'main.dart');
      expect(
        script.indexOf('"dart_sdk.js"'),
        lessThan(script.indexOf('"main_module.bootstrap.js"')),
      );
    });

    test('the main module hands off to the on-load-end script', () {
      final script = generateDDCMainModuleScript(entrypoint: 'main.dart');
      expect(script, contains('on_load_end_bootstrap.js'));
      expect(script, contains(r'window.$onLoadEndCallback'));
      // And that script is nothing but the callback it hands off to.
      expect(generateOnLoadEndScript(), r'window.$onLoadEndCallback();');
    });

    test('the prerequisite scripts are the ones the server serves', () {
      final script = generateDDCBootstrapScript(entrypoint: 'main.dart');
      expect(script, contains('"ddc_module_loader.js"'));
      expect(script, contains('"stack_trace_mapper.js"'));
    });

    // Hot reload's browser half: DWDS calls this, it fetches the list the
    // module server publishes, and re-requests every module named in it.
    test(
      'the reload hook fetches the descriptor file the server publishes',
      () {
        final script = generateDDCBootstrapScript(entrypoint: 'main.dart');
        expect(script, contains(r'window.$dartReloadModifiedModules'));
        expect(script, contains("'reloaded_sources.json'"));
      },
    );

    test('native null assertions reach the SDK options', () {
      expect(
        generateDDCMainModuleScript(
          entrypoint: 'main.dart',
          nativeNullAssertions: false,
        ),
        contains('nativeNonNullAsserts: false'),
      );
      expect(
        generateDDCMainModuleScript(
          entrypoint: 'main.dart',
          nativeNullAssertions: true,
        ),
        contains('nativeNonNullAsserts: true'),
      );
    });
  });
}
