import 'connector_provider.dart';

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:serial/serial.dart';

import './launch_site_store.dart';
import './telemetry_provider.dart';

/// Resolved path to the user's `Documents/TryCatch/recordings/` directory.
final recordingsDirectoryProvider = FutureProvider<String>((ref) async {
  return RecordingService.getRecordingsDirectory();
});

/// Service managing telemetry recording files and session recording lifecycle.
abstract final class RecordingService {
  /// Starts a recording session with an auto-generated timestamp file in the documents recordings folder.
  ///
  /// The currently selected launch site is stamped into the recording file
  /// header. A site is mandatory — with none selected this is a no-op.
  static Future<void> startRecording(Ref ref) async {
    final site = ref.read(currentLaunchSiteProvider);
    if (site == null) return;
    final connectorId =
        ref.read(activeConnectorIdProvider).value ?? defaultVisibleConnectorId;
    final now = DateTime.now();
    final timestamp =
        '${now.year}-${_twoDigits(now.month)}-${_twoDigits(now.day)}_'
        '${_twoDigits(now.hour)}-${_twoDigits(now.minute)}-${_twoDigits(now.second)}';

    final dirPath = await getRecordingsDirectory();
    final filePath =
        '$dirPath${Platform.pathSeparator}telemetry_${timestamp}_${now.microsecondsSinceEpoch}.bin';

    ref
        .read(serialWorkerProvider)
        .send(
          StartRecordingCommand(
            filePath: filePath,
            launch: LaunchRef(
              latitude: site.latitude,
              longitude: site.longitude,
              mslM: site.altitudeMsl,
              name: site.name,
            ),
            connectorId: connectorId,
          ),
        );
  }

  /// Stops the active recording session.
  static void stopRecording(Ref ref) {
    ref.read(serialWorkerProvider).send(const StopRecordingCommand());
  }

  /// Opens the recordings folder in the desktop OS file explorer.
  static Future<void> openRecordingsFolder() async {
    final path = await getRecordingsDirectory();
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    if (Platform.isWindows) {
      await Process.run('explorer.exe', [dir.absolute.path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [dir.absolute.path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [dir.absolute.path]);
    }
  }

  /// Resolves the user's `Documents/TryCatch/recordings` directory cross-platform.
  static Future<String> getRecordingsDirectory() async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${docsDir.path}${Platform.pathSeparator}TryCatch${Platform.pathSeparator}recordings',
      );
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir.path;
    } catch (_) {
      // Fallback for standalone/test environments
      final fallback = Directory(
        '${Directory.current.path}${Platform.pathSeparator}recordings',
      );
      if (!await fallback.exists()) {
        await fallback.create(recursive: true);
      }
      return fallback.path;
    }
  }

  static String _twoDigits(int n) => n.toString().padLeft(2, '0');
}
