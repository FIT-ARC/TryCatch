import '../../state/connector_provider.dart';
import '../../core/flight_peaks.dart';
export '../../core/flight_peaks.dart';

import 'package:dead_reckoning/dead_reckoning.dart' show haversineDistanceM;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../core/format.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/waiting_for_data.dart';

/// Flight highlights: session extremes in one tile.
///
/// - Max ascent / descent velocity (m/s, vertical component)
/// - Top speed (m/s, also as Mach — on a partial feed this is the
///   available component's peak and may match an ascent/descent max)
/// - Max acceleration (m/s², also as G)
/// - Replay-only: total drift (launch site → last GPS fix) and max
///   altitude (no live equivalent — the flight is still in progress)
///
/// Live peaks accumulate across the session; replay peaks are cached for
/// the whole decoded recording, independent of the playhead.
class HighlightsTile extends ConsumerWidget {
  const HighlightsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Highlights are velocity/acceleration extremes — without either the
    // tile has nothing to extreme over.
    final connector = ref.watch(activeConnectorProvider);
    final hasVelocity =
        connector.capabilities.supports(TelemetryField.velocityVertical) ||
        connector.capabilities.supports(TelemetryField.velocityHorizontal);
    final hasAccel = connector.capabilities.supports(
      TelemetryField.acceleration,
    );
    if (!hasVelocity && !hasAccel) {
      return Center(
        child: NotProvidedByConnector(
          field: 'Velocity / Acceleration',
          connectorName: connector.displayName,
        ),
      );
    }
    final replaying = ref.watch(replayProvider.select((s) => s.isActive));
    final summary = replaying
        ? ref.watch(replayHighlightsProvider)
        : ref.watch(
            telemetryStoreProvider.select(
              (s) =>
                  (peaks: s.peaks, lastFix: s.latest, empty: s.history.isEmpty),
            ),
          );
    final site = ref.watch(effectiveLaunchSiteProvider);
    if (summary.empty) return const Center(child: WaitingForData());
    final peaks = summary.peaks;
    final lastFix = replaying ? summary.lastFix : null;
    final drift = site != null && lastFix != null
        ? haversineDistanceM(
            site.latitude,
            site.longitude,
            lastFix.latitude,
            lastFix.longitude,
          )
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
            // Top speed is always shown when any velocity component exists —
            // on a partial feed (e.g. vertical-only) it is the available
            // component's peak, even if it matches an ascent/descent max.
            if (hasVelocity)
              Expanded(
                child: _Cell(
                  label: 'Top speed',
                  value: '${peaks.maxTotal.toStringAsFixed(1)} m/s',
                  sub:
                      'M ${FlightPeaks.mach(peaks.maxTotal).toStringAsFixed(2)}',
                  color: AppColors.seriesVelocity,
                ),
              ),
            if (hasAccel)
              Expanded(
                child: _Cell(
                  label: 'Max acceleration',
                  value: '${peaks.maxAccel.toStringAsFixed(1)} m/s²',
                  sub:
                      '${FlightPeaks.gForce(peaks.maxAccel).toStringAsFixed(1)} G',
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
          style: AppText.microLabel.copyWith(
            fontSize: 10.5,
            letterSpacing: 1.2,
          ),
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
