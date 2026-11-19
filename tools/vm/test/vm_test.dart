import 'package:overhead_vm/create_vm.dart';
import 'package:overhead_vm/e2e.dart';
import 'package:test/test.dart';

import '../../ci_matrix/e2e_matrix.dart';
import '../create_linux_vm.dart';
import '../create_windows_vm.dart';
import '../e2e_items.dart';

void main() {
  group('flutterItems', () {
    E2eOptions parse(List<String> args) =>
        E2eOptions.parse(['vm', ...args], repoOptions: {'rules-dart'});

    test(
      'runs the matrix workspaces of the VM system, with the root on Linux',
      () {
        for (final windows in [false, true]) {
          final items = flutterItems(
            parse([if (windows) '--windows']),
            rulesDart: false,
          );
          final os = windows ? Os.windows : Os.linux;
          expect(items.map((i) => i.folder).toList(), [
            if (!windows) '.',
            for (final e in e2eEntries)
              if (e.runs.containsKey(os)) 'e2e/${e.module}',
          ]);
        }
      },
    );

    test('gives every folder the e2e job timeout and passes exit 4', () {
      final items = flutterItems(parse([]), rulesDart: false);
      expect(items.map((i) => i.timeout).toSet(), {folderTimeout});
      expect(folderTimeout, const Duration(minutes: 120));
      expect(items.map((i) => i.passExitCodes).toSet(), {
        {0, 4},
      });
    });

    test('--folders names the folders, any other one runs //...', () {
      final items = flutterItems(
        parse(['--folders=e2e/not_a_workspace,.']),
        rulesDart: false,
      );
      expect(items.map((i) => i.folder), ['e2e/not_a_workspace', '.']);
      expect(items.first.bazelArgs, ['test', '--test_output=errors', '//...']);
    });

    test('gives a module the flags and targets of its entry', () {
      final items = flutterItems(
        parse(['--windows', '--folders=e2e/plugin_example']),
        rulesDart: false,
      );
      expect(items.single.bazelArgs, [
        'test',
        '--test_output=errors',
        '--build_tests_only',
        '--test_tag_filters=windows_host',
        '//...',
      ]);
    });

    test('--rules-dart overrides rules_dart, and overhead in the root', () {
      final items = flutterItems(
        parse(['--folders=.,e2e/hello_world', '--rules-dart=x']),
        rulesDart: true,
      );
      expect(
        items.first.bazelArgs,
        containsAll([
          '--override_module=rules_dart=/tmp/rules_dart',
          '--override_module=overhead=/tmp/rules_dart/overhead',
          '--lockfile_mode=off',
        ]),
      );
      expect(
        items.last.bazelArgs,
        isNot(contains('--override_module=overhead=/tmp/rules_dart/overhead')),
      );
    });
  });

  group('VMs', () {
    test('the Windows startup carries what the visual checks need', () {
      final script = windowsStartupScript(flutterWindowsVm('3.13.4'));
      expect(script, contains('dartsdk-windows-x64-release.zip'));
      expect(script, contains('3.13.4/sdk'));
      expect(script, contains(r'C:\tools\PsExec64.exe'));
      expect(script, contains('dxcam'));
      expect(script, contains('gen_snapshot.exe'));
      expect(script, isNot(contains('TOOLS_DIR')));
      expect(script, isNot(contains('DART_SDK_URL')));
      expect(flutterWindowsVm('3.13.4').displayDevice, isTrue);
      expect(
        windowsSpecializeScript(flutterWindowsVm('3.13.4')),
        contains('net user testuser'),
      );
    });

    test('the Linux startup installs GTK and the Dart SDK', () {
      final script = linuxStartupScript(flutterLinuxVm('3.13.4'));
      expect(script, contains('libgtk-3-0'));
      expect(script, contains('xvfb'));
      expect(script, contains('3.13.4/sdk/dartsdk-linux-x64-release.zip'));
    });
  });
}
