import 'dart:ui';
import 'dart:io';
import 'dart:typed_data'; // Uint8List
import 'dart:math' as math;
import 'package:pdf/pdf.dart';
// import 'package:pdf/src/pdf/obj/type1_font.dart';
import 'package:flutter/services.dart' show rootBundle, ByteData;
import 'package:vector_math/vector_math_64.dart';

import 'color.dart';
import 'draw_on.dart';
import 'viewport.dart';

// ----------------------------------------------------------------------

// Canonicalise weight/style by VALUE, not by FontWeight/FontStyle.toString(): Flutter 3.44
// changed those enums' toString (FontWeight.bold no longer prints "FontWeight.w700"), which
// silently broke getFont's hardcoded string cases so all bold/italic text fell back to regular
// Helvetica. Compare the values directly so the key always matches the switch below.
String fontKey(LabelStyle style) {
  final weight = (style.fontWeight == FontWeight.w700) ? "FontWeight.w700" : "FontWeight.w400";
  final fstyle = (style.fontStyle == FontStyle.italic) ? "FontStyle.italic" : "FontStyle.normal";
  return "${style.fontFamily} $weight $fstyle";
}

// The PDF standard Type1 fonts (Helvetica/Times/Courier) returned by
// CanvasPdf.getFont are Latin1-only: PdfFont.stringMetrics/drawString run the
// text through Latin1Codec.encode, which throws on any code unit > 0xFF (e.g.
// Chinese serum names). Strings that contain such characters are routed to a
// bundled Unicode TrueType font instead — see CanvasPdf.getUnicodeFont.
bool _isLatin1(String s) {
  for (final u in s.codeUnits) {
    if (u > 0xFF) return false;
  }
  return true;
}

class CanvasPdf extends CanvasRoot {
  CanvasPdf(Size canvasSize)
      : doc = PdfDocument(),
        _fonts = <String, PdfFont>{},
        super(canvasSize) {
    PdfPage(doc, pageFormat: PdfPageFormat(canvasSize.width, canvasSize.height));
    canvas = doc.pdfPageList.pages[0].getGraphics();

    // coordinate system of Pdf has origin in the bottom left, change it ours with origin at the top left
    canvas.setTransform(Matrix4.identity()
      ..scale(1.0, -1.0)
      ..translate(0.0, -canvasSize.height, 0.0));
  }

  void paintBy(Function painter) {
    painter(this);
  }

  @override
  void draw(Rect drawingArea, Viewport viewport, Function doDraw, {Color? debuggingOutline, bool clip = false}) {
    canvas
      ..saveContext()
      ..setTransform(Matrix4.translationValues(drawingArea.left, drawingArea.top, 0.0));
    if (clip) {
      canvas
        ..drawRect(0.0, 0.0, drawingArea.width, drawingArea.height)
        ..clipPath();
    }
    canvas.saveContext();
    doDraw(_DrawOnPdf(this, drawingArea.size, viewport));
    canvas.restoreContext();
    if (debuggingOutline != null) {
      canvas
        ..drawRect(0.0, 0.0, drawingArea.width, drawingArea.height)
        ..setStrokeColor(PdfColor.fromInt(debuggingOutline.value))
        ..setLineWidth(3.0)
        ..strokePath();
    }
    canvas.restoreContext();
  }

  Future<Uint8List> bytes() async {
    return doc.save();
  }

  void write(String filename, {bool open = true}) async {
    final file = File(filename);
    await file.writeAsBytes(await doc.save());
    if (open) {
      await Process.run("open-and-back-to-emacs", [filename]);
    }
  }

