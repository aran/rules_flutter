/// What a web run's dev server is, decided once, at plan time.
///
/// The flags governing web serving have to reach sites that are nowhere near
/// the argument parser: the DDC module server, the static bundle server, DWDS.
/// Threaded as separate parameters they would arrive at some of those sites
/// and not others, which is exactly the shape this repo keeps hitting — a flag
/// honoured on one path and silently dropped on another.
///
/// So they travel as one value instead. Upstream converged on the same shape
/// (`WebDevServerConfig`: host, port, https, headers), for the same reason.
///
/// Every refusal lives in [WebOptions.resolve], for the same reason
/// [resolveWebMode] is the one place `--wasm` and `--hot` are read: a flag that
/// cannot mean anything for this run is an error stated once, by name, before
/// a build is spent on it.
library;

import 'package:args/args.dart';

import 'command_failure.dart';
import 'dev_tool_exception.dart';
import 'web_mode.dart';

/// The hostname that binds every interface rather than one address.
///
/// Upstream's spelling, and its default. Ours is [defaultHostname] instead —
/// see there for why.
///
/// Both families: the URL a run on this hostname publishes says `localhost`
/// (see [WebServerOptions.displayHost]), and that name is 127.0.0.1 and ::1.
/// A wildcard on one family is reachable by only half its own URL, which is
/// the same interception the loopback default was fixed for.
const anyHostname = 'any';

/// Where the dev server binds unless told otherwise.
///
/// Upstream defaults to [anyHostname], which puts the dev server — and the
/// app's sources, which it serves — on every network the host is attached to.
/// A dev loop has no reason to be reachable off the machine by default, so
/// this one binds the loopback and `--web-hostname any` is how you ask for the
/// other thing. A deliberate divergence, not an oversight.
const defaultHostname = 'localhost';

/// The headers that cross-origin-isolate the pages this tool serves.
///
/// `SharedArrayBuffer` — which the skwasm renderer's multi-threading depends
/// on — is only available to cross-origin-isolated pages, and isolation is
/// judged per response.
///
/// `credentialless` rather than `require-corp`, matching upstream
/// (`web_constants.dart`). Both isolate the page; `require-corp` additionally
/// blocks every cross-origin subresource that does not carry CORP or CORS
/// headers, so a page that loads an image or a font from a CDN breaks under it
/// and loads under `credentialless`.
const crossOriginIsolationHeaders = {
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'credentialless',
};

/// Everything that decides what the dev server *is*.
///
/// Both web servers — the DDC module server and the static bundle server —
/// are built from one of these, so no flag can apply to a DDC run and quietly
/// not to a WASM one.
class WebServerOptions {
  /// The address to bind. [anyHostname] means every address of every
  /// interface, over both IPv4 and IPv6.
  final String hostname;

  /// The port to bind. `0` picks an ephemeral one; anything else is a promise,
  /// and a bind that cannot keep it fails naming the port.
  final int port;

  /// The certificate chain served over TLS, or null for plain HTTP. Always set
  /// together with [tlsCertKeyPath] — [WebOptions.resolve] refuses one without
  /// the other.
  final String? tlsCertPath;

  /// The private key for [tlsCertPath].
  final String? tlsCertKeyPath;

  /// Extra headers added to every response. Handler-set headers win, so these
  /// cannot retype an asset out from under the browser.
  final Map<String, String> headers;

  /// Whether [crossOriginIsolationHeaders] go on every response.
  ///
  /// No default here on purpose: it depends on the run's [WebMode], and a
  /// second answer living in this class is how the two come to disagree.
  /// [WebOptions.resolve] is the one place it is decided.
  final bool crossOriginIsolation;

  const WebServerOptions({
    required this.crossOriginIsolation,
    this.hostname = defaultHostname,
    this.port = 0,
    this.tlsCertPath,
    this.tlsCertKeyPath,
    this.headers = const {},
  });

  /// Whether this server speaks HTTPS.
  bool get isSecure => tlsCertPath != null;

  /// The URL scheme that follows from [isSecure].
  String get scheme => isSecure ? 'https' : 'http';

