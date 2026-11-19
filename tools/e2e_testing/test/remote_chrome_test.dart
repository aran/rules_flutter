import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/remote_chrome.dart';
import 'package:test/test.dart';

void main() {
  const page = 'http://localhost:8123/';

  test('gives "any" debugging port the free one, keeps the rest', () {
    final launch = RemoteChromeLaunch.parse([
      '--remote-debugging-port=0',
      '--user-data-dir=/tmp/p',
      page,
    ], debugPort: 9555);
    expect(launch.args, ['--remote-debugging-port=9555', page]);
    expect(launch.debugPort, 9555);
    expect(launch.serverPort, 8123);
    expect(launch.profile, '/tmp/p');
  });

  test('keeps a debugging port the run asked for', () {
    final launch = RemoteChromeLaunch.parse([
      '--remote-debugging-port=9333',
      '--user-data-dir=/tmp/p',
      page,
    ], debugPort: 9555);
    expect(launch.debugPort, 9333);
    expect(launch.args.first, '--remote-debugging-port=9333');
  });

  test('refuses a page that is not on the loopback', () {
    expect(
      () => RemoteChromeLaunch.parse([
        '--user-data-dir=/tmp/p',
        'http://example.com:80/',
      ], debugPort: 1),
      throwsArgumentError,
    );
  });

  test(
    'runs the browser with its arguments intact on a fresh profile',
    () async {
      final launch = RemoteChromeLaunch.parse([
        '--user-data-dir=/not/on/the/host',
        "--flag=it's quoted",
        page,
      ], debugPort: 1);
      // echo stands in for Chrome: it prints the command line it was given and
      // exits, which ends the script as Chrome exiting would. stdin stays open,
      // as ssh's does: its end is what quits the browser early.
      final shell = await Process.start('/bin/sh', [
        '-c',
        launch.remoteScript('/bin/echo'),
      ]);
      final out = shell.stdout.transform(utf8.decoder).join();
      final err = shell.stderr.transform(utf8.decoder).join();
      final code = await shell.exitCode;
      await shell.stdin.close();
      final result = (exitCode: code, stdout: await out, stderr: await err);
      expect(result.exitCode, 0, reason: result.stderr);
      final line = result.stdout.trim();
      expect(line, contains("--flag=it's quoted $page"));
      final profile = RegExp('--user-data-dir=(\\S+)').firstMatch(line)![1]!;
      expect(profile, isNot('/not/on/the/host'));
      expect(Directory(profile).existsSync(), isFalse, reason: 'not removed');
    },
    // The script is for the host's shell, which the machine sending it need
    // not have: here it runs in this one's, and Windows has none.
    testOn: '!windows',
  );

  test('fails a run whose Chrome restarted itself, and ends the new one', () async {
    // Stands in for a Chrome that restarts itself: it exits with 0, leaving a
    // process of its own on the profile with `--restart` (the relauncher, then
    // the new browser), which blocks opening a FIFO until it is killed.
    final dir = Directory.systemTemp.createTempSync('remote_chrome_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final chrome = File('${dir.path}/chrome')
      ..writeAsStringSync(r'''
#!/bin/sh
profile=${1#--user-data-dir=}
mkfifo "$profile/hold"
sh -c 'read -r _ < "$0/hold"' "$profile" "$1" --restart </dev/null >/dev/null 2>&1 &
until ps -A -o command= | grep -F -- "$1 --restart" | grep -q -v grep; do :; done
echo "$profile"
exit 0
''');
    Process.runSync('chmod', ['+x', chrome.path]);

    final launch = RemoteChromeLaunch.parse([
      '--user-data-dir=/not/on/the/host',
      page,
    ], debugPort: 1);
    final shell = await Process.start('/bin/sh', [
      '-c',
      launch.remoteScript(chrome.path),
    ]);
    final out = shell.stdout.transform(utf8.decoder).join();
    final err = shell.stderr.transform(utf8.decoder).join();
    final code = await shell.exitCode;
    await shell.stdin.close();

    expect(code, 1);
    expect(await err, contains('Chrome restarted itself'));
    final profile = (await out).trim();
    expect(Directory(profile).existsSync(), isFalse, reason: 'not removed');
    final processes = Process.runSync('ps', ['-A', '-o', 'command=']).stdout;
    expect(
      '$processes'.split('\n').where((line) => line.contains(profile)),
      isEmpty,
      reason: 'the restarted browser was left running',
    );
  });
}
