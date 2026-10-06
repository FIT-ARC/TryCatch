import '../../state/connector_provider.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../core/format.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/waiting_for_data.dart';

/// Operator uplink log: every command sent (or attempted) to the rocket,
/// oldest first.
///
/// Live, each row reads its age ticking up every second ("Arm — 12 s
/// ago"). During a replay the same rows read their flight time
/// ("Arm — at 1:23"); tapping one seeks the replay there, and commands
/// still ahead of the playhead render dimmed. Failed attempts render in
/// the destructive accent so they stand out from successful sends.
class CommandsTile extends ConsumerStatefulWidget {
  const CommandsTile({super.key});

  @override
  ConsumerState<CommandsTile> createState() => _CommandsTileState();
}

class _CommandsTileState extends ConsumerState<CommandsTile> {
  Timer? _ticker;
  final ScrollController _scrollController = ScrollController();
  int _prevCount = 0;

  @override
  void initState() {
    super.initState();
    // Drives the live "N s ago" ages; replay rows show fixed flight times.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(
      telemetryStoreProvider.select(
        (s) => (replaying: s.replaying, empty: s.history.isEmpty),
      ),
    );
    final replayActive = ref.watch(replayProvider.select((s) => s.isActive));
    final replaying = store.replaying && replayActive;

    if (replaying) {
      final commands = ref.watch(replayCommandsProvider);
      if (commands.isEmpty) {
        return Center(
          child: Text(
            'No commands in this recording',
            style: AppText.microLabel,
          ),
        );
      }
      _prevCount = commands.length;
      return ListView.separated(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 2),
        itemCount: commands.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, thickness: 1, color: AppColors.border),
        itemBuilder: (context, index) {
          final replayCommand = commands[index];
          return _CommandRow(
            command: replayCommand.command,
            time: 'at ${formatMinSec(replayCommand.positionMs)}',
            replaying: true,
            positionMs: replayCommand.positionMs,
          );
        },
      );
    }

    final commands = ref.watch(commandLogProvider);
    if (store.empty && commands.isEmpty) {
      return const Center(child: WaitingForData());
    }
    if (commands.isEmpty) {
      return Center(child: Text('No commands yet', style: AppText.microLabel));
    }

    // Live auto-scrolls to the bottom when new commands arrive.
    if (commands.length > _prevCount) {
      _prevCount = commands.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: commands.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, thickness: 1, color: AppColors.border),
      // Oldest first: chronological order (oldest at top, newest at bottom).
      itemBuilder: (context, index) {
        final command = commands[index];
        return _CommandRow(
          command: command,
          time: formatAgoMs(nowMs - command.receivedAtMs),
          replaying: false,
          positionMs: 0,
        );
      },
    );
  }
}

/// One log row: status icon + command name + source/status on the left,
/// time on the right. During a replay the whole row seeks to the command
/// on tap.
class _CommandRow extends ConsumerWidget {
  final SentCommand command;
  final String time;
  final bool replaying;

  /// Flight-clock position of the command (replay only).
  final int positionMs;

