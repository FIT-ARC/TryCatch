import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart';

/// One flat-shaded triangle of the parametric rocket mesh.
class RocketMeshTri {
  final Vector3 a, b, c;
  final Vector3 normal;
  final Color color;

  /// `true` for the paired opposite faces of the fins: exactly one of each
  /// pair faces the camera, so painters cull the other instead of letting
  /// the coplanar pair flicker.
  final bool doubleSided;

  /// `true` for single-sheet surfaces (parachute canopy, vent, shroud
  /// lines): painters must draw them from both sides with no backface
  /// culling at all.
  final bool noCull;

  /// `true` for nose-cone triangles, so painters can hide the cone when it
  /// pops and render the parachute instead.
  final bool isNoseCone;

  /// `true` for the dark disk closing the tube where the cone sat: drawn
  /// only while popped, so the open airframe never looks see-through once
  /// painters cull interior backfaces.
  final bool interiorCap;

  RocketMeshTri(this.a, this.b, this.c, this.color,
      {this.doubleSided = false,
      this.noCull = false,
      this.isNoseCone = false,
      this.interiorCap = false})
      : normal = (b - a).cross(c - a).normalized();
}

/// Parametric rocket mesh shared by the orientation viewer and the flight
/// path view: pink body tube, pink Haack nose cone with a black tip,
/// black fin cage with four swept-rectangle fins, black bottom cap.
///
/// Longitudinal proportions follow `Downloads/Raketa.ork` (FINAL): upper
/// tube 0.5 m, motor/fin tube 0.19 m, Haack nose 0.165 m, all Ø 66.8 mm,
/// 4 fins with equal root/tip chord 0.07 m, sweep 0.028 m, span 0.07 m at
/// the tube base — everything uniformly ×2.48 (upper : cage : nose =
/// 1 : 0.38 : 0.33 and L/D ≈ 12.8, exactly as in the .ork).
///
/// The pink tube starts exactly where the cage sleeve ends (butt joint, no
/// overlapping shells) so the two cylinders can't z-fight.
///
/// Model space: nose along +Y, cage base at y = -0.74, fin bottoms at
/// y = -0.77, tip at y = +1.38.
abstract final class RocketMesh {
  static const int _segments = 20;
  static const double _bodyRadius = 0.083;
  static const double _bodyTop = 0.97;
  static const double _bodyBottom = -0.74;

  /// Pink tube bottom: exactly where the cage sleeve ends (butt joint, no
  /// overlapping shells → no z-fighting).
  static const double _tubeBottom = -0.27;
  static const double _noseTip = 1.38;

  /// Nose profile stations (LV-Haack).
  static const int _noseRings = 12;

  /// Fraction of the nose painted black: only the top 5 cm of the 16.5 cm
  /// .ork cone, like the real airframe — the rest stays pink.
  static const double _noseTipFraction = 0.05 / 0.165;

  /// Fin cage sleeve over the lower body (top edge meets the tube bottom).
  static const double _cageTop = -0.27;

  /// Open-tube lid while popped: 2 mm inset per side (4 mm narrower
  /// overall than the bore) so its rim never ties with the tube wall in
  /// the depth sort (the old flush disk bled a black sliver through the
  /// tube side), floating ~2 cm above the rim like a cap.
  static const double _mouthInset = 0.002;
  static const double _mouthLift = 0.02;
  static const double _finSpan = 0.17;

  /// Swept rectangular fin: constant chord (root == tip, as in the .ork),
  /// tip shifted toward the tail. The fin bottoms sit slightly below the
  /// cage base so the two overlap.
  static const double _finChord = 0.17;
  static const double _finSweep = 0.07;
  static const double _finDrop = 0.03;

  /// Distance from the model origin to the lowest point (fin bottoms, which
  /// sit slightly below the cage base), used to stand the rocket on the
  /// ground in the flight views.
  static const double baseExtent = -_bodyBottom + _finDrop;

  /// Longitudinal centre of gravity in model units (+Y), from the Raketa.ork
  /// mass budget: ~0.46 m from the nose tip of the 0.755 m airframe
  /// (nose 0.106 kg + forward avionics vs motor + fins aft). The flight
  /// views pivot the mesh about this point so pitch/roll rotate the
  /// airframe about its centre and the trail meets the rocket's middle.
  static const double cgY = 0.07;

  /// Section lengths, exposed for tests locking the .ork proportions.
  static double get upperTubeLength => _bodyTop - _tubeBottom;
  static double get cageLength => _cageTop - _bodyBottom;
  static double get noseLength => _noseTip - _bodyTop;
  static double get noseBlackLength => _noseTipFraction * noseLength;
  static double get bodyRadius => _bodyRadius;
  static double get bodyTop => _bodyTop;

  /// Nose tip height (model units, +Y).
  static double get noseTip => _noseTip;

