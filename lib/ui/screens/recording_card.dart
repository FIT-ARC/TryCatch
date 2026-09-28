import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:serial/serial.dart' show connectorById;

import '../../core/flight_events.dart';
import '../../core/format.dart';
import '../../services/flight_trim.dart'
    show buildAltProfile, buildTrackProfile;
import '../../services/recording_repository.dart';
import '../../session/feedback.dart';
import '../../state/launch_site_store.dart';
import '../../theme/app_colors.dart';
import '../components/app_card.dart';
import '../tiles/shared/map_tiles.dart';
import './orbit_preview.dart';
import './recording_info.dart';

class RecordingCard extends ConsumerStatefulWidget {
  final RecordingInfo info;
  final bool isLoaded;
  final bool isLoading;
  final bool busy;
  final VoidCallback onPlay;
  final VoidCallback onDelete;
  final VoidCallback onTrim;
  final VoidCallback onRenamed;

  const RecordingCard({
    super.key,
    required this.info,
    required this.isLoaded,
    this.isLoading = false,
    this.busy = false,
    required this.onPlay,
    required this.onDelete,
    required this.onTrim,
    required this.onRenamed,
  });

  @override
  ConsumerState<RecordingCard> createState() => RecordingCardState();
}

class RecordingCardState extends ConsumerState<RecordingCard> {
  bool _savingSite = false;
  @override
  void initState() {
    super.initState();
    // Each card decodes its own file concurrently after the grid is already
    // on screen — the list never waits for the slowest recording.
    if (!widget.info.previewDone) _loadPreview();
  }

  /// Decode pass for packet count, duration, max altitude, the altitude
  /// profile and the 3D track.
  ///
  /// Chunks hold raw stream fragments (not one packet each), so they go
  /// through the packet parser before decoding — decoding chunks directly
  /// yields nothing and renders a flat preview. Stats already known from
  /// the file header are kept; the decode only adds the visual profiles.
  Future<void> _loadPreview() async {
    try {
      final flight = await RecordingRepository.decodePreview(widget.info.path);
      if (!mounted) return;
      setState(() {
        final info = widget.info;
        if (!flight.isEmpty) {
          final frames = flight.frames;
          info.packets ??= frames.length;
          info.durationMs ??=
              frames.last.receivedAtMs - frames.first.receivedAtMs;
          if (info.maxAltM == null) {
            var maxAlt = double.negativeInfinity;
            for (final frame in frames) {
              if (frame.baroAltitude > maxAlt) maxAlt = frame.baroAltitude;
            }
            if (maxAlt.isFinite) info.maxAltM = maxAlt;
          }
          info.altProfile = buildAltProfile(frames);
          info.track = buildTrackProfile(frames);
          // Previews decode with the file's own connector (see
          // decodeRecordingFrames); its event table draws the markers.
          final previewConnector = connectorById(info.connectorId);
          info.events = detectFlightEvents(
            frames,
            eventDefs: previewConnector?.events,
            connector: previewConnector,
          );
        }
        info.previewDone = true;
      });
    } catch (_) {
      // Preview stays empty; the file can still (maybe) replay.
      if (!mounted) return;
      setState(() => widget.info.previewDone = true);
    }
  }

