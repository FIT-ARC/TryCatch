import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/tiles/shared/gpu/rocket_gpu_view.dart';
import 'package:trycatch/ui/tiles/shared/rocket_mesh.dart';
import 'package:vector_math/vector_math_64.dart';

/// The attitude viewer must render the rocket centred: the mesh origin sits
/// below the geometric centre, so a naive look-at-origin parks the rocket
/// high with the nose clipped (verified against a 600×300 tile before the
/// fix: bbox centre ≈ 38 px above screen centre, tip off-screen).
void main() {
  // Wide tile matching the reported screenshot shape.
  const sizeW = 600.0;
  const sizeH = 300.0;

  Offset? toScreen(Vector3 world, Matrix4 vp) {
    final clip = vp.transformed(Vector4(world.x, world.y, world.z, 1));
    if (clip.w <= 0.001) return null;
    final ndc = clip.xyz / clip.w;
    return Offset(
      (ndc.x * 0.5 + 0.5) * sizeW,
      (0.5 - ndc.y * 0.5) * sizeH,
    );
  }

  ({double cx, double cy, double minY, double maxY}) projectedCenter({
    required bool cone,
    required bool chute,
  }) {
    final aspect = sizeW / sizeH;
    final proj = makePerspectiveMatrix(radians(42), aspect, 0.1, 20.0);
    const azDeg = -35.0;
    const elDeg = 16.0;
    final az = radians(azDeg);
    final el = radians(elDeg);
    final camDir = Vector3(
      math.cos(el) * math.sin(az),
      math.sin(el),
      math.cos(el) * math.cos(az),
    );
    final framing = rocketFramingGpu(
      showNoseCone: cone,
      showParachute: chute,
    );
    final target = framing.target;
    final view = makeViewMatrix(
        target + camDir.scaled(framing.distance), target, Vector3(0, 1, 0));
    final vp = proj * view;
    const modelScale = 0.9;
    final model = RocketMesh.orientationMatrix(
      pitchDeg: 0,
      yawDeg: 0,
      rollDeg: 0,
      scale: modelScale,
    );
    final chuteModel = Matrix4.translation(
            model.transformed3(Vector3(0, RocketMesh.bodyTop, 0)))
        ..scaleByDouble(0.9, 0.9, 0.9, 1.0);

    var minX = double.infinity;
    var maxX = -double.infinity;
    var minY = double.infinity;
    var maxY = -double.infinity;
    void push(Vector3 w) {
      final s = toScreen(w, vp);
      if (s == null) return;
      if (s.dx < minX) minX = s.dx;
      if (s.dx > maxX) maxX = s.dx;
      if (s.dy < minY) minY = s.dy;
      if (s.dy > maxY) maxY = s.dy;
    }

    for (final tri in RocketMesh.mesh(showNoseCone: cone)) {
      push(model.transformed3(tri.a));
      push(model.transformed3(tri.b));
      push(model.transformed3(tri.c));
    }
    if (chute) {
      for (final tri in ParachuteMesh.triangles) {
        push(chuteModel.transformed3(tri.a));
        push(chuteModel.transformed3(tri.b));
        push(chuteModel.transformed3(tri.c));
      }
    }
    return (
      cx: (minX + maxX) / 2,
      cy: (minY + maxY) / 2,
      minY: minY,
      maxY: maxY,
    );
  }

  for (final config in [
    (cone: true, chute: false, name: 'assembled'),
    (cone: false, chute: false, name: 'popped, no chute'),
    (cone: false, chute: true, name: 'under canopy'),
  ]) {
    test('rocket centred ${config.name}', () {
      final c = projectedCenter(cone: config.cone, chute: config.chute);
      // Bounding-box centre lands on the screen centre (perspective makes
      // the projected box very slightly asymmetric — allow a few px).
      expect((c.cx - sizeW / 2).abs(), lessThan(10));
      expect((c.cy - sizeH / 2).abs(), lessThan(10));
      // Nothing clipped.
      expect(c.minY, greaterThanOrEqualTo(-2));
      expect(c.maxY, lessThanOrEqualTo(sizeH + 2));
    });
  }
}
