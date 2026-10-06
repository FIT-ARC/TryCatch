import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dead_reckoning/dead_reckoning.dart' show metresPerDegreeLat;
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/core/elevation_math.dart' show terrariumHeight;
import 'package:trycatch/state/launch_site_store.dart' show LaunchSite;
import 'package:trycatch/ui/tiles/shared/satellite_ground.dart';
import 'package:trycatch/ui/tiles/shared/slippy_math.dart';

void main() {
  group('slippy tile math', () {
    test('tile contains its source point', () {
      for (final (lat, lon, zoom) in [
        (50.0755, 14.4378, 15), // Prague
        (0.0, 0.0, 10),
        (-33.8688, 151.2093, 12), // Sydney
        (40.7128, -74.0060, 16), // New York
      ]) {
        final x = satTileX(lon, zoom);
        final y = satTileY(lat, zoom);
        final west = satTileLonWest(x, zoom);
        final east = satTileLonWest(x + 1, zoom);
        final north = satTileLatNorth(y, zoom);
        final south = satTileLatNorth(y + 1, zoom);
        expect(lon, inInclusiveRange(west, east));
        expect(lat, inInclusiveRange(south, north));
      }
    });

    test('tile X wraps longitude, Y clamps latitude', () {
      final n = 1 << 12;
      expect(satTileX(180, 12), n - 1);
      expect(satTileX(-180, 12), 0);
      expect(satTileY(85.0511, 12), 0);
      expect(satTileY(-85.0511, 12), n - 1);
    });

    test('zoom grows as the requested extent shrinks', () {
      const lat = 50.0;
      final zNear = satZoomForHalfMeters(60, lat);
      final zFar = satZoomForHalfMeters(2000, lat);
      expect(zNear, greaterThan(zFar));
      expect(zNear, inInclusiveRange(10, 19));
      expect(zFar, inInclusiveRange(10, 19));
    });

    test('metres-per-pixel halves per zoom level', () {
      expect(
        satMetresPerPixel(50, 15),
        closeTo(2 * satMetresPerPixel(50, 16), 1e-9),
      );
    });
  });

  group('satUvFraction', () {
    test('centre maps to centre, cardinals to edges', () {
      const lat0 = 50.5;
      const lon0 = 14.5;
      final cosLat0 = math.cos(lat0 * math.pi / 180);

      ({double u, double v}) uv(double eastM, double southM) => satUvFraction(
        eastM,
        southM,
        lat0,
        lon0,
        cosLat0,
        northLat: 51.0,
        southLat: 50.0,
        westLon: 14.0,
        eastLon: 15.0,
      );

      final centre = uv(0, 0);
      expect(centre.u, closeTo(0.5, 1e-9));
      expect(centre.v, closeTo(0.5, 1e-9));

      // 0.25° east → u 0.75.
      final eastM = 0.25 * metresPerDegreeLat * cosLat0;
      expect(uv(eastM, 0).u, closeTo(0.75, 1e-9));

      // 0.25° north (negative world Z) → v 0.25.
      final northM = 0.25 * metresPerDegreeLat;
      expect(uv(0, -northM).v, closeTo(0.25, 1e-9));
    });
  });

  group('shouldApplyTerrainStage', () {
    test('new site always applies', () {
      expect(
        shouldApplyTerrainStage(
          currentKey: 'a',
          currentStage: 3,
          key: 'b',
          stage: 1,
        ),
        isTrue,
      );
    });

    test('same site upgrades only', () {
      expect(
        shouldApplyTerrainStage(
          currentKey: 'a',
          currentStage: 1,
          key: 'a',
          stage: 3,
        ),
        isTrue,
      );
      expect(
        shouldApplyTerrainStage(
          currentKey: 'a',
          currentStage: 3,
          key: 'a',
          stage: 3,
        ),
        isFalse,
      );
      expect(
        shouldApplyTerrainStage(
          currentKey: 'a',
          currentStage: 3,
          key: 'a',
          stage: 1,
        ),
        isFalse,
      );
    });
  });

  group('buildTerrainMesh', () {
    TerrainMesh meshOf({
      ElevationGrid? dem,
      double half = 100.0,
      int res = 9,
    }) => buildTerrainMesh(
      northLat: 0.01,
      southLat: -0.01,
      westLon: -0.01,
      eastLon: 0.01,
      imgW: 256,
      imgH: 256,
      coverageHalfMeters: 1000,
      dem: dem,
      lat0: 0.0,
      lon0: 0.0,
      cosLat0: 1.0,
      halfMeters: half,
      resolution: res,
    );

    test('spans the requested square with valid indices', () {
      final mesh = meshOf();
      expect(mesh.vertexCount, 81);
      expect(mesh.indices.length, 8 * 8 * 6);
      expect(mesh.world[0], closeTo(-100, 1e-9));
      expect(mesh.world[2], closeTo(-100, 1e-9));
      final last = (mesh.vertexCount - 1) * 3;
      expect(mesh.world[last], closeTo(100, 1e-9));
      expect(mesh.world[last + 2], closeTo(100, 1e-9));
      for (final i in mesh.indices) {
        expect(i, inInclusiveRange(0, mesh.vertexCount - 1));
      }
      // Flat without DEM, up normals, radially feathered to the tier edge:
      // opaque centre, zero at the mid-sides (feather radius = tier half).
      for (var k = 0; k < mesh.vertexCount; k++) {
        expect(mesh.world[k * 3 + 1], 0.0);
        expect(mesh.normals[k * 3 + 1], 1.0);
      }
      expect(mesh.alpha[4 * 9 + 4], closeTo(1.0, 1e-9));
      expect(mesh.alpha[4 * 9 + 8], closeTo(0.0, 1e-9));
      expect(mesh.alpha[0], closeTo(0.0, 1e-9));
    });

    test('bakes DEM heights, normals and imagery UVs', () {
      // East column 100 m MSL over datum 0 across a ±0.01° grid.
      final dem = ElevationGrid(
        northLat: 0.01,
        southLat: -0.01,
        westLon: -0.01,
        eastLon: 0.01,
        datumMsl: 0,
        cols: 2,
        rows: 2,
        heights: Float32List.fromList([0, 100, 0, 100]),
      );
      final mesh = meshOf(dem: dem, half: 1000.0, res: 5);
      // East edge ≈ 95 m, west edge ≈ 5 m (bilinear across the grid).
      for (var j = 0; j < 5; j++) {
        final west = mesh.world[(j * 5) * 3 + 1];
        final east = mesh.world[(j * 5 + 4) * 3 + 1];
        expect(east, greaterThan(west + 50));
      }
      // Surface rises eastward → normals tilt west.
      expect(mesh.normals[0], lessThan(0));
      // UVs land inside the image, east of west.
      for (final uv in mesh.uvPts) {
        expect(uv.dx, inInclusiveRange(0, 256));
        expect(uv.dy, inInclusiveRange(0, 256));
      }
      expect(mesh.uvPts[4].dx, greaterThan(mesh.uvPts[0].dx));
    });
  });

  group('drape fades', () {
    test('rim feather is opaque inside, gone at the rim', () {
      expect(satRimAlpha(0, 10000), closeTo(1.0, 1e-9));
      expect(satRimAlpha(7000, 10000), closeTo(1.0, 1e-9));
      expect(satRimAlpha(10000, 10000), closeTo(0.0, 1e-9));
      expect(satRimAlpha(20000, 10000), closeTo(0.0, 1e-9));
    });
  });

  group('terrainSurfaceY', () {
    test('no DEM means the flat plane', () {
      expect(
        terrainSurfaceY(
          null,
          eastM: 100,
          southM: -50,
          lat0: 50.0,
          lon0: 14.0,
          cosLat0: math.cos(50 * math.pi / 180),
        ),
        0.0,
      );
    });
  });

  group('terrain caps', () {
    test('terrain extent is a fixed 20x20 km (never scales with flight)', () {
      expect(satFixedHalfMeters, 10000);
      expect(satMidHalfMeters, 5000);
      expect(satPadHalfMeters, 1250);
    });

    test('pad tier restores the original launch-site sharpness', () {
      // ~0.77 m/px at 50° latitude: zoom 17 over the central 2.5 km.
      expect(
        satZoomForHalfMeters(
          satPadHalfMeters,
          50.0,
          targetPixels: satPadTargetPixels,
        ),
        17,
      );
      expect(satMetresPerPixel(50.0, 17), lessThan(1.0));
    });

    test('imagery windows stay bounded', () {
      final outer = satImageryWindow(
        50.0,
        14.0,
        10000,
        targetPixels: satOuterTargetPixels,
        maxTileRadius: satOuterTileRadius,
      );
      expect(outer.length, lessThanOrEqualTo(81));
      expect(outer, isNotEmpty);
      final mid = satImageryWindow(
        50.0,
        14.0,
        5000,
        targetPixels: satMidTargetPixels,
        maxTileRadius: satMidTileRadius,
      );
      expect(mid.length, lessThanOrEqualTo(81));
      final pad = satImageryWindow(
        50.0,
        14.0,
        satPadHalfMeters,
        targetPixels: satPadTargetPixels,
        maxTileRadius: satPadTileRadius,
      );
      expect(pad.length, lessThanOrEqualTo(49));
      expect(pad, isNotEmpty);
    });

    test('terrain URL set covers imagery, DEM and every bucket', () {
      final urls = satTerrainTileUrls(50.0, 14.0);
      expect(urls, isNotEmpty);
      expect(urls.length, lessThan(1200));
      expect(urls.any((u) => u.contains('terrarium')), isTrue);
      expect(urls.any((u) => u.contains('World_Imagery')), isTrue);
      // Deterministic: same input twice, same set.
      expect(satTerrainTileUrls(50.0, 14.0), orderedEquals(urls));
      // DEM window alone stays small (5x5 max).
      expect(satDemWindow(50.0, 14.0).length, lessThanOrEqualTo(25));
    });
  });

  group('elevation', () {
    test('terrariumHeight decodes sea level and extremes', () {
      expect(terrariumHeight(128, 0, 0), closeTo(0.0, 1e-9));
      expect(terrariumHeight(128, 0, 128), closeTo(0.5, 1e-9));
      expect(terrariumHeight(0, 0, 0), closeTo(-32768.0, 1e-9));
      expect(terrariumHeight(255, 255, 255), closeTo(32767 + 255 / 256, 1e-9));
    });

    ElevationGrid gridOf(List<double> h, {double datumMsl = 250}) =>
        ElevationGrid(
          northLat: 1.0,
          southLat: 0.0,
          westLon: 0.0,
          eastLon: 1.0,
          datumMsl: datumMsl,
          cols: 2,
          rows: 2,
          heights: Float32List.fromList(h),
        );

    // Anchor at the grid centre: lat0 0.5, lon0 0.5.
    double rel(ElevationGrid g, double eastM, double southM) =>
        g.sampleRel(eastM, southM, 0.5, 0.5, math.cos(0.5 * math.pi / 180));

    test('centre samples bilinear minus datum at true 1:1 scale', () {
      final g = gridOf([100, 200, 300, 400]);
      expect(rel(g, 0, 0), closeTo(0.0, 1e-6));
      final g2 = gridOf([100, 200, 300, 400], datumMsl: 0);
      // Bilinear mean 250, rendered at true scale (no exaggeration) so it
      // agrees with the rocket's baro-AGL altitude.
      expect(rel(g2, 0, 0), closeTo(250.0, 1e-6));
    });

    test('relief is true height above the site datum', () {
      // Uniform 300 m MSL terrain over a 250 m MSL pad renders 50 m up.
      final g = gridOf([300, 300, 300, 300], datumMsl: 250);
      expect(rel(g, 0, 0), closeTo(50.0, 1e-6));
    });

    test('relief clamps and the outside stays flat', () {
      final g = gridOf([0, 0, 0, 10000], datumMsl: 0);
      expect(rel(g, 0, 0), demMaxReliefMeters);
      expect(rel(g, 1e7, 0), 0.0);
      expect(rel(g, 0, 1e7), 0.0);
    });

    test('relief fades to zero at the grid edge (no cliff)', () {
      final g = gridOf([0, 0, 0, 10000], datumMsl: 0);
      final cosLat = math.cos(0.5 * math.pi / 180);
      // West edge (u = 0): fade is exactly 0 despite the 10 km corner.
      expect(rel(g, -0.5 * metresPerDegreeLat * cosLat, 0), 0.0);
    });

    test('flat grid has an up normal', () {
      final g = gridOf([250, 250, 250, 250]);
      final n = g.normalAt(0, 0, 0.5, 0.5, math.cos(0.5 * math.pi / 180));
      expect(n.x, closeTo(0.0, 1e-9));
      expect(n.y, closeTo(1.0, 1e-9));
      expect(n.z, closeTo(0.0, 1e-9));
    });

    test('buildNormals: flat is up, eastward slope tilts west', () {
      Float32List build(List<double> h) => ElevationGrid.buildNormals(
        heights: Float32List.fromList(h),
        cols: 2,
        rows: 2,
        northLat: 0.001,
        southLat: 0.0,
        westLon: 0.0,
        eastLon: 0.001,
      );
      final flat = build([250, 250, 250, 250]);
      expect(flat.length, 12);
      expect(flat[0], closeTo(0.0, 1e-9));
      expect(flat[1], closeTo(1.0, 1e-9));
      expect(flat[2], closeTo(0.0, 1e-9));
      // Heights rise eastward (~0.9 m/m over the 111 m wide grid).
      final slope = build([0, 100, 0, 100]);
      expect(slope[0], lessThan(-0.5));
      expect(slope[1], greaterThan(0.5));
      expect(slope[1], lessThan(1.0));
    });

    test('normalAt serves the precomputed grid', () {
      final heights = Float32List.fromList([0, 100, 0, 100]);
      final g = ElevationGrid(
        northLat: 0.001,
        southLat: 0.0,
        westLon: 0.0,
        eastLon: 0.001,
        datumMsl: 0,
        cols: 2,
        rows: 2,
        heights: heights,
        normals: ElevationGrid.buildNormals(
          heights: heights,
          cols: 2,
          rows: 2,
          northLat: 0.001,
          southLat: 0.0,
          westLon: 0.0,
          eastLon: 0.001,
        ),
      );
      final n = g.normalAt(
        0,
        0,
        0.0005,
        0.0005,
        math.cos(0.0005 * math.pi / 180),
      );
      expect(n.x, lessThan(-0.5));
      expect(n.y, greaterThan(0.5));
    });
  });

  group('averageRgba', () {
    test('solid color round-trips', () {
      final bytes = Uint8List.fromList([200, 100, 50, 255, 200, 100, 50, 255]);
      final c = averageRgba(bytes);
      expect(c.a, 1.0);
      expect((c.r * 255).round(), 200);
      expect((c.g * 255).round(), 100);
      expect((c.b * 255).round(), 50);
    });

    test('empty input falls back to neutral sage', () {
      expect(averageRgba(Uint8List(0)).toARGB32(), 0xFFB7BCAE);
    });
  });

  group('pad grounding', () {
    const site = LaunchSite(
      name: 'Pad',
      latitude: 50.0,
      longitude: 14.0,
      altitudeMsl: 403,
    );

    ElevationGrid flatDem(double datum) => ElevationGrid(
      northLat: 50.01,
      southLat: 49.99,
      westLon: 13.99,
      eastLon: 14.01,
      datumMsl: datum,
      cols: 2,
      rows: 2,
      heights: Float32List.fromList([390, 390, 390, 390]),
    );

    test('scene site follows DEM datum once elevation is in', () {
      expect(resolveSceneSite(site, null), same(site));
      expect(resolveSceneSite(null, flatDem(390)), isNull);
      final grounded = resolveSceneSite(site, flatDem(390))!;
      expect(grounded.latitude, 50.0);
      expect(grounded.longitude, 14.0);
      expect(grounded.name, 'Pad');
      expect(grounded.altitudeMsl, 390);
    });

    test('terrain at pad renders at furniture plane', () {
      // Datum IS the DEM height at the pad: relief there is 0, so pad
      // furniture (y=0) sits exactly on the drape.
      final dem = flatDem(390);
      final cosLat0 = math.cos(50.0 * math.pi / 180);
      expect(dem.sampleRel(0, 0, 50.0, 14.0, cosLat0), closeTo(0, 1e-6));
    });
  });
}
