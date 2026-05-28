/// Runs the rules_flutter e2e suites on a remote VM over SSH.
///
/// Usage:
///   dart run tools/vm/run_e2e.dart <vm-name> [--windows] \
///       [--folders=.,e2e/hello_world] [--keep-going]
///
/// Transfers the committed working tree (`git archive HEAD`) to the VM, clones
/// the `rules_dart` sibling it depends on, extracts, then runs `bazel test
/// //...` in each folder, mirroring `.github/workflows/ci.yaml`. Exit code 4
/// ("no test targets") counts as a pass. Prints a per-folder PASS/FAIL summary
/// and exits non-zero if any folder failed.
///
/// On Windows a short `--output_user_root` is used so deeply nested runfiles
/// (e.g. the hermetic Python interpreter's `_socket.pyd`) stay under the
/// 260-char MAX_PATH limit — the same fix the Windows CI job applies.
library;

import 'dart:async';
import 'dart:io';

import 'gcloud.dart';

/// The default folder matrix, mirroring the `e2e` job in
/// `.github/workflows/ci.yaml`. `.` is the root module (Starlark unit tests).
/// Override with `--folders=` to scope a run (e.g. just the Linux or Windows
/// subset).
const _ciFolders = [
  '.',
  'e2e/smoke',
  'e2e/hello_world',
  'e2e/ffi_example',
  'e2e/plugin_example',
  'e2e/ffi_plugin_example',
  'e2e/codegen',
];

/// Per-folder timeout. The first folder pays for the hermetic Flutter SDK +
/// engine download; later folders re-fetch (separate output bases).
const _folderTimeout = Duration(minutes: 30);

/// Short Windows output root — keeps generated paths under MAX_PATH (260).
const _winOutputRoot = 'C:/b';

class _FolderResult {
  _FolderResult(this.folder, this.exitCode, this.pass, this.tail);
  final String folder;
  final int exitCode;
  final bool pass;
  final String tail;
}

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: dart run tools/vm/run_e2e.dart <vm-name> [--windows] '
      '[--folders=a,b,c] [--keep-going]',
    );
    exit(2);
  }
  final vmName = positional.first;
  final isWindows = args.contains('--windows');
  final keepGoing = args.contains('--keep-going');
  final foldersArg = args
      .firstWhere((a) => a.startsWith('--folders='), orElse: () => '')
      .replaceFirst('--folders=', '');
  final folders = foldersArg.isEmpty
      ? _ciFolders
      : foldersArg.split(',').map((s) => s.trim()).toList();

  final repoRoot = _repoRoot();
  _warnIfDirty(repoRoot);

  // 1. Package the committed tree.
  final tgz = '${Directory.systemTemp.path}/rules_flutter_src.tgz';
  print('Packaging committed HEAD -> $tgz');
  _run('git', [
    '-C',
    repoRoot,
    'archive',
    '--format=tar.gz',
    '--prefix=rules_flutter/',
    '-o',
    tgz,
    'HEAD',
  ]);

  // 2. Wait for the toolchain, then transfer + extract + clone rules_dart.
  await _waitForToolchain(vmName, isWindows: isWindows);
  print('Transferring source tree to $vmName ...');
  if (isWindows) {
    await scpToVm(vmName, tgz, 'C:/rf_src.tgz', compress: true);
    // Separate, simple commands. A compound `cmd /c "... & ... & ..."` mangles
    // through gcloud ssh -> Windows cmd and can silently no-op.
    await sshExec(vmName, 'rmdir /s /q C:\\rf'); // tolerate "not found"
    await sshRun(vmName, 'mkdir C:\\rf');
    await sshRun(vmName, 'tar -xf C:\\rf_src.tgz -C C:\\rf');
    await sshExec(vmName, 'rmdir /s /q C:\\rules_dart');
    await sshRun(
      vmName,
      'git clone --depth 1 https://github.com/aran/rules_dart.git '
      'C:\\rules_dart',
    );
  } else {
    await scpToVm(vmName, tgz, '~/rules_flutter_src.tgz', compress: true);
    await sshRun(
      vmName,
      "bash -lc 'rm -rf ~/rf && mkdir -p ~/rf && "
      "tar xzf ~/rules_flutter_src.tgz -C ~/rf'",
    );
    await sshRun(
      vmName,
      "bash -lc 'rm -rf ~/rules_dart && "
      "git clone --depth 1 https://github.com/aran/rules_dart.git "
      "~/rules_dart'",
    );
  }

  // 3. Run each folder.
  final results = <_FolderResult>[];
  for (final folder in folders) {
    stdout.writeln('\n=== $folder ===');
    final result = await _runFolder(vmName, folder, isWindows: isWindows);
    results.add(result);
    stdout.writeln(
      '${result.pass ? "PASS" : "FAIL"} $folder (exit ${result.exitCode})',
    );
    if (!result.pass && !keepGoing) {
      stdout.writeln('Stopping (use --keep-going to run the rest).');
      break;
    }
  }

  // 4. Summary.
  stdout.writeln(
    '\n========== SUMMARY (${isWindows ? "windows" : "linux"}) ==========',
  );
  for (final r in results) {
    stdout.writeln('  ${r.pass ? "PASS" : "FAIL"}  ${r.folder}');
  }
  final failed = results.where((r) => !r.pass).toList();
  if (failed.isEmpty) {
    stdout.writeln('\nAll ${results.length} folders passed.');
    exit(0);
  }
  stdout.writeln('\n${failed.length} folder(s) FAILED:');
  for (final r in failed) {
    stdout.writeln('\n----- ${r.folder} (exit ${r.exitCode}) -----');
    stdout.writeln(r.tail);
  }
  exit(1);
}

