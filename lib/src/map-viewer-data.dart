import 'dart:io';
import 'dart:typed_data'; // Uint8List

import 'package:flutter/material.dart';

import 'package:universal_platform/universal_platform.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import 'error.dart';
import 'decompress.dart';
import 'chart.dart';
import 'socket-events.dart' as socket_events;
import 'viewport.dart' as vp;
import 'plot_spec.dart';

// ======================================================================

abstract class AntigenicMapViewerCallbacks {
  void updateCallback({int? plotSpecIndex});
  void showMessage(String text, {Color backgroundColor = Colors.red});
  void hideMessage();
  Future<Uint8List?> exportPdf({double canvasPdfWidth = 800.0});
}

// ----------------------------------------------------------------------

class AntigenicMapViewerData {
  final AntigenicMapViewerCallbacks _callbacks;
  String? chartFilename; // for reloadChart()
  Chart? chart;
  Projection? projection;
  vp.Viewport? viewport; // base (fit-to-layout) viewport; PDF export and the view-reset use this
  double viewZoom = 1.0; // interactive zoom factor (>1 zoomed in); 1.0 = fit
  Offset viewPan = Offset.zero; // interactive pan of the view centre, in viewport coordinate units
  bool _chartBeingLoaded = false;
  Socket? _socket;
  late bool openExportedPdf;
  Size antigenicMapPainterSize = Size.zero; // to auto-resize window
  List<PlotSpec> plotSpecs = <PlotSpec>[];
  int currentPlotSpecIndex = -1;
  // final aaPerPos = <int, Map<String, int>>{};

  /// Point (layout) indexes the user has dragged this session. Reported to the server (get_moved_points) so it
  /// can pin them (Projection.set_unmovable) before relaxing. Antigens come first (0..nAg-1), then sera.
  final Set<int> movedPoints = <int>{};

  /// Point (layout) indexes currently selected via a rubber-band box. Dragging a selected point moves the whole
  /// set together. Antigens come first (0..nAg-1), then sera.
  final Set<int> selectedPoints = <int>{};

  AntigenicMapViewerData(this._callbacks);

  void setChart(Chart aChart) {
    chart = aChart;
    projection = chart!.projections[0];
    plotSpecs = chart!.plotSpecs(projection);
    movedPoints.clear();
    selectedPoints.clear();
    resetView();
    _chartBeingLoaded = false;
    _callbacks.hideMessage();
    currentPlotSpecIndex = -1;
    _callbacks.updateCallback(plotSpecIndex: 0);
    // makeAaPerPos();
  }

  /// Move antigen/serum point [pointNo] to [newTransformedPos] (transformed/viewport coordinates) and record it
  /// as moved. The underlying chart json is updated so exportToJson() / get_chart return the new coordinates.
  void movePoint(int pointNo, Vector3 newTransformedPos) {
    if (projection != null) {
      projection!.moveTransformedPoint(pointNo, newTransformedPos);
      movedPoints.add(pointNo);
    }
  }

  /// Undo all point moves, restoring original coordinates.
  void resetMovedPoints() {
    projection?.resetMovedPoints();
    movedPoints.clear();
  }

  /// Select every shown point whose (transformed) coordinate falls within the box with corners [c1] and [c2]
  /// (both in transformed/viewport coordinates). Replaces the previous selection.
  void selectPointsInBox(Vector3 c1, Vector3 c2) {
    selectedPoints.clear();
    if (projection == null || currentPlotSpecIndex < 0) return;
    final layout = projection!.transformedLayout();
    final minX = c1.x < c2.x ? c1.x : c2.x, maxX = c1.x < c2.x ? c2.x : c1.x;
    final minY = c1.y < c2.y ? c1.y : c2.y, maxY = c1.y < c2.y ? c2.y : c1.y;
    final spec = currentPlotSpec;
    for (var i = 0; i < layout.length; ++i) {
      final p = layout[i];
      if (p != null && spec[i].shown && p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY) {
        selectedPoints.add(i);
      }
    }
  }

  void clearSelection() {
    selectedPoints.clear();
  }

  /// Apply one streamed intermediate optimiser layout (a LAYT frame received during an animated relax) and
  /// repaint. [rawCoords] is a list of per-point [x, y(, z)] (or null for disconnected points) in the projection's
  /// raw layout space. The viewport, plot style and selection are left untouched so the animation stays smooth;
  /// the live stress readout updates automatically because it is computed from the displayed layout.
  void applyLayoutFrame(List<dynamic> rawCoords, {bool commit = false}) {
    if (projection == null) return;
    final parsed = rawCoords.map<Vector3?>((c) {
      if (c is List && c.length >= 2) {
        return Vector3((c[0] as num).toDouble(), (c[1] as num).toDouble(), c.length >= 3 ? (c[2] as num).toDouble() : 0.0);
      }
      return null;
    }).toList();
    projection!.setDisplayLayout(parsed, commit: commit);
    _callbacks.updateCallback();
  }

