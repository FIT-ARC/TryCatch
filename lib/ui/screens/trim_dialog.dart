import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart' show connectorById;

import '../../core/flight_events.dart';
import '../../core/format.dart';
import '../../core/path_utils.dart';
import '../../services/flight_trim.dart' show buildAltProfile, trimRecording;
import '../../services/recording_repository.dart';
import '../../session/feedback.dart';
import '../../theme/app_colors.dart';
import './recording_info.dart';
import './trim_chart.dart';

/// Trims a time slice of a recording into a new `.bin` file.
class TrimDialog extends ConsumerStatefulWidget {
  final RecordingInfo info;

  const TrimDialog({super.key, required this.info});

  @override
  ConsumerState<TrimDialog> createState() => _TrimDialogState();
}

class _TrimDialogState extends ConsumerState<TrimDialog> {
  late double _startS;
  late double _endS;
  late final TextEditingController _name;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final totalS = (widget.info.durationMs ?? 0) / 1000;
    _startS = 0;
    _endS = totalS;
    final base = widget.info.name.replaceAll('.bin', '');
    _name = TextEditingController(text: '${base}_trim');
    // Self-heal: if the card preview never decoded (stale/empty profile),
    // decode on demand so the altitude graph and event markers still show.
    if (widget.info.altProfile.length < 2 || !widget.info.previewDone) {
      final preview = widget.info.isBundled
          ? RecordingRepository.decodePreviewFromAsset(widget.info.path)
          : RecordingRepository.decodePreview(widget.info.path);
      preview.then((flight) {
        if (!mounted || flight.isEmpty) return;
        setState(() {
          if (widget.info.altProfile.length < 2) {
            widget.info.altProfile = buildAltProfile(flight.frames);
          }
          final previewConnector =
              connectorById(widget.info.connectorId);
          widget.info.events = detectFlightEvents(
            flight.frames,
            eventDefs: previewConnector?.events,
            connector: previewConnector,
          );
        });
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (widget.info.isBundled) {
      setState(() => _error = 'Bundled recordings are read-only.');
      return;
    }
    final fileName = _name.text.trim();
    if (fileName.isEmpty || basename(fileName) != fileName) {
      setState(() => _error = 'Give the clip a plain file name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final dst = '${widget.info.directory}$fileName.bin';
      if (await File(dst).exists()) {
        if (!mounted) return;
        setState(() {
          _error = 'A file with that name already exists.';
          _saving = false;
        });
        return;
      }
      final kept = await trimRecording(
        srcPath: widget.info.path,
        dstPath: dst,
        startMs: (_startS * 1000).round(),
        endMs: (_endS * 1000).round(),
      );
      if (!mounted) return;
      if (kept == 0) {
        setState(() {
          _error = 'The selected slice holds no packets.';
          _saving = false;
        });
        return;
      }
      Navigator.of(context).pop(true);
      ref.successToast('Saved $fileName.bin ($kept packets).');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not write the clip.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalS = (widget.info.durationMs ?? 0) / 1000;
    return AlertDialog(
      title: const Text('Trim flight', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Keep ${formatMinSec((_startS * 1000).round())} – '
              '${formatMinSec((_endS * 1000).round())} '
              'of ${formatMinSec(widget.info.durationMs ?? 0)}.',
              style: AppText.mono.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.mutedForeground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            // Altitude context with the kept window highlighted and flight
            // milestones marked on the curve (dimmed outside the kept slice).
            if (widget.info.altProfile.length >= 2) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 110,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.muted,
                    borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: TrimChart(
                    values: widget.info.altProfile,
                    events: widget.info.events,
                    totalMs: widget.info.durationMs ?? 0,
                    startMs: (_startS * 1000).round(),
                    endMs: (_endS * 1000).round(),
                    color: AppColors.seriesAltitude,
                  ),
                ),
              ),
            ],
            RangeSlider(
              values: RangeValues(_startS, _endS),
              min: 0,
              max: totalS,
              divisions: totalS.ceil().clamp(1, 1200),
              labels: RangeLabels(
                formatMinSec((_startS * 1000).round()),
                formatMinSec((_endS * 1000).round()),
              ),
              onChanged: _saving
                  ? null
                  : (v) => setState(() {
                      _startS = v.start;
                      _endS = v.end;
                    }),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: 'New file name',
                suffixText: '.bin',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: AppColors.destructive, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (_saving || _endS <= _startS) ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save clip'),
        ),
      ],
    );
  }
}
