import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// When `APERTURE_VISUAL_OUT` is set, renders the nearest [RepaintBoundary]
/// around [boundary] to `$APERTURE_VISUAL_OUT/$name.png`. Otherwise a no-op,
/// so the normal suite stays free of file output.
Future<void> captureSurface(
    WidgetTester tester, Finder boundary, String name) async {
  final dir = Platform.environment['APERTURE_VISUAL_OUT'];
  if (dir == null || dir.isEmpty) return;
  RenderObject? render = boundary.evaluate().first.renderObject;
  while (render != null && render is! RenderRepaintBoundary) {
    render = render.parent;
  }
  if (render is! RenderRepaintBoundary) {
    throw StateError('No RepaintBoundary around $boundary');
  }
  final repaint = render;
  await tester.runAsync(() async {
    final image = await repaint.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(data!.buffer.asUint8List());
  });
}
