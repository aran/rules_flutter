/// Draws with a shader SkSL cannot compile, to show that it still builds and
/// loads under Impeller. Prints `impeller_shader_results paint=PASS` when the
/// centre pixel is the green the weights sum to.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

void main() => runApp(const MaterialApp(home: _Page()));

class _Page extends StatefulWidget {
  const _Page();

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  final _key = GlobalKey();
  ui.FragmentProgram? _program;
  String _result = 'pending';

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    try {
      final binding = WidgetsBinding.instance;
      while (binding.platformDispatcher.implicitView!.physicalSize.isEmpty) {
        await binding.endOfFrame;
      }
      final program = await ui.FragmentProgram.fromAsset(
        'packages/impeller_shader/shaders/indexed.frag',
      );
      setState(() => _program = program);
      await binding.endOfFrame;
      final boundary =
          _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = (await image.toByteData())!;
      final i = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      final green = bytes.getUint8(i + 1);
      final red = bytes.getUint8(i);
      image.dispose();
      setState(
        () => _result = green > 240 && red < 16
            ? 'PASS'
            : 'FAIL(r=$red g=$green)',
      );
    } on Object catch (e) {
      setState(() => _result = 'FAIL(${e.runtimeType}: $e)');
    }
    debugPrint('impeller_shader_results paint=$_result');
  }

  @override
  Widget build(BuildContext context) {
    final program = _program;
    return Scaffold(
      body: Column(
        children: [
          Text(
            'paint=$_result',
            key: const ValueKey('impeller_shader_result'),
          ),
          RepaintBoundary(
            key: _key,
            child: SizedBox.square(
              dimension: 120,
              child: program == null
                  ? null
                  : CustomPaint(painter: _Painter(program)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Painter extends CustomPainter {
  _Painter(this.program);

  final ui.FragmentProgram program;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader()..setFloat(0, 4);
    for (var i = 1; i <= 4; i++) {
      shader.setFloat(i, 0.25);
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_Painter old) => old.program != program;
}
