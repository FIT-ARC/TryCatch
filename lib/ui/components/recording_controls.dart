import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../theme/app_colors.dart';
import '../../core/app_config.dart';
import '../../core/format.dart';
import '../../state/launch_site_store.dart';
import '../../state/telemetry_provider.dart';

/// Recording control for the top bar: a Record button when idle, or the
/// elapsed time with a stop action while recording. Fixed at
/// [AppConfig.topBarChipWidth] like the other top-bar chips, content
/// centered, so siblings never shift.
///
/// A launch site is mandatory: without one selected the button stays
/// disabled (recordings stamp the site into the file header).
class RecordingControls extends ConsumerStatefulWidget {
  const RecordingControls({super.key});

  @override
  ConsumerState<RecordingControls> createState() => _RecordingControlsState();
}

class _RecordingControlsState extends ConsumerState<RecordingControls> {
  DateTime? _startedAt;
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncWithStatus(bool isRecording) {
    if (isRecording && _startedAt == null) {
      _startedAt = DateTime.now();
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } else if (!isRecording && _startedAt != null) {
      _startedAt = null;
      _ticker?.cancel();
      _ticker = null;
    }
  }

  String _elapsed() {
    final started = _startedAt;
    if (started == null) return '0:00';
    return formatMinSec(DateTime.now().difference(started).inMilliseconds);
  }

  @override
  Widget build(BuildContext context) {
    final status =
        ref.watch(serialStatusProvider).value ?? const SerialWorkerStatus();
    _syncWithStatus(status.isRecording);

    Widget child;
    final connected = status.isConnected;
    if (status.isRecording) {      child = Tooltip(
        message: 'Stop recording',
        child: FilledButton.icon(
          onPressed: ref.read(serialConfigProvider.notifier).stopRecording,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.destructive,
            foregroundColor: AppColors.primaryForeground,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: const Icon(Icons.stop_rounded, size: 15),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _RecordingDot(),
              const SizedBox(width: 6),
              Text(
                _elapsed(),
                style: AppText.mono.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      final hasSite = ref.watch(currentLaunchSiteProvider) != null;
      final canRecord = connected && hasSite;
      child = Tooltip(
        message: !connected
            ? 'Connect first — recording needs a live link'
            : !hasSite
                ? 'Set a launch site in Settings first — recordings require one'
                : 'Record raw telemetry to a file',
        child: OutlinedButton.icon(
          onPressed: canRecord
              ? ref.read(serialConfigProvider.notifier).startRecording
              : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.destructive,
            disabledForegroundColor:
                AppColors.destructive.withValues(alpha: 0.45),
            side: BorderSide(
                color: AppColors.destructive.withValues(
                    alpha: canRecord ? 1.0 : 0.45)),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: const Icon(Icons.radio_button_checked, size: 14),
          label: const Text('Record'),
        ),
      );
    }

    return SizedBox(
      width: AppConfig.topBarChipWidth,
      height: 32,
      child: Center(child: child),
    );
  }
}

class _RecordingDot extends StatefulWidget {
  const _RecordingDot();

  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.25, end: 1.0).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.primaryForeground,
        ),
      ),
    );
  }
}
