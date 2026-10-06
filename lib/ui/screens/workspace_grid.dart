import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/app_colors.dart';
import '../components/app_card.dart';
import './tile_leaf_scope.dart';
import './tile_picker_dialog.dart';
import '../../state/layout_tree.dart';
import '../../session/feedback.dart';
import '../tile_registry.dart';
import '../../state/workspace_controller.dart';
import '../../state/workspace_models.dart';

/// Renders the active workspace as a KD-tree tiling.
///
/// Edit-mode additions over the baseline:
///   • Directional split arrows on tile hover — one-click to add beside.
///   • Merge chip on every divider — collapses a split with an undo snackbar.
///   • Group highlight on divider hover — tints tiles on each side so the
///     user can see what moves together when they drag.
///   • Edge-zone drag — dragging a tile to the outer ~28 % of another tile
///     re-parents it (restructure); dropping on the centre still swaps.
class WorkspaceGrid extends ConsumerStatefulWidget {
  final bool editMode;

  const WorkspaceGrid({super.key, required this.editMode});

  @override
  ConsumerState<WorkspaceGrid> createState() => _WorkspaceGridState();
}

class _WorkspaceGridState extends ConsumerState<WorkspaceGrid> {
  // ── Divider drag state ───────────────────────────────────────────────────────
  String? _dragDividerId;
  double _dragStartRatio = 0.5;
  double _dividerDragOffset = 0;
  String? _snapLabel;
  double? _dragRatio;

  // ── Leaf drag state (swap / restructure) ─────────────────────────────────────
  String? _dragLeafId;
  String? _dropTargetId; // tile under the pointer
  SplitDirection? _dropZone; // null → centre/swap, else directional insert
  Offset _dragPointer = Offset.zero;

  // ── Hover state (split arrows + group highlight) ──────────────────────────────
  String? _hoveredTileId;
  String? _hoveredDividerId;
  Timer? _tileHoverTimer;

  // ── Layout memo ───────────────────────────────────────────────────────────────
  LayoutNode? _layoutForRoot;
  Size? _layoutForSize;
  LayoutResult? _layoutCache;
  Size? _lastLayoutSize;

  @override
  void dispose() {
    _tileHoverTimer?.cancel();
    super.dispose();
  }