  /// Lowest point of the airframe (fin bottoms, model units).
  static double get finBottom => _bodyBottom - _finDrop;

  /// Open-tube lid geometry (model units): height above the tube rim and
  /// per-side radial inset from the bore.
  static double get mouthLift => _mouthLift;
  static double get mouthInset => _mouthInset;
  static double get finChord => _finChord;
  static double get finSpan => _finSpan;
  static double get finSweep => _finSweep;

  // Team pink airframe (identical in light + dark palettes, so const).
  static const Color _bodyColor = Color(0xFFFF00A1);
  static const Color _blackColor = Color(0xFF232328);

  static final List<RocketMeshTri> triangles = _build();

  /// Airframe triangles with the nose cone optionally hidden. Painters
  /// iterate this instead of [triangles]; the parachute lives in its own
  /// ([ParachuteMesh]) world-up frame and is drawn separately. While popped,
  /// the interior cap closes the tube mouth.
  static Iterable<RocketMeshTri> mesh({bool showNoseCone = true}) sync* {
    for (final t in triangles) {
      if (t.isNoseCone && !showNoseCone) continue;
      if (t.interiorCap && showNoseCone) continue;
      yield t;
    }
  }

  /// LV-Haack nose radius at profile fraction [t] (0 = nose base, 1 = tip),
  /// the same series the .ork nose cone uses: slender with a sharp tip.
  static double _haackRadius(double t) {
    final u = (1 - t).clamp(0.0, 1.0);
    if (u <= 0) return 0.0;
    final theta = math.acos((1 - 2 * u).clamp(-1.0, 1.0));
    return _bodyRadius * math.sqrt((theta - math.sin(2 * theta) / 2) / math.pi);
  }

