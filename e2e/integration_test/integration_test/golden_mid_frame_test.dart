import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'swatch.dart';

/// The swatch against its golden while the engine is still drawing the frames
/// before it, as a busy machine leaves it after any `pumpAndSettle`.
///
/// The engine draws frames and encodes pictures on one worker, in the order it
/// is asked. A slow picture handed to it first holds up the two frames pumped
/// after it, so both are still to be drawn, one waiting its turn behind the
/// other, when `matchesGoldenFile` takes its picture.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the swatch matches its golden while frames are drawn', (
    tester,
  ) async {
    await tester.pumpWidget(swatch(const Color(0xFF2196F3)));
    await tester.pumpAndSettle();

    final slow = _slowPicture();
    tester.binding.scheduleForcedFrame();
    await tester.pump();
    tester.binding.scheduleForcedFrame();
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey('swatch')),
      matchesGoldenFile(goldenPath),
    );
    await slow;
  });
}

/// A large picture of hundreds of wide, blurred, overlapping rings, encoded as
/// a PNG: quick to ask for, slow for the engine to draw.
Future<void> _slowPicture() async {
  const side = 4096;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final random = Random(1);
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 40
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30);
  for (var i = 0; i < 300; i++) {
    paint.color = Color(0x40000000 | random.nextInt(0xFFFFFF));
    canvas.drawCircle(
      Offset(random.nextDouble() * side, random.nextDouble() * side),
      100 + random.nextDouble() * 400,
      paint,
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(side, side);
  picture.dispose();
  try {
    await image.toByteData(format: ui.ImageByteFormat.png);
  } finally {
    image.dispose();
  }
}
