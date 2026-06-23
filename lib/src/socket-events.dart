import 'dart:io';
import 'dart:async';
import 'dart:typed_data'; // Uint8List
import 'dart:math';
import 'dart:convert'; // json
import 'package:flutter/services.dart';

import 'error.dart';
import 'map-viewer-data.dart';

// ----------------------------------------------------------------------

class SocketEventHandler {
  final AntigenicMapViewerData antigenicMapViewerData;
  final Stream<Event> _transformed;
  final Socket socket;
  var _processing = 0;

  SocketEventHandler({required this.socket, required this.antigenicMapViewerData}) : _transformed = socket.transform(const _Transformer());

  void handle() async {
    await for (final event in _transformed) {
      event.act(socket, antigenicMapViewerData, this);
    }
  }

  void startProcessing() {
    ++_processing;
  }

  void endProcessing() {
    --_processing;
  }

  Future quit() async {
    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 10));
      return _processing > 0;
    });
    socket.add(Uint8List.fromList("QUIT".codeUnits));
    // info("quitting");
  }
}

// ----------------------------------------------------------------------

abstract class Event {
  Event();

  /// Called when the whole even is stored in data
  void prepare();

  void act(Socket socket, AntigenicMapViewerData antigenicMapViewerData, SocketEventHandler handler);

  /// Build an event for the 4-byte [eventCode] parsed from the wire (the payload is read separately
  /// via [allocate]/[fill]). All events kateri *receives* are length-prefixed (CHRT/COMD/LAYT).
  factory Event.create(String eventCode) {
    switch (eventCode) {
      case "CHRT":
        return ChartEvent();
      case "COMD":
        return CommandEvent();
      case "LAYT":
        return LayoutFrameEvent();
      default:
        throw FormatError("unrecognized socket event: \"$eventCode\"");
    }
  }

  /// Allocate the payload buffer once the 8-byte header (code + length) has been parsed.
  void allocate(int length) {
    _data = Uint8List(length);
    _stored = 0;
  }

  /// Copy as many payload bytes as are available from [source] starting at [start] into the
  /// preallocated buffer; return the number of bytes consumed. A payload split across several
  /// socket reads is handled transparently — the remaining bytes arrive in later calls.
  int fill(Uint8List source, int start) {
    final copyCount = min(source.length - start, _data!.length - _stored);
    _data!.setRange(_stored, _stored + copyCount, source, start);
    _stored += copyCount;
    return copyCount;
  }

  /// Payload length in bytes (0 before [allocate]).
  int get length => _data?.length ?? 0;

  /// Returns true once the whole payload has been read and the event is ready to dispatch.
  bool finished() {
    return _data != null && _data!.length == _stored;
  }

  void send(Socket socket, String command, Uint8List data) {
    final remainder = data.length.remainder(4);
    final padding = remainder != 0 ? Uint8List(4 - remainder) : Uint8List(0);
    final payloadLength = Uint8List(4);
    payloadLength.buffer.asUint32List(0, 1)[0] = data.length;
    // info("[socket] sending $command ${data.length} bytes with padding ${padding.length}");
    socket.add(Uint8List.fromList(command.codeUnits));
    socket.add(payloadLength);
    socket.add(data);
    socket.add(padding);
  }

  Uint8List? _data;
  int _stored = 0; // number of bytes already in _data
}

// ----------------------------------------------------------------------

class ChartEvent extends Event {
  @override
  void prepare() {
    info("receiving chart (${_data!.length} bytes)");
  }

  @override
  void act(Socket socket, AntigenicMapViewerData antigenicMapViewerData, SocketEventHandler handler) {
    if (_data == null) return;
    antigenicMapViewerData.setChartFromBytes(_data!);
  }

  @override
  String toString() {
    if (_data == null) {
      return "ChartEvent(empty)";
    } else {
      return "ChartEvent(${_data!.length} $_stored bytes)";
    }
  }
}

// ----------------------------------------------------------------------

/// One intermediate optimiser layout streamed by the server during an animated relax. Payload is JSON
/// {"l": [[x, y], ...]} of raw layout coordinates (one per point, null/[] for disconnected). Rendered in place
/// without resetting the viewport/plot style so the relax animates smoothly.
class LayoutFrameEvent extends Event {
  List<dynamic> _coords = const [];
  bool _commit = false; // true for the last frame: commit coords to the model so get_chart returns them

  @override
  void prepare() {
    if (_data == null) return;
    try {
      final decoded = jsonDecode(utf8.decode(_data!));
      _coords = (decoded["l"] as List?) ?? const [];
      _commit = decoded["final"] == true;
    } catch (err) {
      throw FormatError("LAYT decoding failed: $err");
    }
  }

  @override
  void act(Socket socket, AntigenicMapViewerData antigenicMapViewerData, SocketEventHandler handler) {
    antigenicMapViewerData.applyLayoutFrame(_coords, commit: _commit);
  }

  @override
  String toString() => "LayoutFrameEvent(${_data?.length ?? 0} bytes${_commit ? ', final' : ''})";
}

// ----------------------------------------------------------------------

typedef _JsonData = Map<String, dynamic>;

class CommandEvent extends Event {
  late final _JsonData data;

  @override
  void prepare() {
    if (_data == null) return;

    // debug("receiving command (${_data!.length} bytes)");

    late final String utf8Decoded;
    try {
      utf8Decoded = utf8.decode(_data!);
    } catch (err) {
      throw FormatError("utf8 decoding failed: $err");
    }
    // debug(utf8Decoded);
    try {
      data = jsonDecode(utf8Decoded);
    } catch (err) {
      throw FormatError("json decoding failed: $err");
    }
  }