  static List<RocketMeshTri> _build() {
    final tris = <RocketMeshTri>[];

    Vector3 ring(double y, double radius, int i) {
      final angle = i * 2 * math.pi / _segments;
      return Vector3(radius * math.cos(angle), y, radius * math.sin(angle));
    }

    // Body tube (pink), from the cage top up.
    for (var i = 0; i < _segments; i++) {
      final a0 = ring(_tubeBottom, _bodyRadius, i);
      final a1 = ring(_tubeBottom, _bodyRadius, i + 1);
      final b0 = ring(_bodyTop, _bodyRadius, i);
      final b1 = ring(_bodyTop, _bodyRadius, i + 1);
      tris.addAll(_quad(b0, b1, a1, a0, _bodyColor));
    }

    // Nose cone: LV-Haack profile in rings, pink with a black tip (top
    // 5 cm, like the real cone).
    final tip = Vector3(0, _noseTip, 0);
    for (var i = 0; i < _noseRings; i++) {
      final t0 = i / _noseRings;
      final t1 = (i + 1) / _noseRings;
      final y0 = _bodyTop + (_noseTip - _bodyTop) * t0;
      final y1 = _bodyTop + (_noseTip - _bodyTop) * t1;
      final color = t0 >= 1 - _noseTipFraction ? _blackColor : _bodyColor;
      for (var j = 0; j < _segments; j++) {
        if (i == _noseRings - 1) {
          final s0 = ring(y0, _haackRadius(t0), j);
          final s1 = ring(y0, _haackRadius(t0), j + 1);
          // Wound tip → s1 → s0 so the fan normal points outward/up like
          // the ring quads below it; the reverse order faces inward and
          // gets backface-culled into a see-through hole from above.
          tris.add(RocketMeshTri(tip, s1, s0, color, isNoseCone: true));
        } else {
          final lo0 = ring(y0, _haackRadius(t0), j);
          final lo1 = ring(y0, _haackRadius(t0), j + 1);
          final hi0 = ring(y1, _haackRadius(t1), j);
          final hi1 = ring(y1, _haackRadius(t1), j + 1);
          tris.addAll(_quad(hi0, hi1, lo1, lo0, color, isNoseCone: true));
        }
      }
    }

    // Popped tube closure: a pink bulkhead disk at the rim plane plus a
    // short black puck (wall + lid) above it. The old floating lid left
    // the open bore visible as a hole underneath; the wall meets the
    // bulkhead edge-on (no coplanar faces → no z-fighting), and the lid
    // stays narrower than the bore so its rim never ties with the tube
    // wall in the depth sort. With the cone on all of it hides behind the
    // nose wall.
    final mouthY = _bodyTop + _mouthLift;
    final mouthR = _bodyRadius - _mouthInset;
    final bulkCenter = Vector3(0, _bodyTop, 0);
    for (var i = 0; i < _segments; i++) {
      final r0 = ring(_bodyTop, _bodyRadius, i);
      final r1 = ring(_bodyTop, _bodyRadius, i + 1);
      tris.add(RocketMeshTri(bulkCenter, r1, r0, _bodyColor,
          interiorCap: true));
    }
    for (var i = 0; i < _segments; i++) {
      final t0 = ring(mouthY, mouthR, i);
      final t1 = ring(mouthY, mouthR, i + 1);
      final b0 = ring(_bodyTop, mouthR, i);
      final b1 = ring(_bodyTop, mouthR, i + 1);
      tris.addAll(_quad(t0, t1, b1, b0, _blackColor, interiorCap: true));
    }
    final mouthCenter = Vector3(0, mouthY, 0);
    for (var i = 0; i < _segments; i++) {
      final p0 = ring(mouthY, mouthR, i);
      final p1 = ring(mouthY, mouthR, i + 1);
      tris.add(RocketMeshTri(mouthCenter, p1, p0, _blackColor,
          interiorCap: true));
    }

    // Fin cage: black sleeve over the lower body + black bottom cap.
    final cageR = _bodyRadius * 1.03;
    for (var i = 0; i < _segments; i++) {
      final t0 = ring(_cageTop, cageR, i);
      final t1 = ring(_cageTop, cageR, i + 1);
      final b0 = ring(_bodyBottom, cageR, i);
      final b1 = ring(_bodyBottom, cageR, i + 1);
      tris.addAll(_quad(t0, t1, b1, b0, _blackColor));
    }
    final center = Vector3(0, _bodyBottom, 0);
    for (var i = 0; i < _segments; i++) {
      final a0 = ring(_bodyBottom, cageR, i);
      final a1 = ring(_bodyBottom, cageR, i + 1);
      // Wound to face down (-Y): visible from below once painters cull
      // backfaces.
      tris.add(RocketMeshTri(center, a0, a1, _blackColor));
    }

    // Four fins, 90° apart. Each fin is a swept rectangle (parallelogram,
    // root == tip chord like the .ork trapezoid set) in the plane spanned
    // by the radial direction and the long axis, double-sided so it reads
    // from both sides. Roots embed into the cage (angled intersection, no
    // coplanar shells). The fin bottoms sit slightly below the cage base
    // so the two overlap instead of meeting edge-to-edge.
    for (var f = 0; f < 4; f++) {
      final angle = f * 2 * math.pi / 4;
      final radial = Vector3(math.cos(angle), 0, math.sin(angle));
      final inner = _bodyRadius * 0.90;

      Vector3 pointAt(double alongY, double out) =>
          radial.scaled(out) + Vector3(0, alongY, 0);

      final finBottom = _bodyBottom - _finDrop;
      final rootBottom = pointAt(finBottom + _finSweep, inner);
      final rootTop = pointAt(finBottom + _finSweep + _finChord, inner);
      final tipBottom = pointAt(finBottom, inner + _finSpan);
      final tipTop = pointAt(finBottom + _finChord, inner + _finSpan);

      tris.addAll(_quad(rootTop, tipTop, tipBottom, rootBottom, _blackColor,
          doubleSided: true));
      // Back face so fins are visible from both sides.
      tris.addAll(_quad(rootTop, rootBottom, tipBottom, tipTop, _blackColor,
          doubleSided: true));
    }

    return tris;
  }

  /// Two triangles for quad (a, b, c, d).
  static List<RocketMeshTri> _quad(
    Vector3 a,
    Vector3 b,
    Vector3 c,
    Vector3 d,
    Color color, {
    bool doubleSided = false,
    bool noCull = false,
    bool isNoseCone = false,
    bool interiorCap = false,
  }) {
    return [
      RocketMeshTri(a, b, c, color,
          doubleSided: doubleSided,
          noCull: noCull,
          isNoseCone: isNoseCone,
          interiorCap: interiorCap),
      RocketMeshTri(a, c, d, color,
          doubleSided: doubleSided,
          noCull: noCull,
          isNoseCone: isNoseCone,
          interiorCap: interiorCap),
    ];
  }

  /// Rocket-oriented attitude (pitch = tilt from vertical, yaw = compass
  /// heading, roll = spin about the long axis) as a model matrix that maps
  /// the mesh into a right-handed world with X east, Y up, Z south
  /// (E×U=S — required so a standard view matrix doesn't mirror east/west),
  /// uniformly scaled to [scale] world units.
  static Matrix4 orientationMatrix({
    required double pitchDeg,
    required double yawDeg,
    double rollDeg = 0,
    double scale = 1.0,
  }) {
    final p = pitchDeg.clamp(0, 120) * math.pi / 180;
    final yaw = yawDeg * math.pi / 180;

    // Facing north (yaw 0) the nose tilts toward −Z; facing east (yaw 90°)
    // toward +X. Right is 90° clockwise of the heading: east when facing
    // north, south when facing east.
    final nose = Vector3(
      math.sin(p) * math.sin(yaw),
      math.cos(p),
      -math.sin(p) * math.cos(yaw),
    );
    final right = Vector3(math.cos(yaw), 0, math.sin(yaw));
    // Right × nose keeps the basis a proper rotation (det +1).
    final back = right.cross(nose).normalized();

    final orientation = Matrix4.zero();
    orientation.setColumn(0, Vector4(right.x, right.y, right.z, 0));
    orientation.setColumn(1, Vector4(nose.x, nose.y, nose.z, 0));
    orientation.setColumn(2, Vector4(back.x, back.y, back.z, 0));
    orientation.setColumn(3, Vector4(0, 0, 0, 1));

    final model = orientation * (Matrix4.identity()..rotateY(radians(rollDeg)));
    model.scaleByDouble(scale, scale, scale, 1.0);
    return model;
  }
}