  String get _sizeLabel {
    if (widget.info.sizeBytes >= 1024 * 1024) {
      return '${(widget.info.sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(widget.info.sizeBytes / 1024).toStringAsFixed(0)} KB';
  }

  /// Saves this recording's header launch position as a preset. The button
  /// hides itself on completion because the preset list (watched in [build])
  /// then covers the site.
  Future<void> _saveLaunchSite(LaunchSite site) async {
    if (_savingSite) return;
    setState(() => _savingSite = true);
    try {
      await ref.read(launchSiteProvider.notifier).savePreset(site);
      unawaited(precacheLaunchSites([site]));
      if (!mounted) return;
      ref.successToast('Saved launch site "${site.name}".');
    } catch (_) {
      if (!mounted) return;
      ref.errorToast('Could not save the launch site.');
    } finally {
      if (mounted) setState(() => _savingSite = false);
    }
  }

  /// Renames the file via a name dialog; the parent rescans on success.
  Future<void> _rename() async {
    final base = widget.info.name.replaceAll('.bin', '');
    final controller = TextEditingController(text: base);
    try {
      final fileName = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Rename flight', style: TextStyle(fontSize: 16)),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'File name'),
            onSubmitted: (_) =>
                Navigator.of(dialogContext).pop(controller.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Rename'),
            ),
          ],
        ),
      );
      if (fileName == null || !mounted) return;
      try {
        await widget.info.renameTo(fileName);
      } catch (e) {
        if (!mounted) return;
        ref.errorToast(e is StateError ? e.message : 'Could not rename.');
        return;
      }
      widget.onRenamed();
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final isLoaded = widget.isLoaded;
    final presets =
        ref.watch(launchSiteProvider).value?.presets ?? const <LaunchSite>[];
    final fileSite = info.launchSite;
    final showExtractSite =
        fileSite != null && !isLaunchSiteSaved(presets, fileSite);
    final canTrim = info.durationMs != null && info.durationMs! > 2000;
    final stats = <String>[
      if (info.durationMs != null) formatMinSec(info.durationMs!),
      if (info.packets != null) '${info.packets} packets',
      if (info.maxAltM != null) 'max ${formatAltitudeM(info.maxAltM)}',
      _sizeLabel,
    ];
    final date = formatDateTime(info.flightDate);

    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      borderColor: isLoaded ? AppColors.primary : null,
      // NOTE: fixed heights only — grid tiles can arrive with an unbounded
      // height during layout, which an Expanded child would explode on.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.flight_takeoff,
                size: 18,
                color: isLoaded ? AppColors.primary : AppColors.mutedForeground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      date,
                      style: AppText.mono.copyWith(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Recording actions',
                iconSize: 18,
                onSelected: (value) {
                  switch (value) {
                    case 'trim':
                      widget.onTrim();
                    case 'rename':
                      _rename();
                    case 'extract':
                      final site = fileSite;
                      if (site != null) _saveLaunchSite(site);
                    case 'delete':
                      widget.onDelete();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'trim',
                    enabled: canTrim,
                    child: const Row(
                      children: [
                        Icon(Icons.content_cut_outlined, size: 16),
                        SizedBox(width: 8),
                        Text('Trim…'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.drive_file_rename_outline, size: 16),
                        SizedBox(width: 8),
                        Text('Rename…'),
                      ],
                    ),
                  ),
                  if (showExtractSite)
                    PopupMenuItem(
                      value: 'extract',
                      enabled: !_savingSite,
                      child: Row(
                        children: [
                          const Icon(Icons.pin_drop_outlined, size: 16),
                          const SizedBox(width: 8),
                          Text(_savingSite ? 'Saving…' : 'Extract site'),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: AppColors.destructive,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Delete',
                          style: TextStyle(color: AppColors.destructive),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Orbiting 3D track preview (altitude sparkline when the
          // recording holds no GPS fixes): the flight at a glance. Shows a
          // spinner until this card's own decode lands. The whole preview
          // is the play affordance, as if it was a video — pink button in
          // the middle, pointer cursor, tap anywhere to open the replay.
          SizedBox(
            height: 200,
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
              clipBehavior: Clip.hardEdge,
              child: InkWell(
                onTap: widget.busy ? null : widget.onPlay,
                mouseCursor: widget.busy
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.muted,
                          borderRadius: BorderRadius.circular(
                            AppDimens.radiusSmall,
                          ),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: info.previewDone
                            ? OrbitOrSparkline(
                                track: info.track,
                                altProfile: info.altProfile,
                              )
                            : const Center(
                                child: SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                      ),
                    ),
                    Center(
                      child: Opacity(
                        opacity: widget.busy && !widget.isLoading ? 0.55 : 1,
                        child: Container(
                          width: 50,
                          height: 50,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primary.withValues(alpha: 0.4),
                          ),
                          child: widget.isLoading
                              ? const SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(
                                  isLoaded ? Icons.replay : Icons.play_arrow,
                                  size: 30,
                                  color: Colors.white,
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            stats.join(' · ').toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.microLabel.copyWith(
              fontSize: 9,
              letterSpacing: 0.8,
              color: AppColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}
