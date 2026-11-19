// Each release bundle carries the index `glyphs`' link hook wrote, at the key
// `rootBundle` loads it by, and lists it in the asset manifest; the declared
// glyphs the app uses and not the other; and the app package's own declared
// asset, which no hook handles. A debug bundle (`--debug`) runs no hook: it
// carries every declared glyph and no index. The native app's assets are its
// `_flutter_assets` directory; a web bundle's are its `assets/`, and the
// recorded uses its compiler wrote beside its output are not deployed.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  String resolve(String path) => runfiles.rlocation(path);

  final debug = args.contains('--debug');
  final paths = args.where((a) => a != '--debug').toList();
  final bundles = <String, String>{
    for (final path in paths)
      if (path.endsWith('_flutter_assets'))
        path: resolve(path)
      else if (path.endsWith('_web'))
        path: '${resolve(path)}/assets',
  };
  if (bundles.length != 3) {
    throw StateError(
      'want the native assets and two web bundles, got $bundles',
    );
  }
  for (final MapEntry(key: name, value: assets) in bundles.entries) {
    try {
      _checkAssets(assets, debug: debug);
    } on StateError catch (e) {
      throw StateError('$name: ${e.message}');
    }
  }
  for (final path in paths.where((p) => p.endsWith('_web'))) {
    final root = Directory(resolve(path));
    final recorded = root
        .listSync(recursive: true)
        .where((e) => e.path.endsWith('.resources.json'))
        .toList();
    if (recorded.isNotEmpty) {
      throw StateError('$path deploys recorded uses: $recorded');
    }
  }
}

void _checkAssets(String bundle, {required bool debug}) {
  final index = File('$bundle/packages/glyphs/glyphs/index.json');
  if (debug) {
    if (index.existsSync()) throw StateError('a debug bundle has the index');
  } else {
    final names = jsonDecode(index.readAsStringSync());
    if (names is! List || names.join(',') != 'heart,star') {
      throw StateError('index is $names, want [heart, star]');
    }
  }

  final shipped = debug ? ['heart', 'moon', 'star'] : ['heart', 'star'];
  for (final glyph in shipped) {
    final file = File('$bundle/packages/glyphs/glyphs/$glyph.txt');
    if (file.readAsStringSync().trim() != 'glyph:$glyph') {
      throw StateError('${file.path} does not hold glyph $glyph');
    }
  }
  if (!debug && File('$bundle/packages/glyphs/glyphs/moon.txt').existsSync()) {
    throw StateError('the unused glyph moon shipped');
  }
  final greeting = File('$bundle/packages/package_assets/greeting.txt');
  if (greeting.readAsStringSync().trim() != 'hello from package_assets') {
    throw StateError('${greeting.path} does not hold the greeting');
  }

  // The `.json` is the base64 of the binary manifest; the key is stored as
  // plain text inside it.
  final manifest = utf8.decode(
    base64.decode(
      jsonDecode(File('$bundle/AssetManifest.bin.json').readAsStringSync())
          as String,
    ),
    allowMalformed: true,
  );
  final listed = debug
      ? 'packages/glyphs/glyphs/moon.txt'
      : 'packages/glyphs/glyphs/index.json';
  if (!manifest.contains(listed)) {
    throw StateError('AssetManifest does not list $listed');
  }
}
