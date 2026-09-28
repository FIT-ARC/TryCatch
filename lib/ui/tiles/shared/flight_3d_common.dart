import 'dart:math' as math;

import 'package:flutter/material.dart';
// `Colors` collides with material's — material's wins here.
import 'package:vector_math/vector_math_64.dart' hide Colors;
import '../../../theme/app_colors.dart';
import './rocket_mesh.dart';

/// Shared scene, camera and painter helpers for the 3D flight views (Flight
/// path, 3D Flight and Onboard camera). Every tile renders the same
/// [FlightScene] with the same orbit cameras and the onboard strap-down lens
/// ([FlightLens]); only the ground and the lens differ.
///
/// World frame (right-handed, so the standard view matrix never mirrors):
/// X east, Y up (AGL), Z **south** — because E×U=S. (A previous revision used
/// +Z north, a left-handed frame that rendered east/west flipped.)
///
/// The compass language is shared too: E amber, U green, N blue.

export './flight_scene_builder.dart';
import './flight_scene_builder.dart';


// ── Camera ───────────────────────────────────────────────────────────────────

/// Vertical field of view (radians) shared by the flight cameras.
const double flightFovY = 50 * math.pi / 180;

/// Fixed downward tilt (degrees) of the onboard strap-down lens: the gaze
/// sits slightly below the airframe plane so a touch more ground shows.
const double onboardDownTiltDeg = 8.0;

/// Computed camera for one frame.
class FlightCamera {
  final Matrix4 view;
  final Matrix4 vp;
  final Vector3 eye;
  final Vector3 target;
  final double dist;

  /// Vertical field of view (radians) and aspect ratio, so the satellite
  /// drape can build analytic ground rays without inverting [vp] per frame
  /// (the inverse jittered at grazing angles and read as terrain wobble).
  final double fovY;
  final double aspect;
  final Vector3 lightDir;

  const FlightCamera({
    required this.view,
    required this.vp,
    required this.eye,
    required this.target,
    required this.dist,
    required this.fovY,
    required this.aspect,
    required this.lightDir,
  });
}

/// The lens a satellite flight painter draws through: one of the
/// user-selectable orbit modes, or the fixed onboard strap-down camera.
sealed class FlightLens {
  const FlightLens();

  /// Builds the frame's camera for [scene].
  FlightCamera compute({required FlightScene scene, required double aspect});

  /// Whether the airframe stays out of its own view (onboard).
  bool get hideAirframe;

  /// Whether the lens-glass vignette is painted (onboard).
  bool get glassVignette;
}

/// An orbit-mode lens carrying the shared orbit angles and zoom.
class OrbitLens extends FlightLens {
  final FlightCameraMode mode;
  final double azimuthDeg;
  final double elevationDeg;
  final double zoom;

  const OrbitLens({
    required this.mode,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.zoom,
  });

  @override
  FlightCamera compute({required FlightScene scene, required double aspect}) =>
      computeFlightCamera(
        scene: scene,
        mode: mode,
        azimuthDeg: azimuthDeg,
        elevationDeg: elevationDeg,
        zoom: zoom,
        aspect: aspect,
      );

  @override
  bool get hideAirframe => false;

  @override
  bool get glassVignette => false;

  @override
  bool operator ==(Object other) =>
      other is OrbitLens &&
      other.mode == mode &&
      other.azimuthDeg == azimuthDeg &&
      other.elevationDeg == elevationDeg &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(mode, azimuthDeg, elevationDeg, zoom);
}

/// The fixed onboard strap-down lens, spun around the rocket's long axis.
class OnboardLens extends FlightLens {
  /// Spin (degrees) around the nose axis from the pure side view.
  final double spinDeg;

  const OnboardLens({required this.spinDeg});

  @override
  FlightCamera compute({required FlightScene scene, required double aspect}) =>
      computeOnboardCamera(scene: scene, spinDeg: spinDeg, aspect: aspect);

  @override
  bool get hideAirframe => true;

  @override
  bool get glassVignette => true;

  @override
  bool operator ==(Object other) =>
      other is OnboardLens && other.spinDeg == spinDeg;

  @override
  int get hashCode => spinDeg.hashCode;
}

FlightCamera computeFlightCamera({
  required FlightScene scene,
  required FlightCameraMode mode,
  required double azimuthDeg,
  required double elevationDeg,
  required double zoom,
  required double aspect,
}) {
  // Camera target/distance. Chase keeps a constant standoff from the
  // rocket (it used to scale with the flight extents, so the camera drifted
  // away as the flight grew); orbit-field frames the whole scene.
  final center = Vector3(0, scene.maxAlt * 0.45, 0);
  final sceneRadius = math.max(40.0, math.max(scene.maxHoriz, scene.maxAlt));

  final (Vector3 target, double dist) = switch (mode) {
    FlightCameraMode.chase => (scene.rocketPos, 7.0 / zoom),
    _ => (
        center,
        math.max(60.0, sceneRadius * 2.2) / zoom,
      ),
  };

  final az = radians(azimuthDeg);
  // Capped below the degenerate straight-down view, where the camera basis
  // (and a map-style N-up/E-right reading of it) breaks down.
  final el = radians(elevationDeg.clamp(-15.0, 80.0));
  final camDir = Vector3(
    math.cos(el) * math.sin(az),
    math.sin(el),
    math.cos(el) * math.cos(az),
  );
  var eye = target + camDir * dist;
  if (eye.y < 2.0) eye = Vector3(eye.x, 2.0, eye.z);

  // Headlight slightly above the camera, like the orientation viewer.
  final light = (camDir.clone()..scale(0.6)) + Vector3(-0.25, 0.8, 0.1);

  return flightCameraFromEyeTarget(
    eye: eye,
    target: target,
    dist: dist,
    fovY: flightFovY,
    aspect: aspect,
    lightDir: light.normalized(),
  );
}

