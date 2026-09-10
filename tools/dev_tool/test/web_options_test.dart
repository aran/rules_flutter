/// [WebOptions] — the one place the web serving flags are read, and the one
/// place a flag that cannot apply is refused.
library;

import 'package:args/args.dart';
import 'package:flutter_bazel_dev_tool/command_failure.dart';
import 'package:flutter_bazel_dev_tool/run_command.dart';
import 'package:flutter_bazel_dev_tool/web_mode.dart';
import 'package:flutter_bazel_dev_tool/web_options.dart';
import 'package:test/test.dart';

/// Parse [args] with the real `run` parser, so a flag this file names and the
/// parser does not is a failure here rather than at runtime.
ArgResults parse(List<String> args) =>
    RunCommand.parser.parse(['--target=//:app', ...args]);

WebOptions? resolveFor(List<String> args, WebMode? mode) =>
    WebOptions.resolve(parse(args), mode);

Matcher throwsDevToolException(Object matcher) => throwsA(
  isA<DevToolException>().having((e) => e.message, 'message', matcher),
);

/// A refusal of a *command*, which is not the same as a run-ending failure:
/// `app.setViewport`'s parameters are the caller's, so getting them wrong is a
/// bad request rather than a reason to end the run. A [DevToolException] here
/// would fall into the control channel's catch-all and come back a 500.
Matcher throwsBadRequest(Object matcher) => throwsA(
  isA<CommandFailure>()
      .having((e) => e.message, 'message', matcher)
      .having((e) => e.kind, 'kind', CommandFailureKind.badRequest),
);

