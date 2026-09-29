/// Physics-lite flight simulator used by the mock serial port to generate
/// realistic telemetry for UI development, testing and demos.
library;

import 'dart:math' as math;

import 'frame_codec.dart';
import 'telemetry_frame.dart';

/// Metres per degree of latitude (mirrors `package:dead_reckoning`
/// `metresPerDegreeLat` — the serial package cannot import it).
const double _metresPerDegreeLat = 111320;

/// Simulated flight phases. Distinct from [FsmState] (the reported rocket
/// state) because some transitions are internal bookkeeping.
enum FlightPhase {
  /// GPS cold start, no fix yet.
  coldStart,

  /// Sitting on the pad with a fix, waiting for ignition.
  pad,

  /// Motor burning.
  boost,

  /// Ballistic ascent after burnout.
  coast,

  /// Brief apogee event before the canopy fills.
  apogee,

  /// Descending under the single parachute.
  chute,

  /// On the ground after touchdown.
  landed,
}

/// Deterministic (seedable) point-mass rocket flight simulator.
///
/// Simulates: GPS cold start → pad hold → motor burn → drag coast → apogee +
/// breakaway-wire hall trigger → single-canopy descent with wind drift →
/// touchdown. Attitude is faked plausibly per phase (roll spin during boost,
/// pendulum swing under canopy, lying on the side after landing).
///
/// Call [step] at a fixed cadence (the mock port uses 10 Hz) and feed the
/// returned frames through [FrameCodec.encodePacket] onto the wire.
class FlightSimulator {
  /// Simulated motor burn time in seconds.
  static const double burnTime = 2.8;

  /// Net world-frame acceleration during boost (m/s²), gravity excluded.
  static const double boostAccel = 55;

  /// Drag coefficient k such that drag decel = k·v² (1/m), coast phase.
  static const double coastDragK = 4e-4;

  /// Drag coefficient of the parachute (1/m) → ~6 m/s terminal.
  static const double chuteDragK = 9.81 / (6 * 6);

  /// Maximum net vertical acceleration under the parachute (m/s²). Caps the
  /// opening shock at a realistic ~4 g instead of the instantaneous
  /// full-drag value.
  static const double maxChuteAccel = 40;

  /// Duration of the GPS cold start (s).
  static const double coldStartSeconds = 2;

  /// Duration of the pad hold before ignition (s).
  static const double padSeconds = 6;

  FlightSimulator({
    this.latitude = 50.0755,
    this.longitude = 14.4378,
    this.startBatteryVoltage = 8.4,
    int? seed,
  })  : _rng = math.Random(seed),
        _battery = startBatteryVoltage;

  /// Launch site WGS84 latitude (degrees, positive North).
  final double latitude;

  /// Launch site WGS84 longitude (degrees, positive East).
  final double longitude;

  /// Battery voltage at t=0.
  final double startBatteryVoltage;

  final math.Random _rng;

  FlightPhase _phase = FlightPhase.coldStart;
  double _t = 0;
  double _altitude = 0;
  double _velUp = 0;
  double _posN = 0;
  double _posE = 0;
  double _roll = 0;
  double _rollRate = 0;
  double _pitch = 0;
  double _yaw = 75;
  double _battery;
  int _seq = 0;
  bool _hallBroken = false;
  double _fallAccel = 0;

  // Slow random-walk GPS error offsets (metres, horizontal only).
  double _gpsErrN = 0;
  double _gpsErrE = 0;

  /// Current simulated time in seconds since simulator start.
  double get simulatedSeconds => _t;

  /// Current internal phase (exposed for tests).
  FlightPhase get phase => _phase;

  /// Advances the simulation by [dt] seconds and returns the telemetry frame.
  TelemetryFrame step(double dt, {int? timestampMs}) {
    _t += dt;
    _seq++;

    switch (_phase) {
      case FlightPhase.coldStart:
        if (_t >= coldStartSeconds) {
          _phase = FlightPhase.pad;
          _t = coldStartSeconds; // keep timeline continuous
        }

      case FlightPhase.pad:
        if (_t >= coldStartSeconds + padSeconds) {
          _phase = FlightPhase.boost;
          _rollRate = 240; // deg/s spin-up at ignition
        }

      case FlightPhase.boost:
        _velUp += boostAccel * dt;
        _altitude += _velUp * dt;
        _pitch = 1.5 * math.sin(_t * 1.1) + 0.8; // slight coning wobble
        _roll += _rollRate * dt;
        if (_t >= coldStartSeconds + padSeconds + burnTime) {
          _phase = FlightPhase.coast;
        }

      case FlightPhase.coast:
        final drag = coastDragK * _velUp * _velUp;
        _velUp -= (9.81 + drag) * dt;
        _altitude += _velUp * dt;
        _pitch *= math.pow(0.5, dt / 1.5); // wobble damps out
        _rollRate *= math.pow(0.5, dt / 2);
        _roll += _rollRate * dt;
        if (_velUp <= 0) {
          _velUp = 0;
          _phase = FlightPhase.apogee;
          _hallBroken = true; // breakaway wire snaps at apogee
        }

      case FlightPhase.apogee:
        // One-beat event state, then the canopy fills.
        _phase = FlightPhase.chute;

      case FlightPhase.chute:
        _velUp += fallStep(chuteDragK, dt);
        _altitude += _velUp * dt;
        _posE += windSpeed(_t) * dt;
        _posN += 0.3 * windSpeed(_t) * dt;
        // Pendulum swing under the canopy.
        _pitch = 12 * math.sin(2 * math.pi * _t / 2.8);
        _yaw = 95 + 15 * math.sin(_t * 0.4);
        _roll = 5 * math.sin(2 * math.pi * _t / 3.1);
        if (_altitude <= 0) {
          _altitude = 0;
          _velUp = 0;
          _phase = FlightPhase.landed;
          _pitch = 85; // lying on its side
          _rollRate = 0;
        }

      case FlightPhase.landed:
        _pitch = 85 + 2 * math.sin(_t * 0.2);
    }

    _battery = startBatteryVoltage - _t * 0.0025;
    _walkGpsError(dt);

    return _buildFrame(timestampMs ?? DateTime.now().millisecondsSinceEpoch);
  }