/// Strap-down onboard lens: the eye rides at the rocket, looking out the
/// airframe's right side (tilted down by [onboardDownTiltDeg]) with the nose
/// as "up", so the horizon follows the full attitude — yaw swings it, pitch
/// tilts it, roll spins it. [spinDeg] turns the gaze around the nose axis
/// (0 = exactly sideways); the lens has a fixed down-tilt and no zoom.
///
/// The look direction and up vector come from the same orientation matrix
/// [RocketMesh] paints with, so lens and airframe can never disagree.
FlightCamera computeOnboardCamera({
  required FlightScene scene,
  required double spinDeg,
  required double aspect,
}) {
  var eye = scene.rocketPos;
  if (eye.y < 2.0) eye = Vector3(eye.x, 2.0, eye.z);
  final orientation = RocketMesh.orientationMatrix(
    pitchDeg: scene.pitchDeg,
    yawDeg: scene.yawDeg,
    rollDeg: scene.rollDeg,
    scale: 1.0,
  );
  Vector3 column(int i) {
    final c = orientation.getColumn(i);
    return Vector3(c.x, c.y, c.z).normalized();
  }

  var upVec = column(1);
  final lookDir = column(0);
  // Spin around the nose axis only, keeping the fixed down-tilt off the
  // airframe plane.
  lookDir.applyAxisAngle(upVec, -radians(spinDeg));
  final elAxis = lookDir.cross(upVec);
  if (elAxis.length > 1e-6) {
    lookDir.applyAxisAngle(elAxis.normalized(), radians(-onboardDownTiltDeg));
  }
  // Defensive: never build the view matrix with a near-collinear up.
  if (lookDir.dot(upVec).abs() > 0.995) {
    upVec = column(2);
    if (lookDir.dot(upVec).abs() > 0.995) upVec = Vector3(0, 1, 0);
  }
  final target = eye + lookDir * 10.0;
  final light = (lookDir.clone()..scale(0.6)) + Vector3(-0.25, 0.8, 0.1);
  final view = makeViewMatrix(eye, target, upVec);
  final vp =
      flightProjection(eyeDist: 10.0, fovY: flightFovY, aspect: aspect) * view;
  return FlightCamera(
    view: view,
    vp: vp,
    eye: eye,
    target: target,
    dist: 10.0,
    fovY: flightFovY,
    aspect: aspect,
    lightDir: light.normalized(),
  );
}

/// Projection whose near/far hug the actual eye distance so it stays
/// well-conditioned: a fixed 0.5 m near against a ~120 km far made the
/// old inverse view-projection jitter at grazing angles. The far plane
/// still clears the 45 km far-terrain ring from any camera.
Matrix4 flightProjection({
  required double eyeDist,
  required double fovY,
  required double aspect,
}) {
  final near = (eyeDist * 0.02).clamp(0.05, 50.0);
  final far = eyeDist + 90000.0;
  return makePerspectiveMatrix(fovY, aspect, near, far);
}

/// Assembles a [FlightCamera] from an explicit eye/target pair (shared by
/// [computeFlightCamera] and [clampEyeAboveTerrain] so both agree exactly).
FlightCamera flightCameraFromEyeTarget({
  required Vector3 eye,
  required Vector3 target,
  required double dist,
  required double fovY,
  required double aspect,
  required Vector3 lightDir,
}) {
  final forward = target - eye;
  final fLen = forward.length;
  Vector3 up = Vector3(0, 1, 0);
  if (fLen > 1e-6) {
    final fNorm = forward / fLen;
    // When looking nearly vertically (straight up or straight down),
    // forward is collinear with world up (0, 1, 0) and the cross product
    // vanishes, causing view-matrix singularity/NaNs. Use North (0, 0, -1)
    // as camera up in that singularity.
    if (fNorm.y.abs() > 0.995) {
      up = Vector3(0, 0, fNorm.y > 0 ? -1 : 1);
    }
  }
  final view = makeViewMatrix(eye, target, up);
  final vp = flightProjection(
        eyeDist: eye.distanceTo(target),
        fovY: fovY,
        aspect: aspect,
      ) *
      view;
  return FlightCamera(
    view: view,
    vp: vp,
    eye: eye,
    target: target,
    dist: dist,
    fovY: fovY,
    aspect: aspect,
    lightDir: lightDir,
  );
}

/// Lifts a camera that ended up under the terrain surface back above it,
/// keeping the target (the clamped rocket) fixed. Without this, chase/pad
/// views dive underground whenever the raw target sits below a DEM hill —
/// the camera must follow the clamped rocket, not the reported one.
FlightCamera clampEyeAboveTerrain(FlightCamera cam, double minEyeY) {
  if (cam.eye.y >= minEyeY) return cam;
  var newEye = Vector3(cam.eye.x, minEyeY, cam.eye.z);
  // Guard against near-vertical look down on steep hills:
  // if eye is pushed high while horizontally close to target, maintain
  // a minimum horizontal distance so the pitch angle does not exceed 80°.
  final dx = newEye.x - cam.target.x;
  final dz = newEye.z - cam.target.z;
  final horizDist = math.sqrt(dx * dx + dz * dz);
  final dy = newEye.y - cam.target.y;
  if (dy > 0) {
    const maxSlope = 5.67128; // tan(80°)
    final minHoriz = dy / maxSlope;
    if (horizDist < minHoriz) {
      if (horizDist > 1e-4) {
        final scale = minHoriz / horizDist;
        newEye = Vector3(
          cam.target.x + dx * scale,
          newEye.y,
          cam.target.z + dz * scale,
        );
      } else {
        newEye = Vector3(newEye.x, newEye.y, newEye.z + minHoriz);
      }
    }
  }
  return flightCameraFromEyeTarget(
    eye: newEye,
    target: cam.target,
    dist: cam.dist,
    fovY: cam.fovY,
    aspect: cam.aspect,
    lightDir: cam.lightDir,
  );
}

// ── Onboard lens: smoothing + vignette ───────────────────────────────────────