/// Runs `bazel test //...` in [folder] and maps the exit code: 0 (success) and
/// 4 (no test targets) pass; anything else fails.
Future<_FolderResult> _runFolder(
  String vmName,
  String folder, {
  required bool isWindows,
}) async {
  final String command;
  if (isWindows) {
    final winFolder = folder == '.'
        ? 'C:\\rf\\rules_flutter'
        : 'C:\\rf\\rules_flutter\\${folder.replaceAll('/', '\\')}';
    // /v:on enables delayed expansion so !errorlevel! is bazel's real exit, not
    // the parse-time value. --output_user_root keeps paths under MAX_PATH.
    command =
        'cmd /v:on /c "cd /d $winFolder && '
        'bazel --output_user_root=$_winOutputRoot '
        'test --test_output=errors //... & '
        'echo RF_EXIT=!errorlevel!"';
  } else {
    final dir = folder == '.'
        ? '\$HOME/rf/rules_flutter'
        : '\$HOME/rf/rules_flutter/$folder';
    command =
        "bash -lc 'cd $dir && "
        "bazel test --test_output=errors //...; echo RF_EXIT=\$?'";
  }

  final ProcessResult result;
  try {
    result = await sshExec(vmName, command).timeout(_folderTimeout);
  } on TimeoutException {
    return _FolderResult(folder, -2, false, 'TIMEOUT after $_folderTimeout');
  }

  final combined = '${result.stdout}\n${result.stderr}';
  final exitCode = _parseRfExit(result.stdout.toString());
  final pass = exitCode == 0 || exitCode == 4;
  return _FolderResult(folder, exitCode, pass, _tail(combined));
}

/// Waits until the VM's toolchain (bazel + C compiler) is installed.
Future<void> _waitForToolchain(String vmName, {required bool isWindows}) async {
  print('Verifying toolchain on $vmName ...');
  // Generous: a fresh Windows VM may need ~15 min before SSH, then ~15 min to
  // finish installing MSVC + bazelisk via the startup script.
  final deadline = DateTime.now().add(const Duration(minutes: 40));
  while (DateTime.now().isBefore(deadline)) {
    final ProcessResult r;
    if (isWindows) {
      r = await sshExec(
        vmName,
        'cmd /c "type C:\\startup_complete.txt && where bazel"',
      );
      if (r.exitCode == 0 &&
          r.stdout.toString().contains('STARTUP_COMPLETE')) {
        return;
      }
    } else {
      r = await sshExec(
        vmName,
        'bash -lc "command -v bazel && command -v cc"',
      );
      if (r.exitCode == 0) return;
    }
    stdout.writeln('  toolchain not ready yet; waiting ...');
    await Future<void>.delayed(const Duration(seconds: 20));
  }
  throw Exception('Timed out waiting for toolchain on $vmName');
}

int _parseRfExit(String stdout) {
  final m = RegExp(r'RF_EXIT=(-?\d+)').firstMatch(stdout);
  return m == null ? -1 : int.parse(m.group(1)!);
}

String _tail(String s, {int lines = 60}) {
  final all = s.split('\n');
  return all.length <= lines ? s : all.sublist(all.length - lines).join('\n');
}

String _repoRoot() {
  final r = Process.runSync('git', ['rev-parse', '--show-toplevel']);
  if (r.exitCode != 0) {
    throw Exception('Not in a git repo: ${r.stderr}');
  }
  return r.stdout.toString().trim();
}

void _warnIfDirty(String repoRoot) {
  final r = Process.runSync('git', [
    '-C',
    repoRoot,
    'status',
    '--porcelain',
    '--untracked-files=no',
  ]);
  if (r.stdout.toString().trim().isNotEmpty) {
    stderr.writeln(
      'WARNING: tracked working-tree changes are NOT included — '
      'run_e2e tests committed HEAD only. Commit first to test them.',
    );
  }
}

void _run(String exe, List<String> args) {
  final r = Process.runSync(exe, args);
  if (r.exitCode != 0) {
    throw Exception('$exe ${args.join(' ')} failed:\n${r.stderr}');
  }
}
