import 'package:dead_reckoning/dead_reckoning.dart' show haversineDistanceM;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../core/format.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/waiting_for_data.dart';

/// Flight highlights: session extremes in one tile.
///
/// - Max ascent / descent velocity (m/s, vertical component)
/// - Top total speed (m/s, also as Mach)
/// - Max acceleration (m/s², also as G)
/// - Replay-only: total drift (launch site → last GPS fix) and max
///   altitude (no live equivalent — the flight is still in progress)
///
/// Live it scans the store ring; during a replay it scans the whole
/// pre-decoded flight so long recordings past the live ring cap still
/// report true peaks.
class HighlightsTile extends ConsumerWidget {
  const HighlightsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Highlights are velocity/acceleration extremes — without either the
    // tile has nothing to extreme over.
    final connector = ref.watch(activeConnectorProvider);
    final hasVelocity =
        connector.capabilities.supports(TelemetryField.velocity);
    final hasAccel =
        connector.capabilities.supports(TelemetryField.acceleration);
    if (!hasVelocity && !hasAccel) {
      return Center(
        child: NotProvidedByConnector(
          field: 'Velocity / Acceleration',
          connectorName: connector.displayName,
        ),
      );
    }
    final state = ref.watch(telemetryStoreProvider);
    final replay = ref.watch(replayProvider);
    final site = ref.watch(effectiveLaunchSiteProvider);

    final Iterable<TelemetryFrame> frames =
        replay.isActive && replay.frames.isNotEmpty
            ? replay.frames
            : state.history;

    if (frames.isEmpty) {
      return const Center(child: WaitingForData());
    }

    final peaks = FlightPeaks.scan(frames);
    final replaying = replay.isActive;

    final lastFix = replaying ? FlightPeaks.lastFix(frames) : null;
    final drift = site != null && lastFix != null
        ? haversineDistanceM(
            site.latitude, site.longitude, lastFix.latitude, lastFix.longitude)
        : null;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _Cell(
                label: '↑ Ascent max',
                value: '${peaks.maxAscent.toStringAsFixed(1)} m/s',
                color: AppColors.seriesVelocityVertical,
              ),
            ),
            Expanded(
              child: _Cell(
                label: '↓ Descent max',
                value: '${peaks.maxDescent.toStringAsFixed(1)} m/s',
                color: AppColors.seriesVelocityVertical,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Cell(
                label: 'Top speed',
                value: '${peaks.maxTotal.toStringAsFixed(1)} m/s',
                sub: 'M ${FlightPeaks.mach(peaks.maxTotal).toStringAsFixed(2)}',
                color: AppColors.seriesVelocity,
              ),
            ),
            Expanded(
              child: _Cell(
                label: 'Max acceleration',
                value: '${peaks.maxAccel.toStringAsFixed(1)} m/s²',
                sub: '${FlightPeaks.gForce(peaks.maxAccel).toStringAsFixed(1)} G',
                color: AppColors.seriesAccel,
              ),
            ),
          ],
        ),
        if (replaying) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _Cell(
                  label: 'Total drift',
                  value: drift == null ? '—' : formatDistanceM(drift),
                  color: AppColors.foreground,
                ),
              ),
              Expanded(
                child: _Cell(
                  label: 'Max altitude',
                  value: formatAltitudeM(peaks.maxAltitude),
                  color: AppColors.seriesAltitude,
                ),
              ),
            ],
          ),
        ],
      ],
    );

    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.maxHeight.isFinite) return content;
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: content,
            ),
          );
        },
      ),
    );
  }
}

/// Session extremes over a set of frames. Pure + unit-testable.
class FlightPeaks {
  final double maxAscent;
  final double maxDescent;
  final double maxTotal;
  final double maxAccel;
  final double maxAltitude;

  const FlightPeaks({
    required this.maxAscent,
    required this.maxDescent,
    required this.maxTotal,
    required this.maxAccel,
    required this.maxAltitude,
  });

  static const double _g0 = 9.80665;

  /// Speed of sound at sea level, 15 °C — good enough for a Mach readout.
  static const double _speedOfSound = 343.0;

  static double gForce(double accelMs2) => accelMs2 / _g0;

  static double mach(double speedMs) => speedMs / _speedOfSound;

  static FlightPeaks scan(Iterable<TelemetryFrame> frames) {
    var ascent = 0.0;
    var descent = 0.0;
    var total = 0.0;
    var accel = 0.0;
    var altitude = 0.0;
    for (final f in frames) {
      if (f.speedVertical > ascent) ascent = f.speedVertical;
      if (f.velocityDown > descent) descent = f.velocityDown;
      if (f.speedTotal > total) total = f.speedTotal;
      if (f.accelTotal > accel) accel = f.accelTotal;
      if (f.baroAltitude > altitude) altitude = f.baroAltitude;
    }
    return FlightPeaks(
      maxAscent: ascent,
      maxDescent: descent,
      maxTotal: total,
      maxAccel: accel,
      maxAltitude: altitude,
    );
  }

  /// Last frame carrying a GPS fix, or `null` when there is none.
  static TelemetryFrame? lastFix(Iterable<TelemetryFrame> frames) {
    TelemetryFrame? last;
    for (final f in frames) {
      if (f.gpsHasFix) last = f;
    }
    return last;
  }
}

/// One highlight cell: micro label on top, mono value below, optional sub —
/// all centred.
class _Cell extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color color;

  const _Cell({
    required this.label,
    required this.value,
    this.sub,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style:
              AppText.microLabel.copyWith(fontSize: 10.5, letterSpacing: 1.2),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppText.mono.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: color,
          ),
        ),
        if (sub != null)
          Text(
            sub!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppText.mono.copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: AppColors.mutedForeground,
            ),
          ),
      ],
    );
  }
}
