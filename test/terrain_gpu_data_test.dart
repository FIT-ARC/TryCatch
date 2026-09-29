import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/tiles/shared/gpu/terrain_gpu_data.dart';
import 'package:trycatch/ui/tiles/shared/satellite_ground.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Locks the retained-mesh → GPU-stream conversion: normalized imagery UVs,
/// baked hillshade RGB, per-vertex feather alpha, and the tier Y lift.
void main() {
  /// Two triangles over a 100 m square, imagery 256 px, mid-tier alpha.
  TerrainMesh mesh() {
    final n = 2;
    final world = Float32List(n * n * 3);
    final normals = Float32List(n * n * 3);
    final alpha = Float32List(n * n);
    final uvPts = <Offset>[];
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        final k = j * n + i;
        world[k * 3] = i * 100.0;
        world[k * 3 + 1] = 5.0;
        world[k * 3 + 2] = j * 100.0;
        normals[k * 3] = 0.0;
        normals[k * 3 + 1] = 1.0;
        normals[k * 3 + 2] = 0.0;
        alpha[k] = (i + j).isEven ? 1.0 : 0.5;
        uvPts.add(Offset(i * 256.0, j * 256.0));
      }
    }
    return TerrainMesh(
      world: world,
      normals: normals,
      alpha: alpha,
      uvPts: uvPts,
      indices: const [0, 1, 3, 0, 3, 2],
      rows: n,
      cols: n,
      half: 50,
    );
  }

  test('normalizes pixel UVs into texture space', () {
    final data = buildTerrainGpuData(
      mesh: mesh(),
      imageWidth: 256,
      imageHeight: 256,
      sunDir: vm.Vector3(0, 1, 0),
    );
    expect(data.texCoords[0], 0.0);
    expect(data.texCoords[1], 0.0);
    // Last vertex (i=1, j=1) sits at the image corner.
    final last = data.vertexCount - 1;
    expect(data.texCoords[last * 2], closeTo(1.0, 1e-6));
    expect(data.texCoords[last * 2 + 1], closeTo(1.0, 1e-6));
  });

  test('bakes hillshade from the sun and keeps feather alpha', () {
    final data = buildTerrainGpuData(
      mesh: mesh(),
      imageWidth: 256,
      imageHeight: 256,
      sunDir: vm.Vector3(0, 1, 0),
    );
    // Flat up-facing normals: fully lit shade (1.0), alpha carried through.
    expect(data.colors[0], closeTo(1.0, 1e-6));
    expect(data.colors[1], closeTo(1.0, 1e-6));
    expect(data.colors[2], closeTo(1.0, 1e-6));
    expect(data.colors[3], 1.0);
    expect(data.colors[7], 0.5);
  });

  test('applies the tier Y lift without touching X/Z', () {
    final lifted = buildTerrainGpuData(
      mesh: mesh(),
      imageWidth: 256,
      imageHeight: 256,
      sunDir: vm.Vector3(0, 1, 0),
      yOffset: padTierLift,
    );
    expect(lifted.positions[1], closeTo(5.0 + padTierLift, 1e-6));
    expect(lifted.positions[0], 0.0);
    expect(lifted.positions[2], 0.0);
  });

  test('indexLimit truncates the draw list', () {
    final data = buildTerrainGpuData(
      mesh: mesh(),
      imageWidth: 256,
      imageHeight: 256,
      sunDir: vm.Vector3(0, 1, 0),
      indexLimit: 3,
    );
    expect(data.indices.length, 3);
  });
}
