import 'dart:io';

import 'package:test/test.dart';

// Import the library directly.
import '../web_template.dart';

late Directory _tmp;

/// Writes [content] to a scratch file and returns its path.
String _template(String name, String content) {
  final file = File('${_tmp.path}/$name')..parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  return file.path;
}

/// Runs the tool over a single template, returning `(output, errors)`.
(String, List<String>) _runOne(
  String content, {
  Map<String, String> webDefines = const {},
  List<String> keepPlaceholders = const [],
  bool devLoopGuard = false,
  bool managesServiceWorker = true,
  bool checkConstructs = true,
  String? baseHref,
  String? staticAssetsUrl,
  Map<String, dynamic> builtins = const {},
  String label = 'web/index.html',
}) {
  final errors = <String>[];
  final outputs = substituteTemplates({
    'web_defines': webDefines,
    'keep_placeholders': keepPlaceholders,
    'files': [
      {
        'template': _template('in_${content.hashCode}.html', content),
        'output': '${_tmp.path}/out.html',
        'label': label,
        'base_href': baseHref,
        'static_assets_url': staticAssetsUrl,
        'dev_loop_guard': devLoopGuard,
        'manages_service_worker': managesServiceWorker,
        'check_constructs': checkConstructs,
        'builtins': builtins,
      },
    ],
  }, errors);
  return (outputs['${_tmp.path}/out.html'] ?? '', errors);
}

