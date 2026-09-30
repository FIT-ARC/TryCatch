import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/tiles/shared/rocket_mesh.dart';
import 'package:trycatch/ui/tiles/shared/gpu/rocket_gpu_data.dart';
import 'package:vector_math/vector_math_64.dart';

/// Locks the CPU-side GPU vertex assembly: one non-indexed face per mesh
/// triangle (mirrored twins for single-sheet surfaces), the engine culling
/// winding, face normals, and linear RGBA colors carried through.
void main() {
  /// Float32 storage rounds the doubles, so corners compare with slack.
  bool samePoint(Vector3 a, Vector3 b) => (a - b).length2 < 1e-12;

  List<Vector3> faceAt(RocketGpuData data, int f) => [
        for (var c = 0; c < 3; c++)
          Vector3(
            data.positions[f * 9 + c * 3],
            data.positions[f * 9 + c * 3 + 1],
            data.positions[f * 9 + c * 3 + 2],
          ),
      ];

  group('buildRocketGpuData', () {
    test('emits three vertices per airframe triangle', () {
      final data = buildRocketGpuData();
      final expected = RocketMesh.mesh().length;
      expect(data.triangleCount, expected);
      expect(data.vertexCount, expected * 3);
      expect(data.positions.length, expected * 9);
      expect(data.normals.length, expected * 9);
      expect(data.colors.length, expected * 12);
    });

    test('carries no canopy geometry', () {
      // The parachute hangs world-up from its own node; the airframe mesh
      // must not embed it.
      expect(buildRocketGpuData().triangleCount, RocketMesh.mesh().length);
      expect(
        buildRocketGpuData(showNoseCone: false).triangleCount,
        RocketMesh.mesh(showNoseCone: false).length,
      );
    });

    test('hiding the nose cone matches the shared mesh filter', () {
      final all = buildRocketGpuData();
      final popped = buildRocketGpuData(showNoseCone: false);
      expect(all.triangleCount, RocketMesh.mesh().length);
      expect(popped.triangleCount, RocketMesh.mesh(showNoseCone: false).length);
    });

    test('keeps the shared mesh winding per face', () {
      // The airframe keeps the mesh's outward-CCW order; the mirroring root
      // node compensates winding engine-side (see FlightGpuView).
      final data = buildRocketGpuData();
      final tri = RocketMesh.mesh().first;
      final corners = [tri.a, tri.b, tri.c];
      var matches = 0;
      for (var f = 0; f < data.triangleCount; f++) {
        final face = faceAt(data, f);
        if (!corners.every((v) => face.any((w) => samePoint(v, w)))) continue;
        matches++;
        expect(samePoint(face[0], tri.a), isTrue);
        expect(samePoint(face[1], tri.b), isTrue);
        expect(samePoint(face[2], tri.c), isTrue);
      }
      expect(matches, 1);
    });

    test('normals are unit length and colors opaque', () {
      final data = buildRocketGpuData();
      for (var v = 0; v < data.vertexCount; v++) {
        final nx = data.normals[v * 3];
        final ny = data.normals[v * 3 + 1];
        final nz = data.normals[v * 3 + 2];
        expect((nx * nx + ny * ny + nz * nz - 1.0).abs() < 1e-5, isTrue);
        expect(data.colors[v * 4 + 3], greaterThan(0.9));
      }
    });
  });

  group('buildParachuteGpuData', () {
    test('emits mirrored twins for every single-sheet triangle', () {
      final data = buildParachuteGpuData();
      expect(data.triangleCount, ParachuteMesh.triangles.length * 2);
      expect(data.vertexCount, data.triangleCount * 3);
    });

    test('canopy faces exist with both windings and opposite normals', () {
      final data = buildParachuteGpuData();
      final tri = ParachuteMesh.triangles.first;
      final corners = [tri.a, tri.b, tri.c];
      final twins = <Vector3>[];
      for (var f = 0; f < data.triangleCount; f++) {
        final face = faceAt(data, f);
        if (!corners.every((v) => face.any((w) => samePoint(v, w)))) continue;
        twins.add(Vector3(
          data.normals[f * 9],
          data.normals[f * 9 + 1],
          data.normals[f * 9 + 2],
        ));
      }
      expect(twins.length, 2);
      expect((twins[0] + twins[1]).length2, lessThan(1e-9));
    });

    test('stays in its own world-up frame at the attach point', () {
      // Origin = shroud attach point ([ParachuteMesh.attachY] above it);
      // the lowest canopy geometry is the skirt. No airframe offset here.
      final data = buildParachuteGpuData();
      final lowest = List.generate(
        data.vertexCount,
        (v) => data.positions[v * 3 + 1],
      ).reduce(math.min);
      expect(lowest, closeTo(ParachuteMesh.attachY, 1e-5));
    });

    test('normals are unit length and colors opaque', () {
      final data = buildParachuteGpuData();
      for (var v = 0; v < data.vertexCount; v++) {
        final nx = data.normals[v * 3];
        final ny = data.normals[v * 3 + 1];
        final nz = data.normals[v * 3 + 2];
        expect((nx * nx + ny * ny + nz * nz - 1.0).abs() < 1e-5, isTrue);
        expect(data.colors[v * 4 + 3], greaterThan(0.9));
      }
    });
  });
}
