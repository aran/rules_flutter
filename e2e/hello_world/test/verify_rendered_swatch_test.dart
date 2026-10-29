// The swatch `:render_swatch` drew in a build action, read as the action's
// output: a PNG of the size it was drawn at.
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  test('the action wrote an 8x8 PNG', () {
    final path = Runfiles.create().rlocation('_main/swatch.png');
    final bytes = ByteData.sublistView(File(path).readAsBytesSync());
    expect(bytes.getUint32(0), 0x89504E47, reason: 'PNG signature');
    // IHDR: width and height, big-endian, after the signature and chunk header.
    expect(bytes.getUint32(16), 8);
    expect(bytes.getUint32(20), 8);
  });
}
