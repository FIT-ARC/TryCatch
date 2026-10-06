import 'dart:math' as math;

import 'package:dead_reckoning/dead_reckoning.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../core/ring_buffer.dart';
import '../../state/layout_tree.dart';
import '../../state/launch_site_store.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../tile_registry.dart';
import '../../state/workspace_controller.dart';
import '../../theme/app_colors.dart';

/// Opens the tile picker.
///
/// * [changeTileId] — replace tile in place.
/// * [splitTileId] + [direction] — directional insert from a split arrow.
/// * [splitTileId] only — split the tile (auto orientation, existing behaviour).
/// * Neither — insert into the largest free area.
void showTilePicker(
  BuildContext context,
  WidgetRef ref, {
  String? splitTileId,
  String? changeTileId,
  SplitDirection? direction,
}) {
  showDialog<void>(
    context: context,
    builder: (_) => _TilePickerDialog(
      splitTileId: splitTileId,
      changeTileId: changeTileId,
      direction: direction,
    ),
  );
}

class _TilePickerDialog extends ConsumerStatefulWidget {
  final String? splitTileId;
  final String? changeTileId;
  final SplitDirection? direction;

  const _TilePickerDialog({
    this.splitTileId,
    this.changeTileId,
    this.direction,
  });

  @override
  ConsumerState<_TilePickerDialog> createState() => _TilePickerDialogState();
}

class _TilePickerDialogState extends ConsumerState<_TilePickerDialog> {
  String _query = '';

  List<TileDescriptor> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return TileRegistry.all;
    return TileRegistry.all
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              t.description.toLowerCase().contains(q),
        )
        .toList();
  }

  String get _title {
    if (widget.changeTileId != null) return 'Change tile type';
    if (widget.direction != null) {
      final side = switch (widget.direction!) {
        SplitDirection.left => 'left',
        SplitDirection.right => 'right',
        SplitDirection.top => 'above',
        SplitDirection.bottom => 'below',
      };
      return 'Add tile — $side';
    }
    if (widget.splitTileId != null) return 'Split tile — pick tile';
    return 'Add a tile';
  }

  void _pick(TileDescriptor descriptor) {
    Navigator.of(context).pop();
    final notifier = ref.read(workspaceProvider.notifier);
    if (widget.changeTileId != null) {
      notifier.changeTileType(widget.changeTileId!, descriptor.id);
    } else if (widget.direction != null && widget.splitTileId != null) {
      notifier.insertBesideTile(
        targetId: widget.splitTileId!,
        direction: widget.direction!,
        tileType: descriptor.id,
      );
    } else {
      notifier.addTile(descriptor.id, splitTileId: widget.splitTileId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tiles = _filtered;
    final media = MediaQuery.of(context).size;
    final dialogWidth = math.min(1140.0, media.width * 0.90);
    final dialogHeight = math.min(780.0, media.height * 0.88);

    return ProviderScope(
      overrides: [
        telemetryStoreProvider.overrideWith(_DummyTelemetryStore.new),
        effectiveLaunchSiteProvider.overrideWithValue(
          const LaunchSite(
            name: 'Launch Pad A',
            latitude: 47.3769,
            longitude: 8.5417,
            altitudeMsl: 450,
          ),
        ),
        serialStatusProvider.overrideWith(
          (ref) => Stream.value(
            const SerialWorkerStatus(isConnected: true, connectedPort: 'DEMO'),
          ),
        ),
      ],
      child: Dialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radius),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: dialogWidth,
            maxHeight: dialogHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Header ──────────────────────────────────────────────────────
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: AppColors.pink,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _title.toUpperCase(),
                        style: AppText.microLabel,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      iconSize: 18,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close, color: AppColors.mutedForeground),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // ── Search ──────────────────────────────────────────────────────
                TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Search tiles…',
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: AppColors.mutedForeground,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.muted,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        AppDimens.radiusSmall,
                      ),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        AppDimens.radiusSmall,
                      ),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        AppDimens.radiusSmall,
                      ),
                      borderSide: BorderSide(color: AppColors.primary),
                    ),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 12),
                // ── Tile grid with actual components ────────────────────────────
                Flexible(
                  child: tiles.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No tiles match',
                              style: TextStyle(
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ),
                        )
                      : GridView.builder(
                          shrinkWrap: true,
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 340,
                                mainAxisExtent: 205,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                              ),
                          itemCount: tiles.length,
                          itemBuilder: (context, index) => _TilePickCard(
                            descriptor: tiles[index],
                            onTap: () => _pick(tiles[index]),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Tile pick card with actual component preview ──────────────────────────────

class _TilePickCard extends StatelessWidget {
  final TileDescriptor descriptor;
  final VoidCallback onTap;

  const _TilePickCard({required this.descriptor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: AppColors.muted,
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Title Row — up to 2 lines so names are never cut off
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Icon(
                        descriptor.icon,
                        size: 15,
                        color: AppColors.pinkDeep,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        descriptor.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Actual Tile Component Preview with Dummy Data
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.border.withValues(alpha: 0.7),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: AbsorbPointer(child: descriptor.builder(context)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Dummy Telemetry Store for Realistic Component Previews ────────────────────

class _DummyTelemetryStore extends TelemetryStore {
  @override
  TelemetryState build() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final history = RingBuffer<TelemetryFrame>(30);
    final deadReckoningHistory = RingBuffer<DeadReckoningPosition>(30);

    const int count = 25;
    for (var i = 0; i < count; i++) {
      final t = i / (count - 1);
      final frameTime = now - ((count - 1 - i) * 1000);
      final alt = 2840.0 * (1.0 - math.pow(1.0 - t, 2).toDouble());
      final vel = 284.0 * math.sin(t * math.pi * 0.9);
      final accel = i < 5 ? 139.0 : 9.8 + 20.0 * (1.0 - t);
      final battery = 8.4 - 0.2 * t;

      final lat = 47.3769 + (0.005 * t);
      final lon = 8.5417 + (0.008 * t);

      final frame = TelemetryFrame(
        receivedAtMs: frameTime,
        flags: FrameFlags.gpsFix,
        sequence: 100 + i,
        latitude: lat,
        longitude: lon,
        baroAltitude: alt,
        velocityNorth: vel * 0.6,
        velocityEast: vel * 0.8,
        velocityUp: vel * 0.5,
        accelX: 0.5,
        accelY: 0.2,
        accelZ: accel,
        gyroX: 1.2,
        gyroY: -0.8,
        gyroZ: 4.5,
        heading: 82.0,
        roll: 12.0 * t,
        pitch: 14.0 * (1.0 - t * 0.5),
        yaw: 82.0,
        batteryVoltage: battery,
        hallRaw: 2500,
        fsmStateId: i < 3
            ? FsmState.armed.id
            : (i < 20 ? FsmState.ascent.id : FsmState.apogee.id),
      );
      history.push(frame);

      deadReckoningHistory.push(
        DeadReckoningPosition(
          atMs: frameTime,
          latitude: lat,
          longitude: lon,
          altitude: 450.0 + alt,
        ),
      );
    }

    return TelemetryState(
      history: history,
      deadReckoningHistory: deadReckoningHistory,
      latest: history.last,
      deadReckoning: deadReckoningHistory.last,
      packetCount: 250,
      sourceName: 'DEMO',
      replaying: false,
    );
  }
}
