import '../../state/recording_provider.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../services/recording_repository.dart';
import '../../foundation/app_log.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../session/feedback.dart';
import '../../state/workspace_controller.dart';
import '../../theme/app_colors.dart';
import './recording_card.dart';
import './recording_info.dart';
import './router.dart';
import './trim_dialog.dart';

export './recording_card.dart';
export './recording_info.dart';
export './trim_chart.dart';
export './trim_dialog.dart';

/// Recorded flights: preview cards with decoded stats, replay, trim-to-new
/// ("save part of a flight") and delete, plus an open-folder shortcut.
class RecordingsScreen extends ConsumerStatefulWidget {
  const RecordingsScreen({super.key});

  @override
  ConsumerState<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends ConsumerState<RecordingsScreen> {
  late Future<List<RecordingInfo>> _recordings;
  String? _loadingPath;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _recordings = _scanRecordings();
  }

  /// Stat-only scan: the grid renders immediately off names/sizes, and each
  /// card decodes its own preview concurrently (see [RecordingCard]).
  /// Fully parsing every file up front would hold the whole list hostage to
  /// the slowest file. Decoded previews are cached for the session (keyed by
  /// path + size + mtime) so refreshes don't re-parse unchanged files.
  /// Headers yield duration/packets/max-alt/connector straight from the
  /// fixed header.
  ///
  /// Read-only bundled assets under `assets/recordings/` are listed next to
  /// the user's files (keyed by asset path) without copying them to disk.
  final _infoCache = <String, RecordingInfo>{};

  Future<List<RecordingInfo>> _scanRecordings() async {
    final dirPath = await ref.read(recordingsDirectoryProvider.future);
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];

