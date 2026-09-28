import 'dart:io';

import 'package:dead_reckoning/dead_reckoning.dart' show haversineDistanceM;
import 'package:serial/serial.dart' show defaultConnectorId;

import '../../core/flight_events.dart';
import '../../core/format.dart';
import '../../core/path_utils.dart';
import '../../services/flight_trim.dart';
import '../../state/launch_site_store.dart';

/// Returns true when [site] already exists in [presets] — either under the
/// same name or within [toleranceM] horizontally of a saved preset (same
/// pad, re-recorded or renamed). Used to hide the per-recording
/// "extract launch position" button when there is nothing new to save.
bool isLaunchSiteSaved(
  List<LaunchSite> presets,
  LaunchSite site, {
  double toleranceM = 50,
}) {
  for (final preset in presets) {
    if (preset.name == site.name) return true;
    if (haversineDistanceM(
          preset.latitude,
          preset.longitude,
          site.latitude,
          site.longitude,
        ) <=
        toleranceM) {
      return true;
    }
  }
  return false;
}

/// Where a recording's bytes live: a user file on disk or a read-only
/// bundled asset (`assets/recordings/`).
enum RecordingOrigin { file, bundled }

/// Metadata + decoded preview about one `.bin` recording.
class RecordingInfo {
  /// Asset key for [RecordingOrigin.bundled], file path for
  /// [RecordingOrigin.file].
  final String path;

  /// Whether this recording is a read-only bundled asset.
  final RecordingOrigin origin;
  final int sizeBytes;
  final DateTime modified;
  int? durationMs;
  int? packets;
  double? maxAltM;

  /// Launch pad position stamped into the file header (`null` for legacy
  /// siteless or unreadable files — nothing to extract then).
  LaunchSite? launchSite;

  /// Stable id of the connector the file was recorded with (from the
  /// header stamp; defaults to the MOCK connector when unknown/unreadable
  /// so previews still decode with something).
  String connectorId = defaultConnectorId;

  /// Decimated barometric altitude profile (≤160 time-tagged points) for
  /// thumbnails and the trim graph.
  List<AltitudePoint> altProfile = const [];

  /// Decimated GPS track (≤160 pts, oldest first) for the 3D orbit preview.
  List<TrackPoint> track = const [];

  /// Flight start from the header (`null` when unreadable — falls back to
  /// the file date).
  DateTime? flightTime;

  /// Date the flight happened (header start, else file date).
  DateTime get flightDate => flightTime ?? modified;

  /// Flight milestones (launch / apogee / …) detected from the preview decode,
  /// in frame order — shown as markers in the trim view.
  List<FlightEvent> events = const [];

  /// Whether the preview decode already ran (successfully or not) — cards
  /// skip re-decoding when the session cache hands them a known file.
  bool previewDone = false;

  RecordingInfo({
    required this.path,
    required this.sizeBytes,
    required this.modified,
    this.origin = RecordingOrigin.file,
    this.durationMs,
    this.packets,
    this.maxAltM,
    this.launchSite,
  });

  /// Bundled recordings are shipped read-only; they cannot be renamed,
  /// trimmed or deleted.
  bool get isBundled => origin == RecordingOrigin.bundled;

  String get name => basename(path);

  String get directory => path.substring(0, path.length - name.length);

  /// Renames the file on disk (names are just filenames, so clips keep
  /// working). The `.bin` suffix is added when missing; existing files are
  /// never overwritten; renaming onto itself is a no-op. Returns the new
  /// path. Bundled recordings are read-only and refuse.
  Future<String> renameTo(String fileName) async {
    if (isBundled) {
      throw StateError('Bundled recordings are read-only.');
    }
    final raw = fileName.trim();
    if (raw.isEmpty || raw.contains('/') || raw.contains(r'\')) {
      throw StateError('Give the flight a plain file name.');
    }
    final clean = basename(raw);
    final withExt = clean.endsWith('.bin') ? clean : '$clean.bin';
    final dst = '$directory$withExt';
    if (dst == path) return path;
    if (await File(dst).exists()) {
      throw StateError('A file with that name already exists.');
    }
    return (await File(path).rename(dst)).path;
  }

  Future<void> delete() async {
    if (isBundled) return;
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}

/// Groups recordings by flight day (header start, else file date),
/// newest day first. Within-day order is preserved, so pass the list
/// newest-first.
Map<DateTime, List<RecordingInfo>> groupRecordingsByDay(
  List<RecordingInfo> recordings,
) {
  final byDay = <DateTime, List<RecordingInfo>>{};
  for (final recording in recordings) {
    final m = recording.flightDate;
    final day = DateTime(m.year, m.month, m.day);
    (byDay[day] ??= []).add(recording);
  }
  return byDay;
}

/// Day-group header: `Today` / `Yesterday` / `20. 9. 2026`.
String recordingDayLabel(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return formatDate(day);
}