  /// The host to put in a URL. [anyHostname] is not a name a browser can
  /// resolve, and a server bound to every interface is reachable on the
  /// loopback, so URLs for it say `localhost` — as upstream's do.
  String get displayHost =>
      hostname == anyHostname ? defaultHostname : hostname;

  /// This server's base URL once [boundPort] is known.
  ///
  /// Deliberately path-less: this URL is concatenated with a leading-slash
  /// path in the module server's `reloaded_sources.json` entries, and a
  /// trailing slash here would make every one of them a double slash.
  Uri baseUri(int boundPort) =>
      Uri(scheme: scheme, host: displayHost, port: boundPort);
}

/// The size a web app should lay out at, whatever size the browser window is.
///
/// A browser window cannot be asked for a phone-sized viewport:
/// `--window-size=393,660` is accepted and then clamped by new-headless Chrome
/// to about 500 CSS px wide, with roughly 87 px of simulated window chrome
/// taken off the height. CDP's `Emulation.setDeviceMetricsOverride` sets the
/// viewport directly and is what this becomes.
class WebViewport {
  /// CSS pixels across, as the page sees them.
  final int width;

  /// CSS pixels down.
  final int height;

  /// The device pixel ratio to emulate, or null to keep the browser's own.
  ///
  /// Null rather than 1: on a Retina display the browser's ratio is 2, and
  /// defaulting to 1 would silently change the capture resolution of a run
  /// that only asked for a viewport size.
  final double? deviceScaleFactor;

  const WebViewport({
    required this.width,
    required this.height,
    this.deviceScaleFactor,
  });

  @override
  String toString() =>
      '${width}x$height${deviceScaleFactor == null ? '' : '@$deviceScaleFactor'}';
}

/// Everything that decides what the launched browser is.
class BrowserLaunchOptions {
  /// The URL handed to the browser, or null to open the dev server's own base
  /// URL. Resolved by [WebOptions.launchUrlFor], which is the one place the
  /// default lives — the server's URL does not exist until it has bound, and
  /// with the default `--web-port` its port is not even chosen.
  final Uri? launchUrl;

  /// Extra switches appended to the browser's command line, after the ones
  /// this tool sets and immediately before the URL — the position upstream
  /// gives them, so a switch Chrome resolves by position behaves the same way.
  final List<String> browserFlags;

  /// Whether the browser runs with no visible window.
  final bool headless;

  /// The CDP port to demand, or null to let the browser pick one. Either way
  /// the launch waits for the browser to announce the port it took.
  final int? debugPort;

  /// The viewport to lay the app out at, or null for the window's own size.
  final WebViewport? viewport;

  const BrowserLaunchOptions({
    this.launchUrl,
    this.browserFlags = const [],
    this.headless = false,
    this.debugPort,
    this.viewport,
  });

  /// The switches a [viewport] carrying a scale adds to the command line.
  ///
  /// The viewport's width and height are applied over CDP once the page is
  /// there, but its scale cannot be: an `Emulation.setDeviceMetricsOverride`
  /// carrying `deviceScaleFactor: 3` drops back to a `window.devicePixelRatio`
  /// of 1 as soon as the CDP client detaches, and `Page.captureScreenshot`
  /// returns a 1x PNG. Under `--force-device-scale-factor=3` the same override
  /// holds. So a scale has to be on the command line, and only a scale does.
  List<String> get scaleFlags {
    final scale = viewport?.deviceScaleFactor;
    return scale == null ? const [] : ['--force-device-scale-factor=$scale'];
  }

  /// The switches a headless launch adds.
  ///
  /// Deliberately NOT `--no-sandbox`, which upstream bundles in here
  /// (`chrome.dart`). Turning the sandbox off is a real reduction in what
  /// contains the browser, and it is not what "run without a window" means;
  /// where it is genuinely needed — an unprivileged container with no user
  /// namespaces — `--web-browser-flag=--no-sandbox` says so out loud, and the
  /// run that needs it is the run that carries it.
  ///
  /// The window size is upstream's: headless Chrome's default viewport is
  /// small enough to change what a Flutter app lays out, so a screenshot taken
  /// headless would not show what the same run shows on screen.
  static const headlessFlags = ['--headless', '--window-size=2400,1800'];
}

