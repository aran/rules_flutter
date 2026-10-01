// Draws a shader SkSL cannot compile, in flutter_tester running Impeller:
// passes only when the build compiled the shader for the tester's Vulkan
// stage, as `flutter test --enable-impeller` needs.
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an Impeller-only shader draws', () async {
    final program = await ui.FragmentProgram.fromAsset('shaders/indexed.frag');
    final shader = program.fragmentShader()..setFloat(0, 4);
    for (var i = 1; i <= 4; i++) {
      shader.setFloat(i, 0.25);
    }
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 8, 8),
      Paint()..shader = shader,
    );
    final image = await recorder.endRecording().toImage(8, 8);
    final bytes = (await image.toByteData())!;
    expect(bytes.getUint8(0), lessThan(16), reason: 'red');
    expect(bytes.getUint8(1), greaterThan(240), reason: 'green');
  });
}