  PdfFont getFont(String key) {
    var font = _fonts[key];
    if (font == null) {
      switch (key) {
        case "LabelFontFamily.monospace FontWeight.w400 FontStyle.normal":
        case "LabelFontFamily.courier FontWeight.w400 FontStyle.normal":
          font = PdfFont.courier(doc);
          break;
        case "LabelFontFamily.monospace FontWeight.w700 FontStyle.normal":
        case "LabelFontFamily.courier FontWeight.w700 FontStyle.normal":
          font = PdfFont.courierBold(doc);
          break;
        case "LabelFontFamily.monospace FontWeight.w400 FontStyle.italic":
        case "LabelFontFamily.courier FontWeight.w400 FontStyle.italic":
          font = PdfFont.courierOblique(doc);
          break;
        case "LabelFontFamily.monospace FontWeight.w700 FontStyle.italic":
        case "LabelFontFamily.courier FontWeight.w700 FontStyle.italic":
          font = PdfFont.courierBoldOblique(doc);
          break;

        case "LabelFontFamily.sansSerif FontWeight.w400 FontStyle.normal":
        case "LabelFontFamily.helvetica FontWeight.w400 FontStyle.normal":
          font = PdfFont.helvetica(doc);
          break;
        case "LabelFontFamily.sansSerif FontWeight.w700 FontStyle.normal":
        case "LabelFontFamily.helvetica FontWeight.w700 FontStyle.normal":
          font = PdfFont.helveticaBold(doc);
          break;
        case "LabelFontFamily.sansSerif FontWeight.w400 FontStyle.italic":
        case "LabelFontFamily.helvetica FontWeight.w400 FontStyle.italic":
          font = PdfFont.helveticaOblique(doc);
          break;
        case "LabelFontFamily.sansSerif FontWeight.w700 FontStyle.italic":
        case "LabelFontFamily.helvetica FontWeight.w700 FontStyle.italic":
          font = PdfFont.helveticaBoldOblique(doc);
          break;

        case "LabelFontFamily.serif FontWeight.w400 FontStyle.normal":
        case "LabelFontFamily.times FontWeight.w400 FontStyle.normal":
          font = PdfFont.times(doc);
          break;
        case "LabelFontFamily.serif FontWeight.w700 FontStyle.normal":
        case "LabelFontFamily.times FontWeight.w700 FontStyle.normal":
          font = PdfFont.timesBold(doc);
          break;
        case "LabelFontFamily.serif FontWeight.w400 FontStyle.italic":
        case "LabelFontFamily.times FontWeight.w400 FontStyle.italic":
          font = PdfFont.timesItalic(doc);
          break;
        case "LabelFontFamily.serif FontWeight.w700 FontStyle.italic":
        case "LabelFontFamily.times FontWeight.w700 FontStyle.italic":
          font = PdfFont.timesBoldItalic(doc);
          break;
      }
      font ??= PdfFont.helvetica(doc);
      _fonts[key] = font;
    }
    return font;
  }

  // Bytes of the bundled Unicode TTF, loaded once and shared across documents.
  // PdfTtfFont itself embeds into a specific PdfDocument, so the font object is
  // per-instance (cached in _unicodeFont) but the source bytes are static.
  static ByteData? _unicodeFontData;

  // Preload the Unicode font asset. Must be awaited before constructing a
  // CanvasPdf that may draw non-Latin1 text, because painting is synchronous
  // while rootBundle.load is async. Safe to call repeatedly (loads once).
  static Future<void> ensureFontsLoaded() async {
    _unicodeFontData ??= await rootBundle.load("assets/fonts/NotoSansSC-Regular.ttf");
  }

  // A Unicode-capable font for this document. Falls back to Helvetica if the
  // asset was not preloaded (then non-Latin1 text would still throw, but that
  // is caught at the socket layer rather than hanging the protocol).
  PdfFont getUnicodeFont() {
    final data = _unicodeFontData;
    if (data == null) return getFont("LabelFontFamily.helvetica FontWeight.w400 FontStyle.normal");
    return _unicodeFont ??= PdfTtfFont(doc, data);
  }

  final PdfDocument doc;
  final Map<String, PdfFont> _fonts;
  PdfFont? _unicodeFont;
  late final PdfGraphics canvas;
}

// ----------------------------------------------------------------------

class _DrawOnPdf extends DrawOn {
  final CanvasPdf _canvasPdf;
  final PdfGraphics _canvas;
  final Size canvasSize;
  final double _pixelSize;

  // aspect: width / height
  _DrawOnPdf(this._canvasPdf, this.canvasSize, Viewport viewport)
      : _canvas = _canvasPdf.canvas,
        _pixelSize = viewport.width / canvasSize.width,
        super(viewport) {
    _canvas.setTransform(Matrix4.identity()
      ..scale(canvasSize.width / viewport.width)
      ..translate(-viewport.left, -viewport.top, 0.0));
  }

  @override
  double get pixelSize => _pixelSize;

  @override
  void transform(Matrix4 transformation) {}

  // ----------------------------------------------------------------------
  // 2D
  // ----------------------------------------------------------------------

  @override
  void point(
      {required Vector3 center,
      required double sizePixels,
      PointShape shape = PointShape.circle,
      Color fill = const Color(0x00000000),
      Color outline = const Color(0xFF000000),
      double outlineWidthPixels = 1.0,
      double rotation = noRotation,
      double aspect = 1.0,
      PointLabel? label}) {
    _canvas
      ..saveContext()
      ..setTransform(Matrix4.translation(center)
        ..rotateZ(rotation)
        ..scale(aspect, 1.0));
    _setColorsLineWidth(fill: fill, outline: outline, lineWidthPixels: outlineWidthPixels);
    _drawShape(shape, sizePixels * pixelSize);
    _fillAndStroke(outlineWidthPixels);
    _canvas.restoreContext();

    if (label != null && label.text.isNotEmpty && label.sizePixels > 0.0) {
      addPointLabel(center: center, sizePixels: sizePixels, outlineWidthPixels: outlineWidthPixels, label: label, delayed: true);
    }
  }

