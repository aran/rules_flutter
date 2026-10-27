// The patch builder `//:mul_hot_patch`, `//:sub_hot_patch` and
// `//:counter_hot_patch` name: the dev tool's side of
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
// State is the other thing a patch cannot carry by itself. A patch is a second
// image, and any storage it defines is its own: it starts fresh, and the image
// the app launched never sees it. So a body keeps no state; the launched image
// holds it and passes it in (see `native/hot_patch_router.h`), and this tool
// refuses the two edits that would break that: a body that defines storage of
// its own (`--body`), and a change to the layout of the state the launched
// image holds (`--state-layout`), which that image laid out in its old shape.
//
//   c_patch_tool --library <lib> --contract <header> --function <name>
//       --body <source> [--state-layout <header>] snapshot --state <dir>
//   c_patch_tool --library <lib> --contract <header> --function <name>
//       --body <source> [--state-layout <header>]
//       patch --state <dir> --symbol flutter_hot_patch_apply=0x... --out <dir>
//
// `--function` is the one function a patch replaces, which the reply names.
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
  final function = options['function']!;
  final state = Directory(options['state']!);
  final launchedLibrary = File('${state.path}/library');
  final launchedContract = File('${state.path}/contract');
  final body = options['body']!;
  final stateLayout = options['state-layout'];
  final launchedStateLayout = File('${state.path}/state_layout');

  switch (commands.single) {
    case 'snapshot':
      state.createSync(recursive: true);
      File(library).copySync(launchedLibrary.path);
      File(contract).copySync(launchedContract.path);
      if (stateLayout != null) {
        File(stateLayout).copySync(launchedStateLayout.path);
      }
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
        final moved = [
          if (gone.isNotEmpty) 'gone: ${gone.join('; ')}',
          if (added.isNotEmpty) 'new: ${added.join('; ')}',
        ];
        final reason =
            'what $contract declares changed since launch '
            '(${moved.join(', ')}). '
            'Dart reaches this library by symbol and a patch is loaded beside '
            'it, so a declaration the running image does not already export '
            'cannot be reached through it.';
        _answer({
          'status': 'restart',
          'reasons': [reason],
        });
        return;
      }
      final reshaped =
          '$stateLayout, the layout of the state the running library holds, '
          'changed since launch. That state was laid out at launch in its old '
          'shape, and a patch would read it through the new one.';
      if (stateLayout != null &&
          !_sameLines(_code(launchedStateLayout.path), _code(stateLayout))) {
        _answer({
          'status': 'restart',
          'reasons': [reshaped],
        });
        return;
      }
      final owned = _ownState(body);
      if (owned.isNotEmpty) {
        final forked =
            '$body defines state of its own '
            '(${owned.map((d) => '`$d`').join(', ')}). A patch is loaded as '
            'a second image, so that state would start fresh there and the '
            'code the app launched would never see it. Keep state in what the '
            'running library holds and passes to $function'
            '${stateLayout == null ? '' : ' ($stateLayout)'}.';
        _answer({
          'status': 'restart',
          'reasons': [forked],
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
        'functions': [function],
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

/// [path]'s lines with line comments, blank lines and runs of whitespace
/// dropped: what a compiler reads, near enough for a short C file.
List<String> _code(String path) => [
  for (final line in File(path).readAsLinesSync())
    if (line.split('//').first.replaceAll(RegExp(r'\s+'), ' ').trim()
        case final code when code.isNotEmpty)
      code,
];

/// The definitions in the C source at [path] that give it storage of its own:
/// a `static` that is not `const`, at any depth, and any other definition at
/// file scope that is not a function, a type or an `extern` declaration.
///
/// Line by line and by brace depth, as crude as the rest of this tool, and
/// enough for a fixture whose bodies are a few lines long.
List<String> _ownState(String path) {
  final found = <String>[];
  var depth = 0;
  for (final line in _code(path)) {
    final atFileScope = depth == 0;
    depth += '{'.allMatches(line).length - '}'.allMatches(line).length;
    if (line.startsWith('#') || !line.endsWith(';')) continue;
    final isStatic = line.startsWith('static ');
    if (line.startsWith('static const ') || line.startsWith('const ')) {
      continue;
    }
    // A prototype, unless it is a function pointer with an initializer.
    if (line.contains('(') && !line.contains('=')) continue;
    if (isStatic ||
        (atFileScope &&
            !line.startsWith('extern ') &&
            !line.startsWith('typedef ') &&
            !RegExp(r'^(struct|union|enum) \w+ ?;$').hasMatch(line))) {
      found.add(line);
    }
  }
  return found;
}

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