  @override
  void act(Socket socket, AntigenicMapViewerData antigenicMapViewerData, SocketEventHandler handler) async {
    // info("CommandEvent.act ${data['C']}");
    switch (data["C"]) {
      case "set_style":
        antigenicMapViewerData.setPlotSpecByName(data["style"] ?? "*unknown*");
        break;
      case "export_to_legacy": // export current style to legacy plot spec
        antigenicMapViewerData.exportCurrentPlotStyleToLegacy();
        break;
      case "get_chart": // send chart (json) back to server
        handler.startProcessing();
        final json = antigenicMapViewerData.chart?.exportToJson();
        if (json != null) {
          send(socket, "CHRT", utf8.encoder.convert(json));
        }
        handler.endProcessing();
        break;
      case "get_moved_points": // send the list of point indexes the user dragged back to server
        handler.startProcessing();
        final movedResult = <String, dynamic>{
          "C": data["C"],
          "_id": data["_id"],
          "moved": antigenicMapViewerData.movedPoints.toList()..sort(),
        };
        send(socket, "JSON", utf8.encoder.convert(jsonEncode(movedResult)));
        handler.endProcessing();
        break;
      case "get_viewport": // send viewport data (json) back to server
        handler.startProcessing();
        final result = <String, dynamic>{
          "C": data["C"],
          "_id": data["_id"],
          "native": antigenicMapViewerData.projection?.viewport().toListDouble(),
          "native_center": antigenicMapViewerData.projection?.viewport().layoutCenter2(),
          "used": antigenicMapViewerData.viewport?.toListDouble()
        };
        send(socket, "JSON", utf8.encoder.convert(jsonEncode(result)));
        handler.endProcessing();
        break;
      case "pdf":
        handler.startProcessing();
        final pdfData = await antigenicMapViewerData.exportPdfToBytes(width: data["width"]?.toDouble());
        if (pdfData != null) {
          send(socket, "PDFB", pdfData);
          // final remainder = pdfData.length.remainder(4);
          // final padding = remainder != 0 ? Uint8List(4 - remainder) : Uint8List(0);
          // final payloadLength = Uint8List(4);
          // payloadLength.buffer.asUint32List(0, 1)[0] = pdfData.length;
          // info("[socket] sending pdf ${pdfData.length} bytes with padding ${padding.length}");
          // socket.add(Uint8List.fromList("PDFB".codeUnits));
          // socket.add(payloadLength);
          // socket.add(pdfData);
          // socket.add(padding);
        }
        handler.endProcessing();
        break;
      case "quit":
        await handler.quit();
        break;
      default:
        error("unrecognized command: $data");
        break;
    }
  }

  @override
  String toString() {
    return "CommandEvent $data";
  }
}

// ----------------------------------------------------------------------

class _Transformer extends StreamTransformerBase<Uint8List, Event> {
  const _Transformer();

  Stream<Event> bind(Stream<Uint8List> stream) {
    return Stream<Event>.eventTransformed(stream, (EventSink<Event> sink) => _EventSink(sink));
  }
}

// ----------------------------------------------------------------------

class _EventSink implements EventSink<Uint8List> {
  final EventSink<Event> _output;
  Event? _current;
  // Frame = 4-byte code + 4-byte little-endian length + payload + padding to a 4-byte boundary.
  // The unix socket hands us arbitrary byte chunks, so any of these parts may be split across reads
  // (or several frames may arrive in one read). These fields carry the partial-parse state between
  // add() calls so a split header — the bug that previously crashed the parser and stalled kateri
  // mid-session — is handled transparently.
  final Uint8List _header = Uint8List(8); // code + length, assembled byte-by-byte across reads
  int _headerStored = 0;
  int _padding = 0; // payload-trailing alignment bytes still to skip before the next frame

  _EventSink(this._output);

  @override
  void add(Uint8List source) {
    var i = 0;
    final n = source.length;
    while (i < n) {
      // 1. skip any 4-byte-alignment padding left over from the previous event's payload
      if (_padding > 0) {
        final skip = min(_padding, n - i);
        i += skip;
        _padding -= skip;
        continue;
      }
      // 2. assemble the 8-byte header (code + length); may span multiple reads
      if (_current == null) {
        while (_headerStored < 8 && i < n) {
          _header[_headerStored++] = source[i++];
        }
        if (_headerStored < 8) break; // header incomplete — resume on the next read
        final code = String.fromCharCodes(_header, 0, 4);
        // length is little-endian: ae writes len.to_bytes(4, sys.byteorder) and both ends are the same host
        final length = _header[4] | (_header[5] << 8) | (_header[6] << 16) | (_header[7] << 24);
        _headerStored = 0;
        _current = Event.create(code);
        _current!.allocate(length);
      }
      // 3. fill the payload (also possibly split across reads)
      i += _current!.fill(source, i);
      if (_current!.finished()) {
        final remainder = _current!.length.remainder(4);
        _padding = remainder == 0 ? 0 : 4 - remainder;
        _current!.prepare();
        _output.add(_current!);
        _current = null;
      }
    }
  }

  @override
  void addError(Object err, [StackTrace? stackTrace]) {
    error("_EventSink.addError $err");
  }

  @override
  void close() {
    // info("_EventSink.close");
    SystemNavigator.pop(animated: true);
  }
}

// ----------------------------------------------------------------------
