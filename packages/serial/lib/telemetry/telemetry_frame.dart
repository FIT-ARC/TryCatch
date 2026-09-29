/// Decoded telemetry frame model and flight software state definitions.
library;

import 'dart:math' as math;

/// Flight software finite state machine states reported by the MOCK rocket.
///
/// Wire values are the `id` of each state; ordering of the enum must not be
/// relied upon when serializing — always use [id]. This enum is the MOCK
/// connector's state vocabulary (see `connectors/mock_connector.dart`,
/// which publishes the same ids with labels/colors/airframe flags for the
/// UI); the shared internal frame carries only the raw `fsmStateId` int so
/// other connectors can use their own id space.
///
/// Each state carries the physical configuration it implies: whether the
/// nosecone is on, whether the parachute is deployed, and whether the 3D
/// views render the open canopy. The nose-cone tile reports
/// [FsmState.hasNosecone] as LOCKED/UNLOCKED; the 3D views render the canopy
/// from [FsmState.showsParachute]. Connector-driven surfaces resolve these
/// via `TelemetryConnector.stateForId` instead of touching this enum.
enum FsmState {
  /// Sitting on the pad, pre-flight checks, GPS acquiring. Assembled.
  idle(0, 'Idle'),

  /// Armed and waiting for ignition. Assembled.
  armed(1, 'Armed'),

  /// Powered ascent and ballistic coast after burnout. Assembled.
  ascent(2, 'Ascent'),

  /// Apogee reached, nosecone popped, waiting for the parachute to open.
  apogee(3, 'Apogee'),

  /// Descending under the open parachute (nosecone gone).
  parachute(4, 'Parachute'),

  /// Touchdown, flight over. Parachute still deployed (collapsed on the
  /// ground), nosecone gone.
  landed(5, 'Landed'),

  /// Bench debug with the airframe open (no nosecone, no parachute).
  debugUnlocked(6, 'Debug - Unlocked'),

  /// Bench debug in flight configuration (nosecone on, no parachute).
  debugLocked(7, 'Debug - Locked'),

  /// Placeholder used when an unmapped wire value is received.
  unknown(255, 'Unknown');

  const FsmState(this.id, this.label);

  /// Value carried in the telemetry frame's FSM byte.
  final int id;

  /// Human-friendly name for UI display.
  final String label;

  /// Whether the nosecone is on in this state.
  bool get hasNosecone => switch (this) {
        FsmState.idle ||
        FsmState.armed ||
        FsmState.ascent ||
        FsmState.debugLocked =>
          true,
        FsmState.apogee ||
        FsmState.parachute ||
        FsmState.landed ||
        FsmState.debugUnlocked ||
        FsmState.unknown =>
          false,
      };

  /// Whether the parachute is deployed in this state. True under the open
  /// canopy ([parachute]) and after touchdown ([landed], collapsed on the
  /// ground). Retained from the previous parachute tile; the nose-cone tile
  /// reports [hasNosecone] instead.
  bool get hasParachute =>
      this == FsmState.parachute || this == FsmState.landed;

  /// Whether the 3D views should render the open canopy. Only [parachute]:
  /// once landed the chute is collapsed on the ground and hidden from the
  /// model (the nose-cone tile still reports UNLOCKED via [hasNosecone]).
  bool get showsParachute => this == FsmState.parachute;

  /// Maps a wire value to a state, falling back to [unknown].
  static FsmState fromId(int id) =>
      FsmState.values.firstWhere((s) => s.id == id, orElse: () => FsmState.unknown);
}

/// Bit positions inside the telemetry frame's flags byte.
abstract final class FrameFlags {
  /// GPS has a position fix.
  static const int gpsFix = 1 << 0;

  /// Legacy wire bit (old 3D-fix flag). Still decoded to preserve the flags
  /// byte, never set on encode and never read — fix state is [gpsFix] alone.
  static const int gpsFix3d = 1 << 1;
}

/// A single internal telemetry frame in SI units.
///
/// The shared representation every connector produces from its own
/// bytestream (e.g. the MOCK connector decodes its 52-byte payloads via
/// `FrameCodec`) and the only thing that leaves the serial package: the
/// worker emits these, the UI consumes them, recordings stamp which
/// connector made them.
///

