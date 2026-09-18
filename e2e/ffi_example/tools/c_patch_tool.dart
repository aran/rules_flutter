// The patch builder `//:mul_hot_patch` names: the dev tool's side of
// `flutter_native_library.hot_patch`, for a C library simple enough that a
// patch is a whole second build of one source file.
//
// Bazel has already built that second library by the time this runs (it is in
// the `hot_patch` target's outputs), so there is nothing to compile here. What
// is left is the decision a real patch builder makes (did the code change, and
// can the change be delivered), made with the crudest honest test: the patch
// library's bytes against the ones at launch, and the header's *declarations*
// against the ones at launch.
//
// Declarations rather than bytes, because the dev tool asks this tool precisely
// when the declared contract moved — it withholds the reload itself only when
// there is no builder to ask. A contract file moves for reasons that change
// what a caller may call and for reasons that do not (a comment, an include, a
// reordering), and the builder is the half that can tell them apart: it holds
// the launch contract and the new one. A signature change is what no patch here
// can carry, because Dart reaches this library by symbol and a patch is loaded
// beside it; anything else the rebuilt code serves.
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
      final was = _declarations(launchedContract.path);
      final now = _declarations(contract);
      if (!_sameLines(was, now)) {
        final gone = [
          for (final d in was)
            if (!now.contains(d)) d,
        ];
        final added = [
          for (final d in now)
            if (!was.contains(d)) d,
        ];
        final reason =
            'what $contract declares changed since launch '
            '(${[
              if (gone.isNotEmpty) 'gone: ${gone.join('; ')}',
              if (added.isNotEmpty) 'new: ${added.join('; ')}',
            ].join(', ')}). '
            'Dart reaches this library by symbol and a patch is loaded beside '
            'it, so a declaration the running image does not already export '
            'cannot be reached through it.';
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

/// What the header lets a caller call: one entry per exported declaration,
/// whitespace collapsed so a reflow is not a signature change.
///
/// Everything else in the file — comments, includes, the export macro's own
/// definition — is left out, which is the whole point: those move the
/// contract's bytes without moving what Dart may call.
List<String> _declarations(String path) => [
  for (final line in File(path).readAsLinesSync())
    if (line.startsWith('FFI_EXAMPLE_EXPORT ') &&
        line.trimRight().endsWith(';'))
      line.replaceAll(RegExp(r'\s+'), ' ').trim(),
];

bool _sameLines(List<String> a, List<String> b) =>
    a.length == b.length && !a.indexed.any((e) => b[e.$1] != e.$2);

bool _sameBytes(String a, String b) {
  final left = File(a).readAsBytesSync();
  final right = File(b).readAsBytesSync();
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
