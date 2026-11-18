/// The runtime a Linux integration test runs its app or browser with: an X
/// server, GTK, Mesa and the libraries headless Chrome links, from the pinned
/// Debian packages of `flutter_linux_runtime`, in place of the host's.
///
/// The host gives only its C and C++ runtime (which the build checks the
/// packages ask no more of than the oldest supported host has) and `/bin/sh`,
/// which the X server runs its keymap compiler through. A test draws on an X
/// server of its own, never the host's display, so it runs the same on a
/// desktop, over SSH and in CI, and two tests never share a screen.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Starts [executable] with [arguments] in exactly [environment]: nothing of
/// the parent's environment is added.
typedef IsolatedProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
);

/// The [IsolatedProcessStarter] of a real process.
Future<Process> startIsolatedProcess(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
) => Process.start(
  executable,
  arguments,
  environment: environment,
  includeParentEnvironment: false,
);

/// Variables of the host's environment that would point a program at the
/// host's display, libraries, modules or settings, which the runtime replaces.
const _hostOnly = {
  'DISPLAY',
  'WAYLAND_DISPLAY',
  'XAUTHORITY',
  'LD_LIBRARY_PATH',
  'LD_PRELOAD',
  'DBUS_SESSION_BUS_ADDRESS',
  'FONTCONFIG_PATH',
  'GDK_PIXBUF_MODULE_FILE',
  'GIO_EXTRA_MODULES',
  'GTK_IM_MODULE_FILE',
  'GTK_MODULES',
  'GTK_PATH',
  'GTK_THEME',
  'XDG_DATA_DIRS',
  'XDG_DATA_HOME',
  'XDG_RUNTIME_DIR',
};

/// The runtime unpacked in the runfiles.
class LinuxRuntime {
  /// A runtime whose `/` is [root], with its libraries in `usr/lib/<triple>`.
  const LinuxRuntime({
    required this.root,
    required this.triple,
    required this.xvfb,
    required this.fontsConf,
  });

  /// The runtime the runner's `linuxRuntime` [config] names, its runfiles
  /// paths turned into files by [resolve]. Throws a [FormatException] naming
  /// the key that is missing.
  factory LinuxRuntime.fromConfig(
    Map<String, Object?> config,
    String Function(String runfilesPath) resolve,
  ) {
    String string(String key) {
      final value = config[key];
      if (value is! String || value.isEmpty) {
        throw FormatException(
          'the config: "launcher.linuxRuntime.$key" must be a non-empty '
          'string, got ${value == null ? 'nothing' : json.encode(value)}',
        );
      }
      return value;
    }

    // A file whose place in the runtime is known, so that the root is found
    // however the runfiles are laid out.
    final xkbcomp = resolve('${string('root')}/usr/bin/xkbcomp');
    return LinuxRuntime(
      root: p.dirname(p.dirname(p.dirname(xkbcomp))),
      triple: string('triple'),
      xvfb: resolve(string('xvfb')),
      fontsConf: resolve(string('fontsConf')),
    );
  }

  /// The runtime's `/`.
  final String root;

  /// The multiarch directory of its libraries: `x86_64-linux-gnu`.
  final String triple;

  /// The X server, patched to run its keymap compiler from `PATH`.
  final String xvfb;

  /// The fontconfig configuration naming the runtime's fonts.
  final String fontsConf;

  String get _lib => p.join(root, 'usr', 'lib', triple);

  String get _share => p.join(root, 'usr', 'share');

