/// [resolveWebMode] — the one derivation of a web run's shape from its flags.
///
/// Every case goes through the real `run` parser, so a default that changes
/// there (notably `--hot` defaulting to on) changes here too, and the
/// `hotExplicit` distinction is exercised the way `RunPlan.resolve` will
/// exercise it: `wasParsed`, not the value.
import 'package:args/args.dart';
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/run_command.dart' show RunCommand;
import 'package:flutter_bazel_dev_tool/web_mode.dart';
import 'package:test/test.dart';

/// Resolve the mode for one set of `run` flags, exactly as the plan will:
/// raw flag values plus `wasParsed('hot')`, against a web or native device.
WebMode? resolveFor(List<String> args, {bool web = true}) {
  final ArgResults r = RunCommand.parser.parse(['-t', '//:app', ...args]);
  return resolveWebMode(
    isWebDevice: web,
    wasmMode: r['wasm'] as bool,
    profileMode: r['profile'] as bool,
    hotReloadEnabled: r['hot'] as bool,
    hotExplicit: r.wasParsed('hot'),
  );
}

void main() {
  group('a native run', () {
    test('has no web mode, whatever the web flags default to', () {
      expect(resolveFor([], web: false), isNull);
      expect(resolveFor(['--profile'], web: false), isNull);
      expect(resolveFor(['--no-hot'], web: false), isNull);
    });

    // The old gate was `isWebDevice && wasmMode`, so on a native device the
    // flag fell through every branch and did nothing — the user asked for a
    // WASM run and got a native one with no mention of the flag.
    test('refuses --wasm instead of silently ignoring it', () {
      expect(
        () => resolveFor(['--wasm'], web: false),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains('-d chrome'),
          ),
        ),
      );
    });
  });

  group('a web run', () {
    test('defaults to the DDC dev loop', () {
      expect(resolveFor([]), isA<DdcWebMode>());
    });

    test('--profile is a static bundle — AOT-style, no dev loop', () {
      expect(resolveFor(['--profile']), isA<StaticWebMode>());
    });

    test('--no-hot is a static bundle — no reload was asked for', () {
      expect(resolveFor(['--no-hot']), isA<StaticWebMode>());
    });

    // `--hot` defaults to on and `--profile` outranks it, the same ranking
    // compilationModeFor applies to the build. An explicit --hot does not
    // change that: profile has never had a reload pipeline anywhere.
    test('--profile outranks --hot, explicit or defaulted', () {
      expect(resolveFor(['--profile', '--hot']), isA<StaticWebMode>());
    });

    test('--wasm is the WASM loop', () {
      expect(resolveFor(['--wasm']), isA<WasmWebMode>());
    });

    test('--wasm --no-hot is still the WASM loop', () {
      expect(resolveFor(['--wasm', '--no-hot']), isA<WasmWebMode>());
    });

    // The old WASM gate ignored --profile while the DDC gate refused it, so
    // `--wasm --profile` ran both the profile session and the WASM handlers
    // by accident. Deliberate now: rebuild + page reload works identically in
    // any compilation mode, so profile only changes what the rebuild builds.
    test('--wasm --profile is the WASM loop, deliberately', () {
      expect(resolveFor(['--wasm', '--profile']), isA<WasmWebMode>());
    });

    // The default quietly stepping aside for WASM is fine; the user's typed
    // request being reinterpreted as "restart only" is not.
    test('an explicit --hot with --wasm is refused, not reinterpreted', () {
      expect(
        () => resolveFor(['--wasm', '--hot']),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains('no hot reload'),
          ),
        ),
      );
    });
  });
}
