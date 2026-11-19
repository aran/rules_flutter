// The bundle carries the package's declared data asset at the key `rootBundle`
// loads it by, and lists it in the asset manifest.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const _key = 'packages/native_assets_synthetic/blob.txt';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  // The app's files; the bundle is the `_flutter_assets` one.
  final path = args.singleWhere((p) => p.endsWith('_flutter_assets'));
  final bundle = runfiles.rlocation(path);

  final blob = File('$bundle/$_key').readAsStringSync().trim();
  if (blob != 'native-assets-synthetic-data-blob-v1') {
    throw StateError('$_key holds "$blob"');
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
  if (!manifest.contains(_key)) {
    throw StateError('AssetManifest does not list $_key');
  }
}