/// Everything the web flags resolve to, plus the refusals.
class WebOptions {
  final WebServerOptions server;
  final BrowserLaunchOptions browser;

  /// Whether the debugger can compile and evaluate Dart expressions against
  /// the running app.
  ///
  /// Belongs to neither the server nor the browser: it wires the run's
  /// resident compiler into DWDS, which is the only thing that can compile a
  /// fragment against the program actually running.
  final bool enableExpressionEvaluation;

  const WebOptions({
    required this.server,
    required this.browser,
    required this.enableExpressionEvaluation,
  });

  /// Every flag name this class reads, so a non-web run can refuse them all by
  /// name rather than ignoring them.
  static const flagNames = [
    'web-port',
    'web-hostname',
    'web-tls-cert-path',
    'web-tls-cert-key-path',
    'web-header',
    'cross-origin-isolation',
    'web-launch-url',
    'web-browser-flag',
    'web-run-headless',
    'web-browser-debug-port',
    'web-enable-expression-evaluation',
    'web-viewport',
  ];

  /// Browser switches this tool sets itself, and what to do instead.
  ///
  /// A user switch that duplicates one of these does not override it: Chrome
  /// resolves duplicates by position, so which copy wins depends on where the
  /// user's flags happened to be spliced, and an invariant this tool relies on
  /// — a throwaway profile, a CDP port it knows, a headless mode it can report
  /// — quietly stops holding. Refused by name instead.
  static const ownedBrowserSwitches = {
    '--user-data-dir':
        'This tool creates and deletes a throwaway browser '
        'profile for each run, and a profile left behind belongs to a browser '
        'a later run can still find.',
    '--remote-debugging-port':
        'Use --web-browser-debug-port, which this tool '
        'then knows to expect on the browser\'s own announcement.',
    '--headless': 'Use --web-run-headless.',
  };

  /// The URL to open, given the dev server's [serverBase], and the check that
  /// it addresses this run's server at all.
  ///
  /// A launch URL pointing somewhere else is not a hang waiting to happen —
  /// it is one: the page would never load from the module server, DWDS would
  /// never see a connection, and a DDC run treats a browser that has not
  /// connected *yet* as normal, so nothing would ever time out. There is no
  /// proxy support here for the case upstream added the flag for, so the
  /// honest answer is to say so.
  ///
  /// A server bound to [anyHostname] answers on every address the host has, so
  /// any host name is accepted for it; the scheme and port still have to be
  /// the ones it took.
  ///
  /// That leaves one hole, deliberately: with `--web-hostname any` a host that
  /// is not this machine at all — a typo — passes, and produces exactly the
  /// hang this check exists to prevent. Closing it means resolving the host
  /// against this machine's own interfaces, which would refuse legitimate
  /// names that resolve through a VPN or a hosts file. `any` is the value that
  /// says "I know where this server is reachable"; the loopback default, which
  /// is what a run gets without asking, is checked exactly.
  Uri launchUrlFor(Uri serverBase) {
    final url = browser.launchUrl;
    if (url == null) return serverBase;
    final hostMatters = server.hostname != anyHostname;
    if (url.scheme != serverBase.scheme ||
        url.port != serverBase.port ||
        (hostMatters && url.host != serverBase.host)) {
      throw DevToolException(
        '--web-launch-url $url does not address this run\'s dev server, '
        'which is serving at $serverBase. The browser would open a page '
        'this run does not serve: nothing would load, and on the DDC dev '
        'loop nothing would ever report that.\n'
        'Point it at $serverBase (a path or fragment on it is fine), or set '
        '--web-hostname and --web-port to the address you meant.',
      );
    }
    return url;
  }

