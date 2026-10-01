/// Draws with a package's fragment shaders, both as a `Paint.shader` and as
/// a `BackdropFilter`, and calls the package's native plugin. It reads its own
/// pixels back and shows one line, `GLASS paint=... filter=... plugin=...`,
/// so a screenshot or a text read says whether each path worked.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:glass_plugin/glass_plugin.dart';

void main() => runApp(const GlassApp());

/// Magenta, the colour the tint shader is given to paint.
const _tint = Color(0xFFFF00FF);

/// Red, which the invert filter should turn cyan.
const _backdrop = Color(0xFFFF0000);

class GlassApp extends StatelessWidget {
  const GlassApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(body: SafeArea(child: _GlassPage())),
  );
}

class _GlassPage extends StatefulWidget {
  const _GlassPage();

  @override
  State<_GlassPage> createState() => _GlassPageState();
}

class _GlassPageState extends State<_GlassPage> {
  final _paintKey = GlobalKey();
  final _filterKey = GlobalKey();
  GlassShaders? _shaders;
  ui.ImageFilter? _filter;
  String _paint = 'pending';
  String _filterResult = 'pending';
  String _plugin = 'pending';

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _check();
    } on Object catch (e) {
      setState(() => _paint = 'FAIL(${e.runtimeType}: $e)');
      debugPrint('glass_results $_summary');
      rethrow;
    }
  }

  Future<void> _check() async {
    // Frames run while the window has no size yet (an Android surface
    // starts at 0x0) and paint nothing, so wait that out first.
    final binding = WidgetsBinding.instance;
    while (binding.platformDispatcher.implicitView!.physicalSize.isEmpty) {
      await binding.endOfFrame;
    }
    final shaders = await GlassShaders.load();
    final filter = _makeFilter(shaders);
    setState(() {
      _shaders = shaders;
      _filter = filter;
    });
    await binding.endOfFrame;
    final paint = await _centre(_paintKey);
    final filtered = filter == null ? null : await _centre(_filterKey);
    final plugin = await _askPlugin();
    setState(() {
      _paint = _verdict(paint, _tint);
      if (filter != null) {
        _filterResult = _verdict(filtered, const Color(0xFF00FFFF));
      }
      _plugin = plugin;
    });
    // The same verdict as a log line, for runs that cannot read the widget
    // tree (a web build compiled to wasm has no VM service).
    debugPrint('glass_results $_summary');
  }

  String get _summary =>
      'paint=$_paint filter=$_filterResult plugin=$_plugin'
      // A wasm build renders with skwasm, a JS build with CanvasKit.
      '${kIsWeb ? ' renderer=${kIsWasm ? 'skwasm' : 'canvaskit'}' : ''}';

  // A hot reload reassembles; report what the paint shader draws now, so a
  // run can see an edited shader arrive without a restart.
  @override
  void reassemble() {
    super.reassemble();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final color = await _centre(_paintKey);
      final hex = color?.toARGB32().toRadixString(16).padLeft(8, '0');
      debugPrint('glass_paint_color 0x$hex');
    });
  }

  /// The invert filter, or null where shader filters are unsupported; then
  /// `_filterResult` says so, and whether constructing one threw.
  ui.ImageFilter? _makeFilter(GlassShaders shaders) {
    if (ui.ImageFilter.isShaderFilterSupported) {
      return ui.ImageFilter.shader(shaders.invert.fragmentShader());
    }
    try {
      ui.ImageFilter.shader(shaders.invert.fragmentShader());
      _filterResult = 'unsupported-but-constructed';
    } on Object catch (e) {
      _filterResult = 'unsupported(${e.runtimeType})';
    }
    return null;
  }

  Future<String> _askPlugin() async {
    if (kIsWeb) return 'none-on-web';
    try {
      final reply = await reduceTransparency();
      return '${reply['platform']}:${reply['reduceTransparency']}';
    } on Object catch (e) {
      return 'FAIL(${e.runtimeType})';
    }
  }

  static RenderRepaintBoundary _boundary(GlobalKey key) =>
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;

  /// The colour at the centre of the boundary under [key].
  Future<Color?> _centre(GlobalKey key) async {
    final image = await _boundary(key).toImage();
    final bytes = await image.toByteData();
    final x = image.width ~/ 2;
    final y = image.height ~/ 2;
    final width = image.width;
    image.dispose();
    if (bytes == null) return null;
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      bytes.getUint8(i + 3),
      bytes.getUint8(i),
      bytes.getUint8(i + 1),
      bytes.getUint8(i + 2),
    );
  }

  static String _verdict(Color? got, Color want) {
    if (got == null) return 'FAIL(no-pixels)';
    int channel(double c) => (c * 255).round();
    final close =
        (channel(got.r) - channel(want.r)).abs() <= 8 &&
        (channel(got.g) - channel(want.g)).abs() <= 8 &&
        (channel(got.b) - channel(want.b)).abs() <= 8;
    final hex = got.toARGB32().toRadixString(16).padLeft(8, '0');
    return close ? 'PASS' : 'FAIL(0x$hex)';
  }

  @override
  Widget build(BuildContext context) {
    final shaders = _shaders;
    final filter = _filter;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('GLASS $_summary', key: const ValueKey('glass_result')),
          const SizedBox(height: 16),
          Row(
            children: [
              RepaintBoundary(
                key: _paintKey,
                child: SizedBox.square(
                  dimension: 120,
                  child: shaders == null
                      ? null
                      : CustomPaint(painter: _TintPainter(shaders.tint)),
                ),
              ),
              const SizedBox(width: 16),
              RepaintBoundary(
                key: _filterKey,
                child: SizedBox.square(
                  dimension: 120,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: _backdrop),
                      if (filter != null)
                        ClipRect(
                          child: BackdropFilter(
                            filter: filter,
                            child: const SizedBox.expand(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TintPainter extends CustomPainter {
  _TintPainter(this.program);

  final ui.FragmentProgram program;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader()
      ..setFloat(0, _tint.r)
      ..setFloat(1, _tint.g)
      ..setFloat(2, _tint.b)
      ..setFloat(3, _tint.a);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_TintPainter old) => old.program != program;
}