  // ----------------------------------------------------------------------
  // Interactive zoom / pan. Only the drawing viewport is adjusted (uniform scale + offset), so the aspect ratio
  // is preserved and the window never resizes. PDF export keeps using the base [viewport].

  /// The viewport actually drawn on screen: the base [viewport] with the interactive zoom and pan applied.
  vp.Viewport? get effectiveViewport {
    final base = viewport;
    if (base == null) return null;
    if (viewZoom == 1.0 && viewPan == Offset.zero) return base;
    final w = base.width / viewZoom, h = base.height / viewZoom;
    final cx = base.centerX + viewPan.dx, cy = base.centerY + viewPan.dy;
    return vp.Viewport.originSizeList([cx - w / 2, cy - h / 2, w, h]);
  }

  /// Zoom by [factor] (>1 zooms in) keeping [worldPos] (in current viewport coordinates) under the cursor.
  void zoomAt(Vector3 worldPos, double factor) {
    final base = viewport;
    if (base == null) return;
    final newZoom = (viewZoom * factor).clamp(0.2, 50.0);
    final r = viewZoom / newZoom; // = newWidth / oldWidth
    final cx = base.centerX + viewPan.dx, cy = base.centerY + viewPan.dy;
    final ncx = worldPos.x - r * (worldPos.x - cx);
    final ncy = worldPos.y - r * (worldPos.y - cy);
    viewZoom = newZoom;
    viewPan = Offset(ncx - base.centerX, ncy - base.centerY);
  }

  /// Pan the view by a delta expressed in viewport coordinate units (content follows the cursor).
  void panByWorld(double dx, double dy) {
    viewPan = Offset(viewPan.dx - dx, viewPan.dy - dy);
  }

  /// Reset zoom and pan back to fit-the-layout.
  void resetView() {
    viewZoom = 1.0;
    viewPan = Offset.zero;
  }

  /// Reframe the base viewport to fit the current layout centred (e.g. after a relax left the map small and
  /// off-centre), and clear any interactive zoom/pan. The window is resized to match by the widget.
  void centreMap() {
    if (projection == null) return;
    final hull = vp.Viewport.hullLayout(projection!.transformedLayout());
    final w = (hull.width + 1).ceilToDouble(), h = (hull.height + 1).ceilToDouble();
    viewport = vp.Viewport.originSizeList([hull.centerX - w / 2, hull.centerY - h / 2, w, h]);
    resetView();
  }

  /// True when driven by a server (ae) over the socket, i.e. relax can be requested.
  bool get connectedToServer => _socket != null;

  /// Ask the server (ae) to relax (re-optimize) the map. Sends an unsolicited RLAX notification over the socket —
  /// a bare 4-byte code with no payload, exactly like the HELO/QUIT handshake frames (NOT the length-prefixed
  /// CHRT/JSON/PDFB response framing). kateri itself never relaxes; the server is expected to react by pulling
  /// the edited layout (get_chart) and relaxing the whole map from those positions — every point free to move,
  /// nothing pinned — then pushing the relaxed chart back (CHRT), which kateri re-renders. The dragged points
  /// merely provide better starting positions to escape local optima. (get_moved_points remains available as
  /// informational reporting of which points the operator touched.)
  void requestRelax() {
    if (_socket == null) {
      _callbacks.showMessage("Not connected to a server — relax runs on the ae side over the socket.");
      return;
    }
    _socket!.write("RLAX");
    info("[relax] requested; ${movedPoints.length} point(s) moved this session");
  }

  void setChartFromBytes(Uint8List bytes) {
    setChart(Chart(bytes));
  }

  void resetChart() {
    chart = null;
    projection = null;
    viewport = null;
    movedPoints.clear();
    selectedPoints.clear();
    _chartBeingLoaded = false;
    currentPlotSpecIndex = -1;
    _callbacks.updateCallback();
  }

  void reloadChart() async {
    if (chartFilename != null) {
      final stopwatch = Stopwatch()..start();
      setChart(Chart(await decompressFile(chartFilename!)));
      debug("$chartFilename re-loaded in ${stopwatch.elapsed}");
    }
  }

  void setPlotSpecByName(String name) {
    final index = plotSpecs.indexWhere((spec) => spec.name() == name);
    if (index >= 0) {
      setPlotSpec(index);
    } else {
      warning("plot style \"$name\" not found");
    }
  }

  int addPlotSpecColorByAA(List<int> positions) {
    if (chart == null && projection == null) throw DataError("no chart, chart: $chart projection: $projection");
    var index = plotSpecs.indexWhere((spec) => spec.name() == PlotSpecColorByAA.myName);
    if (index < 0) {
      plotSpecs.add(PlotSpecColorByAA(chart!, projection!));
      index = plotSpecs.length - 1;
    }
    (plotSpecs[index] as PlotSpecColorByAA).setPositions(positions);
    return index;
  }

  void setPlotSpec(int index) {
    if (chart != null && index < plotSpecs.length) {
      if (currentPlotSpecIndex != index) {
        currentPlotSpecIndex = index;
        currentPlotSpec.activate();
      }
      viewport = plotSpecs[index].viewport() ?? projection!.viewport();
      info("projection ${projection!.viewport()}");
      info("used       $viewport  aspect:${viewport!.aspectRatio()}");
    }
  }

