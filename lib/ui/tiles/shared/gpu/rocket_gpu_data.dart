import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:vector_math/vector_math_64.dart';

import '../rocket_mesh.dart';

/// Pure CPU-side conversion of the parametric rocket airframe into
/// GPU-uploadable vertex streams (positions, normals, linear RGBA colors).
///
/// No engine dependency: the result feeds any GPU mesh builder
/// (`flutter_scene` `MeshGeometry.fromArrays`, or a future replacement)
/// without pulling `flutter_gpu` into unit tests. Normals are the mesh
/// face normals, giving the airframe its flat-shaded look.
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

/// One emitted GPU face: the three corner positions, the outward normal and
/// the linear RGBA color.
class _GpuFace {
  final Vector3 a;
  final Vector3 b;
  final Vector3 c;
  final Vector3 normal;
  final Color color;

  const _GpuFace(this.a, this.b, this.c, this.normal, this.color);
}

/// Builds the airframe vertex streams for [showNoseCone]. The parachute is
/// NOT part of the airframe: it hangs world-up from the popped tube mouth
/// while the airframe tilts with the attitude, so views mount it as its own
/// node via [buildParachuteGpuData].
///
/// Winding: triangles keep the shared mesh's outward-CCW order — the views
/// render the airframe under a mirroring root node whose reversed winding
/// the engine encoder compensates, so culling behaves exactly as the mesh's
/// own convention (see `FlightGpuView._engineCamera`).
RocketGpuData buildRocketGpuData({
  bool showNoseCone = true,
}) {
  return _packFaces([
    for (final tri in RocketMesh.mesh(showNoseCone: showNoseCone))
      ..._emit(tri, Vector3.zero()),
  ]);
}

/// Builds the parachute canopy in its own world-up frame: origin at the
/// shroud-line attach point, canopy straight up +Y. Views translate it to
/// the popped tube mouth and never tilt it with the airframe. Every
/// triangle is single-sheet ([RocketMeshTri.noCull]), so each emits a
/// mirrored twin with the opposite winding and negated normal — the canopy
/// reads from above and below with exactly one front-facing copy.
RocketGpuData buildParachuteGpuData() {
  return _packFaces([
    for (final tri in ParachuteMesh.triangles) ..._emit(tri, Vector3.zero()),
  ]);
}

double _srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// Packs faces into non-indexed vertex streams (positions, normals, linear
/// RGBA colors), three vertices per face.
RocketGpuData _packFaces(List<_GpuFace> faces) {
  final positions = Float32List(faces.length * 9);
  final normals = Float32List(faces.length * 9);
  final colors = Float32List(faces.length * 12);
  for (var f = 0; f < faces.length; f++) {
    final face = faces[f];
    final corners = [face.a, face.b, face.c];
    final color = face.color;
    final r = _srgbToLinear(color.r);
    final g = _srgbToLinear(color.g);
    final b = _srgbToLinear(color.b);
    final a = color.a;
    for (var c = 0; c < 3; c++) {
      final v = f * 9 + c * 3;
      positions[v] = corners[c].x;
      positions[v + 1] = corners[c].y;
      positions[v + 2] = corners[c].z;
      normals[v] = face.normal.x;
      normals[v + 1] = face.normal.y;
      normals[v + 2] = face.normal.z;
      final o = f * 12 + c * 4;
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

/// Emits [tri] shifted by [offset]: the face in the mesh's own winding, plus
/// a mirrored twin for single-sheet [RocketMeshTri.noCull] surfaces.
List<_GpuFace> _emit(RocketMeshTri tri, Vector3 offset) {
  final a = tri.a + offset;
  final b = tri.b + offset;
  final c = tri.c + offset;
  final face = _GpuFace(a, b, c, tri.normal, tri.color);
  if (!tri.noCull) return [face];
  return [
    face,
    _GpuFace(a, c, b, -tri.normal, tri.color),
  ];
}