  const _CommandRow({
    required this.command,
    required this.time,
    required this.replaying,
    required this.positionMs,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Live rows resolve with the active connector; replay rows with the
    // recording's own connector (auto-selected on play, but the row must
    // not depend on the live toggle).
    final TelemetryConnector connector;
    if (replaying) {
      final id = ref.watch(replayProvider.select((s) => s.connectorId));
      connector = connectorById(id) ?? ref.watch(activeConnectorProvider);
    } else {
      connector = ref.watch(activeConnectorProvider);
    }
    final description = connector.describeCommand(command.bytes);
    final failed = command.status == CommandStatus.failed;
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          _CommandDot(
            command: command,
            replaying: replaying,
            positionMs: positionMs,
            connector: connector,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  description.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                Text(
                  '${command.source.label} • ${command.status.label}'
                      .toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.microLabel.copyWith(
                    fontSize: 9,
                    color: failed ? AppColors.destructive : null,
                  ),
                ),
              ],
            ),
          ),
          Text(
            time,
            maxLines: 1,
            style: AppText.mono.copyWith(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: AppColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
    final hex = [
      for (final b in command.bytes.take(4))
        b.toRadixString(16).padLeft(2, '0'),
    ].join(' ');
    if (!replaying) {
      return Tooltip(
        message: '${description.subtitle} ($hex)',
        waitDuration: const Duration(milliseconds: 500),
        child: content,
      );
    }
    final isLoading = ref.watch(replayProvider.select((s) => s.isLoading));
    final durationMs = ref.watch(replayProvider.select((s) => s.durationMs));
    final target = durationMs == null
        ? positionMs
        : positionMs.clamp(0, durationMs);
    return Tooltip(
      message:
          '${description.label} at ${formatMinSec(positionMs)} — tap to seek',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: isLoading
            ? null
            : () => ref.read(replayProvider.notifier).seek(target),
        child: MouseRegion(cursor: SystemMouseCursors.click, child: content),
      ),
    );
  }
}

/// Status icon for a log row. Static live; during a replay a leaf consumer
/// on the playhead dims commands still ahead, so the row never rebuilds at
/// the ticker rate.
class _CommandDot extends ConsumerWidget {
  final SentCommand command;
  final bool replaying;
  final int positionMs;

  /// Connector that named this row (already resolved by the parent row).
  final TelemetryConnector connector;

  const _CommandDot({
    required this.command,
    required this.replaying,
    required this.positionMs,
    required this.connector,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failed = command.status == CommandStatus.failed;
    final description = connector.describeCommand(command.bytes);
    final Color color;
    final IconData icon;
    if (failed) {
      color = AppColors.destructive;
      icon = Icons.error_outline;
    } else {
      color = description.danger ? AppColors.destructive : AppColors.primary;
      icon = _iconFor(command.bytes, connector);
    }
    var dimmed = false;
    if (replaying) {
      final position = ref.watch(replayProvider.select((s) => s.positionMs));
      dimmed = position < positionMs;
    }
    return Opacity(
      opacity: dimmed ? 0.35 : 1.0,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.5),
        ),
        child: Icon(icon, size: 14, color: color),
      ),
    );
  }
}

/// Glyph per uplink frame: connector catalog id first, then a state-request
/// match, then a terminal fallback. Mirrors the control-panel mapping.
IconData _iconFor(List<int> bytes, TelemetryConnector connector) {
  for (final cmd in connector.commands) {
    if (cmd.bytes.length == bytes.length) {
      var match = true;
      for (var i = 0; i < cmd.bytes.length; i++) {
        if (cmd.bytes[i] != bytes[i]) {
          match = false;
          break;
        }
      }
      if (match) {
        return switch (cmd.id) {
          'arm' => Icons.gpp_good_outlined,
          'disarm' => Icons.gpp_bad_outlined,
          'fire_parachute' => Icons.paragliding,
          'beep' => Icons.campaign_outlined,
          'reset_fsm' => Icons.restart_alt,
          _ => Icons.terminal,
        };
      }
    }
  }
  for (final state in connector.states) {
    final want = connector.bytesForState(state.id);
    if (want != null &&
        want.length == bytes.length &&
        _bytesEqual(want, bytes)) {
      return Icons.account_tree_outlined;
    }
  }
  return Icons.terminal;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Display labels for the log subtitle line.
extension CommandLogLabels on CommandSource {
  String get label => switch (this) {
    CommandSource.controlPanel => 'Control panel',
    CommandSource.fsm => 'FSM',
    CommandSource.unknown => 'Unknown',
  };
}

extension CommandStatusLabels on CommandStatus {
  String get label => switch (this) {
    CommandStatus.sent => 'Sent',
    CommandStatus.failed => 'Failed',
  };
}