/// Per-tick blend factor for the onboard strap-down lens: a light touch, so
/// most of the raw attitude shows through each tick and only the high-
/// frequency jitter melts away.
const double onboardSmoothFactor = 0.3;

/// Raw-attitude jump that snaps the smoother instead of slewing (replay
/// seeks, new flights, link dropouts). Below this the lens eases over.
const double onboardSnapDegrees = 30.0;

/// Shortest-path lerp between degree angles (wraps at 360, so 350 → 10
/// eases forward through 0 instead of slewing back 340°). Pure.
double dampAngleDeg(double prev, double next, double t) {
  var d = (next - prev) % 360.0;
  if (d > 180.0) d -= 360.0;
  if (d < -180.0) d += 360.0;
  return prev + d * t;
}

/// Tiny exponential smoother for the onboard attitude, one per tile. First
/// update (or any jump past [onboardSnapDegrees]) snaps straight to raw so
/// seeks and new flights never smear across the sky.
class OnboardAttitudeSmoother {
  double _pitch = 0;
  double _yaw = 0;
  double _roll = 0;
  bool _hasValue = false;

  double get pitchDeg => _pitch;
  double get yawDeg => _yaw;
  double get rollDeg => _roll;

  void reset() => _hasValue = false;

  void _snap(double pitchDeg, double yawDeg, double rollDeg) {
    _pitch = pitchDeg;
    _yaw = yawDeg;
    _roll = rollDeg;
    _hasValue = true;
  }

  static double _circDelta(double from, double to) {
    var d = (to - from) % 360.0;
    if (d > 180.0) d -= 360.0;
    if (d < -180.0) d += 360.0;
    return d;
  }

  void update({
    required double pitchDeg,
    required double yawDeg,
    required double rollDeg,
    double factor = onboardSmoothFactor,
  }) {
    if (!_hasValue) {
      _snap(pitchDeg, yawDeg, rollDeg);
      return;
    }
    if ((pitchDeg - _pitch).abs() > onboardSnapDegrees ||
        _circDelta(_yaw, yawDeg).abs() > onboardSnapDegrees ||
        _circDelta(_roll, rollDeg).abs() > onboardSnapDegrees) {
      _snap(pitchDeg, yawDeg, rollDeg);
      return;
    }
    _pitch += (pitchDeg - _pitch) * factor;
    _yaw = dampAngleDeg(_yaw, yawDeg, factor);
    _roll = dampAngleDeg(_roll, rollDeg, factor);
  }

  /// Eases [scene]'s attitude one tick and returns it with the smoothed
  /// angles; the trail and extents pass through untouched. Call once per
  /// build for the onboard lens.
  FlightScene apply(FlightScene scene) {
    update(
      pitchDeg: scene.pitchDeg,
      yawDeg: scene.yawDeg,
      rollDeg: scene.rollDeg,
    );
    return scene.withAttitude(
      pitchDeg: pitchDeg,
      yawDeg: yawDeg,
      rollDeg: rollDeg,
    );
  }
}

/// Onboard gaze spin (degrees) after a horizontal drag [dx]: dragging right
/// turns the gaze around the nose, wrapped to [0, 360).
double spinAfterDrag(double spinDeg, double dx) => (spinDeg - dx * 0.4) % 360;

/// Camera-lens vignette for the onboard view: a hard-edged dark ring hugging
/// the frame periphery, painted last so it reads as glass in front of the
/// scene. (The gradient radius is a fraction of the shortest side, so stop
/// 1.0 lands past the corners and they always reach full [strength].)
void paintVignette(Canvas canvas, Size size, {double strength = 0.85}) {
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.9,
        colors: [
          const Color(0x00000000),
          const Color(0x00000000),
          Colors.black.withValues(alpha: strength),
          Colors.black.withValues(alpha: strength),
        ],
        stops: const [0.0, 0.7, 0.9, 1.0],
      ).createShader(Offset.zero & size),
  );
}

// ── Projection helpers ───────────────────────────────────────────────────────

/// Clip-space → NDC → pixel coordinates; `null` when behind the lens or
/// between the lens and the near plane (whose `1/w` divide would explode
/// into streaks — see [_clipInFront]).
Offset? projectToScreen(Vector3 world, Matrix4 vp, Size size) {
  final clip = vp.transformed(Vector4(world.x, world.y, world.z, 1));
  if (!_clipInFront(clip)) return null;
  final ndc = clip.xyz / clip.w;
  return Offset(
    (ndc.x * 0.5 + 0.5) * size.width,
    (0.5 - ndc.y * 0.5) * size.height,
  );
}

/// Clips 2D segment [p0]->[p1] against [rect] using Cohen-Sutherland.
/// Returns the clipped endpoints, or `null` if completely outside.
(Offset, Offset)? clipSegment2D(Offset p0, Offset p1, Rect rect) {
  var x0 = p0.dx, y0 = p0.dy;
  var x1 = p1.dx, y1 = p1.dy;
  if (x0.isNaN || y0.isNaN || x1.isNaN || y1.isNaN) return null;
  if (x0.isInfinite || y0.isInfinite || x1.isInfinite || y1.isInfinite) {
    return null;
  }

  const inside = 0;
  const left = 1;
  const right = 2;
  const bottom = 4;
  const top = 8;

  int outCode(double x, double y) {
    var code = inside;
    if (x < rect.left) {
      code |= left;
    } else if (x > rect.right) {
      code |= right;
    }
    if (y < rect.top) {
      code |= top;
    } else if (y > rect.bottom) {
      code |= bottom;
    }
    return code;
  }

  var code0 = outCode(x0, y0);
  var code1 = outCode(x1, y1);

  while (true) {
    if ((code0 | code1) == 0) {
      return (Offset(x0, y0), Offset(x1, y1));
    } else if ((code0 & code1) != 0) {
      return null;
    } else {
      final outCodeOut = code0 != 0 ? code0 : code1;
      double x = 0, y = 0;
      final dx = x1 - x0;
      final dy = y1 - y0;

      if ((outCodeOut & top) != 0) {
        if (dy.abs() < 1e-12) return null;
        x = x0 + dx * (rect.top - y0) / dy;
        y = rect.top;
      } else if ((outCodeOut & bottom) != 0) {
        if (dy.abs() < 1e-12) return null;
        x = x0 + dx * (rect.bottom - y0) / dy;
        y = rect.bottom;
      } else if ((outCodeOut & right) != 0) {
        if (dx.abs() < 1e-12) return null;
        y = y0 + dy * (rect.right - x0) / dx;
        x = rect.right;
      } else if ((outCodeOut & left) != 0) {
        if (dx.abs() < 1e-12) return null;
        y = y0 + dy * (rect.left - x0) / dx;
        x = rect.left;
      }

      if (outCodeOut == code0) {
        x0 = x;
        y0 = y;
        code0 = outCode(x0, y0);
      } else {
        x1 = x;
        y1 = y;
        code1 = outCode(x1, y1);
      }
    }
  }
}

