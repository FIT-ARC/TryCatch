import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

import '../satellite_ground.dart';

/// Pure CPU conversion of one retained [TerrainMesh] tier into GPU-ready
/// vertex streams for the satellite drape.
///
/// The retained mesh already carries world positions, surface normals and a
/// baked rim-feather alpha; this adds normalized texture coordinates (the
/// legacy mesh stored them in image pixels) and a baked directional hillshade
/// in the vertex RGB, so the GPU material samples the imagery once and needs
/// no per-frame lighting. Engine-free for unit testing.
class TerrainGpuData {
  final Float32List positions;
  final Float32List normals;
  final Float32List texCoords;
  final Float32List colors;
  final List<int> indices;

  const TerrainGpuData({
    required this.positions,
    required this.normals,
    required this.texCoords,
    required this.colors,
    required this.indices,
  });

  int get vertexCount => positions.length ~/ 3;
}

/// Builds [TerrainGpuData] for [mesh] against an imagery texture of
/// [imageWidth] x [imageHeight] pixels.
///
/// [sunDir] is the world-space (X east, Y up, Z south) unit light direction;
/// [yOffset] nudges a tier a few centimetres above the one it overdraws so the
/// blended tiers never z-fight, and [indexLimit] truncates the index list when
/// a caller renders a lower-detail pass.
TerrainGpuData buildTerrainGpuData({
  required TerrainMesh mesh,
  required int imageWidth,
  required int imageHeight,
  required vm.Vector3 sunDir,
  double yOffset = 0,
  int? indexLimit,
}) {
  final count = mesh.vertexCount;
  final positions = Float32List(count * 3);
  final normals = Float32List(count * 3);
  final texCoords = Float32List(count * 2);
  final colors = Float32List(count * 4);
  final invW = imageWidth <= 0 ? 1.0 : 1.0 / imageWidth;
  final invH = imageHeight <= 0 ? 1.0 : 1.0 / imageHeight;
  for (var v = 0; v < count; v++) {
    positions[v * 3] = mesh.world[v * 3];
    positions[v * 3 + 1] = mesh.world[v * 3 + 1] + yOffset;
    positions[v * 3 + 2] = mesh.world[v * 3 + 2];
    final nx = mesh.normals[v * 3];
    final ny = mesh.normals[v * 3 + 1];
    final nz = mesh.normals[v * 3 + 2];
    normals[v * 3] = nx;
    normals[v * 3 + 1] = ny;
    normals[v * 3 + 2] = nz;
    final uv = mesh.uvPts[v];
    texCoords[v * 2] = uv.dx * invW;
    texCoords[v * 2 + 1] = uv.dy * invH;
    final lit = nx * sunDir.x + ny * sunDir.y + nz * sunDir.z;
    final shade = 0.72 + 0.28 * (lit > 0 ? lit : 0.0);
    colors[v * 4] = shade;
    colors[v * 4 + 1] = shade;
    colors[v * 4 + 2] = shade;
    colors[v * 4 + 3] = mesh.alpha[v];
  }
  final indices = indexLimit == null
      ? mesh.indices
      : mesh.indices.sublist(0, indexLimit.clamp(0, mesh.indices.length));
  return TerrainGpuData(
    positions: positions,
    normals: normals,
    texCoords: texCoords,
    colors: colors,
    indices: indices,
  );
}

/// Tier Y offsets (m) that keep the nested drape layers from z-fighting once
/// they share a depth buffer: the sharpest tier sits highest.
const double padTierLift = 0.30;
const double midTierLift = 0.15;
const double outerTierLift = 0.0;