/// Conventions:
/// - Position: WGS84 degrees; altitude is metres above the launch site.
///   The connector picks the source sensor (baro/Kalman); there is no
///   separate GPS altitude. Use [altitudeMsl] with the site MSL to get MSL.
/// - Velocity: NEU frame (North, East, Up) in m/s — [velocityUp] is
///   positive away from the ground.
/// - Acceleration: body frame in m/s² (specific force, i.e. +9.81 on the pad).
/// - Gyro: body frame rotation in deg/s.
/// - Attitude ([roll], [pitch], [yaw]) is rocket-oriented rather than
///   aircraft-oriented:
///   - `pitch` — tilt away from vertical (0° = nose straight up, 90° = horizontal)
///   - `yaw`   — compass heading the nose points towards (0–360°)
///   - `roll`  — spin about the longitudinal axis (deg, unbounded)
class TelemetryFrame {
  /// Wall-clock time the frame was parsed (Unix epoch, ms).
  final int receivedAtMs;

  /// Raw flags byte — see [FrameFlags] helpers below.
  final int flags;

  /// Rolling sequence number assigned by the rocket (detects dropped frames).
  final int sequence;

  /// WGS84 latitude in degrees (positive North).
  final double latitude;

  /// WGS84 longitude in degrees (positive East).
  final double longitude;

  /// Altitude in metres above the launch site, from the connector's
  /// chosen sensor (baro/Kalman). Zero is the pad.
  final double baroAltitude;

  /// North velocity in m/s.
  final double velocityNorth;

  /// East velocity in m/s.
  final double velocityEast;

  /// Up velocity in m/s (positive away from the ground).
  final double velocityUp;

  /// Body-frame X acceleration in m/s².
  final double accelX;

  /// Body-frame Y acceleration in m/s².
  final double accelY;

  /// Body-frame Z (longitudinal) acceleration in m/s².
  final double accelZ;

  /// Body-frame X rotation rate in deg/s.
  final double gyroX;

  /// Body-frame Y rotation rate in deg/s.
  final double gyroY;

  /// Body-frame Z (longitudinal) rotation rate in deg/s.
  final double gyroZ;

  /// Compass heading in degrees [0, 360).
  final double heading;

  /// Roll about the longitudinal axis in degrees.
  final double roll;

  /// Tilt away from vertical in degrees (0 = straight up).
  final double pitch;

  /// Nose compass heading in degrees.
  final double yaw;

  /// Battery voltage in volts.
  final double batteryVoltage;

  /// Raw hall sensor reading (breakaway wire), dimensionless ADC count,
  /// typically a few thousand.
  final int hallRaw;

  /// Raw FSM state byte as received (use [fsmState] for the enum).
  final int fsmStateId;

  /// Decoded FSM state; [FsmState.unknown] for unmapped values.
  FsmState get fsmState => FsmState.fromId(fsmStateId);

  /// Whether the GPS reported a position fix.
  bool get gpsHasFix => flags & FrameFlags.gpsFix != 0;

  /// Altitude above mean sea level in metres for a pad at [groundMsl].
  double altitudeMsl(double groundMsl) => groundMsl + baroAltitude;

  /// Total (3D) speed in m/s.
  double get speedTotal =>
      _sqrt(velocityNorth * velocityNorth + velocityEast * velocityEast + velocityUp * velocityUp);

  /// Horizontal (ground) speed in m/s.
  double get speedHorizontal =>
      _sqrt(velocityNorth * velocityNorth + velocityEast * velocityEast);

  /// Vertical speed in m/s, positive up.
  double get speedVertical => velocityUp;

  /// Total (3D) body acceleration magnitude in m/s².
  double get accelTotal =>
      _sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ);

  /// Horizontal body acceleration magnitude in m/s².
  double get accelHorizontal => _sqrt(accelX * accelX + accelY * accelY);

  /// Vertical (longitudinal, body-frame Z) acceleration in m/s², signed
  /// specific force (≈ +9.81 on the pad). Equals world-vertical acceleration
  /// while the rocket flies upright.
  double get accelVertical => accelZ;

  const TelemetryFrame({
    this.receivedAtMs = 0,
    this.flags = 0,
    this.sequence = 0,
    this.latitude = 0,
    this.longitude = 0,
    this.baroAltitude = 0,
    this.velocityNorth = 0,
    this.velocityEast = 0,
    this.velocityUp = 0,
    this.accelX = 0,
    this.accelY = 0,
    this.accelZ = 0,
    this.gyroX = 0,
    this.gyroY = 0,
    this.gyroZ = 0,
    this.heading = 0,
    this.roll = 0,
    this.pitch = 0,
    this.yaw = 0,
    this.batteryVoltage = 0,
    this.hallRaw = 0,
    this.fsmStateId = 0,
  });

  static double _sqrt(double v) {
    if (v <= 0) return 0;
    final r = math.sqrt(v);
    return r.isNaN ? 0 : r;
  }
}
