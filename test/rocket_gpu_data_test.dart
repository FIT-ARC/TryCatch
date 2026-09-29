import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/tiles/shared/rocket_mesh.dart';
import 'package:trycatch/ui/tiles/shared/gpu/rocket_gpu_data.dart';

/// Locks the CPU-side GPU vertex assembly: one non-indexed triangle per mesh
/// triangle, face normals, and linear RGBA colors carried through.
void main() {
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

    test('adds canopy triangles only while the chute is deployed', () {
      final noChute = buildRocketGpuData();
      final chute = buildRocketGpuData(showParachute: true);
      expect(
        chute.triangleCount - noChute.triangleCount,
        ParachuteMesh.triangles.length,
      );
    });

    test('hiding the nose cone matches the shared mesh filter', () {
      final all = buildRocketGpuData();
      final popped = buildRocketGpuData(showNoseCone: false);
      expect(all.triangleCount, RocketMesh.mesh().length);
      expect(popped.triangleCount, RocketMesh.mesh(showNoseCone: false).length);
    });

    test('normals are unit length and colors opaque', () {
      final data = buildRocketGpuData(showParachute: true);
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
