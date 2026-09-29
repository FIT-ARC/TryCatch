import 'dart:typed_data';

import '../rocket_mesh.dart';

/// Pure CPU-side conversion of the parametric rocket airframe into
/// GPU-uploadable vertex streams (positions, normals, linear RGBA colors).
///
/// No engine dependency: the result feeds any GPU mesh builder
/// (`flutter_scene` `MeshGeometry.fromArrays`, or a future replacement)
/// without pulling `flutter_gpu` into unit tests. Normals are the mesh
/// face normals, matching the flat shading of the legacy `CustomPainter`
/// path (`paintRocketMesh`).
class RocketGpuData {
  final Float32List positions;
  final Float32List normals;
  final Float32List colors;

  const RocketGpuData({
    required this.positions,
    required this.normals,
    required this.colors,
  });

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => vertexCount ~/ 3;
}

/// Builds the airframe vertex streams for [showNoseCone]/[showParachute].
/// Non-indexed: every triangle owns its three vertices, so coplanar fin
/// pairs and single-sheet canopy triangles need no cull flags on the GPU —
/// both windings are already explicit in the mesh.
RocketGpuData buildRocketGpuData({
  bool showNoseCone = true,
  bool showParachute = false,
}) {
  final tris = <RocketMeshTri>[
    ...RocketMesh.mesh(showNoseCone: showNoseCone),
    if (showParachute) ...ParachuteMesh.triangles,
  ];
  final positions = Float32List(tris.length * 9);
  final normals = Float32List(tris.length * 9);
  final colors = Float32List(tris.length * 12);
  for (var t = 0; t < tris.length; t++) {
    final tri = tris[t];
    final corners = [tri.a, tri.b, tri.c];
    // Opaque white when the mesh carries no color (never today; defensive).
    final r = tri.color.r;
    final g = tri.color.g;
    final b = tri.color.b;
    final a = tri.color.a;
    for (var c = 0; c < 3; c++) {
      final v = t * 9 + c * 3;
      positions[v] = corners[c].x;
      positions[v + 1] = corners[c].y;
      positions[v + 2] = corners[c].z;
      normals[v] = tri.normal.x;
      normals[v + 1] = tri.normal.y;
      normals[v + 2] = tri.normal.z;
      final o = t * 12 + c * 4;
      colors[o] = r;
      colors[o + 1] = g;
      colors[o + 2] = b;
      colors[o + 3] = a;
    }
  }
  return RocketGpuData(
    positions: positions,
    normals: normals,
    colors: colors,
  );
}