void drawWorldSegment(Canvas canvas, Vector3 a, Vector3 b, Matrix4 vp,
    Size size, Paint paint) {
  final clipped = clipWorldSegment(a, b, vp, size);
  if (clipped == null) return;
  canvas.drawLine(clipped.$1, clipped.$2, paint);
}

/// Projects a world-space segment to drawable screen endpoints: near-plane
/// pull-in for ends behind the camera plus 2D bounds clipping. Returns
/// `null` when fully behind the camera or off screen. Shared core of
/// [drawWorldSegment] and the batched polyline painters below, so single
/// lines and batched paths clip identically.
(Offset, Offset)? clipWorldSegment(
    Vector3 a, Vector3 b, Matrix4 vp, Size size) {
  var ca = _clipOf(a, vp);
  var cb = _clipOf(b, vp);
  final aIn = _clipInFront(ca);
  final bIn = _clipInFront(cb);
  // Fully outside the near planes: nothing to draw.
  if (!aIn && !bIn) return null;
  // Partially outside: pull the outside end to the near-plane intersection
  // instead of dropping the whole line (receding lines used to vanish at
  // low camera angles).
  if (!aIn) {
    ca = _clipNear(ca, cb);
  } else if (!bIn) {
    cb = _clipNear(cb, ca);
  }
  final pa = _divideClip(ca, size);
  final pb = _divideClip(cb, size);
  final safeRect =
      Rect.fromLTRB(-64, -64, size.width + 64, size.height + 64);
  return clipSegment2D(pa, pb, safeRect);
}

/// Near-plane guard for [projectToScreen] and friends: drawable means past
/// the lens (`w > eps`) AND past the true near plane (`z + w > eps` —
/// the perspective matrix is OpenGL-style, so near is `z = -w`, not a
/// fixed `w` cutoff; geometry between lens and near must not project).
/// (An older 0.5 m cutoff ate the rocket mesh and ground cells close to
/// the lens; a bare `w > eps` kept between-lens-and-near streaks.)
const double clipEps = 1e-6;

bool _clipInFront(Vector4 c) =>
    c.w > clipEps && (c.z + c.w) > clipEps;

Vector4 _clipOf(Vector3 world, Matrix4 vp) =>
    vp.transformed(Vector4(world.x, world.y, world.z, 1));

Offset _divideClip(Vector4 c, Size size) => Offset(
      (c.x / c.w * 0.5 + 0.5) * size.width,
      (0.5 - c.y / c.w * 0.5) * size.height,
    );

/// Intersection of segment out→inn with the near volume (both the lens
/// plane `w = eps` and the near plane `z + w = eps`): the farther of the
/// two crossings, so the pulled-in end satisfies both. A single-plane
/// crossing is wrong for grazing edges that pierce the planes in
/// either order.
Vector4 _clipNear(Vector4 out, Vector4 inn) {
  var t = 0.0;
  final dw = inn.w - out.w;
  if (dw.abs() >= 1e-12) {
    t = math.max(t, (clipEps - out.w) / dw);
  }
  final dn = (inn.z + inn.w) - (out.z + out.w);
  if (dn.abs() >= 1e-12) {
    t = math.max(t, (clipEps - (out.z + out.w)) / dn);
  }
  t = t.clamp(0.0, 1.0);
  return out * (1 - t) + inn * t;
}

/// Generic Sutherland–Hodgman pass of polygon [poly] against one clip-space
/// plane, keeping the `dist > eps` side.
List<Vector4> _clipPlane4(
  List<Vector4> poly,
  double Function(Vector4 v) dist,
) {
  if (poly.isEmpty) return poly;
  final out = <Vector4>[];
  for (var i = 0; i < poly.length; i++) {
    final cur = poly[i];
    final prev = poly[(i + poly.length - 1) % poly.length];
    final dCur = dist(cur);
    final dPrev = dist(prev);
    final curIn = dCur > clipEps;
    final prevIn = dPrev > clipEps;
    Vector4 cross(Vector4 o, Vector4 n, double dO, double dN) {
      final denom = dN - dO;
      if (denom.abs() < 1e-12) return n;
      final t = ((clipEps - dO) / denom).clamp(0.0, 1.0);
      return o * (1 - t) + n * t;
    }

    if (curIn) {
      if (!prevIn) out.add(cross(prev, cur, dPrev, dCur));
      out.add(cur);
    } else if (prevIn) {
      out.add(cross(cur, prev, dCur, dPrev));
    }
  }
  return out;
}