  LayoutResult _layoutCached(LayoutNode root, Size size) {
    if (identical(root, _layoutForRoot) && size == _layoutForSize) {
      return _layoutCache!;
    }
    final result = layoutTree(
      root,
      Rect2(0, 0, size.width, size.height),
      TileRegistry.minSizeOf,
    );
    _layoutForRoot = root;
    _layoutForSize = size;
    _layoutCache = result;
    updateKnownRects(result);
    return result;
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(workspaceProvider).value?.active;
    if (workspace == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final root = workspace.root;
    if (root == null) {
      return _EmptyWorkspace(onAddTile: () => showTilePicker(context, ref));
    }

    return Padding(
      padding: const EdgeInsets.all(AppDimens.outerPadding),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          _lastLayoutSize = size;
          final result = _layoutCached(root, size);

          final editIdle = widget.editMode && _dragDividerId == null;
          final showGroupHighlight =
              editIdle && _hoveredDividerId != null && _dragLeafId == null;

          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // ── 1. Tiles ───────────────────────────────────────────────────────
              for (final entry in result.leafRects.entries)
                if (TileRegistry.byId(_typeOf(workspace, entry.key)) != null)
                  _buildLeaf(
                    workspace: workspace,
                    tileId: entry.key,
                    rect: entry.value,
                    // Show swap-target highlight only for centre-zone drops.
                    swapTarget: _dropTargetId == entry.key && _dropZone == null,
                  ),

              // ── 2. Drop-zone overlay (directional or swap preview) ─────────────
              if (_dragLeafId != null && _dropTargetId != null)
                _buildDropZoneOverlay(result),

              // ── 3. Group highlight ─────────────────────────────────────────────
              if (showGroupHighlight)
                Positioned.fill(
                  key: const ValueKey('group_highlight_layer'),
                  child: IgnorePointer(
                    child: Stack(
                      children: _buildGroupHighlight(workspace, result),
                    ),
                  ),
                ),

              // ── 4. Dividers + merge chips ──────────────────────────────────────
              for (final divider in result.dividers)
                ..._buildDivider(divider, result.dividers),

              // ── 5. Snap overlay during divider drag ───────────────────────────
              if (_dragDividerId != null) _buildSnapOverlay(result, size),

              // ── 6. Drag badge ─────────────────────────────────────────────────
              if (_dragLeafId != null)
                Positioned(
                  key: const ValueKey('drag_badge_layer'),
                  left: _dragPointer.dx,
                  top: _dragPointer.dy,
                  child: IgnorePointer(
                    child: _DragBadge(directional: _dropZone != null),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  String _typeOf(Workspace ws, String tileId) =>
      ws.leafOf(tileId)?.tileType ?? '';

  // ── Leaves ───────────────────────────────────────────────────────────────────

  Widget _buildLeaf({
    required Workspace workspace,
    required String tileId,
    required Rect2 rect,
    required bool swapTarget,
  }) {
    final tileType = _typeOf(workspace, tileId);
    final descriptor = TileRegistry.byId(tileType);
    if (descriptor == null) return const SizedBox.shrink();

    final isDragged = _dragLeafId == tileId;

    // Leaf identity + persisted settings ride down to the tile: stateful
    // tiles (the 3D flight views' camera mode) restore their selection and
    // report changes back so the save file follows the live UI.
    final tile = TileLeafScope.fromSettings(
      tileId: tileId,
      settings: workspace.leafOf(tileId)?.settings ?? const {},
      onCameraMode: (mode) =>
          ref.read(workspaceProvider.notifier).setTileCameraMode(tileId, mode),
      child: descriptor.builder(context),
    );

    Widget card = AppCard(
      fillChild: true,
      title: descriptor.title,
      borderColor: isDragged || swapTarget ? AppColors.primary : null,
      padding: descriptor.immersive ? EdgeInsets.zero : null,
      trailing: widget.editMode
          ? _EditHeaderActions(
              tileId: tileId,
              tileWidth: rect.width,
              swapTarget: swapTarget,
            )
          : null,
      child: widget.editMode ? AbsorbPointer(child: tile) : tile,
    );

    if (widget.editMode) {
      final showArrows = _hoveredTileId == tileId && _dragLeafId == null;

      // Layer split arrows on top of the card.
      card = Stack(
        children: [card, if (showArrows) _buildSplitArrowsOverlay(tileId)],
      );

      // Hover + drag gesture.
      card = MouseRegion(
        onEnter: (_) {
          _tileHoverTimer?.cancel();
          setState(() => _hoveredTileId = tileId);
        },
        onExit: (_) {
          // Small delay so moving from tile body to a split arrow doesn't
          // flicker the arrows away before the arrow's onEnter fires.
          _tileHoverTimer?.cancel();
          _tileHoverTimer = Timer(const Duration(milliseconds: 80), () {
            if (mounted) setState(() => _hoveredTileId = null);
          });
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            setState(() {
              _dragLeafId = tileId;
              _dragPointer = Offset(
                rect.left + details.localPosition.dx,
                rect.top + details.localPosition.dy,
              );
              _dropTargetId = null;
              _dropZone = null;
            });
          },
          onPanUpdate: (details) {
            _dragPointer += details.delta;
            final target = _leafAt(_dragPointer, tileId);
            final zone = _computeDropZone(target, _dragPointer);
            if (target != _dropTargetId || zone != _dropZone) {
              setState(() {
                _dropTargetId = target;
                _dropZone = zone;
              });
            } else {
              setState(() {}); // repaint badge position
            }
          },
          onPanEnd: (_) {
            final target = _dropTargetId;
            final zone = _dropZone;
            if (target != null) {
              if (zone != null) {
                ref
                    .read(workspaceProvider.notifier)
                    .moveTileBeside(
                      sourceId: tileId,
                      targetId: target,
                      direction: zone,
                    );
              } else {
                ref
                    .read(workspaceProvider.notifier)
                    .swapTiles(tileId: tileId, ontoTileId: target);
              }
            }
            setState(() {
              _dragLeafId = null;
              _dropTargetId = null;
              _dropZone = null;
            });
          },
          child: card,
        ),
      );
    }

    return Positioned(
      key: ValueKey('leaf_$tileId'),
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: card,
    );
  }

  // ── Split arrows overlay ──────────────────────────────────────────────────────

  /// Four directional arrow buttons rendered over the tile content.
  /// They're inside the tile's Stack so they never conflict with divider hover,
  /// and since they sit *under* the outer GestureDetector, a drag started on an
  /// arrow still drags the tile — only a clean tap triggers the picker.
  Widget _buildSplitArrowsOverlay(String tileId) {
    return Positioned.fill(
      child: Stack(
        children: [
          // Left
          Positioned(
            left: 6,
            top: 0,
            bottom: 0,
            child: Center(
              child: _SplitArrowButton(
                icon: Icons.arrow_back,
                tooltip: 'Add tile to the left',
                onTap: () => showTilePicker(
                  context,
                  ref,
                  splitTileId: tileId,
                  direction: SplitDirection.left,
                ),
              ),
            ),
          ),
          // Right
          Positioned(
            right: 6,
            top: 0,
            bottom: 0,
            child: Center(
              child: _SplitArrowButton(
                icon: Icons.arrow_forward,
                tooltip: 'Add tile to the right',
                onTap: () => showTilePicker(
                  context,
                  ref,
                  splitTileId: tileId,
                  direction: SplitDirection.right,
                ),
              ),
            ),
          ),
          // Top — offset below card header (~36 px).
          Positioned(
            top: 38,
            left: 0,
            right: 0,
            child: Center(
              child: _SplitArrowButton(
                icon: Icons.arrow_upward,
                tooltip: 'Add tile above',
                onTap: () => showTilePicker(
                  context,
                  ref,
                  splitTileId: tileId,
                  direction: SplitDirection.top,
                ),
              ),
            ),
          ),
          // Bottom
          Positioned(
            bottom: 6,
            left: 0,
            right: 0,
            child: Center(
              child: _SplitArrowButton(
                icon: Icons.arrow_downward,
                tooltip: 'Add tile below',
                onTap: () => showTilePicker(
                  context,
                  ref,
                  splitTileId: tileId,
                  direction: SplitDirection.bottom,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Leaf hit-test ─────────────────────────────────────────────────────────────

  String? _leafAt(Offset position, String excludeId) {
    final workspace = ref.read(workspaceProvider).value?.active;
    final root = workspace?.root;
    if (root == null) return null;
    final size = _lastLayoutSize;
    if (size == null) return null;
    final result = _layoutCached(root, size);
    for (final entry in result.leafRects.entries) {
      if (entry.key == excludeId) continue;
      final r = entry.value;
      if (position.dx >= r.left &&
          position.dx <= r.left + r.width &&
          position.dy >= r.top &&
          position.dy <= r.top + r.height) {
        return entry.key;
      }
    }
    return null;
  }

  // ── Edge-zone computation ─────────────────────────────────────────────────────

  /// Returns which edge of the drop target the pointer is in, or null for the
  /// centre zone (swap).  The outer ~28 % on each axis is the edge zone.
  SplitDirection? _computeDropZone(String? targetId, Offset pointer) {
    if (targetId == null) return null;
    final rect = _layoutCache?.leafRects[targetId];
    if (rect == null) return null;

    final relX = (pointer.dx - rect.left) / rect.width;
    final relY = (pointer.dy - rect.top) / rect.height;

    const edge = 0.28;
    final inEdgeX = relX < edge || relX > 1 - edge;
    final inEdgeY = relY < edge || relY > 1 - edge;
    if (!inEdgeX && !inEdgeY) return null; // centre → swap

    final dLeft = relX;
    final dRight = 1 - relX;
    final dTop = relY;
    final dBottom = 1 - relY;
    final minDist = math.min(math.min(dLeft, dRight), math.min(dTop, dBottom));

    if (minDist == dLeft) return SplitDirection.left;
    if (minDist == dRight) return SplitDirection.right;
    if (minDist == dTop) return SplitDirection.top;
    return SplitDirection.bottom;
  }

  // ── Drop-zone overlay ─────────────────────────────────────────────────────────

  Widget _buildDropZoneOverlay(LayoutResult result) {
    final targetId = _dropTargetId;
    if (targetId == null) return const SizedBox.shrink();
    final rect = result.leafRects[targetId];
    if (rect == null) return const SizedBox.shrink();

    double left = rect.left, top = rect.top;
    double width = rect.width, height = rect.height;

    final zone = _dropZone;
    if (zone != null) {
      switch (zone) {
        case SplitDirection.left:
          width = rect.width * 0.5;
        case SplitDirection.right:
          left = rect.left + rect.width * 0.5;
          width = rect.width * 0.5;
        case SplitDirection.top:
          height = rect.height * 0.5;
        case SplitDirection.bottom:
          top = rect.top + rect.height * 0.5;
          height = rect.height * 0.5;
      }
    }

    return Positioned(
      key: const ValueKey('drop_zone_overlay'),
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(
              alpha: zone != null ? 0.20 : 0.10,
            ),
            border: zone != null
                ? Border.all(color: AppColors.primary, width: 1.5)
                : null,
          ),
        ),
      ),
    );
  }

  // ── Group highlight ───────────────────────────────────────────────────────────

  /// Tints tiles on each side of the hovered divider so the user can see
  /// what moves together when they drag.
  List<Widget> _buildGroupHighlight(Workspace workspace, LayoutResult result) {
    final nodeId = _hoveredDividerId;
    if (nodeId == null) return const [];
    final groups = splitGroupLeaves(workspace.root, nodeId);
    if (groups.a.isEmpty && groups.b.isEmpty) return const [];

    final widgets = <Widget>[];
    for (final id in groups.a) {
      final r = result.leafRects[id];
      if (r == null) continue;
      widgets.add(
        Positioned(
          left: r.left,
          top: r.top,
          width: r.width,
          height: r.height,
          child: IgnorePointer(
            child: Container(color: AppColors.pink.withValues(alpha: 0.09)),
          ),
        ),
      );
    }
    for (final id in groups.b) {
      final r = result.leafRects[id];
      if (r == null) continue;
      widgets.add(
        Positioned(
          left: r.left,
          top: r.top,
          width: r.width,
          height: r.height,
          child: IgnorePointer(
            child: Container(
              color: AppColors.fixedBlueAccent.withValues(alpha: 0.06),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  // ── Dividers ──────────────────────────────────────────────────────────────────

  /// Returns the draggable divider line AND (in edit mode) the merge chip.
  List<Widget> _buildDivider(DividerHandle divider, List<DividerHandle> all) {
    if (!widget.editMode) {
      return [
        Positioned(
          left: divider.hitArea.left,
          top: divider.hitArea.top,
          width: divider.hitArea.width,
          height: divider.hitArea.height,
          child: const SizedBox.shrink(),
        ),
      ];
    }

    final isDragging = _dragDividerId == divider.nodeId;
    final snapped = isDragging && _snapLabel != null;
    final thickness = snapped ? 4.0 : (isDragging ? 3.0 : 1.0);
    final lineColor = isDragging ? AppColors.primary : AppColors.strongBorder;

    const hit = 10.0;
    final hArea = divider.hitArea;

    final dividerWidget = Positioned(
      key: ValueKey('divider_${divider.nodeId}'),
      left: hArea.left - (divider.vertical ? 0 : (hit - dividerWidth) / 2),
      top: hArea.top - (divider.vertical ? (hit - dividerWidth) / 2 : 0),
      width: divider.vertical ? hArea.width : hit,
      height: divider.vertical ? hit : hArea.height,
      child: MouseRegion(
        cursor: divider.vertical
            ? SystemMouseCursors.resizeRow
            : SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _hoveredDividerId = divider.nodeId),
        onExit: (_) => setState(() {
          if (_hoveredDividerId == divider.nodeId) {
            _hoveredDividerId = null;
          }
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () => ref
              .read(workspaceProvider.notifier)
              .toggleSplitOrientation(nodeId: divider.nodeId),
          onPanStart: (_) {
            setState(() {
              _dragDividerId = divider.nodeId;
              _dragStartRatio = divider.ratio;
              _dividerDragOffset = 0;
              _snapLabel = null;
              _dragRatio = divider.ratio;
            });
          },
          onPanUpdate: (details) {
            _dividerDragOffset += divider.vertical
                ? details.delta.dy
                : details.delta.dx;
            final raw = (_dragStartRatio + _dividerDragOffset / divider.extent)
                .clamp(0.02, 0.98);
            final snap = snapDividerRatio(
              rawRatio: raw,
              dragged: divider,
              all: _layoutCache?.dividers ?? all,
            );
            final ratio = (snap?.ratio ?? raw).clamp(0.02, 0.98);
            setState(() {
              _snapLabel = snap?.label;
              _dragRatio = ratio;
            });
            ref
                .read(workspaceProvider.notifier)
                .setRatio(nodeId: divider.nodeId, ratio: ratio, persist: false);
          },
          onPanEnd: (_) {
            setState(() {
              _dragDividerId = null;
              _snapLabel = null;
              _dragRatio = null;
            });
            ref.read(workspaceProvider.notifier).persistActive();
          },
          child: Tooltip(
            message: 'Double-click to rotate',
            child: Center(
              child: divider.vertical
                  ? Container(height: thickness, color: lineColor)
                  : Container(width: thickness, color: lineColor),
            ),
          ),
        ),
      ),
    );

    // ── Merge chip ─────────────────────────────────────────────────────────────
    // Shown only when not dragging anything (keeps the UI clean mid-drag).
    final chipX = hArea.left + hArea.width / 2;
    final chipY = hArea.top + hArea.height / 2;
    final showMergeChip = _dragDividerId == null && _dragLeafId == null;

    final mergeChip = showMergeChip
        ? Positioned(
            key: ValueKey('merge_${divider.nodeId}'),
            left: chipX - 10,
            top: chipY - 10,
            width: 20,
            height: 20,
            child: _MergeChipButton(
              onTapDown: (details) =>
                  _showMergeMenu(divider, details.globalPosition),
            ),
          )
        : null;

    return [dividerWidget, ?mergeChip];
  }

  // ── Merge menu ────────────────────────────────────────────────────────────────

  Future<void> _showMergeMenu(
    DividerHandle divider,
    Offset globalPosition,
  ) async {
    // Snapshot for undo before anything changes.
    final oldRoot = ref.read(workspaceProvider).value?.active?.root;

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final result = await showMenu<KeepSide>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: [
        PopupMenuItem(
          value: KeepSide.a,
          child: Row(
            children: [
              Icon(
                divider.vertical
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_left,
                size: 16,
                color: AppColors.mutedForeground,
              ),
              const SizedBox(width: 8),
              Text(divider.vertical ? 'Keep top' : 'Keep left'),
            ],
          ),
        ),
        PopupMenuItem(
          value: KeepSide.b,
          child: Row(
            children: [
              Icon(
                divider.vertical
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 16,
                color: AppColors.mutedForeground,
              ),
              const SizedBox(width: 8),
              Text(divider.vertical ? 'Keep bottom' : 'Keep right'),
            ],
          ),
        ),
      ],
    );

    if (result == null || !mounted) return;

    await ref
        .read(workspaceProvider.notifier)
        .mergeDivider(nodeId: divider.nodeId, keepSide: result);

    if (!mounted) return;
    ref.infoToast(
      'Section removed',
      actionLabel: 'Undo',
      onAction: () {
        ref.read(workspaceProvider.notifier).restoreRoot(oldRoot);
      },
    );
  }

  // ── Snap overlay ──────────────────────────────────────────────────────────────

  Widget _buildSnapOverlay(LayoutResult result, Size gridSize) {
    final id = _dragDividerId;
    if (id == null) return const SizedBox.shrink();
    DividerHandle? dragged;
    for (final d in result.dividers) {
      if (d.nodeId == id) {
        dragged = d;
        break;
      }
    }
    if (dragged == null) return const SizedBox.shrink();
    final d = dragged;
    final ratio = _dragRatio ?? d.ratio;
    final pct = (ratio * 100).round();
    final label = _snapLabel == null ? '$pct%' : '$pct% · $_snapLabel';

    final midX = d.hitArea.left + d.hitArea.width / 2;
    final midY = d.hitArea.top + d.hitArea.height / 2;

    final isAligned = _snapLabel == 'Aligned';
    return Stack(
      children: [
        if (isAligned)
          if (d.vertical)
            Positioned(
              left: 0,
              top: midY - 0.5,
              width: gridSize.width,
              height: 1,
              child: IgnorePointer(
                child: Container(
                  color: AppColors.primary.withValues(alpha: 0.55),
                ),
              ),
            )
          else
            Positioned(
              left: midX - 0.5,
              top: 0,
              width: 1,
              height: gridSize.height,
              child: IgnorePointer(
                child: Container(
                  color: AppColors.primary.withValues(alpha: 0.55),
                ),
              ),
            ),
        Positioned(
          left: (d.vertical ? midX + 10 : midX - 20).clamp(
            0.0,
            (gridSize.width - 90).clamp(0.0, double.infinity),
          ),
          top: (d.vertical ? midY - 34 : midY + 10).clamp(
            0.0,
            (gridSize.height - 30).clamp(0.0, double.infinity),
          ),
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.fixedBlack.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _snapLabel == null
                      ? AppColors.fixedWhite24
                      : AppColors.primary,
                ),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  color: AppColors.fixedWhite,
                  fontSize: 11,
                  fontFeatures: [],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Split arrow button ─────────────────────────────────────────────────────────

/// Small circular button shown at a tile's edge in edit mode.
/// Lives inside the tile's own Stack so it doesn't conflict with the divider
/// MouseRegion above it. A tap opens the directional tile picker; a drag on
/// the same area still starts the tile-drag gesture from the outer detector.
class _SplitArrowButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _SplitArrowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.card.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        elevation: 2,
        shadowColor: AppColors.fixedBlack.withValues(alpha: 0.25),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          mouseCursor: SystemMouseCursors.click,
          child: SizedBox(
            width: 26,
            height: 26,
            child: Icon(icon, size: 14, color: AppColors.foreground),
          ),
        ),
      ),
    );
  }
}

// ── Merge chip button ──────────────────────────────────────────────────────────

/// Tiny × badge centred on a divider. Tapping it shows the keep-A / keep-B
/// menu (handled by the parent state so it has access to `ref` and `mounted`).
class _MergeChipButton extends StatelessWidget {
  final void Function(TapDownDetails) onTapDown;

  const _MergeChipButton({required this.onTapDown});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: onTapDown,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.strongBorder),
            boxShadow: [
              BoxShadow(
                color: AppColors.fixedBlack.withValues(alpha: 0.12),
                blurRadius: 4,
              ),
            ],
          ),
          child: Center(
            child: Icon(
              Icons.close,
              size: 10,
              color: AppColors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Drag badge ─────────────────────────────────────────────────────────────────

class _DragBadge extends StatelessWidget {
  /// When true the drag will restructure rather than swap — use a different icon.
  final bool directional;

  const _DragBadge({this.directional = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: AppColors.fixedBlack.withValues(alpha: 0.2),
            blurRadius: 6,
          ),
        ],
      ),
      child: Icon(
        directional ? Icons.open_with : Icons.swap_horiz,
        size: 14,
        color: AppColors.primaryForeground,
      ),
    );
  }
}

// ── Edit-mode header actions ───────────────────────────────────────────────────

/// Header actions in edit mode: Change type + Remove.
/// "Split" is replaced by the directional split arrows on tile hover.
/// Narrow tiles collapse both into a `…` menu.
class _EditHeaderActions extends ConsumerWidget {
  final String tileId;
  final double tileWidth;
  final bool swapTarget;

  const _EditHeaderActions({
    required this.tileId,
    required this.tileWidth,
    required this.swapTarget,
  });

  static const double _collapseBelow = 320;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(workspaceProvider.notifier);
    void change() => showTilePicker(context, ref, changeTileId: tileId);
    void remove() => notifier.removeTile(tileId);

    if (swapTarget || tileWidth < _collapseBelow) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (swapTarget)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(Icons.swap_horiz, size: 16, color: AppColors.primary),
            ),
          PopupMenuButton<String>(
            tooltip: 'Tile actions',
            icon: Icon(
              Icons.more_horiz,
              size: 16,
              color: AppColors.mutedForeground,
            ),
            padding: EdgeInsets.zero,
            onSelected: (value) {
              switch (value) {
                case 'change':
                  change();
                case 'remove':
                  remove();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'change',
                child: Row(
                  children: [
                    Icon(Icons.swap_horiz, size: 16),
                    SizedBox(width: 8),
                    Text('Change type…'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'remove',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 16),
                    SizedBox(width: 8),
                    Text('Remove'),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderIconButton(
          icon: Icons.swap_horiz,
          tooltip: 'Change tile type',
          onTap: change,
        ),
        const SizedBox(width: 4),
        _HeaderIconButton(
          icon: Icons.delete_outline,
          tooltip: 'Remove this tile',
          danger: true,
          onTap: remove,
        ),
      ],
    );
  }
}

// ── Compact icon button ────────────────────────────────────────────────────────

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool danger;
  final VoidCallback onTap;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    this.danger = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.destructive : AppColors.mutedForeground;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: AppColors.fixedTransparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: onTap,
            mouseCursor: SystemMouseCursors.click,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(icon, size: 13, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Empty workspace ────────────────────────────────────────────────────────────

class _EmptyWorkspace extends StatelessWidget {
  final VoidCallback onAddTile;

  const _EmptyWorkspace({required this.onAddTile});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dashboard_customize_outlined,
            size: 40,
            color: AppColors.strongBorder,
          ),
          const SizedBox(height: 12),
          Text(
            'This workspace is empty',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Tiles show live telemetry, charts and 3D views.',
            style: TextStyle(color: AppColors.mutedForeground),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onAddTile,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add tile'),
          ),
        ],
      ),
    );
  }
}