/// Deployed recovery parachute: a dome canopy of alternating red/white
/// radial gores with a vent hole at the apex, hung on shroud lines above
/// the popped body tube. Stylised from the .ork chute (Ø 0.9 m, 6 lines).
///
/// Own frame, shared by every renderer: origin at the shroud-line attach
/// point (just above the body top), canopy straight up +Y. The GPU airframe
/// embeds it world-up from the popped tube mouth
/// ([RocketMesh.bodyTop]) — never tilted with the airframe — so the chute
/// always hangs above the rocket.
///
/// Every triangle is [RocketMeshTri.noCull]: single-sheet canopy that must
/// draw from outside and from below with no backface culling.
abstract final class ParachuteMesh {
  static const int goreCount = 12;
  static const int bands = 4;

  /// Canopy skirt radius and apex vent radius.
  static const double skirtRadius = 0.55;
  static const double ventRadius = 0.07;

  /// Shroud-line attach height above the origin.
  static const double attachY = 0.02;

  /// Canopy vertical extent above the origin (skirt rim → apex).
  static const double skirtY = 0.57;
  static const double apexY = skirtY + 0.30;

  /// Shroud lines: every second gore seam.
  static const int lineCount = 6;
  static const double lineWidth = 0.018;

  static const Color red = Color(0xFFE03131);
  static const Color white = Color(0xFFF4F2EC);
  static const Color lineColor = Color(0xFF9A9AA0);

  static final List<RocketMeshTri> triangles = _build();

  /// Dome profile from the vent lip out to the skirt (radius, height).
  static List<math.Point<double>> get profile => _profile();
  static List<math.Point<double>> _profile() => const [
        math.Point(ventRadius, apexY),
        math.Point(0.24, apexY - 0.04),
        math.Point(0.40, apexY - 0.13),
        math.Point(0.51, apexY - 0.23),
        math.Point(skirtRadius, skirtY),
      ];

  static List<RocketMeshTri> _build() {
    final tris = <RocketMeshTri>[];
    final prof = _profile();

    Vector3 domePoint(int gore, double r, double y) {
      final angle = gore * 2 * math.pi / goreCount;
      return Vector3(r * math.cos(angle), y, r * math.sin(angle));
    }

    // The apex stays open: the profile starts at the vent radius, so the
    // top ring is a hole with nothing behind it.
    for (var g = 0; g < goreCount; g++) {
      final color = g.isEven ? red : white;
      for (var b = 0; b < prof.length - 1; b++) {
        final lo = prof[b];
        final hi = prof[b + 1];
        // Note: [lo] is the higher (apex-side) station, [hi] the lower one.
        final a0 = domePoint(g, lo.x, lo.y);
        final a1 = domePoint(g + 1, lo.x, lo.y);
        final b0 = domePoint(g, hi.x, hi.y);
        final b1 = domePoint(g + 1, hi.x, hi.y);
        tris.addAll(RocketMesh._quad(a0, a1, b1, b0, color, noCull: true));
      }
    }

    // Shroud lines: crossed quads (tangent + radial) from the skirt (every
    // second seam) down to the attach point, so the cords never vanish
    // edge-on when viewed from any angle.
    final attach = Vector3(0, attachY, 0);
    for (var l = 0; l < lineCount; l++) {
      final angle = l * 2 * math.pi / lineCount;
      final tangent = Vector3(-math.sin(angle), 0, math.cos(angle));
      final radial = Vector3(math.cos(angle), 0, math.sin(angle));
      final top = Vector3(skirtRadius * math.cos(angle), skirtY,
          skirtRadius * math.sin(angle));
      final wTan = tangent.scaled(lineWidth / 2);
      final wRad = radial.scaled(lineWidth / 2);
      tris.addAll(RocketMesh._quad(top + wTan, top - wTan, attach - wTan, attach + wTan,
          lineColor,
          noCull: true));
      tris.addAll(RocketMesh._quad(top + wRad, top - wRad, attach - wRad, attach + wRad,
          lineColor,
          noCull: true));
    }

    return tris;
  }
}