/// Fills a world-space quad, clipped against the near plane (Sutherland–
/// Hodgman in clip space) so the ground keeps covering the view at low
/// camera angles instead of popping out.
void fillWorldQuad(
    Canvas canvas, List<Vector3> corners, Matrix4 vp, Size size, Paint paint) {
  var poly = [for (final c in corners) _clipOf(c, vp)];
  // Near-volume clip (lens plane, then true near plane) so the ground keeps
  // covering the view at low camera angles instead of popping out — and so
  // between-lens-and-near corners never project into streaks.
  poly = _clipPlane4(poly, (v) => v.w);
  poly = _clipPlane4(poly, (v) => v.z + v.w);
  final clipped = poly;
  if (clipped.length < 3) return;
  final path = Path();
  for (var i = 0; i < clipped.length; i++) {
    final p = _divideClip(clipped[i], size);
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  path.close();
  canvas.drawPath(path, paint);
}

void drawGroundCircle(Canvas canvas, Vector3 center, double radius, Matrix4 vp,
    Size size, Paint paint) {
  final path = Path();
  var pen = false;
  for (var i = 0; i <= 32; i++) {
    final a = i * 2 * math.pi / 32;
    final s = projectToScreen(
      center + Vector3(radius * math.cos(a), 0, radius * math.sin(a)),
      vp,
      size,
    );
    if (s == null) {
      pen = false;
      continue;
    }
    if (pen) {
      path.lineTo(s.dx, s.dy);
    } else {
      path.moveTo(s.dx, s.dy);
      pen = true;
    }
  }
  canvas.drawPath(path, paint);
}

/// Rounds up to a 1-2-5 progression so grid spacing stays readable.
double niceCeil(double v) {
  if (v <= 0) return 1;
  final mag =
      math.pow(10, (math.log(v) / math.ln10).floorToDouble()).toDouble();
  for (final m in const [1.0, 2.0, 5.0, 10.0]) {
    if (v <= m * mag) return m * mag;
  }
  return 10 * mag;
}

/// Ground grid extents for a scene (shared by the plain and textured ground
/// so the satellite patch can be sized to cover them).
///
/// Capped at 10 km half-side (20×20 km): the camera still frames flights
/// that drift further, but the detailed ground/imagery stops growing and
/// the far-terrain ring takes over behind it.
({double half, double step}) flightGroundGrid(FlightScene scene) {
  final gridHalf = math.min(
      10000.0,
      niceCeil(
          math.max(60.0, math.max(scene.maxHoriz * 1.3, scene.maxAlt * 0.6))));
  final step = niceCeil(gridHalf / 8);
  final n = (gridHalf / step).ceil();
  return (half: n * step, step: step);
}

// ── Shared painters ──────────────────────────────────────────────────────────

/// Procedural sky + far terrain ring, painted first so low camera angles meet
/// a horizon instead of the card void. Palette-relative, so dark mode gets a
/// night sky for free. (A photo skybox can replace the gradient later — the
/// call sits in one place per painter.)
///
/// The far ring is deliberately huge (past the horizon from any flight
/// camera) and sits a hair below the detailed plane so the near ground
/// overdraws it with no z-fighting shimmer; it is tinted from [groundTint]
/// (the satellite patch's mean color) lightly lifted toward the sky, so the
/// seam reads as distance instead of a grey card. Sky and ground meet
/// directly at the horizon — no haze band overlays (a banded overlay reads
/// as a separate stripe at low camera angles).
void paintSkyAndFarTerrain(Canvas canvas, Size size, FlightCamera cam,
    {Color? groundTint}) {
  final vp = cam.vp;
  final dark = AppThemeMode.instance.value;
  final zenith = dark
      ? const Color(0xFF0A0E1E)
      : const Color(0xFF7FA8D9);
  final mid = dark
      ? const Color(0xFF232B4A)
      : const Color(0xFFB4C9E4);
  final horizonSky = dark
      ? const Color(0xFF3D3A4D)
      : const Color(0xFFE9E6EC);
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: const Alignment(0, 0.9),
        colors: [zenith, mid, horizonSky],
        stops: const [0.0, 0.55, 0.85],
      ).createShader(Offset.zero & size),
  );
  // Far ground picks up the local landscape; the haze pull toward the sky
  // keeps it luminous at the horizon without washing it grey up close.
  final neutral = dark
      ? const Color(0xFF2A2E2A)
      : const Color(0xFFB7BCAE);
  final tint = groundTint ?? neutral;
  final farBase = dark
      ? Color.lerp(tint, Colors.black, 0.55)!
      : Color.lerp(tint, horizonSky, 0.22)!;
  const farHalf = 45000.0;
  const farY = -1.5;
  fillWorldQuad(
    canvas,
    [
      Vector3(-farHalf, farY, -farHalf),
      Vector3(farHalf, farY, -farHalf),
      Vector3(farHalf, farY, farHalf),
      Vector3(-farHalf, farY, farHalf),
    ],
    vp,
    size,
    Paint()..color = farBase,
  );
}

/// GPS trail (solid blue). The dead reckoning estimate is never part of the
/// trail — when [FlightScene.rocketIsDeadReckoning] is true the trail stops
/// at the last GPS fix and the
/// dead-reckoning leg is drawn separately as a violet dashed connector (see
/// [paintDropLineAndDeadReckoning]). With [tipOverride] (and a GPS-locked rocket) the
/// last leg runs to the override (the CG-anchored, ground-clamped rocket
/// position) instead of the raw reported fix, so the trail meets the
/// rocket's middle.
void paintFlightTrail(
    Canvas canvas, FlightScene scene, Matrix4 vp, Size size,
    {Vector3? tipOverride}) {
  final gpsPaint = Paint()
    ..color = AppColors.seriesGpsTrack.withValues(alpha: 0.85)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  // One batched path instead of a drawLine per leg (up to 400 draw calls):
  // identical pixels (same paint, same per-leg clipping), one draw. The pen
  // breaks at culled legs so near-plane seams can't stitch across the lens.
  final path = Path();
  Offset? pen;
  void leg(Vector3 from, Vector3 to) {
    final clipped = clipWorldSegment(from, to, vp, size);
    if (clipped == null) {
      pen = null;
      return;
    }
    final (p0, p1) = clipped;
    final cur = pen;
    if (cur == null || (cur - p0).distance > 1e-3) {
      path.moveTo(p0.dx, p0.dy);
    }
    path.lineTo(p1.dx, p1.dy);
    pen = p1;
  }

  for (var i = 1; i < scene.trail.length; i++) {
    leg(scene.trail[i - 1], scene.trail[i]);
  }
  if (tipOverride != null && scene.trail.isNotEmpty && !scene.rocketIsDeadReckoning) {
    final last = scene.trail.last;
    if ((tipOverride - last).length > 1e-6) {
      leg(last, tipOverride);
    }
  }
  canvas.drawPath(path, gpsPaint);
}