  void _drawShape(PointShape shape, double size) {
    final radius = size / 2;
    switch (shape) {
      case PointShape.circle:
        _canvas.drawEllipse(0.0, 0.0, radius, radius);
        break;

      case PointShape.egg:
        // https://books.google.de/books?id=StdwgT34RCwC&pg=PA107
        _canvas
          ..moveTo(0.0, radius)
          ..curveTo(radius * 1.4, radius * 0.95, radius * 0.8, -radius * 0.98, 0.0, -radius)
          ..curveTo(-radius * 0.8, -radius * 0.98, -radius * 1.4, radius * 0.95, 0.0, radius)
          ..closePath();
        break;

      case PointShape.box:
        _canvas.drawRect(-radius, -radius, size, size);
        break;

      case PointShape.uglyegg:
        final c1x = radius * 1.0, c1y = radius * 0.6, c2x = radius * 0.8, c2y = -radius * 0.6;
        _canvas
          ..moveTo(0.0, radius)
          ..lineTo(c1x, c1y)
          ..lineTo(c2x, c2y)
          ..lineTo(0.0, -radius)
          ..lineTo(-c2x, c2y)
          ..lineTo(-c1x, c1y)
          ..closePath();
        break;

      case PointShape.triangle:
        final cosPi6 = math.cos(math.pi / 6);
        _canvas
          ..moveTo(0.0, -radius)
          ..lineTo(-radius * cosPi6, size / 4)
          ..lineTo(radius * cosPi6, size / 4)
          ..closePath();
        break;
    }
  }

  @override
  void path(List<Offset> vertices, {Color outline = const Color(0xFF000000), Color fill = const Color(0x00000000), double lineWidthPixels = 1.0, bool close = true}) {
    _canvas.saveContext();
    _setColorsLineWidth(fill: fill, outline: outline, lineWidthPixels: lineWidthPixels);
    _canvas.moveTo(vertices[0].dx, vertices[0].dy);
    for (var vertix in vertices.getRange(1, vertices.length)) {
      _canvas.lineTo(vertix.dx, vertix.dy);
    }
    _canvas.closePath();
    _fillAndStroke(lineWidthPixels);
    _canvas.restoreContext();
  }

  void _setColorsLineWidth({required Color fill, required Color outline, required lineWidthPixels}) {
    final fillC = PdfColor.fromInt(fill.value), outlineC = PdfColor.fromInt(outline.value);
    _canvas
      ..setGraphicState(PdfGraphicState(fillOpacity: fillC.alpha, strokeOpacity: outlineC.alpha))
      ..setFillColor(fillC)
      ..setStrokeColor(outlineC)
      ..setLineWidth(lineWidthPixels * pixelSize);
  }

  void _fillAndStroke(double lineWidthPixels) {
    if (lineWidthPixels > 0) {
      _canvas.fillAndStrokePath();
    } else {
      _canvas.fillPath();
    }
  }

  @override
  void circle({required Vector3 center, required double radius, Color fill = const Color(0x00000000), Color outline = const Color(0xFF000000), double outlineWidthPixels = 1.0, double rotation = noRotation, double aspect = 1.0}) {
    _canvas
      ..saveContext()
      ..setTransform(Matrix4.translationValues(center.x, center.y, 0)
        ..rotateZ(rotation)
        ..scale(aspect, 1.0));
    _setColorsLineWidth(fill: fill, outline: outline, lineWidthPixels: outlineWidthPixels);
    _canvas.drawEllipse(0.0, 0.0, radius, radius);
    _fillAndStroke(outlineWidthPixels);
    _canvas.restoreContext();
  }

