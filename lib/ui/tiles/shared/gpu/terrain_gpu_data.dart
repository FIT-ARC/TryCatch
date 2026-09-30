import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

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
/// a caller renders a lower-detail pass. [uvScale]/[uvOffset] remap the
/// normalized UVs into a sub-region of the texture (the atlas bands).
///
/// Winding: the retained mesh's top side is wound clockwise seen from above,
/// which the engine's backface culling keeps hidden — every triangle is
/// emitted reversed so the drape renders its top side from above and culls
/// from below (cameras are terrain-clamped).
TerrainGpuData buildTerrainGpuData({
  required TerrainMesh mesh,
  required int imageWidth,
  required int imageHeight,
  required vm.Vector3 sunDir,
  double yOffset = 0,
  int? indexLimit,
  Offset uvScale = const Offset(1, 1),
  Offset uvOffset = Offset.zero,
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
    texCoords[v * 2] = uv.dx * invW * uvScale.dx + uvOffset.dx;
    texCoords[v * 2 + 1] = uv.dy * invH * uvScale.dy + uvOffset.dy;
    final lit = nx * sunDir.x + ny * sunDir.y + nz * sunDir.z;
    final shade = 0.72 + 0.28 * (lit > 0 ? lit : 0.0);
    colors[v * 4] = shade;
    colors[v * 4 + 1] = shade;
    colors[v * 4 + 2] = shade;
    colors[v * 4 + 3] = mesh.alpha[v];
  }
  final source = indexLimit == null
      ? mesh.indices
      : mesh.indices.sublist(0, indexLimit.clamp(0, mesh.indices.length));
  final indices = List<int>.filled(source.length, 0);
  for (var i = 0; i + 2 < source.length; i += 3) {
    indices[i] = source[i];
    indices[i + 1] = source[i + 2];
    indices[i + 2] = source[i + 1];
  }
  return TerrainGpuData(
    positions: positions,
    normals: normals,
    texCoords: texCoords,
    colors: colors,
    indices: indices,
  );
}

/// Tier Y offsets (m). With single-mesh atlas drawing, tiers blend in index
/// order, so no vertical displacement is needed and the drape sits directly
/// on the DEM surface everywhere.
const double padTierLift = 0.0;
const double midTierLift = 0.0;
const double outerTierLift = 0.0;

/// One drape tier of an atlas: the retained mesh, the pixel size of the
/// imagery it drapes, and the tier's Y lift.
class TerrainAtlasTier {
  final TerrainMesh mesh;
  final int imageWidth;
  final int imageHeight;
  final double yOffset;

  const TerrainAtlasTier({
    required this.mesh,
    required this.imageWidth,
    required this.imageHeight,
    required this.yOffset,
  });
}

/// Combined GPU vertex streams for several drape tiers sharing one atlas
/// texture ([atlasWidth] x [atlasHeight] pixels, tiers stacked vertically in
/// list order).
class TerrainAtlasGpuData {
  final Float32List positions;
  final Float32List normals;
  final Float32List texCoords;
  final Float32List colors;
  final List<int> indices;
  final int atlasWidth;
  final int atlasHeight;

  const TerrainAtlasGpuData({
    required this.positions,
    required this.normals,
    required this.texCoords,
    required this.colors,
    required this.indices,
    required this.atlasWidth,
    required this.atlasHeight,
  });

  int get vertexCount => positions.length ~/ 3;
}

/// Builds one combined mesh over [tiers], each tier's UVs remapped into its
/// vertical band of the atlas and its indices shifted past the tiers before
/// it. The engine blends translucent surfaces per draw call, so one mesh
/// makes the layered blend order the list order — outer context first, sharp
/// pad last — deterministically, instead of leaving it to the engine's
/// translucent depth sort (whose key barely separates tiers whose bounds
/// centers nearly coincide).
TerrainAtlasGpuData buildTerrainAtlasGpuData({
  required List<TerrainAtlasTier> tiers,
  required vm.Vector3 sunDir,
}) {
  assert(tiers.isNotEmpty);
  final atlasWidth = tiers.map((t) => t.imageWidth).reduce(math.max);
  final atlasHeight = tiers.fold(0, (sum, t) => sum + t.imageHeight);

  final parts = <TerrainGpuData>[];
  var bandY = 0;
  for (final tier in tiers) {
    parts.add(buildTerrainGpuData(
      mesh: tier.mesh,
      imageWidth: tier.imageWidth,
      imageHeight: tier.imageHeight,
      sunDir: sunDir,
      yOffset: tier.yOffset,
      uvScale: Offset(
        tier.imageWidth / atlasWidth,
        tier.imageHeight / atlasHeight,
      ),
      uvOffset: Offset(0, bandY / atlasHeight),
    ));
    bandY += tier.imageHeight;
  }

  final vertexCount = parts.fold(0, (sum, p) => sum + p.vertexCount);
  final indexCount = parts.fold(0, (sum, p) => sum + p.indices.length);
  final positions = Float32List(vertexCount * 3);
  final normals = Float32List(vertexCount * 3);
  final texCoords = Float32List(vertexCount * 2);
  final colors = Float32List(vertexCount * 4);
  final indices = List<int>.filled(indexCount, 0);

  var vertexFill = 0;
  var indexFill = 0;
  for (final part in parts) {
    final n = part.vertexCount;
    positions.setRange(vertexFill * 3, (vertexFill + n) * 3, part.positions);
    normals.setRange(vertexFill * 3, (vertexFill + n) * 3, part.normals);
    texCoords.setRange(vertexFill * 2, (vertexFill + n) * 2, part.texCoords);
    colors.setRange(vertexFill * 4, (vertexFill + n) * 4, part.colors);
    for (var i = 0; i < part.indices.length; i++) {
      indices[indexFill + i] = part.indices[i] + vertexFill;
    }
    vertexFill += n;
    indexFill += part.indices.length;
  }

  return TerrainAtlasGpuData(
    positions: positions,
    normals: normals,
    texCoords: texCoords,
    colors: colors,
    indices: indices,
    atlasWidth: atlasWidth,
    atlasHeight: atlasHeight,
  );
}