  /// Refuse every web flag the user typed on a run that is not a web run.
  ///
  /// `wasParsed` is what makes this possible without also refusing the
  /// defaults: a flag the user never typed is not a request.
  static void refuseOnNonWebRun(ArgResults results, Iterable<String> names) {
    final passed = names
        .where(results.options.contains)
        .where(results.wasParsed);
    if (passed.isEmpty) return;
    throw DevToolException(
      '${passed.map((f) => '--$f').join(', ')} only applies to a browser: it '
      'configures the web dev server or the browser this run would launch, '
      'and this run is not on a web device.\n'
      'Drop it, or run with -d chrome.',
    );
  }

  /// Resolve the web flags for a run whose shape is [mode], or null when the
  /// run does not target a browser.
  static WebOptions? resolve(ArgResults results, WebMode? mode) {
    if (mode == null) {
      refuseOnNonWebRun(results, flagNames);
      return null;
    }

    // Cross-origin isolation is on for the WASM dev loop and off otherwise,
    // matching upstream (`webCrossOriginIsolation ?? webUseWasm`). The skwasm
    // renderer's threading needs SharedArrayBuffer, which only an isolated
    // page has; a DDC or plain-JS page does not, and isolation there only
    // costs it every cross-origin subresource that carries no CORP header.
    // The flag declares no default, so `null` *is* "not asked for" — no
    // `wasParsed` needed, and `--help` cannot print a default the code does
    // not use.
    final crossOriginIsolation =
        (results['cross-origin-isolation'] as bool?) ?? mode is WasmWebMode;

    final headers = parseWebHeaders(results['web-header'] as List<String>);
    if (crossOriginIsolation) {
      final clashing = headers.keys.where(
        (k) => crossOriginIsolationHeaders.keys.any(
          (h) => h.toLowerCase() == k.toLowerCase(),
        ),
      );
      if (clashing.isNotEmpty) {
        throw DevToolException(
          '--web-header sets ${clashing.join(' and ')}, which '
          '--cross-origin-isolation also sets. Two values for one header is '
          'not a state this server can be in.\n'
          'Pass --no-cross-origin-isolation to own those headers yourself, '
          'or drop them from --web-header.',
        );
      }
    }

    final certPath = results['web-tls-cert-path'] as String?;
    final certKeyPath = results['web-tls-cert-key-path'] as String?;
    if ((certPath == null) != (certKeyPath == null)) {
      final given = certPath == null
          ? '--web-tls-cert-key-path'
          : '--web-tls-cert-path';
      final missing = certPath == null
          ? '--web-tls-cert-path'
          : '--web-tls-cert-key-path';
      throw DevToolException(
        '$given needs $missing: TLS takes a certificate and the key that '
        'authenticates it, and a server cannot be brought up with one of '
        'them.\n'
        'Pass both to serve over HTTPS, or neither to serve over HTTP.',
      );
    }

    final browserFlags = results['web-browser-flag'] as List<String>;
    for (final flag in browserFlags) {
      final instead = ownedBrowserSwitches[flag.split('=').first];
      if (instead == null) continue;
      throw DevToolException(
        '--web-browser-flag cannot pass ${flag.split('=').first}: this tool '
        'sets it itself, and a browser given it twice resolves the two by '
        'position rather than by intent.\n$instead',
      );
    }

    final viewport = parseWebViewport(results['web-viewport'] as String?);
    // Owned only when there is a scale to set. Chrome resolves a duplicated
    // switch by position, so both copies present would make the page's pixel
    // ratio depend on splice order; without --web-viewport@scale, though,
    // nothing here sets the switch and passing it directly is legitimate.
    if (viewport?.deviceScaleFactor != null) {
      final clashing = browserFlags.where(
        (f) => f.split('=').first == '--force-device-scale-factor',
      );
      if (clashing.isNotEmpty) {
        throw DevToolException(
          '--web-browser-flag cannot pass --force-device-scale-factor '
          'alongside --web-viewport $viewport, which sets it from the '
          'viewport\'s own scale. A browser given the switch twice resolves '
          'the two by position rather than by intent.\n'
          'Drop the --web-browser-flag, or drop the @scale from '
          '--web-viewport and set the ratio yourself.',
        );
      }
    }

    // Only the DDC dev loop has a resident compiler and a debugger to
    // evaluate with. `wasParsed` separates a request from the default: asking
    // for it where it cannot work is an error, the default stepping aside is
    // not.
    final expressionEvaluation =
        results['web-enable-expression-evaluation'] as bool;
    if (results.wasParsed('web-enable-expression-evaluation') &&
        expressionEvaluation &&
        mode is! DdcWebMode) {
      throw DevToolException(
        '--web-enable-expression-evaluation cannot be honored for this run: '
        'evaluating an expression means compiling it against the program '
        'that is running, and only the DDC dev loop has a resident compiler '
        'and a debugger to do that with. '
        '${mode is WasmWebMode ? '--wasm builds with dart2wasm, which has '
                  'neither.' : 'This run serves a built bundle statically, with '
                  'no VM service.'}\n'
        'Drop the flag, or run the DDC dev loop (no --wasm, no --profile, '
        'no --no-hot).',
      );
    }

