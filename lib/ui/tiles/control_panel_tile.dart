import '../components/two_click_button.dart';
import '../../state/launch_site_store.dart';
import '../../state/connector_provider.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../theme/app_colors.dart';

import 'package:serial/serial.dart';

extension ConnectorCommandUi on ConnectorCommand {
  IconData get icon => switch (id) {
    'arm' => Icons.gpp_good_outlined,
    'disarm' => Icons.gpp_bad_outlined,
    'fire_parachute' => Icons.paragliding,
    'beep' => Icons.campaign_outlined,
    'reset_fsm' => Icons.restart_alt,
    'move_up' => Icons.arrow_upward,
    'move_down' => Icons.arrow_downward,
    'move_east' => Icons.arrow_forward,
    'move_west' => Icons.arrow_back,
    _ => Icons.terminal,
  };
}

/// Two-click command panel: every tile requires a second confirming click
/// within 3 seconds before the bytes go out on the wire.
class ControlPanelTile extends ConsumerStatefulWidget {
  const ControlPanelTile({super.key});

  @override
  ConsumerState<ControlPanelTile> createState() => _ControlPanelWidgetState();
}

class _ControlPanelWidgetState extends ConsumerState<ControlPanelTile> {
  final _confirmation = TwoClickController<String>();
  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Commands make no sense while replaying a recording — the radio is
    // idle and the Replay workspace omits this tile entirely; this guard
    // covers custom layouts that still contain it.
    if (ref.watch(replayProvider.select((s) => s.isActive))) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 22, color: AppColors.faint),
            SizedBox(height: 8),
            Text(
              'Control panel disabled during replay',
              style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    final connected =
        (ref.watch(serialStatusProvider).value?.isConnected ?? false) &&
        ref.watch(currentLaunchSiteProvider.select((s) => s != null));
    ref.listen(serialStatusProvider, (_, next) {
      if (next.value?.isConnected != true) _confirmation.clear();
    });
    ref.listen(activeConnectorProvider, (_, _) => _confirmation.clear());

    // Buttons fill the tile: a 2-column grid (3 when wide) whose row height
    // is derived from the available height, so the buttons stretch to fill
    // the tile instead of sitting in a fixed strip. Falls back to
    // scrolling at the 54px minimum (icon-over-label needs the room) when
    // the tile is too short. The catalog comes from the active connector.
    final commands = ref.watch(activeConnectorProvider).commands;
    if (commands.isEmpty) {
      return Center(
        child: Text(
          'No commands on this connector',
          style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          textAlign: TextAlign.center,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Four commands always form a 2x2 grid, even on wide tiles where
        // the default would be 3 columns (3 + 1 orphan row).
        final columns = commands.length == 4
            ? 2
            : (constraints.maxWidth > 460 ? 3 : 2);
        final rows = (commands.length / columns).ceil();
        final bounded = constraints.maxHeight.isFinite;
        final fillExtent = (constraints.maxHeight - 8 * (rows - 1)) / rows;
        final extent = bounded ? math.max(54.0, fillExtent) : 56.0;

        final grid = GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: extent,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          children: [
            for (final command in commands)
              TwoClickButton<String>(
                id: command.id,
                controller: _confirmation,
                enabled: connected,
                onConfirm: () => ref
                    .read(serialConfigProvider.notifier)
                    .sendBytes(
                      command.bytes,
                      source: CommandSource.controlPanel,
                    ),
                builder: (context, state, tap) => _CommandTile(
                  command: command,
                  state: state,
                  enabled: connected,
                  onTap: tap ?? () {},
                ),
              ),
          ],
        );

        if (bounded && fillExtent >= 54.0) return grid;
        return SingleChildScrollView(child: grid);
      },
    );
  }
}

class _CommandTile extends StatelessWidget {
  final ConnectorCommand command;
  final TwoClickState state;
  final bool enabled;
  final VoidCallback onTap;

  const _CommandTile({
    required this.command,
    required this.state,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = command.danger ? AppColors.destructive : AppColors.primary;

    final Color background;
    final Color foreground;
    final Color border;
    final String label;
    final IconData icon;
    switch (state) {
      case TwoClickState.idle:
        background = AppColors.card;
        foreground = AppColors.foreground;
        border = AppColors.border;
        label = command.label;
        icon = command.icon;
      case TwoClickState.confirm:
        background = accent;
        foreground = AppColors.primaryForeground;
        border = accent;
        label = 'Tap again to confirm';
        icon = Icons.priority_high;
      case TwoClickState.sent:
        background = AppColors.success;
        foreground = AppColors.primaryForeground;
        border = AppColors.success;
        label = 'Sent';
        icon = Icons.check;
    }

    // Disabled keeps its real colors at reduced opacity instead of
    // flipping to grey text.
    final content = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          side: BorderSide(
            color: state == TwoClickState.idle
                ? border
                : AppColors.fixedTransparent,
            width: 1,
          ),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 21,
                  color: state == TwoClickState.idle ? accent : foreground,
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final withOpacity = enabled
        ? content
        : Opacity(opacity: 0.45, child: content);

    return Tooltip(
      message: enabled ? command.description : 'Connect first',
      waitDuration: const Duration(milliseconds: 500),
      child: withOpacity,
    );
  }
}
