// The app's own package's link hook: writes the motto it imports from the
// app's own `lib/` into a data asset.
import 'dart:io';

import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:own_hook/src/motto.dart';

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    final file = input.outputDirectory.resolve('motto.txt');
    File.fromUri(file).writeAsStringSync(motto);
    output.assets.data.add(
      DataAsset(package: input.packageName, name: 'motto.txt', file: file),
    );
  });
}
