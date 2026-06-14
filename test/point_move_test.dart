// Tests for interactive point moving (Projection.moveTransformedPoint / resetMovedPoints).
//
// These exercise the model layer only — no GUI, no real surveillance data. A tiny synthetic chart with
// made-up names and coordinates is used. The key property verified is that a point dropped at a given
// transformed/viewport position is written back into the raw layout ("l") such that exportToJson() reflects
// the move correctly through both the projection transformation ("t") and kateri's viewport recentering.

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:kateri/src/chart.dart';

Chart _makeChart({List<dynamic>? transformation}) {
  final json = {
    "c": {
      "i": {"V": "TEST"},
      "t": {"l": <dynamic>[]},
      "a": [
        {"N": "AG0"},
        {"N": "AG1"},
        {"N": "AG2"},
      ],
      "s": [
        {"N": "SR0"},
      ],
      "P": [
        {
          "l": [
            [0.0, 0.0],
            [2.0, 0.0],
            [0.0, 3.0],
            [2.0, 3.0],
          ],
          if (transformation != null) "t": transformation,
        },
      ],
    },
  };
  return Chart(utf8.encode(jsonEncode(json)));
}

List<double> _exportedLayoutPoint(Chart chart, int pointNo) {
  final decoded = jsonDecode(chart.exportToJson());
  return (decoded["c"]["P"][0]["l"][pointNo] as List).cast<num>().map((e) => e.toDouble()).toList();
}

void main() {
  test('move with identity transformation writes inverted-recenter raw coords into json', () {
    final chart = _makeChart();
    final proj = chart.projections[0];

    // With identity transformation, displayed = raw + recenterAdjust; point 0 is at raw (0,0) so its displayed
    // position equals the recenter adjustment.
    final adjust = proj.transformedLayout()[0]!;

    final dropAt = Vector3(5.0, 5.0, 0.0);
    proj.moveTransformedPoint(1, dropAt);

    final expectedRaw = dropAt - adjust;
    final exported = _exportedLayoutPoint(chart, 1);
    expect(exported[0], closeTo(expectedRaw.x, 1e-9));
    expect(exported[1], closeTo(expectedRaw.y, 1e-9));

    // The on-screen (transformed) position must now be where it was dropped.
    expect(proj.transformedLayout()[1]!.x, closeTo(dropAt.x, 1e-9));
    expect(proj.transformedLayout()[1]!.y, closeTo(dropAt.y, 1e-9));

    // Untouched points keep their original exported coords.
    expect(_exportedLayoutPoint(chart, 0), [0.0, 0.0]);
    expect(_exportedLayoutPoint(chart, 2), [0.0, 3.0]);
  });

  test('move with a y-flip transformation round-trips through the transformation', () {
    // "t":[1,0,0,-1] (column-major) flips y: (x,y) -> (x,-y).
    final chart = _makeChart(transformation: [1.0, 0.0, 0.0, -1.0]);
    final proj = chart.projections[0];

    const ref = 0, moved = 2;
    final dRef = proj.transformedLayout()[ref]!;
    final dMoved = proj.transformedLayout()[moved]!;

    final dropAt = dMoved + Vector3(1.0, 1.0, 0.0);
    proj.moveTransformedPoint(moved, dropAt);

    // Apply the projection transformation to the exported raw coords and check the moved-vs-reference offset
    // matches the dropped-vs-reference offset (the constant recenter adjustment cancels in the difference).
    Vector3 transformed(List<double> raw) => Vector3(raw[0], -raw[1], 0.0);
    final trMoved = transformed(_exportedLayoutPoint(chart, moved));
    final trRef = transformed(_exportedLayoutPoint(chart, ref));

    expect((trMoved.x - trRef.x), closeTo(dropAt.x - dRef.x, 1e-9));
    expect((trMoved.y - trRef.y), closeTo(dropAt.y - dRef.y, 1e-9));
  });

  test('resetMovedPoints restores original coordinates', () {
    final chart = _makeChart(transformation: [1.0, 0.0, 0.0, -1.0]);
    final proj = chart.projections[0];

    final originalRaw1 = _exportedLayoutPoint(chart, 1);
    final originalDisplayed1 = Vector3.copy(proj.transformedLayout()[1]!);

    proj.moveTransformedPoint(1, Vector3(9.0, -4.0, 0.0));
    proj.moveTransformedPoint(3, Vector3(-1.0, 7.0, 0.0));
    expect(_exportedLayoutPoint(chart, 1), isNot(orderedEquals(originalRaw1)));

    proj.resetMovedPoints();

    final restored1 = _exportedLayoutPoint(chart, 1);
    expect(restored1[0], closeTo(originalRaw1[0], 1e-9));
    expect(restored1[1], closeTo(originalRaw1[1], 1e-9));
    expect(proj.transformedLayout()[1]!.x, closeTo(originalDisplayed1.x, 1e-9));
    expect(proj.transformedLayout()[1]!.y, closeTo(originalDisplayed1.y, 1e-9));
  });
}