    final recordings = <RecordingInfo>[];
    final seen = <String>{};
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.bin')) continue;
      try {
        final stat = await entity.stat();
        seen.add(entity.path);
        final cached = _infoCache[entity.path];
        if (cached != null &&
            cached.sizeBytes == stat.size &&
            cached.modified == stat.modified) {
          recordings.add(cached);
          continue;
        }
        final info = RecordingInfo(
          path: entity.path,
          sizeBytes: stat.size,
          modified: stat.modified,
        );
        try {
          _applyHeader(info, await tryReadRecordingHeader(entity.path));
        } catch (_) {
          // Header read is best-effort; the card decode fills stats instead.
        }
        _infoCache[entity.path] = info;
        recordings.add(info);
      } catch (e) {
        AppLog.warn('Skipping recording ${entity.path}: $e');
      }
    }
    for (final assetKey in await RecordingRepository.bundledRecordingKeys()) {
      seen.add(assetKey);
      final cached = _infoCache[assetKey];
      if (cached != null) {
        recordings.add(cached);
        continue;
      }
      try {
        final bytes = await RecordingRepository.readAssetBytes(assetKey);
        final info = RecordingInfo(
          path: assetKey,
          sizeBytes: bytes.lengthInBytes,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
          origin: RecordingOrigin.bundled,
        );
        _applyHeader(info, RecordingHeader.decode(bytes));
        _infoCache[assetKey] = info;
        recordings.add(info);
      } catch (_) {
        // Skip unreadable assets; they stay out of the grid.
      }
    }
    _infoCache.removeWhere((key, _) => !seen.contains(key));
    // Newest flight day first, alphabetical by file name within a day.
    DateTime dayOf(RecordingInfo info) {
      final d = info.flightDate;
      return DateTime(d.year, d.month, d.day);
    }

    recordings.sort((a, b) {
      final day = dayOf(b).compareTo(dayOf(a));
      if (day != 0) return day;
      return a.name.compareTo(b.name);
    });
    return recordings;
  }

  /// Fills a recording's header-derived metadata (launch site, connector,
  /// flight time and stats) from [header], skipping a null/unreadable one.
  void _applyHeader(RecordingInfo info, RecordingHeader? header) {
    if (header == null) return;
    info.launchSite = launchSiteFromHeader(header);
    if (header.connectorId.isNotEmpty) {
      info.connectorId = header.connectorId;
    }
    if (header.startMicros > 0) {
      info.flightTime = DateTime.fromMicrosecondsSinceEpoch(header.startMicros);
    }
    if (header.hasStats) {
      info.durationMs = header.durationMs;
      info.packets = header.packetCount;
      info.maxAltM = header.maxBaroAltM;
    }
  }

  Future<void> _openFolder() async {
    try {
      await RecordingService.openRecordingsFolder();
    } catch (_) {
      if (!mounted) return;
      ref.errorToast('Could not open the folder.');
    }
  }

  Future<void> _play(RecordingInfo recording) async {
    if (_loadingPath != null) return;
    // Opening a replay clears live buffers, so confirm first when a
    // recording is running. The live link is dropped by play() itself —
    // no reconnect needed afterwards — so connectedness needs no confirm.
    // Replacing an already-open replay needs no confirmation.
    final serialStatus = ref.read(serialStatusProvider).value;
    final isRecording = serialStatus?.isRecording ?? false;
    if (isRecording) {
      if (!context.mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Stop recording and open replay?'),
          content: const Text(
            'Opening a replay stops the current recording and clears live '
            'data. The recording file is kept.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Stop & open'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      ref.read(serialConfigProvider.notifier).stopRecording();
    }
    setState(() => _loadingPath = recording.path);
    try {
      final replay = ref.read(replayProvider.notifier);
      if (recording.isBundled) {
        await replay.playAsset(recording.path);
      } else {
        await replay.play(recording.path);
      }
    } finally {
      if (mounted) setState(() => _loadingPath = null);
    }
    // Jump to the dashboard once a replay actually loaded;
    // load errors stay on this screen.
    if (!context.mounted) return;
    final replay = ref.read(replayProvider);
    if (replay.isActive && replay.errorMsg == null) {
      // Always show the first layout — no heuristics.
      final workspaces =
          ref.read(workspaceProvider).value?.workspaces ?? const [];
      if (workspaces.isNotEmpty) {
        await ref
            .read(workspaceProvider.notifier)
            .setActive(workspaces.first.id);
      }
      ref.read(appRouterProvider.notifier).go(AppScreen.dashboard);
    }
  }

  @override
  Widget build(BuildContext context) {
    final replay = ref.watch(replayProvider);

    final isLoading = _loadingPath != null || replay.isLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Reserved slot: inserting the progress bar must not push the grid
        // down (that 2px jump coincides with the pink card outline and
        // reads as the outline shifting the layout).
        SizedBox(
          height: 2,
          child: isLoading
              ? const LinearProgressIndicator(minHeight: 2)
              : const SizedBox.shrink(),
        ),
        if (replay.isActive && replay.errorMsg != null)
          // Playback controls live in the top bar; surface only load errors.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppColors.destructive.withValues(alpha: 0.08),
            child: Text(
              replay.errorMsg!,
              style: TextStyle(fontSize: 12.5, color: AppColors.destructive),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppDimens.pagePadding,
            AppDimens.pagePadding,
            AppDimens.pagePadding,
            8,
          ),
          child: Row(
            children: [
              Text(
                'RECORDED FLIGHTS',
                style: AppText.microLabel.copyWith(letterSpacing: 1.4),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _openFolder,
                icon: const Icon(Icons.folder_open_outlined, size: 16),
                label: const Text('Open folder'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => setState(_reload),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<RecordingInfo>>(
            future: _recordings,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Could not read recordings: ${snapshot.error}'),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => setState(_reload),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              }
              final recordings = snapshot.data ?? const [];
              if (recordings.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.flight,
                        size: 40,
                        color: AppColors.strongBorder,
                      ),
                      const SizedBox(height: 12),
                      const Text('No recordings yet'),
                      const SizedBox(height: 4),
                      Text(
                        'Connect a port, then hit Record in the top bar.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => ref
                            .read(appRouterProvider.notifier)
                            .go(AppScreen.dashboard),
                        icon: const Icon(
                          Icons.space_dashboard_outlined,
                          size: 16,
                        ),
                        label: const Text('Go to dashboard'),
                      ),
                    ],
                  ),
                );
              }

              final byDay = groupRecordingsByDay(recordings);
              final now = DateTime.now();

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.pagePadding,
                  0,
                  AppDimens.pagePadding,
                  AppDimens.pagePadding,
                ),
                itemCount: byDay.length,
                itemBuilder: (context, group) {
                  final day = byDay.keys.elementAt(group);
                  final flights = byDay[day]!;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 8),
                        child: Text(
                          recordingDayLabel(day, now).toUpperCase(),
                          style: AppText.microLabel.copyWith(
                            letterSpacing: 1.4,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 440,
                              // Content budget: 18 card padding + ~32 header + 6
                              // + 200 preview + 6 + ~12 stats.
                              mainAxisExtent: 284,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                            ),
                        itemCount: flights.length,
                        itemBuilder: (context, index) {
                          final recording = flights[index];
                          final isLoaded = replay.filePath == recording.path;
                          final cardLoading = _loadingPath == recording.path;
                          return RecordingCard(
                            info: recording,
                            isLoaded: isLoaded,
                            isLoading: cardLoading,
                            busy: _loadingPath != null,
                            onPlay: () => _play(recording),
                            onDelete: () async {
                              await recording.delete();
                              setState(_reload);
                            },
                            onTrim: () async {
                              final saved = await showDialog<bool>(
                                context: context,
                                builder: (_) => TrimDialog(info: recording),
                              );
                              if (saved == true) setState(_reload);
                            },
                            onRenamed: () => setState(_reload),
                          );
                        },
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
