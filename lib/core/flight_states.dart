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

/// Fraction through the contiguous [stateId] run containing [positionMs]
/// (flight-clock ms): entry → exit of the run. For replay progress bars
/// over full pre-decoded flights.
///
/// Positions before the run yield 0; zero-length runs yield 1 once
/// reached. Empty input yields 0.
double stateSegmentProgress(
    List<TelemetryFrame> frames, int positionMs, int stateId) {
  if (frames.isEmpty) return 0;
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
  if (tip < 0) return 0;
  if (frames[tip].fsmStateId != stateId) return 0;
  var start = tip;
  while (start > 0 && frames[start - 1].fsmStateId == stateId) {
    start--;
  }
  var end = tip;
  while (end + 1 < frames.length && frames[end + 1].fsmStateId == stateId) {
    end++;
  }
  final entry = frames[start].receivedAtMs;
  final exit = frames[end].receivedAtMs;
  if (exit <= entry) return 1;
  return ((abs - entry) / (exit - entry)).clamp(0.0, 1.0);
}
