import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/integration/linux_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

// The runtime's paths are joined with the host's separator, so what a test
// expects is joined the same way rather than written out with `/`.
String _under(String base, List<String> parts) => p.joinAll([base, ...parts]);

const _runtime = LinuxRuntime(
  root: '/rf/rt/root',
  triple: 'x86_64-linux-gnu',
  xvfb: '/rf/rt/runtime/Xvfb',
  fontsConf: '/rf/rt/fonts.conf',
);

final _lib = _under('/rf/rt/root', ['usr', 'lib', 'x86_64-linux-gnu']);

const _host = {
  'HOME': '/home/me',
  'TEST_TMPDIR': '/tmp/t',
  'DISPLAY': ':0',
  'WAYLAND_DISPLAY': 'wayland-0',
  'XAUTHORITY': '/home/me/.Xauthority',
  'LD_LIBRARY_PATH': '/opt/host/lib',
  'GTK_PATH': '/usr/lib/gtk-3.0',
  'XDG_DATA_DIRS': '/usr/share',
  'XDG_DATA_HOME': '/home/me/.local/share',
  'XDG_RUNTIME_DIR': '/run/user/1000',
  'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/1000/bus',
};

void main() {
  group('LinuxRuntime.fromConfig', () {
    test('finds the root from a file whose place in it is known', () {
      final runtime = LinuxRuntime.fromConfig(const {
        'root': 'rt/root',
        'triple': 'aarch64-linux-gnu',
        'xvfb': 'rt/runtime/Xvfb',
        'fontsConf': 'rt/fonts.conf',
      }, (path) => '/runfiles/$path');

      expect(runtime.root, '/runfiles/rt/root');
      expect(runtime.triple, 'aarch64-linux-gnu');
      expect(runtime.xvfb, '/runfiles/rt/runtime/Xvfb');
      expect(runtime.fontsConf, '/runfiles/rt/fonts.conf');
    });

    test('names the key a config lacks', () {
      expect(
        () => LinuxRuntime.fromConfig(const {'root': 'rt/root'}, (p) => p),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('"launcher.linuxRuntime.triple"'),
          ),
        ),
      );
    });
  });

  group('the environment a program of the runtime runs in', () {
    final env = _runtime.environment(
      host: _host,
      cacheDir: '/tmp/t/cache',
      display: 7,
    );

    test('is the display of the test, never the host\'s', () {
      expect(env['DISPLAY'], ':7');
      expect(env.containsKey('WAYLAND_DISPLAY'), isFalse);
      expect(env.containsKey('XAUTHORITY'), isFalse);
      expect(env['GDK_BACKEND'], 'x11');
    });

    test('loads the runtime\'s libraries and modules, not the host\'s', () {
      expect(env['LD_LIBRARY_PATH'], _lib);
      expect(env['LIBGL_DRIVERS_PATH'], p.join(_lib, 'dri'));
      expect(env['GIO_MODULE_DIR'], p.join(_lib, 'gio', 'modules'));
      expect(env['FONTCONFIG_FILE'], '/rf/rt/fonts.conf');
      expect(env.containsKey('GTK_PATH'), isFalse);
    });

    test('reads the runtime\'s data files, so no settings schema of the '
        'host\'s', () {
      expect(env['XDG_DATA_DIRS'], _under('/rf/rt/root', ['usr', 'share']));
    });

    test('reads no settings schema from the user\'s data directory either', () {
      // GLib looks in `$XDG_DATA_HOME` before `XDG_DATA_DIRS`.
      expect(env['XDG_DATA_HOME'], p.join('/tmp/t/cache', 'xdg-data'));
      expect(env['XDG_DATA_HOME'], isNot(_host['XDG_DATA_HOME']));
    });

    test('reaches no session bus of the host\'s, by address or by the '
        'runtime directory GLib finds one in', () {
      expect(env.containsKey('DBUS_SESSION_BUS_ADDRESS'), isFalse);
      expect(env.containsKey('XDG_RUNTIME_DIR'), isFalse);
    });

    test('keeps the rest of the host\'s', () {
      expect(env['HOME'], '/home/me');
      expect(env['TEST_TMPDIR'], '/tmp/t');
    });

    test('has no display for a program that draws on none', () {
      expect(
        _runtime
            .environment(host: _host, cacheDir: '/c')
            .containsKey('DISPLAY'),
        isFalse,
      );
    });
  });

  group('startDisplay', () {
    late FakeProcess server;
    late List<(String, List<String>, Map<String, String>)> started;

    Future<XvfbDisplay> start() => _runtime.startDisplay(
      host: _host,
      cacheDir: '/c',
      start: (exe, args, env) async {
        started.add((exe, args, env));
        return server;
      },
    );

    setUp(() {
      server = FakeProcess();
      started = [];
    });

    test('is the display number the server announces once it is ready, on '
        'a server of the runtime\'s that finds its keymaps there', () async {
      final display = start();
      await server.outputAttached;
      server.emitStdout('3');

      expect((await display).number, 3);
      final (exe, args, env) = started.single;
      expect(exe, '/rf/rt/runtime/Xvfb');
      expect(args, containsAllInOrder(['-displayfd', '1']));
      expect(
        args,
        containsAllInOrder([
          '-xkbdir',
          _under('/rf/rt/root', ['usr', 'share', 'X11', 'xkb']),
        ]),
      );
      expect(env['PATH'], _under('/rf/rt/root', ['usr', 'bin']));
      expect(env.containsKey('DISPLAY'), isFalse);
    });

    test('fails with what the server said when it ends before it is '
        'ready', () async {
      final display = start();
      await server.outputAttached;
      server
        ..emitStderr('(EE) Cannot establish any listening sockets\n')
        ..complete(1);

      await expectLater(
        display,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('exited with code 1'),
              contains('Cannot establish any listening sockets'),
            ),
          ),
        ),
      );
    });

    test('stop ends the server, killing one that does not end when '
        'asked', () async {
      final display = start();
      await server.outputAttached;
      server
        ..emitStdout('0')
        ..ignoresSigterm = true;

      await (await display).stop(bound: const Duration(milliseconds: 10));

      expect(server.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
    });
  });
}