    return WebOptions(
      enableExpressionEvaluation: expressionEvaluation && mode is DdcWebMode,
      server: WebServerOptions(
        hostname: results['web-hostname'] as String? ?? defaultHostname,
        port: parseWebPort(results['web-port'] as String?),
        tlsCertPath: certPath,
        tlsCertKeyPath: certKeyPath,
        headers: headers,
        crossOriginIsolation: crossOriginIsolation,
      ),
      browser: BrowserLaunchOptions(
        launchUrl: parseWebLaunchUrl(results['web-launch-url'] as String?),
        browserFlags: browserFlags,
        headless: results['web-run-headless'] as bool,
        debugPort: parsePortFlag(
          results['web-browser-debug-port'] as String?,
          '--web-browser-debug-port',
        ),
        viewport: viewport,
      ),
    );
  }
}

/// `--web-launch-url` as a URL, or null when unset.
///
/// Only `http` and `https`: the flag names the page a browser opens, so it has
/// to be one a browser can fetch. Upstream validates the same two schemes.
/// Whether it addresses *this run's* server is a separate question, answered
/// by [WebOptions.launchUrlFor] once the server has bound.
Uri? parseWebLaunchUrl(String? raw) {
  if (raw == null) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw DevToolException(
      '--web-launch-url "$raw" is not an http or https URL. It names the '
      'page the browser opens, so it has to be one a browser can fetch — as '
      'in --web-launch-url http://localhost:8080/#/settings.',
    );
  }
  return uri;
}

/// Headers that describe how a response is framed rather than what it says.
///
/// `dart:io` does not send these as written — it reads them as instructions
/// about the message itself. `Content-Length` becomes the body length it
/// computes (and a non-numeric value throws out of the bind);
/// `Transfer-Encoding: chunked` becomes a framing flag and no header at all;
/// `Connection` moves the socket's keep-alive state. Setting any of them
/// through `--web-header` would be a flag accepted and not honoured — or
/// honoured by corrupting every response — so they are refused by name.
const _framingHeaders = {
  'content-length': 'the server computes it from the body it sends',
  'transfer-encoding': 'the server chooses how it frames a response',
  'connection': 'the server owns whether a connection is kept alive',
};

/// `--web-header KEY=VALUE` entries as a map.
///
/// Split on the first `=` only, so a value may contain them. A repeated key is
/// the last one — a header cannot usefully have two values here, and
/// collapsing at parse time is what keeps the wire from carrying both.
Map<String, String> parseWebHeaders(List<String> raw) {
  final headers = <String, String>{};
  for (final entry in raw) {
    final split = entry.indexOf('=');
    if (split <= 0) {
      throw DevToolException(
        '--web-header "$entry" is not a NAME=VALUE pair. A header needs a '
        'name before the "=" and a value after it, as in '
        '--web-header X-Custom-Header=value.',
      );
    }
    final name = entry.substring(0, split);
    final why = _framingHeaders[name.toLowerCase()];
    if (why != null) {
      throw DevToolException(
        '--web-header cannot set $name: it is not a header the server puts '
        'on the wire as written — $why.\n'
        'Setting it here would either be ignored or would break every '
        'response.',
      );
    }
    headers[name] = entry.substring(split + 1);
  }
  return headers;
}