/// CG-anchored, ground-clamped rocket position for the flight views.
///
/// The mesh pivots about its CG ([RocketMesh.cgY]) so pitch/roll rotate the
/// airframe about its centre; the anchor is the reported position lifted
/// just enough to keep the tail (vertical) or belly (horizontal) out of the
/// ground surface. [groundY] is the terrain height under the rocket (0 on
/// the flat plain view); aloft the lift is zero and the trail meets the CG
/// exactly.
Vector3 cgAnchorPos({
  required Vector3 rocketPos,
  required double pitchDeg,
  required double yawDeg,
  required double scale,
  double groundY = 0.0,
}) {
  final orientation = RocketMesh.orientationMatrix(
    pitchDeg: pitchDeg,
    yawDeg: yawDeg,
    scale: 1.0,
  );
  final bodyAxis = orientation.transformed3(Vector3(0, 1, 0)).normalized();
  final tailOff = (RocketMesh.finBottom - RocketMesh.cgY) * scale;
  final noseOff = (RocketMesh.noseTip - RocketMesh.cgY) * scale;
  final radius = RocketMesh.bodyRadius * scale;
  final lowest = rocketPos.y +
      math.min(math.min(tailOff * bodyAxis.y, noseOff * bodyAxis.y), -radius);
  if (lowest >= groundY) return rocketPos;
  return rocketPos + Vector3(0, groundY - lowest, 0);
}

/// Screen-space dashed segment between two world points, clipped against
/// the near plane like [drawWorldSegment]. Pure screen-space dashing keeps
/// dash lengths uniform regardless of perspective depth.
void drawWorldDashedSegment(Canvas canvas, Vector3 a, Vector3 b, Matrix4 vp,
    Size size, Paint paint,
    {double dashPx = 6, double gapPx = 4}) {
  var ca = _clipOf(a, vp);
  var cb = _clipOf(b, vp);
  final aIn = _clipInFront(ca);
  final bIn = _clipInFront(cb);
  if (!aIn && !bIn) return;
  if (!aIn) {
    ca = _clipNear(ca, cb);
  } else if (!bIn) {
    cb = _clipNear(cb, ca);
  }
  final pa = _divideClip(ca, size);
  final pb = _divideClip(cb, size);
  final safeRect =
      Rect.fromLTRB(-64, -64, size.width + 64, size.height + 64);
  final clipped = clipSegment2D(pa, pb, safeRect);
  if (clipped == null) return;
  final p0 = clipped.$1;
  final p1 = clipped.$2;
  final dx = p1.dx - p0.dx;
  final dy = p1.dy - p0.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1e-6) return;
  final ux = dx / len;
  final uy = dy / len;
  var dist = 0.0;
  while (dist < len) {
    final end = math.min(dist + dashPx, len);
    canvas.drawLine(
      Offset(p0.dx + ux * dist, p0.dy + uy * dist),
      Offset(p0.dx + ux * end, p0.dy + uy * end),
      paint,
    );
    dist = end + gapPx;
  }
}