void main() {
  group('a run that is not a web run', () {
    test('refuses each web flag the user typed, by name', () {
      // A flag accepted and ignored is the failure to avoid: every one of
      // these is refused with its own name in the message.
      const cases = {
        '--web-port': ['--web-port=8080'],
        '--web-hostname': ['--web-hostname=any'],
        '--web-tls-cert-path': ['--web-tls-cert-path=/c'],
        '--web-tls-cert-key-path': ['--web-tls-cert-key-path=/k'],
        '--web-header': ['--web-header=X-A=b'],
        // Named canonically even when typed as the negation: that is the
        // option, and `--no-` is how it is set to false.
        '--cross-origin-isolation': ['--no-cross-origin-isolation'],
        '--web-launch-url': ['--web-launch-url=http://localhost:1/'],
        '--web-browser-flag': ['--web-browser-flag=--mute-audio'],
        '--web-run-headless': ['--web-run-headless'],
        '--web-browser-debug-port': ['--web-browser-debug-port=9222'],
        '--web-viewport': ['--web-viewport=393x660'],
        '--web-enable-expression-evaluation': [
          '--no-web-enable-expression-evaluation',
        ],
      };
      cases.forEach((name, args) {
        expect(
          () => resolveFor(args, null),
          throwsDevToolException(
            allOf(contains(name), contains('not on a web device')),
          ),
          reason: args.join(' '),
        );
      });
    });

    test('names every offending flag at once', () {
      expect(
        () => resolveFor(['--web-port=8080', '--web-hostname=any'], null),
        throwsDevToolException(
          allOf(contains('--web-port'), contains('--web-hostname')),
        ),
      );
    });

    test('a flag left at its default is not a request', () {
      // `--cross-origin-isolation` defaults to true, so every native run
      // arrives here with a value for it. Only a flag the user typed counts.
      expect(resolveFor([], null), isNull);
    });
  });

  group('cross-origin isolation', () {
    test('is on for a WASM run and off for the others', () {
      // Upstream's default (`webCrossOriginIsolation ?? webUseWasm`): the
      // skwasm renderer's threading needs SharedArrayBuffer, which only an
      // isolated page has. A DDC or static page does not, and isolation
      // there costs it every cross-origin subresource without a CORP header.
      expect(
        resolveFor([], const WasmWebMode())!.server.crossOriginIsolation,
        isTrue,
      );
      expect(
        resolveFor([], const DdcWebMode())!.server.crossOriginIsolation,
        isFalse,
      );
      expect(
        resolveFor([], const StaticWebMode())!.server.crossOriginIsolation,
        isFalse,
      );
    });

    test('an explicit flag overrides the default in both directions', () {
      expect(
        resolveFor([
          '--no-cross-origin-isolation',
        ], const WasmWebMode())!.server.crossOriginIsolation,
        isFalse,
      );
      expect(
        resolveFor([
          '--cross-origin-isolation',
        ], const DdcWebMode())!.server.crossOriginIsolation,
        isTrue,
      );
    });

    test('the header values are the ones that isolate a page', () {
      // Asserted exactly. `credentialless` rather than `require-corp`,
      // matching upstream: both isolate, but `require-corp` also blocks every
      // cross-origin subresource that carries no CORP header.
      expect(crossOriginIsolationHeaders, {
        'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Embedder-Policy': 'credentialless',
      });
    });

    test('refuses a --web-header that fights it, naming both flags', () {
      // Adding both would put two values for one header on the wire and let
      // the browser decide — the silent conflict this repo forbids. Every
      // combination stays expressible: --no-cross-origin-isolation plus your
      // own headers.
      expect(
        () => resolveFor([
          '--web-header=Cross-Origin-Opener-Policy=unsafe-none',
        ], const WasmWebMode()),
        throwsDevToolException(
          allOf(
            contains('Cross-Origin-Opener-Policy'),
            contains('--cross-origin-isolation'),
          ),
        ),
      );
      // Case-insensitively, because header names are.
      expect(
        () => resolveFor([
          '--web-header=cross-origin-embedder-policy=require-corp',
        ], const WasmWebMode()),
        throwsDevToolException(contains('--cross-origin-isolation')),
      );
    });

    test('the same header is allowed once isolation is off', () {
      final options = resolveFor([
        '--no-cross-origin-isolation',
        '--web-header=Cross-Origin-Opener-Policy=unsafe-none',
      ], const WasmWebMode())!;
      expect(
        options.server.headers['Cross-Origin-Opener-Policy'],
        'unsafe-none',
      );
    });
  });

  group('--web-port', () {
    test('unset is an ephemeral port', () {
      expect(resolveFor([], const DdcWebMode())!.server.port, 0);
    });

    test('a number is the port', () {
      expect(
        resolveFor(['--web-port=8080'], const DdcWebMode())!.server.port,
        8080,
      );
    });

    test('refuses anything that is not a port', () {
      for (final bad in ['http', '-1', '65536', '80.5', '']) {
        expect(
          () => resolveFor(['--web-port=$bad'], const DdcWebMode()),
          throwsDevToolException(
            allOf(contains('--web-port'), contains('0-65535')),
          ),
          reason: bad,
        );
      }
    });
  });

  group('--web-hostname', () {
    test('defaults to the loopback, not to every interface', () {
      // A deliberate divergence from upstream, which defaults to `any`. A dev
      // loop has no reason to publish the app's sources to the LAN unasked.
      final server = resolveFor([], const DdcWebMode())!.server;
      expect(server.hostname, 'localhost');
      expect(server.displayHost, 'localhost');
    });

    test('"any" binds everything but still shows as localhost in URLs', () {
      // `any` is not a name a browser resolves, and a server on every
      // interface is reachable on the loopback.
      final server = resolveFor([
        '--web-hostname=any',
      ], const DdcWebMode())!.server;
      expect(server.hostname, 'any');
      expect(server.displayHost, 'localhost');
    });

    test('any other name is used as given', () {
      final server = resolveFor([
        '--web-hostname=127.0.0.1',
      ], const DdcWebMode())!.server;
      expect(server.displayHost, '127.0.0.1');
      expect(server.baseUri(4321).toString(), 'http://127.0.0.1:4321');
    });
  });

  group('--web-header', () {
    test('parses NAME=VALUE, keeping "=" in the value', () {
      final headers = resolveFor([
        '--web-header=X-A=one',
        '--web-header=X-B=a=b=c',
      ], const DdcWebMode())!.server.headers;
      expect(headers, {'X-A': 'one', 'X-B': 'a=b=c'});
    });

    test('a repeated name collapses to the last value', () {
      // One header cannot have two values here; collapsing at parse time is
      // what keeps the wire from carrying both.
      final headers = resolveFor([
        '--web-header=X-A=first',
        '--web-header=X-A=second',
      ], const DdcWebMode())!.server.headers;
      expect(headers, {'X-A': 'second'});
    });

    test('refuses a value with no name or no "="', () {
      for (final bad in ['novalue', '=novalue']) {
        expect(
          () => resolveFor(['--web-header=$bad'], const DdcWebMode()),
          throwsDevToolException(
            allOf(contains('--web-header'), contains('NAME=VALUE')),
          ),
          reason: bad,
        );
      }
    });

    test('no headers is an empty map, not a null', () {
      expect(resolveFor([], const DdcWebMode())!.server.headers, isEmpty);
    });

    test(
      'refuses the headers that describe the message rather than say it',
      () {
        // dart:io does not put these on the wire as written: it reads them as
        // instructions about the response. `Content-Length` becomes the length
        // it computes (and a non-numeric value throws out of the bind);
        // `Transfer-Encoding: chunked` becomes a framing flag and no header at
        // all. Accepted, they would be a flag that is ignored or one that
        // corrupts every response.
        for (final name in [
          'Content-Length',
          'content-length',
          'Transfer-Encoding',
          'Connection',
        ]) {
          expect(
            () => resolveFor(['--web-header=$name=1'], const DdcWebMode()),
            throwsDevToolException(
              allOf(contains('--web-header'), contains(name)),
            ),
            reason: name,
          );
        }
      },
    );

    test('a header that merely resembles a framing one is allowed', () {
      // Matched on the name, not on a prefix.
      expect(
        resolveFor([
          '--web-header=X-Content-Length=1',
        ], const DdcWebMode())!.server.headers,
        {'X-Content-Length': '1'},
      );
    });
  });

  group('TLS', () {
    test('both paths make a secure server', () {
      final server = resolveFor([
        '--web-tls-cert-path=/certs/c.pem',
        '--web-tls-cert-key-path=/certs/k.pem',
      ], const DdcWebMode())!.server;
      expect(server.isSecure, isTrue);
      expect(server.scheme, 'https');
      expect(server.baseUri(8443).toString(), 'https://localhost:8443');
    });

    test('neither path leaves it plain', () {
      final server = resolveFor([], const DdcWebMode())!.server;
      expect(server.isSecure, isFalse);
      expect(server.scheme, 'http');
      expect(server.baseUri(8080).toString(), 'http://localhost:8080');
    });

    test('one without the other is refused, naming the missing flag', () {
      // A certificate with no key cannot bring a server up at all, and
      // quietly serving HTTP instead would be the same class of failure as
      // ignoring the flag.
      expect(
        () => resolveFor(['--web-tls-cert-path=/c'], const DdcWebMode()),
        throwsDevToolException(
          allOf(
            contains('--web-tls-cert-path'),
            contains('--web-tls-cert-key-path'),
          ),
        ),
      );
      expect(
        () => resolveFor(['--web-tls-cert-key-path=/k'], const DdcWebMode()),
        throwsDevToolException(
          allOf(
            contains('--web-tls-cert-key-path'),
            contains('--web-tls-cert-path'),
          ),
        ),
      );
    });
  });

  group('--web-browser-flag', () {
    test('carries the user\'s switches through in order', () {
      final browser = resolveFor([
        '--web-browser-flag=--no-sandbox',
        '--web-browser-flag=--proxy-server=http://p:1',
      ], const DdcWebMode())!.browser;
      expect(browser.browserFlags, [
        '--no-sandbox',
        '--proxy-server=http://p:1',
      ]);
    });

    test(
      'refuses a switch this tool owns, pointing at the flag that means it',
      () {
        // Chrome resolves a duplicated switch by position, so passing one of
        // these would make the outcome depend on splice order and quietly break
        // an invariant the tool relies on.
        expect(
          () => resolveFor([
            '--web-browser-flag=--user-data-dir=/tmp/p',
          ], const DdcWebMode()),
          throwsDevToolException(
            allOf(
              contains('--user-data-dir'),
              contains('throwaway'),
            ),
          ),
        );
        expect(
          () => resolveFor([
            '--web-browser-flag=--remote-debugging-port=9222',
          ], const DdcWebMode()),
          throwsDevToolException(contains('--web-browser-debug-port')),
        );
        expect(
          () =>
              resolveFor(['--web-browser-flag=--headless'], const DdcWebMode()),
          throwsDevToolException(contains('--web-run-headless')),
        );
      },
    );

    test('a switch that merely starts like an owned one is allowed', () {
      // Matched on the switch name, not on a prefix: `--headless-something`
      // is a different switch and refusing it would be the tool inventing a
      // rule Chrome does not have.
      expect(
        resolveFor([
          '--web-browser-flag=--user-data-dir-suffix=x',
        ], const DdcWebMode())!.browser.browserFlags,
        ['--user-data-dir-suffix=x'],
      );
    });
  });

  /// Laying a web app out at a phone's size is what a responsive-layout check
  /// needs, and a browser window cannot be asked for one:
  /// `--web-browser-flag=--window-size=393,660` is accepted and then clamped
  /// by new-headless Chrome, which also takes simulated browser chrome off the
  /// height. The viewport comes from CDP instead.
  group('--web-viewport', () {
    test('is unset unless asked', () {
      expect(resolveFor([], const DdcWebMode())!.browser.viewport, isNull);
    });

    test('reads a size, and a scale when one is given', () {
      final plain = resolveFor([
        '--web-viewport=393x660',
      ], const DdcWebMode())!.browser.viewport!;
      expect((plain.width, plain.height), (393, 660));
      // No `@scale` means the browser's own ratio, not a made-up 1.
      expect(plain.deviceScaleFactor, isNull);

      final scaled = resolveFor([
        '--web-viewport=393x660@3',
      ], const DdcWebMode())!.browser.viewport!;
      expect((scaled.width, scaled.height), (393, 660));
      expect(scaled.deviceScaleFactor, 3.0);
    });

    test('refuses a size that is not one', () {
      for (final bad in ['393', '393x', 'x660', '0x660', '393x660@0', 'wide']) {
        expect(
          () => resolveFor(['--web-viewport=$bad'], const DdcWebMode()),
          throwsDevToolException(contains('--web-viewport')),
          reason: bad,
        );
      }
    });

    test('refuses --force-device-scale-factor only when it would clash', () {
      // Unconditionally owning the switch would be wrong: without a scale to
      // set, passing it directly is a legitimate thing to do.
      expect(
        resolveFor([
          '--web-browser-flag=--force-device-scale-factor=2',
        ], const DdcWebMode())!.browser.browserFlags,
        ['--force-device-scale-factor=2'],
      );
      expect(
        () => resolveFor([
          '--web-viewport=393x660@3',
          '--web-browser-flag=--force-device-scale-factor=2',
        ], const DdcWebMode()),
        throwsDevToolException(
          allOf(
            contains('--force-device-scale-factor'),
            contains('--web-viewport'),
          ),
        ),
      );
    });
  });

  /// The runtime half of the viewport: `app.setViewport` over the control
  /// channel, so a form-factor sweep is one run rather than one run per size.
  group('app.setViewport params', () {
    test('reads a width and a height', () {
      final v = parseSetViewportCommand({'width': 393, 'height': 660});
      expect((v.width, v.height), (393, 660));
      // Never a scale: the command cannot set one, so it must not look like
      // it defaulted one either.
      expect(v.deviceScaleFactor, isNull);
    });

    test('refuses a scale rather than accepting and ignoring it', () {
      // A ratio cannot be changed on a running browser — it comes from
      // --force-device-scale-factor, fixed when Chrome starts. Silently
      // dropping it would report success for something that did not happen.
      for (final key in ['scale', 'deviceScaleFactor', 'devicePixelRatio']) {
        expect(
          () => parseSetViewportCommand({
            'width': 393,
            'height': 660,
            key: 3,
          }),
          throwsBadRequest(
            allOf(
              contains(key),
              contains('--force-device-scale-factor'),
              // Says what to do instead with the numbers already filled in
              // — the ratio the caller asked for, not the name of the key
              // they passed it under.
              contains('--web-viewport 393x660@3'),
            ),
          ),
          reason: key,
        );
      }
    });

    test('refuses a size that is missing or not a positive whole number', () {
      final bad = <String, Map<String, dynamic>>{
        'no width': {'height': 660},
        'no height': {'width': 393},
        'zero': {'width': 0, 'height': 660},
        'negative': {'width': 393, 'height': -1},
        'a string': {'width': '393', 'height': 660},
        'fractional': {'width': 393.5, 'height': 660},
      };
      bad.forEach((why, params) {
        expect(
          () => parseSetViewportCommand(params),
          throwsBadRequest(contains('app.setViewport needs')),
          reason: why,
        );
      });
    });
  });

  group('--web-run-headless', () {
    test('is off unless asked', () {
      expect(resolveFor([], const DdcWebMode())!.browser.headless, isFalse);
      expect(
        resolveFor([
          '--web-run-headless',
        ], const DdcWebMode())!.browser.headless,
        isTrue,
      );
    });

    test('does not turn the browser sandbox off', () {
      // Upstream bundles `--no-sandbox` into headless. Turning the sandbox off
      // is not what "no window" means, and a run that genuinely needs it says
      // so with --web-browser-flag.
      expect(
        BrowserLaunchOptions.headlessFlags,
        isNot(contains('--no-sandbox')),
      );
      expect(BrowserLaunchOptions.headlessFlags, contains('--headless'));
      // Headless Chrome's default viewport is small enough to change what a
      // Flutter app lays out, so a headless screenshot would not show what
      // the same run shows on screen. Upstream's size.
      expect(
        BrowserLaunchOptions.headlessFlags,
        contains('--window-size=2400,1800'),
      );
    });
  });

  group('--web-browser-debug-port', () {
    test('unset lets the browser pick', () {
      expect(resolveFor([], const DdcWebMode())!.browser.debugPort, isNull);
    });

    test('a number is the port', () {
      expect(
        resolveFor([
          '--web-browser-debug-port=9222',
        ], const DdcWebMode())!.browser.debugPort,
        9222,
      );
    });

    test('refuses anything that is not a port', () {
      expect(
        () => resolveFor(['--web-browser-debug-port=nine'], const DdcWebMode()),
        throwsDevToolException(contains('--web-browser-debug-port')),
      );
    });
  });

  group('--web-launch-url', () {
    final base = Uri.parse('http://localhost:8080');

    test('unset opens the server\'s own URL', () {
      expect(resolveFor([], const DdcWebMode())!.launchUrlFor(base), base);
    });

    test('a URL on the dev server is used as given', () {
      final options = resolveFor([
        '--web-launch-url=http://localhost:8080/#/settings',
      ], const DdcWebMode())!;
      expect(
        options.launchUrlFor(base).toString(),
        'http://localhost:8080/#/settings',
      );
    });

    test('refuses a URL this run does not serve', () {
      // Not a hang waiting to happen — it is one: the page would never load
      // from the dev server, DWDS would never see a connection, and a DDC run
      // treats a browser that has not connected yet as normal.
      for (final url in [
        'http://localhost:9999/', // wrong port
        'http://example.com:8080/', // wrong host
        'https://localhost:8080/', // wrong scheme
      ]) {
        expect(
          () => resolveFor([
            '--web-launch-url=$url',
          ], const DdcWebMode())!.launchUrlFor(base),
          throwsDevToolException(
            allOf(
              contains('--web-launch-url'),
              contains(base.toString()),
            ),
          ),
          reason: url,
        );
      }
    });

    test('a server on every interface accepts any host at its port', () {
      // `--web-hostname any` really does answer on every address this host
      // has, so naming one of them is not pointing somewhere else.
      final options = resolveFor([
        '--web-hostname=any',
        '--web-launch-url=http://192.168.1.5:8080/',
      ], const DdcWebMode())!;
      expect(options.launchUrlFor(base).toString(), 'http://192.168.1.5:8080/');
      // The port still has to be the one it took.
      expect(
        () => resolveFor([
          '--web-hostname=any',
          '--web-launch-url=http://192.168.1.5:9999/',
        ], const DdcWebMode())!.launchUrlFor(base),
        throwsDevToolException(contains('--web-launch-url')),
      );
    });

    test('refuses anything a browser cannot open', () {
      for (final bad in [
        'file:///tmp/index.html',
        'localhost:8080',
        'ftp://x/',
      ]) {
        expect(
          () => resolveFor(['--web-launch-url=$bad'], const DdcWebMode()),
          throwsDevToolException(
            allOf(contains('--web-launch-url'), contains('http')),
          ),
          reason: bad,
        );
      }
    });
  });

  group('--web-enable-expression-evaluation', () {
    test('is on for the DDC dev loop by default', () {
      expect(
        resolveFor([], const DdcWebMode())!.enableExpressionEvaluation,
        isTrue,
      );
      expect(
        resolveFor([
          '--no-web-enable-expression-evaluation',
        ], const DdcWebMode())!.enableExpressionEvaluation,
        isFalse,
      );
    });

    test('is off where there is no compiler, and says nothing about it', () {
      // The default stepping aside is silent — the user did not ask. WASM
      // compiles with dart2wasm and a static run serves a built bundle;
      // neither has a resident compiler or a debugger.
      for (final mode in [const WasmWebMode(), const StaticWebMode()]) {
        expect(
          resolveFor([], mode)!.enableExpressionEvaluation,
          isFalse,
          reason: '$mode',
        );
        expect(
          resolveFor([
            '--no-web-enable-expression-evaluation',
          ], mode)!.enableExpressionEvaluation,
          isFalse,
          reason: 'turning off what was already off is not an error',
        );
      }
    });

    test('an explicit request where it cannot work is refused, by name', () {
      // Accepting it and quietly doing nothing is the failure to avoid.
      for (final mode in [const WasmWebMode(), const StaticWebMode()]) {
        expect(
          () => resolveFor(['--web-enable-expression-evaluation'], mode),
          throwsDevToolException(
            allOf(
              contains('--web-enable-expression-evaluation'),
              contains('DDC'),
            ),
          ),
          reason: '$mode',
        );
      }
    });
  });
}
