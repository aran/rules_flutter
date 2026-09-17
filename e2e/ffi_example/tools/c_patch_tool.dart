// The patch builder `//:mul_hot_patch` names: the dev tool's side of
// `flutter_native_library.hot_patch`, for a C library simple enough that a
// patch is a whole second build of one source file.
//
// Bazel has already built that second library by the time this runs (it is in
// the `hot_patch` target's outputs), so there is nothing to compile here. What
// is left is the decision a real patch builder makes (did the code change, and
// can the change be delivered), made with the crudest honest test: the patch
// library's bytes against the ones at launch, and the header against the one at
// launch. A header change is a signature change, which no patch can carry.
//
//   c_patch_tool --library <lib> --contract <header> snapshot --state <dir>
//   c_patch_tool --library <lib> --contract <header> patch --state <dir>
//       --symbol flutter_hot_patch_apply=0x... --out <dir>
//
// `patch` prints one JSON line. The symbol address is accepted and unused: this
// library's patches reach nothing in the running image by address.

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  final commands = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      options[args[i].substring(2)] = args[++i];
    } else {
      commands.add(args[i]);
    }
  }
  final library = options['library']!;
  final contract = options['contract']!;
  final state = Directory(options['state']!);
  final launchedLibrary = File('${state.path}/library');
  final launchedContract = File('${state.path}/contract');

  switch (commands.single) {
    case 'snapshot':
      state.createSync(recursive: true);
      File(library).copySync(launchedLibrary.path);
      File(contract).copySync(launchedContract.path);
      _answer({'status': 'ok'});
    case 'patch':
      if (!_sameBytes(contract, launchedContract.path)) {
        final reason =
            '$contract changed since launch, and a signature change cannot '
            'be patched into a running library.';
        _answer({
          'status': 'restart',
          'reasons': [reason],
        });
        return;
      }
      if (_sameBytes(library, launchedLibrary.path)) {
        _answer({'status': 'unchanged'});
        return;
      }
      final out = Directory(options['out']!)..createSync(recursive: true);
      final name = library.split('/').last;
      final patch = File(library).copySync('${out.path}/$name');
      _answer({
        'status': 'patched',
        'file': patch.path,
        'functions': ['mul_body'],
      });
    default:
      stderr.writeln('unknown command: ${commands.single}');
      exitCode = 64;
  }
}

void _answer(Map<String, Object?> answer) => stdout.writeln(jsonEncode(answer));

bool _sameBytes(String a, String b) {
  final left = File(a).readAsBytesSync();
  final right = File(b).readAsBytesSync();
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