  @override
  void arc(
      {required Vector3 center,
      required double radius,
      required Sector sector, // 0.0 is upright
      Color fill = const Color(0x00000000),
      Color outline = const Color(0xFF000000),
      double outlineWidthPixels = 1.0}) {
    _canvas
      ..saveContext()
      ..setTransform(Matrix4.translationValues(center.x, center.y, 0)..rotateZ(sector.begin));
    final otherPointOnArc = Offset(math.sin(sector.angle) * radius, -math.cos(sector.angle) * radius);
    if (fill.alpha > 0) {
      final fillc = PdfColor.fromInt(fill.value);
      _canvas
        ..moveTo(0.0, 0.0)
        ..lineTo(0.0, -radius)
        ..bezierArc(0.0, -radius, radius, radius, otherPointOnArc.dx, otherPointOnArc.dy, large: sector.angle > math.pi, sweep: true)
        ..lineTo(0.0, 0.0)
        ..setGraphicState(PdfGraphicState(fillOpacity: fillc.alpha))
        ..setFillColor(fillc)
        ..fillPath();
    }
    if (outlineWidthPixels > 0 && outline.alpha > 0) {
      final outlineCircleC = PdfColor.fromInt(outline.value);
      _canvas
        ..moveTo(0.0, -radius)
        ..bezierArc(0.0, -radius, radius, radius, otherPointOnArc.dx, otherPointOnArc.dy, large: sector.angle > math.pi, sweep: true)
        ..setGraphicState(PdfGraphicState(strokeOpacity: outlineCircleC.alpha))
        ..setStrokeColor(outlineCircleC)
        ..setLineWidth(outlineWidthPixels * pixelSize)
        ..strokePath();
    }
    _canvas.restoreContext();
  }

  static const fontScaleToMatchCanvas = 1.02;

  @override
  void text(String text, Offset origin, {double sizePixels = 20.0, double rotation = 0.0, LabelStyle textStyle = const LabelStyle()}) {
    final colorC = PdfColor.fromInt(textStyle.color.value);
    // Latin1 text keeps the standard Type1 fonts (Latin layout unchanged);
    // anything with non-Latin1 characters draws through the Unicode TTF.
    final font = _isLatin1(text) ? _canvasPdf.getFont(fontKey(textStyle)) : _canvasPdf.getUnicodeFont();
    final fontSize = sizePixels * pixelSize * fontScaleToMatchCanvas;
    _canvas
      ..saveContext()
      ..setTransform(Matrix4.translationValues(origin.dx, origin.dy, 0)
        ..rotateZ(rotation)
        ..scale(1.0, -1.0));
    if (textStyle.haloWidthPixels > 0.0) {
      final haloC = PdfColor.fromInt(textStyle.haloColor.value);
      // isolate the stroke pass in its own save/restore: the text rendering mode (Tr) is part of the
      // graphics state and persists, and the fill drawString below (default fill mode) won't reset it —
      // without this the fill pass would also stroke, leaving white-outlined transparent glyphs.
      _canvas
        ..saveContext()
        ..setGraphicState(PdfGraphicState(strokeOpacity: haloC.alpha))
        ..setStrokeColor(haloC)
        ..setLineWidth(textStyle.haloWidthPixels * pixelSize)
        ..drawString(font, fontSize, text, 0.0, 0.0, mode: PdfTextRenderingMode.stroke) // halo under fill
        ..restoreContext();
    }
    _canvas
      ..setGraphicState(PdfGraphicState(strokeOpacity: colorC.alpha, fillOpacity: colorC.alpha))
      ..setFillColor(colorC)
      ..drawString(font, fontSize, text, 0.0, 0.0)
      ..restoreContext();
  }

  @override
  Size textSize(String text, {double sizePixels = 20.0, LabelStyle textStyle = const LabelStyle()}) {
    final font = _isLatin1(text) ? _canvasPdf.getFont(fontKey(textStyle)) : _canvasPdf.getUnicodeFont();
    final metrics = font.stringMetrics(text);
    const height = 1.0;         // instead of metrics.height (1.156) to match canvas font size
    return Size(metrics.width, height) * (sizePixels * pixelSize * fontScaleToMatchCanvas);
  }

  @override
  void grid({double step = 1.0, Color color = const Color(0xFFB0B0B0), double lineWidthPixels = 1.0}) {
    final colorc = PdfColor.fromInt(color.value);
    _canvas
      ..saveContext()
      ..setStrokeColor(colorc)
      ..setLineWidth(lineWidthPixels * pixelSize);
    for (var x = viewport.left; x <= viewport.right; x += step) {
      _canvas
        ..moveTo(x, viewport.top)
        ..lineTo(x, viewport.bottom);
    }
    for (var y = viewport.top; y <= viewport.bottom; y += step) {
      _canvas
        ..moveTo(viewport.left, y)
        ..lineTo(viewport.right, y);
    }
    _canvas
      ..strokePath()
      ..restoreContext();
  }

  // ----------------------------------------------------------------------
  // 3D
  // ----------------------------------------------------------------------

  @override
  void point3d(
      {required Vector3 center,
      required double sizePixels,
      PointShape shape = PointShape.circle,
      Color fill = const Color(0x00000000),
      Color outline = const Color(0xFF000000),
      double outlineWidthPixels = 1.0,
      double rotation = noRotation,
      double aspect = 1.0}) {
    point(center: center, sizePixels: sizePixels, shape: shape, fill: fill, outline: outline, outlineWidthPixels: outlineWidthPixels, rotation: rotation, aspect: aspect);
  }
}