/// Drop line rocket→ground plus the violet dead reckoning marker when
/// dead-reckoned:
/// a ring at the estimate and a dashed connector from the last known GPS
/// position ([FlightScene.trail].last) to the estimate, so the dead
/// reckoning position
/// never leaves a solid trail.
/// With [anchorOverride] the line hangs from the CG anchor instead of the
/// raw reported fix. [groundY] is the terrain surface under the rocket
/// (0 on the flat plain view).
void paintDropLineAndDeadReckoning(
    Canvas canvas, FlightScene scene, Matrix4 vp, Size size,
    {Vector3? anchorOverride, double groundY = 0.0}) {
  final top = anchorOverride ?? scene.rocketPos;
  drawWorldSegment(
    canvas,
    top,
    Vector3(top.x, groundY, top.z),
    vp,
    size,
    Paint()
      ..color = AppColors.mutedForeground.withValues(alpha: 0.45)
      ..strokeWidth = 1,
  );
  if (scene.rocketIsDeadReckoning) {
    if (scene.trail.isNotEmpty) {
      final last = scene.trail.last;
      if ((top - last).length > 1e-6) {
        drawWorldDashedSegment(
          canvas,
          last,
          top,
          vp,
          size,
          Paint()
            ..color = AppColors.seriesDeadReckoning.withValues(alpha: 0.9)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round,
        );
      }
    }
    final s = projectToScreen(top, vp, size);
    if (s != null) {
      canvas.drawCircle(
        s,
        11,
        Paint()
          ..color = AppColors.seriesDeadReckoning.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawCircle(
        s,
        2,
        Paint()..color = AppColors.seriesDeadReckoning,
      );
    }
  }
}

/// Formats a below-terrain depth for the rocket badge: one decimal under
/// 10 m, whole metres above. Pure — unit-tested.
String formatUnderMeters(double meters) {
  final m = meters.clamp(0.0, 99999.0);
  return m < 10
      ? '${m.toStringAsFixed(1)} m under ground'
      : '${m.round()} m under ground';
}

/// Cheap Minecraft-style shadow disk: a flat translucent ellipse on the
/// terrain surface under the rocket, so the eye can anchor the airframe to
/// the ground it is flying over. Skipped when the surface point is behind
/// the camera.
void paintShadowDisk(
    Canvas canvas, Matrix4 vp, Size size, Vector3 surfaceCenter, double radius,
    {double alpha = 0.30}) {
  final path = Path();
  var started = false;
  for (var i = 0; i <= 24; i++) {
    final a = i * 2 * math.pi / 24;
    final s = projectToScreen(
      surfaceCenter +
          Vector3(radius * math.cos(a), 0, radius * math.sin(a)),
      vp,
      size,
    );
    // Behind the camera (lens inside the disk): skip rather than smear.
    if (s == null) return;
    if (started) {
      path.lineTo(s.dx, s.dy);
    } else {
      path.moveTo(s.dx, s.dy);
      started = true;
    }
  }
  path.close();
  canvas.drawPath(
    path,
    Paint()..color = const Color(0xFF000000).withValues(alpha: alpha),
  );
}

/// "N m under ground" badge next to a terrain-clamped rocket. No-op when
/// the anchor projects behind the camera.
void paintUnderGroundLabel(
    Canvas canvas, Matrix4 vp, Size size, Vector3 anchorWorld, String text) {
  final pos = projectToScreen(anchorWorld, vp, size);
  if (pos == null) return;
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: AppText.microLabel.copyWith(
        fontSize: 10,
        letterSpacing: 0.5,
        color: AppColors.warning,
        fontWeight: FontWeight.w700,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, pos + const Offset(12, -30));
}

/// Rocket mesh at [rocketPos] with the shared attitude. [baseLift] (in model
/// units) is the pre-rotation lift: the flight views pass `-RocketMesh.cgY`
/// so the mesh pivots about its CG (see [cgAnchorPos], which also keeps the
/// airframe out of the ground plane). The attitude viewer passes 0 to keep
/// rotating about the mesh origin (already ~the CG).
///
/// [showNoseCone] hides the popped cone; [showParachute] hangs the canopy
/// world-up from the body top: the attach point follows the (possibly
/// tilted) airframe, but the chute itself never tilts.
void paintRocketMesh(
  Canvas canvas,
  Size size,
  Matrix4 vp,
  Matrix4 view,
  Vector3 lightDir, {
  required Vector3 rocketPos,
  required double pitchDeg,
  required double yawDeg,
  required double rollDeg,
  required double scale,
  double baseLift = 0.0,
  bool showNoseCone = true,
  bool showParachute = false,
}) {
  final orientation = RocketMesh.orientationMatrix(
    pitchDeg: pitchDeg,
    yawDeg: yawDeg,
    rollDeg: rollDeg,
    scale: scale,
  );
  final model = Matrix4.translation(rocketPos) *
      orientation *
      Matrix4.translation(Vector3(0, baseLift, 0));

  // Parachute frame: translated to the body-top attach point, uniformly
  // scaled, but never rotated — the canopy always hangs straight up.
  final chuteModel = Matrix4.translation(
          model.transformed3(Vector3(0, RocketMesh.bodyTop, 0)))
      ..scaleByDouble(scale, scale, scale, 1.0);

  final visible = <_PaintTri>[];
  var index = 0;

  void push(RocketMeshTri tri, Matrix4 m, Vector3 worldNormal) {
    final a = m.transformed3(tri.a);
    final b = m.transformed3(tri.b);
    final c = m.transformed3(tri.c);

    final screenA = projectToScreen(a, vp, size);
    final screenB = projectToScreen(b, vp, size);
    final screenC = projectToScreen(c, vp, size);
    if (screenA == null || screenB == null || screenC == null) return;
    final area = (screenB.dx - screenA.dx) * (screenC.dy - screenA.dy) -
        (screenC.dx - screenA.dx) * (screenB.dy - screenA.dy);
    if (area.abs() < 1e-6) return;

    // Closed airframe: cull backfaces so the far wall can never bleed
    // through the near one at glancing angles (the old streaks). Fin
    // sheets come in exact opposite pairs, so exactly one survives.
    // Parachute sheets (noCull) always draw, from both sides.
    if (!tri.noCull) {
      final viewNormal = view.transformed(Vector4(
          worldNormal.x, worldNormal.y, worldNormal.z, 0));
      if (viewNormal.z <= 1e-6) return;
    }
    final brightness =
        0.44 + 0.56 * math.max(0.0, worldNormal.dot(lightDir));

    final za = view.transformed3(a).z;
    final zb = view.transformed3(b).z;
    final zc = view.transformed3(c).z;

    visible.add(_PaintTri(
      screenA,
      screenB,
      screenC,
      depth: (za + zb + zc) / 3,
      order: index,
      brightness: brightness.clamp(0.0, 1.0),
      base: tri.color,
    ));
    index++;
  }

  for (final tri in RocketMesh.mesh(showNoseCone: showNoseCone)) {
    // Normals rotate with the orientation (no translation, no base lift —
    // the lift runs along the long axis and must not leak into lighting).
    push(tri, model, orientation.transformed3(tri.normal).normalized());
  }
  if (showParachute) {
    for (final tri in ParachuteMesh.triangles) {
      // Unrotated frame: mesh normals are already world-aligned.
      push(tri, chuteModel, tri.normal.normalized());
    }
  }
  visible.sort((x, y) {
    final d = x.depth.compareTo(y.depth);
    return d != 0 ? d : x.order.compareTo(y.order);
  });

  final fill = Paint();
  final triPath = Path();
  for (final tri in visible) {
    fill.color = Color.fromARGB(
      255,
      (tri.base.r * 255 * tri.brightness).round().clamp(0, 255),
      (tri.base.g * 255 * tri.brightness).round().clamp(0, 255),
      (tri.base.b * 255 * tri.brightness).round().clamp(0, 255),
    );
    // Single fill pass per tri (reused Paint/Path, no per-tri allocation).
    // The old second pass — a same-color 0.6 px stroke over every tri —
    // doubled the draw calls for no visible gain and its overdraw shimmered
    // along edges at glancing angles.
    triPath
      ..reset()
      ..moveTo(tri.a.dx, tri.a.dy)
      ..lineTo(tri.b.dx, tri.b.dy)
      ..lineTo(tri.c.dx, tri.c.dy)
      ..close();
    canvas.drawPath(triPath, fill);
  }
}

class _PaintTri {
  final Offset a, b, c;
  final double depth;

  /// Mesh order — stabilises the sort when coplanar faces tie on depth.
  final int order;
  final double brightness;
  final Color base;

  const _PaintTri(this.a, this.b, this.c,
      {required this.depth,
      required this.order,
      required this.brightness,
      required this.base});
}

/// Plain ground: subtle fill + 1-2-5 grid + projected N (−Z, blue) / E (+X,
/// amber) labels that rotate with the view.
void paintGroundPlain(
    Canvas canvas, FlightScene scene, Matrix4 vp, Size size) {
  final grid = flightGroundGrid(scene);
  final half = grid.half;
  final step = grid.step;
  final n = (half / step).ceil();

  final c0 = Vector3(-half, 0, -half);
  final c1 = Vector3(half, 0, -half);
  final c2 = Vector3(half, 0, half);
  final c3 = Vector3(-half, 0, half);
  // Subtle ground fill (near-plane clipped, survives low camera angles).
  fillWorldQuad(
    canvas,
    [c0, c1, c2, c3],
    vp,
    size,
    Paint()..color = AppColors.muted.withValues(alpha: 0.65),
  );

  final gridLine = Paint()
    ..color = AppColors.border
    ..strokeWidth = 1;
  final axisLine = Paint()
    ..color = AppColors.strongBorder
    ..strokeWidth = 1.4;
  for (var k = -n; k <= n; k++) {
    final off = k * step;
    final paint = k == 0 ? axisLine : gridLine;
    drawWorldSegment(canvas, Vector3(off, 0, -half), Vector3(off, 0, half), vp,
        size, paint);
    drawWorldSegment(canvas, Vector3(-half, 0, off), Vector3(half, 0, off), vp,
        size, paint);
  }

  paintGroundLabels(canvas, vp, size, half: half, step: step);
}

void paintGroundLabel(Canvas canvas, Matrix4 vp, Size size, Vector3 world,
    String label, Color color) {
  final pos = projectToScreen(world, vp, size);
  if (pos == null) return;
  final tp = TextPainter(
    text: TextSpan(
      text: label,
      style: AppText.microLabel.copyWith(
        fontSize: 10,
        letterSpacing: 1,
        color: color,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, pos + const Offset(-4, -8));
}

/// Cardinal ground labels — north sits on −Z (world Z is south).
void paintGroundLabels(Canvas canvas, Matrix4 vp, Size size,
    {required double half, required double step}) {
  paintGroundLabel(canvas, vp, size, Vector3(half + step * 0.3, 0, 0), 'E',
      AppColors.warning);
  paintGroundLabel(canvas, vp, size, Vector3(0, 0, -(half + step * 0.3)), 'N',
      AppColors.info);
}

void paintLaunchSite(
    Canvas canvas, FlightScene scene, Matrix4 vp, Size size) {
  // The flag marks a real configured/file launch site — never a fallback
  // origin (first fix). Without a site there is nothing to flag. Real-life
  // scale: 2 m pole, 2 m diameter ground circle.
  if (scene.siteName == null || scene.siteName!.isEmpty) return;
  drawWorldSegment(
    canvas,
    Vector3.zero(),
    Vector3(0, 2, 0),
    vp,
    size,
    Paint()
      ..color = AppColors.pinkDeep
      ..strokeWidth = 1.6,
  );
  final tip = projectToScreen(Vector3(0, 2, 0), vp, size);
  final tail = projectToScreen(Vector3(0, 1.5, 0), vp, size);
  final point = projectToScreen(Vector3(0.52, 1.75, 0), vp, size);
  if (tip != null && tail != null && point != null) {
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(point.dx, point.dy)
        ..lineTo(tail.dx, tail.dy)
        ..close(),
      Paint()..color = AppColors.pinkDeep,
    );
  }
  drawGroundCircle(
    canvas,
    Vector3.zero(),
    1,
    vp,
    size,
    Paint()
      ..color = AppColors.pinkDeep.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4,
  );

  final labelPos = projectToScreen(Vector3(0, 2.6, 0), vp, size);
  if (labelPos == null) return;
  final tp = TextPainter(
    text: TextSpan(
      text: 'Launch site · ${scene.siteName}',
      style: AppText.microLabel.copyWith(
        fontSize: 9,
        letterSpacing: 1,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, labelPos + const Offset(4, -6));
}

/// Corner compass: North (−Z) / East (+X) / Up (+Y), projected with the live
/// camera rotation, so the gizmo and the ground labels always agree.
void paintCompass(Canvas canvas, Size size, Matrix4 view) {
  final origin = Offset(34, size.height - 38);
  const len = 26.0;
  const eyeDist = 3.0;

  final r = view.getRow(0).xyz;
  final u = view.getRow(1).xyz;
  final b = view.getRow(2).xyz;

  ({Offset offset, double toward}) project(Vector3 dirRaw) {
    final d = dirRaw.normalized();
    final vx = d.dot(r);
    final vy = d.dot(u);
    final vz = d.dot(b);
    final s = len * eyeDist / math.max(0.8, eyeDist - vz);
    return (offset: Offset(vx * s, -vy * s), toward: vz);
  }

  final axes = <(Color, String, ({Offset offset, double toward}))>[
    (AppColors.warning, 'E', project(Vector3(1, 0, 0))),
    (AppColors.success, 'U', project(Vector3(0, 1, 0))),
    (AppColors.info, 'N', project(Vector3(0, 0, -1))),
  ]..sort((x, y) => x.$3.toward.compareTo(y.$3.toward));

  for (final (color, label, projected) in axes) {
    final end = origin + projected.offset;
    final alpha = projected.toward < -0.15 ? 0.35 : 1.0;
    final lineColor = color.withValues(alpha: alpha);
    canvas.drawLine(
      origin,
      end,
      Paint()
        ..color = lineColor
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: lineColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, end + const Offset(2, -10));
  }
}