/// `--web-port` as a port number. Unset is `0` — an ephemeral port.
int parseWebPort(String? raw) => parsePortFlag(raw, '--web-port') ?? 0;

/// A port-valued flag, or null when unset.
int? parsePortFlag(String? raw, String flag) {
  if (raw == null) return null;
  final port = int.tryParse(raw);
  if (port == null || port < 0 || port > 65535) {
    throw DevToolException(
      '$flag "$raw" is not a port number. Ports are 0-65535, and 0 asks for '
      'any free one.',
    );
  }
  return port;
}

/// `--web-viewport` as a [WebViewport], or null when unset.
///
/// The spelling is `WxH` with an optional `@scale` — `393x660`, `393x660@3` —
/// which reads as the thing it describes and matches how device sizes are
/// written everywhere else.
///
/// Every part is refused rather than defaulted. A zero or negative dimension
/// is not a viewport a page can lay out in, and a scale of zero divides the
/// capture to nothing; taking a nearby number instead would lay the app out at
/// a size nobody asked for and report it as the one they did.
WebViewport? parseWebViewport(String? raw) {
  if (raw == null) return null;
  final match = RegExp(
    r'^(\d+)x(\d+)(?:@(\d+(?:\.\d+)?))?$',
  ).firstMatch(raw.trim());
  final width = match == null ? null : int.parse(match.group(1)!);
  final height = match == null ? null : int.parse(match.group(2)!);
  final scaleText = match?.group(3);
  final scale = scaleText == null ? null : double.parse(scaleText);
  if (width == null ||
      height == null ||
      width <= 0 ||
      height <= 0 ||
      (scale != null && scale <= 0)) {
    throw DevToolException(
      '--web-viewport "$raw" is not a viewport size. Write it as WIDTHxHEIGHT '
      'in CSS pixels, with an optional device pixel ratio after an @ — as in '
      '--web-viewport 393x660 or --web-viewport 393x660@3. Every part has to '
      'be greater than zero.',
    );
  }
  return WebViewport(width: width, height: height, deviceScaleFactor: scale);
}

/// The viewport an `app.setViewport` command asks for.
///
/// Deliberately narrower than [parseWebViewport]: no scale. A device pixel
/// ratio cannot be changed on a running browser — an
/// `Emulation.setDeviceMetricsOverride` carrying `deviceScaleFactor: 3` leaves
/// `window.devicePixelRatio` at 1 the moment the CDP client detaches, and
/// capture resolution follows Chrome's `--force-device-scale-factor` switch,
/// which is fixed for the life of the browser process. So a scale passed here
/// could only be accepted and ignored, and is refused by name instead: the run
/// that needs a different ratio is a new run with `--web-viewport WxH@scale`.
WebViewport parseSetViewportCommand(Map<String, dynamic> params) {
  for (final rejected in ['scale', 'deviceScaleFactor', 'devicePixelRatio']) {
    if (!params.containsKey(rejected)) continue;
    // A command's parameters being wrong is a refusal, not a run-ending
    // failure: a DevToolException would escape to the transport's catch-all and
    // tell the caller its own typo was a 500.
    throw CommandFailure.badRequest(
      'app.setViewport cannot change $rejected on a running browser. The '
      'device pixel ratio comes from Chrome\'s --force-device-scale-factor '
      'switch, which is fixed when the browser starts, and an override that '
      'sets it is undone as soon as this tool disconnects.\n'
      'Relaunch with --web-viewport ${params['width'] ?? 'WIDTH'}x'
      '${params['height'] ?? 'HEIGHT'}@${params[rejected]} to change it, or '
      'drop $rejected to change only the size.',
    );
  }
  int require(String name) {
    final value = params[name];
    if (value is int && value > 0) return value;
    throw CommandFailure.badRequest(
      'app.setViewport needs $name as a whole number of CSS pixels greater '
      'than zero; it got ${value == null ? 'nothing' : '"$value"'}.\n'
      'Call it as {"method":"app.setViewport","params":{"appId":"...",'
      '"width":393,"height":660}}.',
    );
  }

  return WebViewport(width: require('width'), height: require('height'));
}
