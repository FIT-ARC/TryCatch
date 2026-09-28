import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../theme/app_colors.dart';
import '../../core/app_config.dart';
import '../../session/feedback.dart';
import '../../state/telemetry_provider.dart';

/// Compact connection control for the top bar: port picker, rescan and link
/// action fused into one pill — the segments share the outer border with
/// square inner corners, so they read as a single button.
///
/// The port segment opens a popup; the middle segment rescans; the link
/// segment is an icon-only connect/disconnect. The outer width is fixed so
/// the bar never shifts when the link comes up.
class SerialControls extends ConsumerWidget {
  /// Nominal segment widths: the outer slot matches [AppConfig.topBarChipWidth]
  /// (same as the other top-bar chips) while the picker segment flexes into
  /// whatever the borders and fixed segments leave over.
  static const double pickerWidth =
      AppConfig.topBarChipWidth - actionWidth - refreshWidth - 2;
  static const double refreshWidth = 32;
  static const double actionWidth = 32;

  const SerialControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ports = ref.watch(availablePortsProvider).value ?? const [];
    final config = ref.watch(serialConfigProvider);
    final status =
        ref.watch(serialStatusProvider).value ?? const SerialWorkerStatus();
    final notifier = ref.read(serialConfigProvider.notifier);

    // Resolve the in-flight connect mark: the worker answered with a live
    // link (idempotent; also covers the "connected to another port" edge).
    // Failures clear via the toast bridge's error listener below.
    ref.listen(serialStatusProvider, (_, next) {
      next.whenData((s) {
        if (s.isConnected) {
          ref.read(serialConfigProvider.notifier).clearConnecting();
        }
      });
    });

    final selected = config.selectedPort;
    final effectiveSelected = selected ??
        (ports.contains(status.connectedPort) ? status.connectedPort : null);
    final connected = status.isConnected;
    // In-flight connect attempt (native open can stall on cranky hardware):
    // the pill shows a spinner + the target port until the worker answers.
    final connecting =
        (!connected) ? config.connectingPort : null;
    final canConnect = !connected && connecting == null && effectiveSelected != null;

    return Container(
      // Total slot stays fixed so siblings never shift; the border paints
      // inside these bounds (insetting the child by 1 px each side), so the
      // picker segment flexes into whatever remains instead of exact-fitting.
      width: pickerWidth + refreshWidth + actionWidth + 2,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        border: Border.all(
          color: connected
              ? AppColors.success.withValues(alpha: 0.5)
              : (connecting != null
                  ? AppColors.primary.withValues(alpha: 0.5)
                  : AppColors.strongBorder),
        ),
      ),
      child: Row(
        children: [
          // Port segment: popup when disconnected, static green name when
          // connected (disconnect first to switch ports).
          Expanded(
            child: SizedBox(
              height: 32,
              child: MouseRegion(
                cursor: connected
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                child: connected
                    ? Tooltip(
                        message:
                            'Connected to ${status.connectedPort ?? ''} — disconnect to switch ports',
                        child: _SegmentLabel(
                          text: status.connectedPort ?? '',
                          textColor: AppColors.success,
                          icon: Icons.lock,
                        ),
                      )
                    : PopupMenuButton<String>(
                        tooltip: ports.isEmpty
                            ? 'No serial ports found — plug in the radio'
                            : 'Select a serial port',
                        borderRadius:
                            BorderRadius.circular(AppDimens.radiusSmall),
                        padding: EdgeInsets.zero,
                        onSelected: notifier.setPort,
                        itemBuilder: (context) => [
                          for (final p in ports)
                            PopupMenuItem(
                              value: p,
                              child: Text(
                                p,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        child: _SegmentLabel(
                          text: connecting ??
                              (effectiveSelected ??
                                  (ports.isEmpty ? 'No ports' : 'Port')),
                          textColor: (connecting ?? effectiveSelected) == null
                              ? AppColors.mutedForeground
                              : AppColors.foreground,
                          icon: Icons.arrow_drop_down,
                        ),
                      ),
              ),
            ),
          ),
          // Rescan segment: circular-arrow refresh between the dropdown and
          // the link action. Hidden while connected (port switching needs a
          // disconnect first) — the picker flexes into the freed space and
          // the outer width stays fixed, so siblings never shift.
          if (!connected) ...[
            // Inner hairline joining the picker and rescan segments.
            Container(
              width: 1,
              height: 18,
              color: AppColors.border,
            ),
            SizedBox(
              width: refreshWidth,
              height: 32,
              child: Tooltip(
                message: 'Rescan for serial ports',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: notifier.refreshPorts,
                    child: Container(
                      alignment: Alignment.center,
                      color: Colors.transparent,
                      child: Icon(
                        Icons.refresh,
                        size: 17,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          // Inner hairline joining the link segment to its neighbor.
          Container(
            width: 1,
            height: 18,
            color: AppColors.border,
          ),
          // Link segment: icon-only connect/disconnect, spinner while the
          // native open is in flight. Pink only when a port is selected
          // (otherwise muted and inert — no hint toast needed).
          SizedBox(
            width: actionWidth,
            height: 32,
            child: Tooltip(
              message: connected
                  ? 'Disconnect ${status.connectedPort ?? ''}'
                  : (connecting != null
                      ? 'Connecting to $connecting…'
                      : (effectiveSelected == null
                          ? 'Select a port first'
                          : 'Connect to $effectiveSelected')),
              child: MouseRegion(
                cursor: canConnect || connected
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Mid-connect taps explain the spinner; a disabled
                  // (port-less) segment is inert by design.
                  onTap: connected
                      ? notifier.disconnect
                      : (connecting != null
                          ? () => ref.infoToast(
                                'Still connecting to $connecting…',
                                title: 'Connecting',
                              )
                          : (canConnect ? notifier.connect : null)),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.horizontal(
                        right: Radius.circular(AppDimens.radiusSmall),
                      ),
                      color: canConnect
                          ? AppColors.primary.withValues(alpha: 0.12)
                          : Colors.transparent,
                    ),
                    child: connecting != null
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          )
                        : Icon(
                            connected ? Icons.link_off : Icons.link,
                            size: 17,
                            color: connected
                                ? AppColors.mutedForeground
                                : (canConnect
                                    ? AppColors.primary
                                    : AppColors.faint),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Label half of the pill: port text + trailing glyph, no own border.
class _SegmentLabel extends StatelessWidget {
  final String text;
  final Color textColor;
  final IconData icon;

  const _SegmentLabel({
    required this.text,
    required this.textColor,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.mono.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: textColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 2),
          Icon(icon, size: 16, color: AppColors.mutedForeground),
        ],
      ),
    );
  }
}
