import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/foundation.dart' show compute;

import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/tiles/shared/gpu/terrain_gpu_data.dart';
import 'package:trycatch/ui/tiles/shared/satellite_ground.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Locks the retained-mesh → GPU-stream conversion: normalized imagery UVs,
/// baked hillshade RGB, per-vertex feather alpha, and the tier Y lift.
void main() {
  test('atlas uploads stay within area and dimension budgets', () {
    for (final (width, height) in [(2304, 6400), (8000, 100), (256, 256)]) {
      final output = boundedTerrainAtlasSize(width, height, 2 * 1024 * 1024);
      expect(output.width * output.height, lessThanOrEqualTo(2 * 1024 * 1024));
      expect(output.width, lessThanOrEqualTo(4096));
      expect(output.height, lessThanOrEqualTo(4096));
    }
  });

  /// Two triangles over a 100 m square, imagery 256 px, mid-tier alpha.
  TerrainMesh mesh([int n = 2]) {
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

  test('large GPU conversion leaves the main event loop responsive', () async {
    final tiers = [
      for (var i = 0; i < 2; i++)
        TerrainAtlasTier(
          mesh: mesh(160),
          imageWidth: 2304,
          imageHeight: 2304,
          yOffset: 0,
        ),
    ];
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    try {
      final data = await compute(terrainAtlasInBackground, tiers);
      expect(data.positions.length ~/ 3, 2 * 160 * 160);
      expect(ticks, greaterThan(0));
    } finally {
      timer.cancel();
    }
  });

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

  test('reverses each triangle so the top side passes culling', () {
    final data = buildTerrainGpuData(
      mesh: mesh(),
      imageWidth: 256,
      imageHeight: 256,
      sunDir: vm.Vector3(0, 1, 0),
    );
    // Mesh indices [0, 1, 3, 0, 3, 2] emit as [0, 3, 1, 0, 2, 3].
    expect(data.indices, [0, 3, 1, 0, 2, 3]);
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

  group('buildTerrainAtlasGpuData', () {
    test('stacks tiers into atlas bands with shifted indices', () {
      final atlas = buildTerrainAtlasGpuData(
        tiers: [
          TerrainAtlasTier(
            mesh: mesh(),
            imageWidth: 256,
            imageHeight: 256,
            yOffset: outerTierLift,
          ),
          TerrainAtlasTier(
            mesh: mesh(),
            imageWidth: 512,
            imageHeight: 128,
            yOffset: midTierLift,
          ),
        ],
        sunDir: vm.Vector3(0, 1, 0),
      );
      expect(atlas.atlasWidth, 512);
      expect(atlas.atlasHeight, 256 + 128);
      expect(atlas.vertexCount, 2 * 4);
      expect(atlas.indices.length, 12);

      // Second tier's vertices start past the first tier's four.
      for (var v = 4; v < 8; v++) {
        expect(atlas.positions[v * 3 + 1], closeTo(5.0 + midTierLift, 1e-6));
      }
      // First tier UVs: unchanged band (256/256 into a 512-wide atlas).
      expect(atlas.texCoords[0], 0.0);
      expect(atlas.texCoords[2], closeTo(256 / 512, 1e-6));
      // Second tier maps into its band: v=4 sits at band start.
      expect(atlas.texCoords[8], 0.0);
      expect(atlas.texCoords[9], closeTo(256 / (256 + 128), 1e-6));
      // Indices of the second tier shift past the first tier's vertices.
      expect(atlas.indices[6], 0 + 4);
    });

    test('keeps the tier list order in the index list', () {
      final atlas = buildTerrainAtlasGpuData(
        tiers: [
          TerrainAtlasTier(
            mesh: mesh(),
            imageWidth: 256,
            imageHeight: 256,
            yOffset: 0,
          ),
          TerrainAtlasTier(
            mesh: mesh(),
            imageWidth: 256,
            imageHeight: 256,
            yOffset: midTierLift,
          ),
        ],
        sunDir: vm.Vector3(0, 1, 0),
      );
      // First six indices reference the first tier's vertices (0..3).
      for (final i in atlas.indices.take(6)) {
        expect(i, lessThan(4));
      }
      // Last six reference the second tier's (4..7).
      for (final i in atlas.indices.skip(6)) {
        expect(i, inInclusiveRange(4, 7));
      }
    });
  });
}
