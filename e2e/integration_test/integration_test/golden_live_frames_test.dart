import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'swatch.dart';

/// The swatch against its golden while the app draws frames of its own accord,
/// as it does under `LiveTestWidgetsFlutterBindingFramePolicy.fullyLive`:
/// frames that no `pump` asked for start while `matchesGoldenFile` takes its
/// picture. Behind the swatch is a background that is slow for the engine to
/// draw, so a frame is always being drawn and the next one waiting.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the swatch matches its golden while frames are drawn live', (
    tester,
  ) async {
    await tester.pumpWidget(
      Stack(
        textDirection: TextDirection.ltr,
        children: [
          const Positioned.fill(child: CustomPaint(painter: _SlowPainter())),
          swatch(const Color(0xFF2196F3)),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Each live frame asks for the next, once one is asked for.
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    var frames = 0;
    binding.addPersistentFrameCallback((_) => frames++);
    try {
      // Two frames no `pump` asked for, so frames are being drawn live.
      await binding.endOfFrame;
      await binding.endOfFrame;
      expect(frames, greaterThanOrEqualTo(2));

      await expectLater(
        find.byKey(const ValueKey('swatch')),
        matchesGoldenFile(goldenPath),
      );
    } finally {
      binding.framePolicy =
          LiveTestWidgetsFlutterBindingFramePolicy.fadePointers;
    }
  });
}

/// Hundreds of wide, blurred, overlapping rings: quick to record, slow for
/// the engine to draw, which it does again every frame.
class _SlowPainter extends CustomPainter {
  const _SlowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(1);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 40
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30);
    for (var i = 0; i < 300; i++) {
      paint.color = Color(0x40000000 | random.nextInt(0xFFFFFF));
      canvas.drawCircle(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
        50 + random.nextDouble() * 200,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SlowPainter oldDelegate) => false;
}
