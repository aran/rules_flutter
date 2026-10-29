// Draws a green swatch with Impeller and writes it as a PNG to RENDER_OUT,
// the way a build action renders media with `flutter_tester_binary`. The
// path is relative to the working directory the action started it in.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('swatch', (tester) async {
    tester.view.physicalSize = const Size(8, 8);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: const ColoredBox(color: Color(0xFF00FF00)),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final (rgba, png) = (await tester.runAsync(() async {
      final image = await boundary.toImage();
      return (
        await image.toByteData(),
        await image.toByteData(format: ui.ImageByteFormat.png),
      );
    }))!;
    expect(rgba!.getUint8(1), greaterThan(240), reason: 'green');
    File(Platform.environment['RENDER_OUT']!)
        .writeAsBytesSync(png!.buffer.asUint8List());
  });
}
