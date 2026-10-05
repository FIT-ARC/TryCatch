import 'telemetry_frame.dart';

/// Uplink framing shared by the MOCK-family rockets.
///
/// All MOCK-family uplink frames share the same framing:
///   `0x54 0x43` magic ('TC') + 1-byte command + 1-byte argument.
/// Each connector owns its command catalog (see its `commands` getter);
/// this file carries only the magic bytes, the FSM state-request wire
/// format, and the display description type.

// ── Magic header ─────────────────────────────────────────────────────────────

/// Magic byte 'T' (0x54) — first byte of every MOCK-family uplink frame.
const int rocketMagicT = 0x54;

/// Magic byte 'C' (0x43) — second byte of every MOCK-family uplink frame.
const int rocketMagicC = 0x43;

/// Human-readable description of 4 raw uplink bytes, resolved against a
/// connector catalog at display time (so catalog renames never invalidate
/// old recordings or log entries).
class UplinkDescription {
  final String label;
  final String subtitle;
  final bool danger;

  const UplinkDescription({
    required this.label,
    required this.subtitle,
    this.danger = false,
  });
}

// ── FSM state commands ───────────────────────────────────────────────────────

/// Wire bytes for requesting an FSM state change from the rocket.
///
/// Frame format: magic + `0x07` (set-FSM-state command) + [FsmState.id].
/// The command byte `0x07` must match the flight software.
abstract final class FsmStateCommands {
  static const magicT = rocketMagicT;
  static const magicC = rocketMagicC;

  /// Command byte for the "set FSM state" uplink.
  static const int setStateCmd = 0x07;

  static List<int> bytesFor(FsmState state) =>
      [rocketMagicT, rocketMagicC, setStateCmd, state.id];
}