  PlotSpec get currentPlotSpec => plotSpecs[currentPlotSpecIndex];

  PlotSpecLegacy plotSpecLegacy() {
    final index = plotSpecs.indexWhere((spec) => spec.name() == PlotSpecLegacy.myName);
    if (index >= 0) {
      return plotSpecs[index] as PlotSpecLegacy;
    } else {
      final ps = chart!.plotSpecLegacy();
      plotSpecs.add(ps);
      return ps;
    }
  }

  bool empty() => chart != null;

  void buildStarted() {
    if (UniversalPlatform.isMacOS && chart == null && !_chartBeingLoaded && _socket == null) {
      // forcing open dialog here does not work in web and eventually leads to problems
      openChart();
    }
  }

  void didChangeDependencies({required String? fileToOpen, required String? socketToConnect}) {
    openLocalAceFile(fileToOpen);
    connectToServer(socketToConnect);
  }

  void exportCurrentPlotStyleToLegacy() {
    if (chart != null && currentPlotSpec.name() != PlotSpecLegacy.myName) {
      plotSpecLegacy().setFrom(currentPlotSpec);
    }
  }

  // ----------------------------------------------------------------------

  void openChart() async {
    final file = (await FilePicker.platform.pickFiles())?.files.single;
    if (file != null) {
      try {
        final stopwatch = Stopwatch()..start();
        // accesing file?.path on web always reports an error (regardles of using try/catch)
        if (file.bytes != null) {
          setChart(Chart(decompressBytes(file.bytes!)));
        } else if (file.path != null) {
          setChart(Chart(await decompressFile(file.path!)));
          chartFilename = file.path;
        }
        debug("chart loaded in ${stopwatch.elapsed}");
      } on Exception catch (err) {
        // cannot import chart from a file
        _callbacks.showMessage(err.toString());
        if (chart == null) {
          resetChart();
        }
      }
    }
    // else {
    //   resetChart();
    // }
  }

  Future<void> openLocalAceFile(String? path) async {
    // print("openLocalAceFile path:$path chart:$chart");
    if (chart == null && path != null) {
      try {
        _chartBeingLoaded = true;
        if (path == "-") {
          setChart(Chart(await decompressStdin()));
        } else {
          setChart(Chart(await decompressFile(path)));
        }
      } on Exception catch (err) {
        // cannot import chart from a file
        _callbacks.showMessage(err.toString());
        resetChart();
      }
    }
  }

  // ----------------------------------------------------------------------

  void connectToServer(String? socketName) async {
    if (socketName != null) {
      _chartBeingLoaded = true;
      while (true) {
        try {
          _socket = await Socket.connect(InternetAddress(socketName, type: InternetAddressType.unix), 0);
          break; // connected
        } on SocketException {
          // socket not available yet, wait
          sleep(const Duration(milliseconds: 100));
        }
      }

      socket_events.SocketEventHandler(socket: _socket!, antigenicMapViewerData: this).handle();
      _socket!.write("HELO");
    }
  }

  // ----------------------------------------------------------------------

  void generatePdf({String? filename, bool? open, double width = 800.0}) async {
    if (chart != null) {
      final stopwatch = Stopwatch()..start();
      final bytes = await _callbacks.exportPdf(canvasPdfWidth: width); // antigenicMapPainter.viewer.exportPdf();
      if (bytes != null) {
        final generatedFilename = await FileSaver.instance.saveFile(name: filename ?? chart!.info.nameForFilename(), bytes: bytes, ext: "pdf", mimeType: MimeType.pdf);
        debug("generatedFilename $generatedFilename");
        if ((open ?? openExportedPdf) && UniversalPlatform.isMacOS) {
          await Process.run("open", [generatedFilename]);
        }
      }
      debug("[exportPdf] ${stopwatch.elapsed} -> ${(1e6 / stopwatch.elapsedMicroseconds).toStringAsFixed(2)} frames per second");
    }
  }

  Future<Uint8List?> exportPdfToBytes({double width = 800.0}) async {
    return _callbacks.exportPdf(canvasPdfWidth: width);
  }

  // ----------------------------------------------------------------------

  // void makeAaPerPos() {
  //   aaPerPos.clear();
  //   if (chart != null) {
  //     for (final aas in chart!.antigens.map((ag) => ag.aa)) {
  //       for (var pos = 0; pos < aas.length; ++pos) {
  //         aaPerPos.update(pos, (oldVal) {
  //           oldVal.update(aas[pos], (oldCount) => oldCount + 1, ifAbsent: () => 1);
  //           return oldVal;
  //         }, ifAbsent: () => <String, int>{aas[pos]: 1});
  //       }
  //     }
  //   }
  //   aaPerPos.removeWhere((pos, aas) => aas.length < 2);
  //   // print("makeAaPerPos");
  //   // aaPerPos.forEach((pos, aas) {
  //   //   print("    $pos   $aas");
  //   // });
  // }
}

// ----------------------------------------------------------------------