  /// Vertical velocity step under the parachute with drag coefficient [k].
  ///
  /// Records the clamped world-frame acceleration in [_fallAccel] so the
  /// reported accelerometer value stays consistent with the kinematics.
  double fallStep(double k, double dt) {
    // v' = -g + k·v² (v negative while falling, drag pushes up).
    final a = (-9.81 + k * _velUp * _velUp).clamp(-maxChuteAccel, 12.0);
    _fallAccel = a;
    final next = _velUp + a * dt;
    // Never overshoot through terminal velocity; clamp for large steps.
    final terminal = -math.sqrt(9.81 / k);
    if (_velUp > terminal && next < terminal) {
      _fallAccel = (terminal - _velUp) / dt;
      return terminal - _velUp;
    }
    return a * dt;
  }

  /// Gustying westerly wind (m/s) pushing the rocket east while chuted.
  double windSpeed(double t) => 7 + 2 * math.sin(t * 0.23) + _noise(0.5);

  /// Raw hall sensor ADC count: ~2500 with the breakaway wire intact, jumping
  /// to ~2950 once it snaps.
  double hallReading() => (_hallBroken ? 2950 : 2500) + _noise(35);

  double _noise(double mag) => (_rng.nextDouble() - 0.5) * 2 * mag;

  void _walkGpsError(double dt) {
    _gpsErrN = (_gpsErrN + _noise(1.2) * dt).clamp(-6, 6);
    _gpsErrE = (_gpsErrE + _noise(1.2) * dt).clamp(-6, 6);
  }

  TelemetryFrame _buildFrame(int receivedAtMs) {
    final gpsFix = _phase != FlightPhase.coldStart;
    var flags = 0;
    if (gpsFix) flags |= FrameFlags.gpsFix;

    // World-frame specific force along the body axis, +9.81 at rest.
    // Under the canopy the specific force is the (clamped) drag itself.
    final double accelLongitudinal = switch (_phase) {
      FlightPhase.coldStart || FlightPhase.pad => 9.81,
      FlightPhase.boost => boostAccel + 9.81,
      FlightPhase.coast => -(coastDragK * _velUp * _velUp),
      FlightPhase.apogee => 9.81,
      FlightPhase.chute => _fallAccel + 9.81,
      FlightPhase.landed => 9.81,
    };

    // Distribute the longitudinal force across body axes using the tilt,
    // plus a little cross-axis noise.
    final tilt = _pitch * math.pi / 180;
    final cosT = math.cos(tilt);
    final sinT = math.sin(tilt);
    final gyroZ = _rollRate;

    return TelemetryFrame(
      receivedAtMs: receivedAtMs,
      flags: flags,
      sequence: _seq,
      latitude: _toLat(_posN + (gpsFix ? _gpsErrN : 0)),
      longitude: _toLon(_posE + (gpsFix ? _gpsErrE : 0)),
      baroAltitude: _altitude + _noise(0.4),
      velocityNorth: _phase == FlightPhase.chute
          ? 0.3 * windSpeed(_t) + _noise(0.3)
          : _noise(0.2),
      velocityEast: _phase == FlightPhase.chute
          ? windSpeed(_t) + _noise(0.3)
          : _noise(0.2),
      velocityUp: _velUp + _noise(0.2),
      accelX: accelLongitudinal * sinT + _noise(0.3),
      accelY: _noise(0.3),
      accelZ: accelLongitudinal * cosT + _noise(0.3),
      gyroX: _phase == FlightPhase.chute
          ? 25 * math.cos(2 * math.pi * _t / 2.4)
          : _noise(2),
      gyroY: _noise(2),
      gyroZ: gyroZ + _noise(1),
      heading: (_yaw + _noise(1)) % 360,
      roll: _roll,
      pitch: _pitch,
      yaw: _yaw,
      batteryVoltage: _battery + _noise(0.01),
      hallRaw: hallReading().round(),
      fsmStateId: _reportedState.id,
    );
  }

  /// Reported wire state: the internal burn/coast phases collapse into the
  /// single ASCENT state.
  FsmState get _reportedState => switch (_phase) {
        FlightPhase.coldStart => FsmState.idle,
        FlightPhase.pad => _t >= coldStartSeconds + 2 ? FsmState.armed : FsmState.idle,
        FlightPhase.boost || FlightPhase.coast => FsmState.ascent,
        FlightPhase.apogee => FsmState.apogee,
        FlightPhase.chute => FsmState.parachute,
        FlightPhase.landed => FsmState.landed,
      };

  double _toLat(double northMetres) =>
      latitude + northMetres / _metresPerDegreeLat;

  double _toLon(double eastMetres) => longitude +
      eastMetres /
          (_metresPerDegreeLat * math.cos(latitude * math.pi / 180));
}