  /// The environment a program of the runtime runs in: [host]'s, without what
  /// would point it at the host's display, libraries or modules, with the
  /// runtime's in their place, and [display] when it draws on one.
  ///
  /// [cacheDir] is where fontconfig keeps its cache: the test's own. It also
  /// holds the (empty) data directory of the user the program runs as.
  Map<String, String> environment({
    required Map<String, String> host,
    required String cacheDir,
    int? display,
  }) => {
    for (final MapEntry(:key, :value) in host.entries)
      if (!_hostOnly.contains(key)) key: value,
    'LD_LIBRARY_PATH': _lib,
    // Mesa's software rasteriser, through the GL dispatch libraries.
    'LIBGL_DRIVERS_PATH': p.join(_lib, 'dri'),
    '__EGL_VENDOR_LIBRARY_DIRS': p.join(_share, 'glvnd', 'egl_vendor.d'),
    'DRIRC_CONFIGDIR': p.join(_share, 'drirc.d'),
    'XKB_CONFIG_ROOT': p.join(_share, 'X11', 'xkb'),
    'XLOCALEDIR': p.join(_share, 'X11', 'locale'),
    'FONTCONFIG_FILE': fontsConf,
    'XDG_CACHE_HOME': cacheDir,
    // GLib's modules are the runtime's, and its settings live in memory: the
    // store that would keep them needs a session daemon.
    'GIO_MODULE_DIR': p.join(_lib, 'gio', 'modules'),
    'GSETTINGS_BACKEND': 'memory',
    // Data files are the runtime's. Unset, GLib reads `/usr/share`, and the
    // engine would take its desktop settings from whatever GSettings schemas
    // the host has compiled. The runtime has none, so the engine logs a
    // critical that it has no `org.gnome.desktop.interface` and uses its own
    // defaults, as it does on any system without a desktop.
    'XDG_DATA_DIRS': _share,
    // GLib reads `$XDG_DATA_HOME/glib-2.0/schemas` before `XDG_DATA_DIRS`, and
    // unset it is `$HOME/.local/share`, which the user's own schemas may be in.
    // A directory of the test's, which has none.
    'XDG_DATA_HOME': p.join(cacheDir, 'xdg-data'),
    // No accessibility bus to bridge to. The engine logs an `atk_socket_embed`
    // critical for it, as it does on any system without a session bus.
    'NO_AT_BRIDGE': '1',
    'GDK_BACKEND': 'x11',
    if (display != null) 'DISPLAY': ':$display',
  };

  /// What the X server is started with: a screen in memory, the display
  /// number it picks written to its standard output once it is ready, and the
  /// runtime's keymaps.
  List<String> get xvfbArguments => [
    '-displayfd',
    '1',
    '-screen',
    '0',
    '1920x1080x24',
    '-nolisten',
    'tcp',
    '-xkbdir',
    p.join(_share, 'X11', 'xkb'),
  ];

  /// Starts an X server of the runtime's and returns it once it is ready.
  ///
  /// Throws a [StateError] with what the server said when it ends before it
  /// says it is ready.
  Future<XvfbDisplay> startDisplay({
    required Map<String, String> host,
    required String cacheDir,
    IsolatedProcessStarter start = startIsolatedProcess,
  }) async {
    final serverEnvironment = {
      ...environment(host: host, cacheDir: cacheDir),
      // The keymap compiler, which the X server runs from `PATH`.
      'PATH': p.join(root, 'usr', 'bin'),
    };
    final process = await start(xvfb, xvfbArguments, serverEnvironment);
    final stderrLines = <String>[];
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stderrLines.add)
        .asFuture<void>();
    final announced = Completer<int>();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final number = int.tryParse(line.trim());
          if (number != null && !announced.isCompleted) {
            announced.complete(number);
          }
        })
        .asFuture<void>();
    final ended = process.exitCode.then<int?>((code) async {
      await Future.wait([stderrDone, stdoutDone]);
      return code;
    });
    final first = await Future.any<Object?>([announced.future, ended]);
    if (!announced.isCompleted) {
      throw StateError(
        'The X server of the Linux runtime ($xvfb) exited with code $first '
        'before it was ready. It said:\n${stderrLines.join('\n')}',
      );
    }
    return XvfbDisplay._(first! as int, process);
  }
}

/// An X server a test started, until it is stopped.
class XvfbDisplay {
  XvfbDisplay._(this.number, this._process);

  /// The display's number: `DISPLAY` is `:<number>`.
  final int number;

  final Process _process;

  /// Stops the server: asked to end, and killed if it has not within [bound].
  Future<void> stop({Duration bound = const Duration(seconds: 5)}) async {
    _process.kill();
    final exited = await _process.exitCode
        .then((_) => true)
        .timeout(bound, onTimeout: () => false);
    if (exited) return;
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode;
  }
}
