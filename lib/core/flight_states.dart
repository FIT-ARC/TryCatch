/// Pure helpers over ordered flight states (FSM tile, event markers).
///
/// All inputs are plain chronological frame lists, so both live rings and
/// pre-decoded replay flights share them.
library;

import 'package:serial/serial.dart';

/// Flight-clock time (`receivedAtMs`) when the trailing run of [stateId]
/// started: scans [chronological] (oldest first) from the end while frames
/// carry [stateId], and falls back to the first frame when the whole input
/// is one state — never "0 s in state" for lack of a transition.
int findStateEntryMs(List<TelemetryFrame> chronological, int stateId) {
  if (chronological.isEmpty) return 0;
  var entry = chronological.first.receivedAtMs;
  for (var i = chronological.length - 1; i >= 0; i--) {
    if (chronological[i].fsmStateId != stateId) {
      entry = chronological[i].receivedAtMs;
      break;
    }
  }
  return entry;
}

/// A contiguous run of one FSM state inside a full flight: everything the
/// replay state readouts need, derived from timeline position alone.
class StateSegment {
  final int stateId;
  final int entryMs;
  final int exitMs;

  const StateSegment({
    required this.stateId,
    required this.entryMs,
    required this.exitMs,
  });
}

/// The state run containing [positionMs] (flight-clock ms) over full
/// pre-decoded [frames], or `null` before the first frame. Pure function
/// of position: pauses, seeks and playback speed cannot perturb it.
StateSegment? segmentAt(List<TelemetryFrame> frames, int positionMs) {
  if (frames.isEmpty) return null;
  final t0 = frames.first.receivedAtMs;
  final abs = t0 + positionMs;
  // Tip: last index at or before the playhead (frames are chronological).
  var lo = 0;
  var hi = frames.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (frames[mid].receivedAtMs <= abs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final tip = lo - 1;
  if (tip < 0) return null;
  final stateId = frames[tip].fsmStateId;
  var start = tip;
  while (start > 0 && frames[start - 1].fsmStateId == stateId) {
    start--;
  }
  var end = tip;
  while (end + 1 < frames.length && frames[end + 1].fsmStateId == stateId) {
    end++;
  }
  return StateSegment(
    stateId: stateId,
    entryMs: frames[start].receivedAtMs,
    exitMs: frames[end].receivedAtMs,
  );
}