void main() {
  setUp(() => _tmp = Directory.systemTemp.createTempSync('web_template_test'));
  tearDown(() => _tmp.deleteSync(recursive: true));

  group('dollar placeholders', () {
    test('every occurrence of the base href is replaced', () {
      // `flutter create` emits one in <base>, but a template may reference it
      // again; upstream's replaceAll semantics take all of them.
      final (out, errors) = _runOne(
        '<base href="\$FLUTTER_BASE_HREF">\n<p>\$FLUTTER_BASE_HREF</p>',
        baseHref: '/myapp/',
      );
      expect(errors, isEmpty);
      expect(out, '<base href="/myapp/">\n<p>/myapp/</p>');
    });

    test('the static assets url is replaced', () {
      final (out, errors) = _runOne(
        '<link href="\$FLUTTER_STATIC_ASSETS_URL/icons/a.png">',
        staticAssetsUrl: 'https://cdn.example.com',
      );
      expect(errors, isEmpty);
      expect(out, '<link href="https://cdn.example.com/icons/a.png">');
    });
  });

  group('web defines', () {
    test('a declared variable is substituted', () {
      final (out, errors) = _runOne(
        '<meta name="api" content="{{API_URL}}">',
        webDefines: {'API_URL': 'https://api.example.com'},
      );
      expect(errors, isEmpty);
      expect(out, '<meta name="api" content="https://api.example.com">');
    });

    test('an undeclared variable is an error naming file and line', () {
      final (out, errors) = _runOne('<html>\n<body>\n{{API_URL}}\n</body>');
      expect(errors, hasLength(1));
      expect(errors.single, contains('web/index.html:3'));
      expect(errors.single, contains('{{API_URL}}'));
      // The message must carry both ways out, or it only says "no".
      expect(errors.single, contains('web_defines'));
      expect(errors.single, contains('keep_placeholders'));
      // The placeholder survives into the returned text; the caller refuses to
      // write anything at all when errors are present.
      expect(out, contains('{{API_URL}}'));
    });

    test('a define no template references is an error', () {
      final (_, errors) = _runOne(
        '<html></html>',
        webDefines: {'UNUSED': 'x'},
      );
      expect(errors, hasLength(1));
      expect(errors.single, contains('UNUSED'));
      expect(errors.single, contains('no template references'));
    });

    test('a define shadowing a built-in name is an error', () {
      final (_, errors) = _runOne(
        '{{flutter_js}}',
        webDefines: {'flutter_js': 'nope'},
      );
      expect(errors.any((e) => e.contains('name the build supplies')), isTrue);
    });

    test('a name in both web_defines and keep_placeholders is an error', () {
      final (_, errors) = _runOne(
        '{{BOTH}}',
        webDefines: {'BOTH': 'x'},
        keepPlaceholders: ['BOTH'],
      );
      expect(
        errors.any((e) => e.contains('cannot be')),
        isTrue,
        reason: 'asking to substitute and preserve the same name is incoherent',
      );
    });
  });

  group('what must not be touched', () {
    test('a spaced moustache is left alone and unreported', () {
      // Vue, Angular and Mustache write `{{ item }}`; upstream's pattern does
      // not match it, and neither must ours, or error-by-default would break
      // every page using a client-side template language.
      const html = '<div>{{ item.name }}</div>\n<div>{{#each xs}}</div>';
      final (out, errors) = _runOne(html);
      expect(errors, isEmpty);
      expect(out, html);
    });

    test('keep_placeholders ships the placeholder as written', () {
      final (out, errors) = _runOne(
        '<div>{{vueThing}}</div>',
        keepPlaceholders: ['vueThing'],
      );
      expect(errors, isEmpty);
      expect(out, '<div>{{vueThing}}</div>');
    });

    test('an unused keep_placeholders entry is not an error', () {
      // Unlike an unused define, an unused passthrough cannot change the
      // output, so erroring would only make a shared list brittle.
      final (_, errors) = _runOne(
        '<html></html>',
        keepPlaceholders: ['neverSeen'],
      );
      expect(errors, isEmpty);
    });
  });

  group('built-ins', () {
    test('a literal value and a file are both substituted', () {
      final jsPath = _template('flutter.js', 'console.log("loader");');
      final (out, errors) = _runOne(
        '{{flutter_js}}\n{{flutter_service_worker_version}}',
        builtins: {
          'flutter_js': {'file': jsPath},
          'flutter_service_worker_version': {'value': '"rules_flutter_7"'},
        },
      );
      expect(errors, isEmpty);
      expect(out, 'console.log("loader");\n"rules_flutter_7"');
    });

    test('the worker version is expressible as null when pwa is off', () {
      // An upstream-shaped bootstrap references the built-in unconditionally;
      // with no worker the value is the literal `null`, not a missing name.
      final (out, errors) = _runOne(
        'serviceWorkerVersion: {{flutter_service_worker_version}}',
        builtins: {
          'flutter_service_worker_version': {'value': 'null'},
        },
      );
      expect(errors, isEmpty);
      expect(out, 'serviceWorkerVersion: null');
    });

    test('a later file inlines an earlier file\'s substituted result', () {
      final errors = <String>[];
      final bootstrap = _template(
        'boot.js',
        '{{flutter_build_config}}\nboot();',
      );
      final index = _template(
        'index.html',
        '<script>{{flutter_bootstrap_js}}</script>',
      );
      final outputs = substituteTemplates({
        'files': [
          {
            'template': bootstrap,
            'output': '${_tmp.path}/boot.out.js',
            'label': 'flutter_bootstrap.js',
            'check_constructs': true,
            'builtins': {
              'flutter_build_config': {'value': '_flutter.buildConfig = {};'},
            },
          },
          {
            'template': index,
            'output': '${_tmp.path}/index.out.html',
            'label': 'index.html',
            'check_constructs': true,
            'builtins': {
              'flutter_bootstrap_js': {'from_output': 0},
            },
          },
        ],
      }, errors);

      expect(errors, isEmpty);
      expect(
        outputs['${_tmp.path}/boot.out.js'],
        '_flutter.buildConfig = {};\nboot();',
      );
      expect(
        outputs['${_tmp.path}/index.out.html'],
        '<script>_flutter.buildConfig = {};\nboot();</script>',
        reason:
            'index.html must inline the bootstrap after it was substituted, '
            'not the raw template',
      );
    });

    test('one bootstrap template serves the bundle and the dev loop', () {
      // A debug build substitutes the same `bootstrap_js` template twice: once
      // for the bundle and once for the DDC dev loop, whose build config names
      // a different compiler. Before this the dev loop generated a bootstrap of
      // its own, so a user template — and any `web_defines` in it — reached
      // `bazel build` and silently nothing at all under `-d chrome`.
      final errors = <String>[];
      final template = _template(
        'boot.js',
        '_flutter.loader.loadEntrypoint();\n'
            '{{flutter_build_config}}\n'
            'window.api = "{{API_URL}}";',
      );
      final outputs = substituteTemplates({
        'web_defines': {'API_URL': 'https://api.example.com'},
        'files': [
          {
            'template': template,
            'output': '${_tmp.path}/boot.out.js',
            'label': 'flutter_bootstrap.js',
            'check_constructs': true,
            'builtins': {
              'flutter_build_config': {'value': 'BUNDLE_CONFIG'},
            },
          },
          {
            'template': template,
            'output': '${_tmp.path}/dev.out.js',
            'label': 'flutter_bootstrap.js (dev loop)',
            'check_constructs': false,
            'builtins': {
              'flutter_build_config': {'value': 'DEV_CONFIG'},
            },
          },
        ],
      }, errors);

      // The define reaches both outputs.
      const define = 'window.api = "https://api.example.com";';
      expect(outputs['${_tmp.path}/boot.out.js'], contains(define));
      expect(outputs['${_tmp.path}/dev.out.js'], contains(define));

      // Each gets its own build config, so the dev loop boots DDC's output
      // rather than the bundle's.
      expect(outputs['${_tmp.path}/boot.out.js'], contains('BUNDLE_CONFIG'));
      expect(outputs['${_tmp.path}/dev.out.js'], contains('DEV_CONFIG'));
      expect(
        outputs['${_tmp.path}/dev.out.js'],
        isNot(contains('BUNDLE_CONFIG')),
      );

      // And the deprecated construct in those shared bytes is one mistake, so
      // it is reported once — reading the same template twice must not double
      // every diagnostic it carries.
      expect(errors, hasLength(1));
      expect(errors.single, contains('flutter_bootstrap.js:1:'));
      expect(errors.single, contains('loadEntrypoint'));
    });

    test('a built-in this file is not given is an error that says so', () {
      // The generic "supply it with web_defines" advice would be a dead end:
      // a define named after a built-in is refused as shadowing.
      final (_, errors) = _runOne('{{flutter_bootstrap_js}}');
      expect(errors, hasLength(1));
      expect(errors.single, contains('supplied by the build'));
      expect(errors.single, isNot(contains('web_defines')));
    });
  });

  group('legacy service worker constructs', () {
    test('the deprecated version constant is refused', () {
      final (_, errors) = _runOne('  const serviceWorkerVersion = null;');
      expect(errors, hasLength(1));
      expect(errors.single, contains('flutter_service_worker_version'));
    });

    test('the var spelling is refused too', () {
      final (_, errors) = _runOne('var serviceWorkerVersion = null;');
      expect(errors, hasLength(1));
    });

    test(
      'a hand-rolled registration is refused when the build ships a worker',
      () {
        final (_, errors) = _runOne(
          "navigator.serviceWorker.register('flutter_service_worker.js')",
        );
        expect(errors, hasLength(1));
        expect(errors.single, contains('flutter.js register'));
      },
    );

    test('but is allowed when the build ships none', () {
      // `pwa = False` hands service worker duty to the app. Refusing the
      // registration there would refuse the very thing the attr grants — and
      // the remedy would tell the user to set a flag they already set.
      final (out, errors) = _runOne(
        "navigator.serviceWorker.register('flutter_service_worker.js')",
        managesServiceWorker: false,
      );
      expect(errors, isEmpty);
      expect(
        out,
        "navigator.serviceWorker.register('flutter_service_worker.js')",
      );
    });

    test(
      'the deprecated version constant is allowed with no managed worker too',
      () {
        final (_, errors) = _runOne(
          'const serviceWorkerVersion = null;',
          managesServiceWorker: false,
        );
        expect(errors, isEmpty);
      },
    );

    test(
      'loadEntrypoint stays refused either way — it is not about workers',
      () {
        final (_, errors) = _runOne(
          '_flutter.loader.loadEntrypoint({});',
          managesServiceWorker: false,
        );
        expect(errors, hasLength(1));
      },
    );

    test('loadEntrypoint is refused because it skips the wasm build', () {
      final (_, errors) = _runOne('_flutter.loader.loadEntrypoint({});');
      expect(errors, hasLength(1));
      expect(errors.single, contains('loader.load()'));
    });
  });

  group('dev loop guard', () {
    test('inlining the boot path into index.html is refused', () {
      for (final name in [
        'flutter_js',
        'flutter_bootstrap_js',
        'flutter_build_config',
      ]) {
        final (_, errors) = _runOne(
          '<script>{{$name}}</script>',
          devLoopGuard: true,
          builtins: {
            name: {'value': 'x'},
          },
        );
        expect(
          errors,
          hasLength(1),
          reason: '$name must be refused under the guard',
        );
        expect(errors.single, contains('hot reload'));
      }
    });

    test('the guard says nothing about a script-src index', () {
      final (out, errors) = _runOne(
        '<script src="flutter_bootstrap.js" async></script>',
        devLoopGuard: true,
      );
      expect(errors, isEmpty);
      expect(out, '<script src="flutter_bootstrap.js" async></script>');
    });

    test('the same template is accepted with the guard off', () {
      final (out, errors) = _runOne(
        '<script>{{flutter_bootstrap_js}}</script>',
        builtins: {
          'flutter_bootstrap_js': {'value': 'boot();'},
        },
      );
      expect(errors, isEmpty);
      expect(out, '<script>boot();</script>');
    });
  });

  test(
    'stock flutter create output passes untouched but for the base href',
    () {
      // The rule that matters most: `flutter create` output must build as-is.
      const created = '''
<!DOCTYPE html>
<html>
<head>
  <base href="\$FLUTTER_BASE_HREF">
  <title>example</title>
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
''';
      final (out, errors) = _runOne(created, baseHref: '/', devLoopGuard: true);
      expect(errors, isEmpty);
      expect(out, created.replaceAll(r'$FLUTTER_BASE_HREF', '/'));
    },
  );
}
