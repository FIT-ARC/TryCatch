import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_common.dart';
import 'package:trycatch/ui/tiles/shared/sat_flight_painter.dart';
import 'package:trycatch/ui/tiles/shared/satellite_ground.dart';
import 'package:trycatch/ui/tiles/shared/slippy_math.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

/// Headless render tests for the 3D satellite drape: synthetic imagery +
/// DEM are pumped through the real [SatFlightPainter] and the resulting
/// pixels are measured. These lock coverage (the tile must actually paint
/// imagery, not mostly far-terrain fallback) and frame-to-frame stability
/// (a micro camera move must not flip the image like ocean waves).
void main() {
  const lat0 = 49.8;
  const lon0 = 16.69;

  FlightAnchor anchor() =>
      FlightAnchor(lat: lat0, lon: lon0, groundMsl: 400);

  FlightScene sceneOf(Vector3 rocket, {String? siteName = 'test'}) =>
      FlightScene(
        trail: [Vector3.zero(), Vector3(50, 30, -40), rocket],
        rocketPos: rocket,
        rocketIsDeadReckoning: false,
        maxAlt: 500,
        maxHoriz: 300,
        pitchDeg: 0,
        yawDeg: 0,
        rollDeg: 0,
        showNoseCone: true,
        showParachute: false,
        siteName: siteName,
      );

  Future<ui.Image> makeImage(int w, int h) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    // Diagonal gradient: any UV smear or seam shows as color error.
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()
        ..shader = ui.Gradient.linear(
          const ui.Offset(0, 0),
          ui.Offset(w.toDouble(), h.toDouble()),
          const [ui.Color(0xFF3A7D2C), ui.Color(0xFFB8A24A)],
        ),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    picture.dispose();
    return image;
  }

  ElevationGrid makeDem() {
    const n = 8;
    final heights = Float32List(n * n);
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        // Gentle slope + ridge, ±40 m around the 400 m datum.
        heights[j * n + i] =
            400 + 30 * (i / (n - 1)) + 10 * (j / (n - 1));
      }
    }
    return ElevationGrid(
      northLat: 50.0,
      southLat: 49.6,
      westLon: 16.4,
      eastLon: 17.0,
      datumMsl: 400,
      cols: n,
      rows: n,
      heights: heights,
      normals: ElevationGrid.buildNormals(
        heights: heights,
        cols: n,
        rows: n,
        northLat: 50.0,
        southLat: 49.6,
        westLon: 16.4,
        eastLon: 17.0,
      ),
    );
  }

  SatelliteTerrain makeTerrain(ui.Image image) {
    final patch = SatellitePatch(
      image: image,
      northLat: 49.85,
      southLat: 49.75,
      westLon: 16.64,
      eastLon: 16.74,
      coverageHalfMeters: 3500,
      averageColor: const ui.Color(0xFF6E7F56),
    );
    return SatelliteTerrain(outer: patch, mid: patch, dem: makeDem());
  }

  Future<Uint8List> renderPixels(
    WidgetTester tester,
    SatFlightPainter painter,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 800,
            height: 600,
            child: CustomPaint(painter: painter),
          ),
        ),
      ),
    );
    await tester.pump();
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image =
        (await tester.runAsync(() => boundary.toImage()))!;
    final data = (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    final bytes = data.buffer.asUint8List();
    image.dispose();
    return bytes;
  }

  SatFlightPainter painterFor({
    required FlightScene scene,
    required SatelliteTerrain? terrain,
    FlightCameraMode mode = FlightCameraMode.orbit,
    double azimuthDeg = 30,
    double elevationDeg = 45,
    double zoom = 1,
  }) {
    final a = anchor();
    return SatFlightPainter(
      scene: scene,
      lens: OrbitLens(
        mode: mode,
        azimuthDeg: azimuthDeg,
        elevationDeg: elevationDeg,
        zoom: zoom,
      ),
      terrain: terrain,
      meshes: terrain == null
          ? null
          : buildTerrainMeshes(terrain,
              lat0: a.lat, lon0: a.lon, cosLat0: a.cosLat),
      anchor: a,
    );
  }

  /// Imagery mask: pixels the drape actually paints (vs plain fallback).
  Uint8List maskFor(Uint8List img, Uint8List plain) {
    const total = 800 * 600;
    final mask = Uint8List(total);
    for (var i = 0; i < total; i++) {
      var dd = 0;
      for (var c = 0; c < 3; c++) {
        dd += (img[i * 4 + c] - plain[i * 4 + c]).abs();
      }
      mask[i] = dd > 24 ? 1 : 0;
    }
    return mask;
  }

  testWidgets('drape covers the view (no postage-stamp terrain)',
      (tester) async {
    final image = await makeImage(256, 256);
    try {
      final scene = sceneOf(Vector3(100, 200, -80));
      final withTerrain = await renderPixels(
          tester, painterFor(scene: scene, terrain: makeTerrain(image)));
      final withoutTerrain =
          await renderPixels(tester, painterFor(scene: scene, terrain: null));
      var different = 0;
      const total = 800 * 600;
      for (var i = 0; i < total; i++) {
        final dr = (withTerrain[i * 4] - withoutTerrain[i * 4]).abs();
        final dg =
            (withTerrain[i * 4 + 1] - withoutTerrain[i * 4 + 1]).abs();
        final db =
            (withTerrain[i * 4 + 2] - withoutTerrain[i * 4 + 2]).abs();
        if (dr + dg + db > 24) different++;
      }
      debugPrint('imagery-influenced fraction: ${different / total}');
      expect(different / total, greaterThan(0.35));
    } finally {
      image.dispose();
    }
  });

  testWidgets('probe matrix across angles and zooms', (tester) async {
    final image = await makeImage(256, 256);
    try {
      final scene = sceneOf(Vector3(100, 200, -80));
      for (final el in [8.0, 20.0, 45.0, 70.0]) {
        for (final zoom in [0.3, 1.0, 3.0]) {
          final a = await renderPixels(
              tester,
              painterFor(
                  scene: scene,
                  terrain: makeTerrain(image),
                  elevationDeg: el,
                  zoom: zoom));
          final b = await renderPixels(
              tester,
              painterFor(
                  scene: scene,
                  terrain: makeTerrain(image),
                  elevationDeg: el + 0.3,
                  zoom: zoom));
          final plain = await renderPixels(
              tester,
              painterFor(
                  scene: scene, terrain: null, elevationDeg: el, zoom: zoom));
          var different = 0;
          var absSum = 0;
          var flipped = 0;
          const total = 800 * 600;
          for (var i = 0; i < total; i++) {
            var dd = 0;
            var px = 0;
            for (var c = 0; c < 3; c++) {
              dd += (a[i * 4 + c] - plain[i * 4 + c]).abs();
              px += (a[i * 4 + c] - b[i * 4 + c]).abs();
            }
            if (dd > 24) different++;
            absSum += px;
            if (px > 150) flipped++;
          }
          debugPrint('el=$el zoom=$zoom imagery=${(different / total).toStringAsFixed(3)} '
              'meanDiff=${(absSum / total / 3).toStringAsFixed(3)} flipped=${(flipped / total).toStringAsFixed(4)}');
          // The drape must cover the view at every angle/zoom — never a
          // postage stamp of imagery in a far-terrain void.
          expect(different / total, greaterThan(0.3));
        }
      }
    } finally {
      image.dispose();
    }
  });

  testWidgets('drape interior stays stable across micro camera moves',
      (tester) async {
    // Outer and mid tiers with DIFFERENT imagery (like real fetches at
    // different zooms) + bumpy DEM: a 0.4° move must not hard-flip any
    // drape pixel away from boundaries (the ocean-wobble signature).
    // Overlay pixels (rocket/trail/drop/shadow) and the horizon sweep
    // are excluded by construction; they legitimately move.
    Future<ui.Image> bandImage(List<int> stops) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 256, 256),
        ui.Paint()
          ..shader = ui.Gradient.linear(
            const ui.Offset(0, 0),
            const ui.Offset(256, 256),
            [ui.Color(stops[0]), ui.Color(stops[1])],
          ),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(256, 256);
      picture.dispose();
      return image;
    }

    ElevationGrid bumpyDem() {
      const n = 32;
      final heights = Float32List(n * n);
      for (var j = 0; j < n; j++) {
        for (var i = 0; i < n; i++) {
          // ~500 m wavelength ridges, ±60 m.
          heights[j * n + i] = 400 +
              60 *
                  (0.6 +
                      0.4 *
                          (math.sin(i * 2.4) * math.cos(j * 1.7)));
        }
      }
      return ElevationGrid(
        northLat: 50.0,
        southLat: 49.6,
        westLon: 16.4,
        eastLon: 17.0,
        datumMsl: 400,
        cols: n,
        rows: n,
        heights: heights,
        normals: ElevationGrid.buildNormals(
          heights: heights,
          cols: n,
          rows: n,
          northLat: 50.0,
          southLat: 49.6,
          westLon: 16.4,
          eastLon: 17.0,
        ),
      );
    }

    final outerImg = await bandImage([0xFF3A7D2C, 0xFFB8A24A]);
    final midImg = await bandImage([0xFF7D3A2C, 0xFF4A7DB8]);
    try {
      Future<void> wobble(
        String name,
        SatelliteTerrain terrain, {
        FlightCameraMode mode = FlightCameraMode.orbit,
        FlightScene? sceneOverride,
        List<double> els = const [10.0, 45.0],
        double azimuthDeg = 30,
        double minBottomCoverage = 0,
      }) async {
        // No site flag/label: only drape + trail/rocket/drop overlays draw,
        // and those are geometrically excluded below.
        final scene =
            sceneOverride ?? sceneOf(Vector3(100, 200, -80), siteName: null);
        for (final el in els) {
          // Rocket pixels move between frames by construction — exclude a
          // box around the airframe in both frames so only drape pixels
          // are measured.
          FlightCamera camFor(double e) => computeFlightCamera(
                scene: scene,
                mode: mode,
                azimuthDeg: azimuthDeg,
                elevationDeg: e,
                zoom: 1,
                aspect: 800 / 600,
              );
          final rA = projectToScreen(
              scene.rocketPos, camFor(el).vp, const Size(800, 600));
          final rB = projectToScreen(
              scene.rocketPos, camFor(el + 0.4).vp, const Size(800, 600));
          // Trail + drop line + shadow pixels move between frames by
          // construction — exclude bands around them too, replicating the
          // painter's own geometry.
          List<Offset?> segmentFor(
              FlightCamera cam, Vector3 from, Vector3 to) => [
                projectToScreen(from, cam.vp, const Size(800, 600)),
                projectToScreen(to, cam.vp, const Size(800, 600)),
              ];
          List<List<Offset?>> overlaySegments(
              FlightCamera cam, SatelliteTerrain tr) {
            final segs = <List<Offset?>>[];
            // The painter clamps the trail to the DEM surface first.
            Vector3 clampP(Vector3 p) {
              final dem = tr.dem;
              final s = dem == null
                  ? 0.0
                  : dem.sampleRel(p.x, p.z, lat0, lon0,
                      math.cos(lat0 * math.pi / 180));
              return s > p.y ? Vector3(p.x, s, p.z) : p;
            }

            final trail = [for (final p in scene.trail) clampP(p)];
            for (var k = 1; k < trail.length; k++) {
              segs.add(segmentFor(cam, trail[k - 1], trail[k]));
            }
            final dem = tr.dem;
            final surf = dem == null
                ? 0.0
                : dem.sampleRel(scene.rocketPos.x, scene.rocketPos.z,
                    lat0, lon0, math.cos(lat0 * math.pi / 180));
            final clamped = surf > scene.rocketPos.y
                ? Vector3(
                    scene.rocketPos.x, surf, scene.rocketPos.z)
                : scene.rocketPos;
            final mesh = cgAnchorPos(
              rocketPos: clamped,
              pitchDeg: 0,
              yawDeg: 0,
              scale: 0.8 / 2.15,
              groundY: surf,
            );
            segs.add(segmentFor(cam, mesh,
                Vector3(clamped.x, surf, clamped.z)));
            return segs;
          }

          final segsA = overlaySegments(camFor(el), terrain);
          final segsB = overlaySegments(camFor(el + 0.4), terrain);
          // Shadow disk centres (1.2 m radius) in both frames.
          List<Offset?> shadowFor(FlightCamera cam) {
            final dem = terrain.dem;
            final surf = dem == null
                ? 0.0
                : dem.sampleRel(scene.rocketPos.x, scene.rocketPos.z,
                    lat0, lon0, math.cos(lat0 * math.pi / 180));
            final sy = surf > scene.rocketPos.y
                ? surf
                : scene.rocketPos.y;
            return [
              projectToScreen(
                  Vector3(scene.rocketPos.x, sy + 0.05, scene.rocketPos.z),
                  cam.vp,
                  const Size(800, 600)),
            ];
          }

          final shA = shadowFor(camFor(el));
          final shB = shadowFor(camFor(el + 0.4));
          bool nearOverlay(int x, int y) {
            for (final r in [rA, rB, ...shA, ...shB]) {
              if (r == null) continue;
              if ((x - r.dx).abs() < 8 && (y - r.dy).abs() < 8) {
                return true;
              }
            }
            for (final r in [rA, rB]) {
              if (r == null) continue;
              if ((x - r.dx).abs() < 40 && (y - r.dy).abs() < 40) {
                return true;
              }
            }
            final p = Offset(x.toDouble(), y.toDouble());
            for (final seg in [...segsA, ...segsB]) {
              for (var k = 1; k < seg.length; k++) {
                final a = seg[k - 1];
                final b = seg[k];
                if (a == null || b == null) continue;
                final abx = b.dx - a.dx;
                final aby = b.dy - a.dy;
                final len2 = abx * abx + aby * aby;
                if (len2 < 1e-12) continue;
                final tt = (((p.dx - a.dx) * abx + (p.dy - a.dy) * aby) /
                        len2)
                    .clamp(0.0, 1.0);
                final dx = p.dx - (a.dx + abx * tt);
                final dy = p.dy - (a.dy + aby * tt);
                if (dx * dx + dy * dy < 36) return true;
              }
            }
            return false;
          }
          final a = await renderPixels(
              tester,
              painterFor(
                  scene: scene,
                  terrain: terrain,
                  mode: mode,
                  azimuthDeg: azimuthDeg,
                  elevationDeg: el));
          final b = await renderPixels(
              tester,
              painterFor(
                  scene: scene,
                  terrain: terrain,
                  mode: mode,
                  azimuthDeg: azimuthDeg,
                  elevationDeg: el + 0.4));
          final plain = await renderPixels(
              tester,
              painterFor(
                  scene: scene,
                  terrain: null,
                  mode: mode,
                  azimuthDeg: azimuthDeg,
                  elevationDeg: el));
          final maskA = maskFor(a, plain);
          final maskB = maskFor(b, plain);
          var interiorFlips = 0;
          var interior = 0;
          final flipSpots = <String>[];
          const w = 800;
          for (var y = 3; y < 600 - 3; y++) {
            for (var x = 3; x < 800 - 3; x++) {
              if (nearOverlay(x, y)) continue;
              final i = y * w + x;
              var full = true;
              for (var dy = -3; dy <= 3 && full; dy++) {
                for (var dx = -3; dx <= 3; dx++) {
                  final j = i + dy * w + dx;
                  if (maskA[j] == 0 || maskB[j] == 0) {
                    full = false;
                    break;
                  }
                }
              }
              if (!full) continue;
              interior++;
              var px = 0;
              for (var c = 0; c < 3; c++) {
                px += (a[i * 4 + c] - b[i * 4 + c]).abs();
              }
              if (px > 150) {
                interiorFlips++;
                if (flipSpots.length < 8) {
                  flipSpots.add('($x,$y):'
                      'a=${a[i * 4]},${a[i * 4 + 1]},${a[i * 4 + 2]} '
                      'b=${b[i * 4]},${b[i * 4 + 1]},${b[i * 4 + 2]}');
                }
              }
            }
          }
          var bottomCovered = 0;
          var bottomTotal = 0;
          for (var y = 300; y < 600; y += 2) {
            for (var x = 0; x < 800; x += 2) {
              bottomTotal++;
              if (maskA[y * w + x] == 1) bottomCovered++;
            }
          }
          final bottomFrac = bottomCovered / bottomTotal;
          debugPrint('$name el=$el interior=$interior interiorFlips=$interiorFlips '
              'bottom=$bottomFrac $flipSpots');
          // Away from boundaries the drape is a smooth function of the
          // camera: a micro move must never hard-flip interior pixels
          // (the ocean-wobble signature). Boundary sweeps (horizon) are
          // excluded by the 7x7 fully-covered mask.
          expect(interior, greaterThan(100000));
          expect(interiorFlips, 0);
          // Foreground must stay covered: clipped (not dropped) hillsides
          // keep painting right up to the lens.
          expect(bottomFrac, greaterThan(minBottomCoverage));
        }
      }

      final outerPatch = SatellitePatch(
        image: outerImg,
        northLat: 49.85,
        southLat: 49.75,
        westLon: 16.64,
        eastLon: 16.74,
        coverageHalfMeters: 3500,
        averageColor: const ui.Color(0xFF6E7F56),
      );
      final midPatch = SatellitePatch(
        image: midImg,
        northLat: 49.82,
        southLat: 49.78,
        westLon: 16.67,
        eastLon: 16.71,
        coverageHalfMeters: 1500,
        averageColor: const ui.Color(0xFF6E7F56),
      );
      ElevationGrid microDem() {
        const n = 16;
        final heights = Float32List(n * n);
        for (var j = 0; j < n; j++) {
          for (var i = 0; i < n; i++) {
            // Sub-metre undulation: the old lift epsilon gate flipped
            // these pixels between two screen anchors across frames.
            heights[j * n + i] =
                400 + 0.3 * math.sin(i * 1.3) * math.cos(j * 0.9);
          }
        }
        return ElevationGrid(
          northLat: 50.0,
          southLat: 49.6,
          westLon: 16.4,
          eastLon: 17.0,
          datumMsl: 400,
          cols: n,
          rows: n,
          heights: heights,
          normals: ElevationGrid.buildNormals(
            heights: heights,
            cols: n,
            rows: n,
            northLat: 50.0,
            southLat: 49.6,
            westLon: 16.4,
            eastLon: 17.0,
          ),
        );
      }

      await wobble('bumpy two-tier',
          SatelliteTerrain(outer: outerPatch, mid: midPatch, dem: bumpyDem()));
      await wobble('flat two-tier',
          SatelliteTerrain(outer: outerPatch, mid: midPatch));
      await wobble('bumpy single-tier',
          SatelliteTerrain(outer: outerPatch, dem: bumpyDem()));
      await wobble('micro-relief single-tier',
          SatelliteTerrain(outer: outerPatch, dem: microDem()));
    } finally {
      outerImg.dispose();
      midImg.dispose();
    }
  });

  testWidgets('foreground ridge never punches holes', (tester) async {
    // A 120 m wall directly ahead of a low chase camera: lifted apices
    // land behind the lens. The old code dropped those nodes (subdivide
    // + discard) and punched flickering holes through the mountainside;
    // clip-space triangles must keep it covered instead.
    ElevationGrid ridgeDem() {
      const n = 32;
      const dLat = 0.0005;
      const dLon = 0.0007;
      final heights = Float32List(n * n);
      double smooth(double t) {
        final c = t.clamp(0.0, 1.0);
        return c * c * (3 - 2 * c);
      }

      for (var j = 0; j < n; j++) {
        final southM = ((j / (n - 1)) - 0.5) * 2 * dLat * 111320;
        for (var i = 0; i < n; i++) {
          final eastM = ((i / (n - 1)) - 0.5) *
              2 *
              dLon *
              111320 *
              math.cos(lat0 * math.pi / 180);
          final ex = smooth((7 - eastM.abs()) / 3);
          final sz = smooth((southM - 30.5) / 1) *
              smooth((36.5 - southM) / 1);
          heights[j * n + i] = 120 * ex * sz;
        }
      }
      return ElevationGrid(
        northLat: lat0 + dLat,
        southLat: lat0 - dLat,
        westLon: lon0 - dLon,
        eastLon: lon0 + dLon,
        datumMsl: 0,
        cols: n,
        rows: n,
        heights: heights,
        normals: ElevationGrid.buildNormals(
          heights: heights,
          cols: n,
          rows: n,
          northLat: lat0 + dLat,
          southLat: lat0 - dLat,
          westLon: lon0 - dLon,
          eastLon: lon0 + dLon,
        ),
      );
    }

    final image = await makeImage(256, 256);
    try {
      final patch = SatellitePatch(
        image: image,
        northLat: lat0 + 0.001,
        southLat: lat0 - 0.001,
        westLon: lon0 - 0.001,
        eastLon: lon0 + 0.001,
        coverageHalfMeters: 60,
        averageColor: const ui.Color(0xFF6E7F56),
      );
      final terrain = SatelliteTerrain(outer: patch, dem: ridgeDem());
      // Rocket 30 m north of the pad, chase lens 7 m behind at 6° — the
      // wall (z 30.5–36.5) fills the foreground between lens and rocket.
      final scene =
          sceneOf(Vector3(0, 8, 30), siteName: null);
      Future<Uint8List> render(double el) => renderPixels(
          tester,
          painterFor(
              scene: scene,
              terrain: terrain,
              mode: FlightCameraMode.chase,
              azimuthDeg: 0,
              elevationDeg: el));
      final a = await render(6.0);
      final b = await render(6.4);
      final plain = await renderPixels(
          tester,
          painterFor(
              scene: scene,
              terrain: null,
              mode: FlightCameraMode.chase,
              azimuthDeg: 0,
              elevationDeg: 6.0));
      final maskA = maskFor(a, plain);
      var covered = 0;
      var total = 0;
      for (var y = 300; y < 600; y += 2) {
        for (var x = 0; x < 800; x += 2) {
          total++;
          if (maskA[y * 800 + x] == 1) covered++;
        }
      }
      final frac = covered / total;
      debugPrint('ridge bottom coverage: $frac');
      // The wall apex sits behind the lens: pre-fix code dropped these
      // nodes (subdivide + discard) and punched holes, so this assertion
      // is what makes the coverage check meaningful.
      final cam = computeFlightCamera(
        scene: scene,
        mode: FlightCameraMode.chase,
        azimuthDeg: 0,
        elevationDeg: 6,
        zoom: 1,
        aspect: 800 / 600,
      );
      final apex = cam.vp.transformed(Vector4(0, 120, 33, 1));
      expect(apex.w, lessThanOrEqualTo(0));
      expect(frac, greaterThan(0.5));
      // And the wall must not flip between the two micro frames.
      final maskB = maskFor(b, plain);
      var flips = 0;
      for (var y = 3; y < 600 - 3; y++) {
        for (var x = 3; x < 800 - 3; x++) {
          final i = y * 800 + x;
          var full = true;
          for (var dy = -3; dy <= 3 && full; dy++) {
            for (var dx = -3; dx <= 3; dx++) {
              final j = i + dy * 800 + dx;
              if (maskA[j] == 0 || maskB[j] == 0) {
                full = false;
                break;
              }
            }
          }
          if (!full) continue;
          var px = 0;
          for (var c = 0; c < 3; c++) {
            px += (a[i * 4 + c] - b[i * 4 + c]).abs();
          }
          if (px > 150) flips++;
        }
      }
      debugPrint('ridge interior flips: $flips');
      // A depth discontinuity (wall silhouette) legitimately reassigns a
      // few pixels on any camera move — correct occlusion change, not a
      // pop. Ocean-scale flicker would be thousands.
      expect(flips, lessThanOrEqualTo(32));
    } finally {
      image.dispose();
    }
  });

  testWidgets('hillside beside the lens never streaks the sky',
      (tester) async {
    // A tall wall beside (not containing) a low chase lens: the wall may
    // legitimately cover the frame side it stands on, but near-plane
    // slivers must never smear across the open sky on the other side
    // (the field-report wedge signature).
    ElevationGrid wallDem() {
      const n = 32;
      const dLat = 0.0006;
      const dLon = 0.001;
      final heights = Float32List(n * n);
      double smooth(double t) {
        final c = t.clamp(0.0, 1.0);
        return c * c * (3 - 2 * c);
      }

      for (var j = 0; j < n; j++) {
        for (var i = 0; i < n; i++) {
          final eastM = ((i / (n - 1)) - 0.5) *
              2 *
              dLon *
              111320 *
              math.cos(lat0 * math.pi / 180);
          // Flat pad apron with a 100 m wall rising east of the camera
          // (right of frame looking north).
          heights[j * n + i] = 100 * smooth((eastM - 30) / 10);
        }
      }
      return ElevationGrid(
        northLat: lat0 + dLat,
        southLat: lat0 - dLat,
        westLon: lon0 - dLon,
        eastLon: lon0 + dLon,
        datumMsl: 0,
        cols: n,
        rows: n,
        heights: heights,
        normals: ElevationGrid.buildNormals(
          heights: heights,
          cols: n,
          rows: n,
          northLat: lat0 + dLat,
          southLat: lat0 - dLat,
          westLon: lon0 - dLon,
          eastLon: lon0 + dLon,
        ),
      );
    }

    Future<ui.Image> bandImage(List<int> stops) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 256, 256),
        ui.Paint()
          ..shader = ui.Gradient.linear(
            const ui.Offset(0, 0),
            const ui.Offset(256, 256),
            [ui.Color(stops[0]), ui.Color(stops[1])],
          ),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(256, 256);
      picture.dispose();
      return image;
    }

    final outerImg = await bandImage([0xFF3A7D2C, 0xFFB8A24A]);
    final midImg = await bandImage([0xFF7D3A2C, 0xFF4A7DB8]);
    final padImg = await bandImage([0xFF2C5A7D, 0xFFA24AB8]);
    try {
      SatellitePatch tier(ui.Image img) => SatellitePatch(
            image: img,
            northLat: lat0 + 0.001,
            southLat: lat0 - 0.001,
            westLon: lon0 - 0.001,
            eastLon: lon0 + 0.001,
            coverageHalfMeters: 3500,
            averageColor: const ui.Color(0xFF6E7F56),
          );
      final terrain = SatelliteTerrain(
          outer: tier(outerImg), mid: tier(midImg), pad: tier(padImg),
          dem: wallDem());
      // Low flight over the flat apron, wall well clear of the lens:
      // nothing above eye level west of the camera. Empty trail keeps the
      // top rows pure sky in the reference render.
      final scene = FlightScene(
        trail: const [],
        rocketPos: Vector3(0, 5, 20),
        rocketIsDeadReckoning: false,
        maxAlt: 50,
        maxHoriz: 60,
        pitchDeg: 0,
        yawDeg: 0,
        rollDeg: 0,
        showNoseCone: true,
        showParachute: false,
        siteName: null,
      );
      Future<Uint8List> render(double el) => renderPixels(
          tester,
          painterFor(
              scene: scene,
              terrain: terrain,
              mode: FlightCameraMode.chase,
              azimuthDeg: 0,
              elevationDeg: el));
      final a = await render(4.0);
      final plain = await renderPixels(
          tester,
          painterFor(
              scene: scene,
              terrain: null,
              mode: FlightCameraMode.chase,
              azimuthDeg: 0,
              elevationDeg: 4.0));

      double region(Uint8List img, int x0, int x1, [int y0 = 0, int y1 = 120]) {
        var contaminated = 0;
        var total = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            total++;
            final i = y * 800 + x;
            var px = 0;
            for (var c = 0; c < 3; c++) {
              px += (img[i * 4 + c] - plain[i * 4 + c]).abs();
            }
            if (px > 150) contaminated++;
          }
        }
        return contaminated / total;
      }

      // The wall legitimately covers the mid-right (guards a vacuous pass
      // where relief renders nothing at all).
      final wallFrac = region(a, 450, 800, 150, 450);
      debugPrint('wall coverage: $wallFrac');
      expect(wallFrac, greaterThan(0.2));

      // A 0.15° nudge must not hard-flip drape pixels: near-plane slivers
      // escaping the clip (the streak signature) sweep wildly between
      // frames, while real hillsides — however steep — stay put. Like the
      // wobble test, only fully drape-covered interior pixels count, so
      // silhouette sweeps and overlays can't trip it.
      final b = await render(4.15);
      final maskA = maskFor(a, plain);
      final maskB = maskFor(b, plain);
      var flips = 0;
      var interior = 0;
      for (var y = 3; y < 600 - 3; y++) {
        for (var x = 3; x < 800 - 3; x++) {
          final i = y * 800 + x;
          var full = true;
          for (var dy = -3; dy <= 3 && full; dy++) {
            for (var dx = -3; dx <= 3; dx++) {
              final j = i + dy * 800 + dx;
              if (maskA[j] == 0 || maskB[j] == 0) {
                full = false;
                break;
              }
            }
          }
          if (!full) continue;
          interior++;
          var px = 0;
          for (var c = 0; c < 3; c++) {
            px += (a[i * 4 + c] - b[i * 4 + c]).abs();
          }
          if (px > 150) flips++;
        }
      }
      debugPrint('wall-scene interior=$interior flips=$flips');
      expect(interior, greaterThan(100000));
      // Same order as the ridge test's allowance: a clip escape would flip
      // thousands here (streaks sweep disproportionately), real hillsides
      // only shimmer at warp seams.
      expect(flips, lessThanOrEqualTo(64));
    } finally {
      outerImg.dispose();
      midImg.dispose();
      padImg.dispose();
    }
  });

  testWidgets('close chase: texture error converges with density',
      (tester) async {
    // Static world meshes interpolate UVs affinely per triangle; near a
    // low chase camera those triangles project large. Rendering the same
    // scene with a 4×-denser pad mesh must barely differ — otherwise the
    // tiers are too coarse and close-up imagery would swim.
    ElevationGrid rollingDem() {
      const n = 32;
      const d = 0.01;
      final heights = Float32List(n * n);
      for (var j = 0; j < n; j++) {
        for (var i = 0; i < n; i++) {
          heights[j * n + i] =
              40 * math.sin(i * 0.9) * math.cos(j * 0.7);
        }
      }
      return ElevationGrid(
        northLat: lat0 + d,
        southLat: lat0 - d,
        westLon: lon0 - d,
        eastLon: lon0 + d,
        datumMsl: 0,
        cols: n,
        rows: n,
        heights: heights,
        normals: ElevationGrid.buildNormals(
          heights: heights,
          cols: n,
          rows: n,
          northLat: lat0 + d,
          southLat: lat0 - d,
          westLon: lon0 - d,
          eastLon: lon0 + d,
        ),
      );
    }

    Future<ui.Image> checkerImage() async {
      // Broadband pattern (seeded random blocks at two scales): a single
      // frequency would alias against mesh cells at harmonic ratios and
      // make the sweep non-monotonic for artefactual reasons.
      const s = 512;
      final rng = math.Random(42);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, s.toDouble(), s.toDouble()),
        ui.Paint()..color = const ui.Color(0xFF3A5A30),
      );
      for (var j = 0; j < s ~/ 8; j++) {
        for (var i = 0; i < s ~/ 8; i++) {
          final v = rng.nextInt(3);
          if (v == 0) continue;
          canvas.drawRect(
            ui.Rect.fromLTWH(i * 8.0, j * 8.0, 8, 8),
            ui.Paint()
              ..color = v == 1
                  ? const ui.Color(0xFFC2B280)
                  : const ui.Color(0xFF1E3A22),
          );
        }
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(s, s);
      picture.dispose();
      return image;
    }

    final image = await checkerImage();
    try {
      final a = anchor();
      final patch = SatellitePatch(
        image: image,
        northLat: lat0 + 0.01,
        southLat: lat0 - 0.01,
        westLon: lon0 - 0.01,
        eastLon: lon0 + 0.01,
        coverageHalfMeters: 1250,
        averageColor: const ui.Color(0xFF6E7F56),
      );
      final dem = rollingDem();
      TerrainMesh padAt(int res) => buildTerrainMesh(
            northLat: patch.northLat,
            southLat: patch.southLat,
            westLon: patch.westLon,
            eastLon: patch.eastLon,
            imgW: 512,
            imgH: 512,
            coverageHalfMeters: patch.coverageHalfMeters,
            dem: dem,
            lat0: a.lat,
            lon0: a.lon,
            cosLat0: a.cosLat,
            halfMeters: satPadHalfMeters,
            resolution: res,
          );
      final scene = sceneOf(Vector3(0, 10, 100), siteName: null);
      Future<Uint8List> renderWith(TerrainMesh pad) => renderPixels(
          tester,
          SatFlightPainter(
            scene: scene,
            lens: const OrbitLens(
              mode: FlightCameraMode.chase,
              azimuthDeg: 0,
              elevationDeg: 8,
              zoom: 1,
            ),
            terrain:
                SatelliteTerrain(outer: patch, pad: patch, dem: dem),
            meshes: (
              outer: buildTerrainMesh(
                northLat: patch.northLat,
                southLat: patch.southLat,
                westLon: patch.westLon,
                eastLon: patch.eastLon,
                imgW: 512,
                imgH: 512,
                coverageHalfMeters: patch.coverageHalfMeters,
                dem: dem,
                lat0: a.lat,
                lon0: a.lon,
                cosLat0: a.cosLat,
                halfMeters: satPadHalfMeters,
                resolution: satMeshOuterRes,
              ),
              mid: null,
              pad: pad,
              padLo: null,
            ),
            anchor: a,
          ));
      // Production density vs a 4×-denser reference: tessellation only
      // changes near-lens clip fans and subpixel rasterization, so the
      // frames must agree broadly (a swapped-winding or broken-UV
      // tessellation would diverge catastrophically, not by single px).
      final hi = await renderWith(padAt(640));
      final lo = await renderWith(padAt(satMeshPadRes));
      var absSum = 0;
      var worst = 0;
      const total = 800 * 600;
      for (var i = 0; i < total; i++) {
        var px = 0;
        for (var c = 0; c < 3; c++) {
          px += (lo[i * 4 + c] - hi[i * 4 + c]).abs();
        }
        absSum += px;
        if (px > worst) worst = px;
      }
      final mean = absSum / total / 3;
      debugPrint('smear mean=${mean.toStringAsFixed(3)} worst=$worst');
      expect(mean, lessThan(10.0));
    } finally {
      image.dispose();
    }
  });

  testWidgets('micro camera move keeps the frame stable', (tester) async {
    final image = await makeImage(256, 256);
    try {
      final scene = sceneOf(Vector3(100, 200, -80));
      final a = await renderPixels(
          tester, painterFor(scene: scene, terrain: makeTerrain(image)));
      final b = await renderPixels(
          tester,
          painterFor(
              scene: scene,
              terrain: makeTerrain(image),
              azimuthDeg: 30.4,
              elevationDeg: 45.2));
      var absSum = 0;
      var flipped = 0;
      const total = 800 * 600;
      for (var i = 0; i < total; i++) {
        var px = 0;
        for (var c = 0; c < 3; c++) {
          px += (a[i * 4 + c] - b[i * 4 + c]).abs();
        }
        absSum += px;
        if (px > 150) flipped++;
      }
      debugPrint('mean abs diff/px: ${absSum / total / 3}');
      debugPrint('flipped fraction: ${flipped / total}');
      expect(absSum / total / 3, lessThan(12.0));
      expect(flipped / total, lessThan(0.05));
    } finally {
      image.dispose();
    }
  });
}
