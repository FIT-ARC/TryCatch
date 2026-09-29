import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dead_reckoning/dead_reckoning.dart'
    show DeadReckoningPosition, metresPerDegreeLat;
import 'package:serial/serial.dart';
import 'package:trycatch/core/ring_buffer.dart';
import 'package:trycatch/state/telemetry_store.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_common.dart';
import 'package:trycatch/ui/tiles/shared/rocket_mesh.dart';
import 'package:vector_math/vector_math_64.dart';

/// Locks the right-handed world frame (X east, Y up, Z south): a previous
/// revision used +Z north, a left-handed frame that rendered east/west
/// flipped on screen.
void main() {
  const lat0 = 50.0755;
  const lon0 = 14.4378;
  final cosLat0 = math.cos(lat0 * math.pi / 180);

  group('worldFromLatLon handedness', () {
    test('east is +X', () {
      final lon = lon0 + 100 / (metresPerDegreeLat * cosLat0);
      final p = worldFromLatLon(lat0, lon, 0, lat0, lon0, cosLat0);
      expect(p.x, closeTo(100, 1e-6));
      expect(p.z, closeTo(0, 1e-6));
    });

    test('north is -Z', () {
      final lat = lat0 + 100 / metresPerDegreeLat;
      final p = worldFromLatLon(lat, lon0, 0, lat0, lon0, cosLat0);
      expect(p.z, closeTo(-100, 1e-6));
      expect(p.x, closeTo(0, 1e-6));
    });

    test('south is +Z', () {
      final lat = lat0 - 50 / metresPerDegreeLat;
      final p = worldFromLatLon(lat, lon0, 0, lat0, lon0, cosLat0);
      expect(p.z, closeTo(50, 1e-6));
    });

    test('negative AGL clamps to the ground plane', () {
      final p = worldFromLatLon(lat0, lon0, -5, lat0, lon0, cosLat0);
      expect(p.y, 0);
    });
  });

  group('orientationMatrix compass', () {
    Vector3 noseOf(Matrix4 m) =>
        Vector3(m.getColumn(1).x, m.getColumn(1).y, m.getColumn(1).z);

    test('vertical rocket points up', () {
      final nose = noseOf(RocketMesh.orientationMatrix(
          pitchDeg: 0, yawDeg: 0, scale: 1));
      expect(nose.x, closeTo(0, 1e-9));
      expect(nose.y, closeTo(1, 1e-9));
      expect(nose.z, closeTo(0, 1e-9));
    });

    test('pitch toward north (yaw 0) tilts to -Z', () {
      final nose = noseOf(RocketMesh.orientationMatrix(
          pitchDeg: 90, yawDeg: 0, scale: 1));
      expect(nose.x, closeTo(0, 1e-9));
      expect(nose.y, closeTo(0, 1e-9));
      expect(nose.z, closeTo(-1, 1e-9));
    });

    test('pitch toward east (yaw 90) tilts to +X', () {
      final nose = noseOf(RocketMesh.orientationMatrix(
          pitchDeg: 90, yawDeg: 90, scale: 1));
      expect(nose.x, closeTo(1, 1e-9));
      expect(nose.y, closeTo(0, 1e-9));
      expect(nose.z, closeTo(0, 1e-9));
    });

    test('basis is a proper rotation (det +1, not a mirror)', () {
      final m = RocketMesh.orientationMatrix(
          pitchDeg: 30, yawDeg: 45, rollDeg: 10, scale: 2);
      expect(m.determinant(), closeTo(8.0, 1e-6));
    });
  });

  group('recovery display state', () {
    test('assembled states show the cone, popped states do not', () {
      for (final s in [
        FsmState.idle,
        FsmState.armed,
        FsmState.ascent,
        FsmState.debugLocked,
      ]) {
        expect(s.hasNosecone, isTrue, reason: '$s');
        expect(s.hasParachute, isFalse, reason: '$s');
        expect(s.showsParachute, isFalse, reason: '$s');
      }
      for (final s in [
        FsmState.apogee,
        FsmState.debugUnlocked,
        FsmState.unknown,
      ]) {
        expect(s.hasNosecone, isFalse, reason: '$s');
        expect(s.hasParachute, isFalse, reason: '$s');
        expect(s.showsParachute, isFalse, reason: '$s');
      }
      expect(FsmState.landed.hasNosecone, isFalse, reason: 'landed');
      expect(FsmState.landed.showsParachute, isFalse, reason: 'landed');
    });

    test('nose cone stays UNLOCKED after landing, canopy renders only mid-descent', () {
      expect(FsmState.parachute.hasNosecone, isFalse);
      expect(FsmState.parachute.hasParachute, isTrue);
      expect(FsmState.parachute.showsParachute, isTrue);
      expect(FsmState.landed.hasNosecone, isFalse);
      expect(FsmState.landed.hasParachute, isTrue);
      expect(FsmState.landed.showsParachute, isFalse);
    });

    test('scene airframe config follows the FSM state', () {
      TelemetryState stateWith(FsmState s) {
        final frame = TelemetryFrame(
          flags: FrameFlags.gpsFix,
          latitude: 50.0,
          longitude: 14.0,
          baroAltitude: 100,
          fsmStateId: s.id,
        );
        final history = RingBuffer<TelemetryFrame>(16)..push(frame);
        return TelemetryState(
          history: history,
          deadReckoningHistory: RingBuffer<DeadReckoningPosition>(16),
          latest: frame,
        );
      }

      final chute = buildFlightScene(
          stateWith(FsmState.parachute), null)!;
      expect(chute.showParachute, isTrue);
      expect(chute.showNoseCone, isFalse);

      final landed =
          buildFlightScene(stateWith(FsmState.landed), null)!;
      expect(landed.showParachute, isFalse);
      expect(landed.showNoseCone, isFalse);

      final pad =
          buildFlightScene(stateWith(FsmState.armed), null)!;
      expect(pad.showNoseCone, isTrue);
      expect(pad.showParachute, isFalse);
    });

    test('relative altitude renders as-is with no grounded pinning', () {
      TelemetryState stateWith(FsmState s, double alt) {
        final frame = TelemetryFrame(
          flags: FrameFlags.gpsFix,
          latitude: 50.0,
          longitude: 14.0,
          baroAltitude: alt,
          fsmStateId: s.id,
        );
        final history = RingBuffer<TelemetryFrame>(16)..push(frame);
        return TelemetryState(
          history: history,
          deadReckoningHistory: RingBuffer<DeadReckoningPosition>(16),
          latest: frame,
        );
      }

      // Raw relative altitude renders untouched in every state.
      final pad = buildFlightScene(stateWith(FsmState.armed, 8.0), null)!;
      expect(pad.rocketPos.y, 8.0);
      expect(pad.trail.map((p) => p.y), everyElement(8.0));

      // Aloft states keep the reported altitude untouched.
      final flying =
          buildFlightScene(stateWith(FsmState.ascent, 100.0), null)!;
      expect(flying.rocketPos.y, 100.0);
    });
  });

  group('flightGroundGrid', () {
    FlightScene sceneWith({required double maxHoriz, required double maxAlt}) =>
        FlightScene(
          trail: const [],
          rocketPos: Vector3.zero(),
          rocketIsDeadReckoning: false,
          maxAlt: maxAlt,
          maxHoriz: maxHoriz,
          pitchDeg: 0,
          yawDeg: 0,
          rollDeg: 0,
          showNoseCone: true,
          showParachute: false,
          siteName: null,
        );

    test('small flights keep the minimum context', () {
      final grid = flightGroundGrid(sceneWith(maxHoriz: 0, maxAlt: 0));
      expect(grid.half, greaterThanOrEqualTo(60.0));
    });

    test('huge flights cap at 20x20 km', () {
      final grid =
          flightGroundGrid(sceneWith(maxHoriz: 40000, maxAlt: 20000));
      expect(grid.half, lessThanOrEqualTo(10000.0));
    });
  });

  group('cgAnchorPos', () {
    // Display scale for the ~80 cm airframe (mesh spans 2.15 model units).
    const scale = 0.8 / 2.15;

    test('vertical on the pad lifts the CG so the tail clears the ground',
        () {
      final anchor = cgAnchorPos(
        rocketPos: Vector3.zero(),
        pitchDeg: 0,
        yawDeg: 0,
        scale: scale,
      );
      // Tail sits (cgY - finBottom) * scale below the CG.
      final expectLift =
          (RocketMesh.cgY - RocketMesh.finBottom) * scale;
      expect(anchor.x, closeTo(0, 1e-9));
      expect(anchor.z, closeTo(0, 1e-9));
      expect(anchor.y, closeTo(expectLift, 1e-9));
    });

    test('horizontal rests the belly at body radius', () {
      final anchor = cgAnchorPos(
        rocketPos: Vector3.zero(),
        pitchDeg: 90,
        yawDeg: 0,
        scale: scale,
      );
      expect(anchor.y, closeTo(RocketMesh.bodyRadius * scale, 1e-9));
    });

    test('aloft the reported position passes through untouched', () {
      final pos = Vector3(10, 100, -5);
      final anchor = cgAnchorPos(
        rocketPos: pos,
        pitchDeg: 30,
        yawDeg: 45,
        scale: scale,
      );
      expect(anchor.x, closeTo(pos.x, 1e-9));
      expect(anchor.y, closeTo(pos.y, 1e-9));
      expect(anchor.z, closeTo(pos.z, 1e-9));
    });

    test('CG sits between the fin bottoms and the nose tip', () {
      expect(RocketMesh.cgY, greaterThan(RocketMesh.finBottom));
      expect(RocketMesh.cgY, lessThan(RocketMesh.noseTip));
    });

    test('terrain surface lifts the airframe instead of the flat plane',
        () {
      const groundY = 12.0;
      final anchor = cgAnchorPos(
        rocketPos: Vector3(0, groundY, 0),
        pitchDeg: 0,
        yawDeg: 0,
        scale: scale,
        groundY: groundY,
      );
      final expectLift =
          (RocketMesh.cgY - RocketMesh.finBottom) * scale;
      expect(anchor.y, closeTo(groundY + expectLift, 1e-9));
    });

    test('mesh already above the terrain passes through untouched', () {
      const groundY = 12.0;
      final pos = Vector3(5, groundY + 50, -3);
      final anchor = cgAnchorPos(
        rocketPos: pos,
        pitchDeg: 0,
        yawDeg: 0,
        scale: scale,
        groundY: groundY,
      );
      expect(anchor.y, closeTo(pos.y, 1e-9));
    });
  });

  group('clampEyeAboveTerrain', () {
    FlightCamera camFor(Vector3 eye, Vector3 target) =>
        flightCameraFromEyeTarget(
          eye: eye,
          target: target,
          dist: eye.distanceTo(target),
          fovY: flightFovY,
          aspect: 800 / 600,
          lightDir: Vector3(0, 1, 0),
        );

    test('eye under the surface is lifted, target kept', () {
      final cam = camFor(Vector3(10, 3, 40), Vector3(0, 25, 0));
      final fixed = clampEyeAboveTerrain(cam, 30.0);
      expect(fixed.eye.y, closeTo(30.0, 1e-9));
      expect(fixed.eye.x, closeTo(10.0, 1e-9));
      expect(fixed.target, cam.target);
      expect(fixed.lightDir, cam.lightDir);
      // Still a working camera: the target projects on screen.
      expect(
          projectToScreen(
              Vector3(0, 25, 0), fixed.vp, const Size(800, 600)),
          isNotNull);
    });

    test('eye already above passes through untouched', () {
      final cam = camFor(Vector3(10, 50, 40), Vector3(0, 25, 0));
      expect(identical(clampEyeAboveTerrain(cam, 30.0), cam), isTrue);
    });
  });

  group('capTrailPoints', () {
    List<Vector3> pts(int n) => [
          for (var i = 0; i < n; i++) Vector3(i.toDouble(), 0, 0),
        ];

    test('short lists pass through untouched', () {
      final p = pts(10);
      expect(identical(capTrailPoints(p), p), isTrue);
    });

    test('tip exact, start kept, capped', () {
      final out = capTrailPoints(pts(1000));
      expect(out.length, lessThanOrEqualTo(400));
      expect(out.first.x, 0);
      expect(out.last.x, 999);
      for (var i = 1; i < out.length; i++) {
        expect(out[i].x, greaterThan(out[i - 1].x));
      }
    });

    test('deterministic for the same input', () {
      final a = capTrailPoints(pts(1234));
      final b = capTrailPoints(pts(1234));
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].x, b[i].x);
      }
    });

    test('growing flights never move displayed points (no crawl)', () {
      // Regression: tip-anchored striding re-phased the whole trail on every
      // tick past the cap and the line visibly wobbled as the rocket flew.
      // Appends may only append (near the tip) or thin to a subset — no
      // surviving sample may ever shift coordinates.
      final full = pts(1200);
      var prev = capTrailPoints(full.sublist(0, 401));
      for (var len = 402; len <= 1200; len += 5) {
        final cur = capTrailPoints(full.sublist(0, len));
        expect(cur.length, lessThanOrEqualTo(400));
        expect(cur.first.x, 0);
        expect(cur.last.x, len - 1);
        // Away from the fresh tail (which legitimately gains newly-arrived
        // data), every displayed point already existed at the same spot.
        for (var i = 0; i < cur.length - 4; i++) {
          final p = cur[i];
          expect(
            prev.any((q) => q.x == p.x),
            isTrue,
            reason: 'len=$len point ${p.x} teleported',
          );
        }
        prev = cur;
      }
    });
  });

  group('trail bucket stability', () {
    TelemetryFrame fixAt(int ms, double alt) => TelemetryFrame(
          flags: FrameFlags.gpsFix,
          latitude: 50.0,
          longitude: 14.0,
          baroAltitude: alt,
          receivedAtMs: ms,
        );

    TelemetryState stateOf(List<TelemetryFrame> frames) {
      final history = RingBuffer<TelemetryFrame>(128);
      for (final f in frames) {
        history.push(f);
      }
      return TelemetryState(
        history: history,
        deadReckoningHistory: RingBuffer<DeadReckoningPosition>(16),
        latest: frames.last,
      );
    }

    test('extending history does not move earlier trail points', () {
      List<TelemetryFrame> frames(int n) =>
          [for (var i = 0; i < n; i++) fixAt(i * 100, i.toDouble())];
      // 30 fixes at 10 Hz stay well under the cap in both scenes; the old
      // span-derived bucket resampled them differently as span grew.
      final a = buildFlightScene(stateOf(frames(30)), null)!;
      final b = buildFlightScene(stateOf(frames(60)), null)!;
      expect(a.trail.length, 30);
      expect(b.trail.length, greaterThanOrEqualTo(30));
      for (var i = 0; i < a.trail.length; i++) {
        expect(b.trail[i].x, closeTo(a.trail[i].x, 1e-9));
        expect(b.trail[i].y, closeTo(a.trail[i].y, 1e-9));
        expect(b.trail[i].z, closeTo(a.trail[i].z, 1e-9));
      }
    });
  });

  group('formatUnderMeters', () {
    test('one decimal under 10 m, whole metres above', () {
      expect(formatUnderMeters(0.26), '0.3 m under ground');
      expect(formatUnderMeters(3), '3.0 m under ground');
      expect(formatUnderMeters(25.6), '26 m under ground');
    });
  });

  group('near-plane clipping', () {
    Matrix4 vpFor(Vector3 eye, Vector3 target) {
      final proj = makePerspectiveMatrix(
          50 * math.pi / 180, 800 / 600, 0.1, 100000);
      return proj * makeViewMatrix(eye, target, Vector3(0, 1, 0));
    }

    const size = Size(800, 600);

    test('geometry just in front of the camera still projects', () {
      final eye = Vector3(0, 5, 10);
      final target = Vector3(0, 0, 0);
      final vp = vpFor(eye, target);
      final dir = (target - eye).normalized();
      // 20 cm in front of the lens: the old 0.5 m cutoff dropped this,
      // eating the rocket mesh and ground cells close to the camera.
      expect(projectToScreen(eye + dir * 0.2, vp, size), isNotNull);
    });

    test('geometry behind the camera is culled', () {
      final eye = Vector3(0, 5, 10);
      final target = Vector3(0, 0, 0);
      final vp = vpFor(eye, target);
      final dir = (target - eye).normalized();
      expect(projectToScreen(eye - dir * 1.0, vp, size), isNull);
    });

    test('geometry between lens and near plane is culled (no streak)', () {
      final eye = Vector3(0, 5, 10);
      final target = Vector3(0, 0, 0);
      // near = 0.1 here: 5 cm out is between lens and near — the old bare
      // `w > eps` test projected it with a 20× divide into a streak.
      final vp = vpFor(eye, target);
      final dir = (target - eye).normalized();
      expect(projectToScreen(eye + dir * 0.05, vp, size), isNull);
      // Just past near still draws.
      expect(projectToScreen(eye + dir * 0.2, vp, size), isNotNull);
    });

    test('straddling segment pulls in to the near plane', () {
      final eye = Vector3(0, 5, 10);
      final target = Vector3(0, 0, 0);
      final vp = vpFor(eye, target);
      final dir = (target - eye).normalized();
      // One end between lens and near, other far ahead: the line draws
      // (pulled in) instead of vanishing or streaking.
      final clipped =
          clipWorldSegment(eye + dir * 0.05, eye + dir * 5.0, vp, size);
      expect(clipped, isNotNull);
      // Fully between lens and near: nothing to draw.
      expect(
          clipWorldSegment(eye + dir * 0.02, eye + dir * 0.05, vp, size),
          isNull);
    });
  });

  group('clipSegment2D', () {
    const rect = Rect.fromLTRB(0, 0, 800, 600);

    test('segment completely inside passes untouched', () {
      final clipped = clipSegment2D(
          const Offset(100, 100), const Offset(700, 500), rect);
      expect(clipped, isNotNull);
      expect(clipped!.$1, const Offset(100, 100));
      expect(clipped.$2, const Offset(700, 500));
    });

    test('segment completely outside is rejected', () {
      expect(
          clipSegment2D(const Offset(-200, 100), const Offset(-50, 200), rect),
          isNull);
      expect(
          clipSegment2D(const Offset(100, 700), const Offset(200, 900), rect),
          isNull);
    });

    test('segment exiting screen is clipped to edge', () {
      final clipped = clipSegment2D(
          const Offset(400, 300), const Offset(400, 100000), rect);
      expect(clipped, isNotNull);
      expect(clipped!.$1, const Offset(400, 300));
      expect(clipped.$2.dx, closeTo(400, 1e-6));
      expect(clipped.$2.dy, closeTo(600, 1e-6));
    });

    test('degenerate and infinite coordinates return null without throwing', () {
      expect(
          clipSegment2D(
              const Offset(double.nan, 0), const Offset(10, 10), rect),
          isNull);
      expect(
          clipSegment2D(
              const Offset(double.infinity, 0), const Offset(10, 10), rect),
          isNull);
    });
  });

  group('vertical camera stability & drop line', () {
    test('looking straight up produces valid view matrix without NaNs', () {
      final cam = flightCameraFromEyeTarget(
        eye: Vector3(0, 0, 0),
        target: Vector3(0, 1000, 0),
        dist: 1000,
        fovY: flightFovY,
        aspect: 800 / 600,
        lightDir: Vector3(0, 1, 0),
      );
      for (final v in cam.view.storage) {
        expect(v.isNaN, isFalse);
        expect(v.isInfinite, isFalse);
      }
      for (final v in cam.vp.storage) {
        expect(v.isNaN, isFalse);
        expect(v.isInfinite, isFalse);
      }
    });

    test('looking straight down produces valid view matrix without NaNs', () {
      final cam = flightCameraFromEyeTarget(
        eye: Vector3(0, 1000, 0),
        target: Vector3(0, 0, 0),
        dist: 1000,
        fovY: flightFovY,
        aspect: 800 / 600,
        lightDir: Vector3(0, 1, 0),
      );
      for (final v in cam.view.storage) {
        expect(v.isNaN, isFalse);
        expect(v.isInfinite, isFalse);
      }
    });

    test('pad camera looking straight up at ascending rocket clips drop line safely', () {
      // Pad camera: eye at (22, 3, 38), rocket at (0, 1000, 0)
      final eye = Vector3(22, 3, 38);
      final rocket = Vector3(0, 1000, 0);
      final ground = Vector3(0, 0, 0);
      final cam = flightCameraFromEyeTarget(
        eye: eye,
        target: rocket,
        dist: 1000,
        fovY: flightFovY,
        aspect: 800 / 600,
        lightDir: Vector3(0, 1, 0),
      );

      // Rocket projects near center of screen
      final rScreen = projectToScreen(rocket, cam.vp, const Size(800, 600))!;
      expect(rScreen.dx, inInclusiveRange(300, 500));
      expect(rScreen.dy, inInclusiveRange(200, 400));

      // Ground is behind camera (projectToScreen returns null)
      expect(projectToScreen(ground, cam.vp, const Size(800, 600)), isNull);

      // drawWorldSegment clipping produces line that terminates at screen margin,
      // never wrapping around from top to bottom
      final ca = cam.vp.transformed(Vector4(rocket.x, rocket.y, rocket.z, 1));
      var cb = cam.vp.transformed(Vector4(ground.x, ground.y, ground.z, 1));
      expect(cb.w, lessThanOrEqualTo(0));

      // Near clip line
      final denom = ca.w - cb.w;
      final t = ((clipEps - cb.w) / denom).clamp(0.0, 1.0);
      cb = cb * (1 - t) + ca * t;
      final pa = Offset(
        (ca.x / ca.w * 0.5 + 0.5) * 800,
        (0.5 - ca.y / ca.w * 0.5) * 600,
      );
      final pb = Offset(
        (cb.x / cb.w * 0.5 + 0.5) * 800,
        (0.5 - cb.y / cb.w * 0.5) * 600,
      );

      final clipped = clipSegment2D(
          pa, pb, Rect.fromLTRB(-64, -64, 800 + 64, 600 + 64));
      expect(clipped, isNotNull);
      // Clipped endpoint must be within screen bounds + safe margin
      expect(clipped!.$1.dx, inInclusiveRange(-64, 864));
      expect(clipped.$1.dy, inInclusiveRange(-64, 664));
      expect(clipped.$2.dx, inInclusiveRange(-64, 864));
      expect(clipped.$2.dy, inInclusiveRange(-64, 664));
    });

    test('clampEyeAboveTerrain on steep hill maintains safe pitch <= 80 deg', () {
      final cam = flightCameraFromEyeTarget(
        eye: Vector3(0, 10, 5),
        target: Vector3(0, 10, 0),
        dist: 5,
        fovY: flightFovY,
        aspect: 800 / 600,
        lightDir: Vector3(0, 1, 0),
      );
      // Hill pushes eye 50m above target
      final clamped = clampEyeAboveTerrain(cam, 60.0);
      expect(clamped.eye.y, 60.0);

      final forward = clamped.target - clamped.eye;
      final horiz = math.sqrt(forward.x * forward.x + forward.z * forward.z);
      final pitchDeg = math.atan2(-forward.y, horiz) * 180 / math.pi;
      // Must be capped at <= 80° (safe from 90° gimbal singularity)
      expect(pitchDeg, lessThanOrEqualTo(80.5));
      for (final v in clamped.view.storage) {
        expect(v.isNaN, isFalse);
      }
    });
  });

  group('onboard camera follows the full attitude', () {
    FlightScene sceneWith({
      required Vector3 pos,
      double pitchDeg = 0,
      double yawDeg = 0,
      double rollDeg = 0,
    }) =>
        FlightScene(
          trail: const [],
          rocketPos: pos,
          rocketIsDeadReckoning: false,
          maxAlt: pos.y,
          maxHoriz: 0,
          pitchDeg: pitchDeg,
          yawDeg: yawDeg,
          rollDeg: rollDeg,
          showNoseCone: true,
          showParachute: false,
          siteName: null,
        );

    FlightCamera onboard(FlightScene scene, {double spin = 0}) =>
        computeOnboardCamera(
          scene: scene,
          spinDeg: spin,
          aspect: 800 / 600,
        );

    Vector3 gaze(FlightCamera cam) =>
        (cam.target - cam.eye).normalized();

    test('level flight looks out the side, yaw swings it', () {
      final tilt = onboardDownTiltDeg * math.pi / 180;
      final ch = math.cos(tilt);
      final sh = math.sin(tilt);
      final east = gaze(onboard(sceneWith(pos: Vector3(0, 100, 0))));
      expect(east.x, closeTo(ch, 1e-9));
      expect(east.y, closeTo(-sh, 1e-9));
      expect(east.z, closeTo(0, 1e-9));

      final south = gaze(onboard(
          sceneWith(pos: Vector3(0, 100, 0), yawDeg: 90)));
      expect(south.x, closeTo(0, 1e-9));
      expect(south.y, closeTo(-sh, 1e-9));
      expect(south.z, closeTo(ch, 1e-9));
    });

    test('lens rides at the rocket with a fixed frame', () {
      final pos = Vector3(30, 200, -40);
      final cam = onboard(sceneWith(pos: pos));
      expect(cam.eye.x, closeTo(pos.x, 1e-9));
      expect(cam.eye.y, closeTo(pos.y, 1e-9));
      expect(cam.eye.z, closeTo(pos.z, 1e-9));
      expect(cam.eye.distanceTo(cam.target), closeTo(10, 1e-9));
      expect(cam.fovY, closeTo(flightFovY, 1e-9));
    });

    test('roll spins the gaze around the nose', () {
      // Vertical rocket, rolled 90°: the side gaze swings from east onto
      // the nose axis plane (here north) while the nose itself stays up.
      // The fixed down-tilt rides along, dipping the gaze below level.
      final tilt = onboardDownTiltDeg * math.pi / 180;
      final cam = onboard(
          sceneWith(pos: Vector3(0, 100, 0), rollDeg: 90));
      final look = gaze(cam);
      expect(look.x, closeTo(0, 1e-6));
      expect(look.y, closeTo(-math.sin(tilt), 1e-6));
      expect(look.z, closeTo(-math.cos(tilt), 1e-6));
    });

    test('pitched-over rocket tilts the horizon (nose stays up)', () {
      // Nose horizontal to the north: the nose must paint straight up on
      // screen while world-up falls to the screen edge. Probe points sit
      // ahead of the lens (pure side points are at eye depth, where the
      // projection is singular).
      final eye = Vector3(0, 100, 0);
      final cam = onboard(
          sceneWith(pos: eye, pitchDeg: 90, yawDeg: 0));
      const size = Size(800, 600);
      final ahead = eye + gaze(cam) * 10;
      final center = projectToScreen(ahead, cam.vp, size)!;
      final noseUp =
          projectToScreen(ahead + Vector3(0, 0, -5), cam.vp, size)!;
      final worldUp =
          projectToScreen(ahead + Vector3(0, 5, 0), cam.vp, size)!;
      expect(noseUp.dx, closeTo(center.dx, 2.0));
      expect(noseUp.dy, lessThan(center.dy));
      expect(worldUp.dx, greaterThan(center.dx));
      for (final v in cam.view.storage) {
        expect(v.isNaN, isFalse);
      }
    });

    test('local look-around matches the old yaw-relative law in level flight',
        () {
      // Level flight keeps world-up as the strapped up, so an azimuth
      // offset must equal the compass yaw (yaw + 90 + offset) exactly,
      // scaled by the fixed down-tilt (horizontal ring shrinks by cos,
      // vertical dips by -sin).
      final tilt = onboardDownTiltDeg * math.pi / 180;
      final ch = math.cos(tilt);
      final sh = math.sin(tilt);
      final cam = onboard(sceneWith(pos: Vector3(0, 100, 0)), spin: 20);
      final look = gaze(cam);
      final yawRad = (90 + 20) * math.pi / 180;
      expect(look.x, closeTo(ch * math.sin(yawRad), 1e-9));
      expect(look.y, closeTo(-sh, 1e-9));
      expect(look.z, closeTo(-ch * math.cos(yawRad), 1e-9));
    });
  });

  group('onboard smoothing', () {
    test('dampAngleDeg takes the short way around the wrap', () {
      expect(dampAngleDeg(350, 10, 0.5), closeTo(360, 1e-9));
      expect(dampAngleDeg(10, 350, 0.5), closeTo(0, 1e-9));
      expect(dampAngleDeg(0, 90, 0.25), closeTo(22.5, 1e-9));
      expect(dampAngleDeg(45, 45, 0.3), closeTo(45, 1e-9));
    });

    test('first update snaps, later ticks ease a fraction', () {
      final s = OnboardAttitudeSmoother();
      s.update(pitchDeg: 5, yawDeg: 350, rollDeg: 0);
      expect(s.pitchDeg, closeTo(5, 1e-9));
      expect(s.yawDeg, closeTo(350, 1e-9));
      s.update(pitchDeg: 15, yawDeg: 10, rollDeg: 0);
      expect(s.pitchDeg, closeTo(5 + 10 * onboardSmoothFactor, 1e-9));
      // 350 → 10 eases forward (+20° path), not back around.
      expect(s.yawDeg, closeTo(350 + 20 * onboardSmoothFactor, 1e-9));
    });

    test('jumps past the snap threshold teleport instead of slewing', () {
      final s = OnboardAttitudeSmoother();
      s.update(pitchDeg: 0, yawDeg: 0, rollDeg: 0);
      s.update(pitchDeg: 0, yawDeg: 100, rollDeg: 0);
      expect(s.yawDeg, closeTo(100, 1e-9));
      s.update(pitchDeg: 80, yawDeg: 100, rollDeg: 0);
      expect(s.pitchDeg, closeTo(80, 1e-9));
    });
  });
}
