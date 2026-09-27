import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/app_colors.dart';
import '../../session/feedback.dart';
import '../../state/workspace_controller.dart';
import './tile_picker_dialog.dart';
export './tile_picker_dialog.dart';
import './workspace_grid.dart';
import '../../state/workspace_models.dart';

/// The main screen: workspace tab strip + the interactive tile grid.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  bool _editMode = false;

  @override
  Widget build(BuildContext context) {
    final wsState = ref.watch(workspaceProvider);
    final workspaces = wsState.value?.workspaces ?? const <Workspace>[];
    final activeId = wsState.value?.activeId ?? '';

    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < workspaces.length && i < 9; i++)
          SingleActivator(LogicalKeyboardKey(0x31 + i), control: true): () {
            ref.read(workspaceProvider.notifier).setActive(workspaces[i].id);
          },
      },
      child: FocusScope(
        autofocus: true,
        child: Column(
          children: [
            _buildTabStrip(context, workspaces, activeId),
            Expanded(child: WorkspaceGrid(editMode: _editMode)),
          ],
        ),
      ),
    );
  }

  // ── Tab strip ───────────────────────────────────────────────────────────────

  Widget _buildTabStrip(
    BuildContext context,
    List<Workspace> workspaces,
    String activeId,
  ) {
    return Container(
      height: AppDimens.workspaceTabsHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.outerPadding),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < workspaces.length; i++)
                    _buildTab(
                      context,
                      workspaces[i],
                      workspaces[i].id == activeId,
                      i,
                      workspaces.length,
                    ),
                  _StripButton(
                    icon: Icons.add,
                    tooltip: 'New workspace',
                    onTap: () => _createWorkspaceDialog(context),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _StripToggle(
            icon: _editMode ? Icons.check : Icons.edit_outlined,
            label: _editMode ? 'Done' : 'Edit layout',
            active: _editMode,
            onTap: () => setState(() => _editMode = !_editMode),
          ),
          // Layout tools only make sense while editing; keep the strip clean
          // during a live session.
          if (_editMode) ...[
            const SizedBox(width: 6),
            _StripToggle(
              icon: Icons.dashboard_customize_outlined,
              label: 'Add tile',
              active: false,
              onTap: () => showTilePicker(context, ref),
            ),
            const SizedBox(width: 6),
            _StripToggle(
              icon: Icons.restart_alt,
              label: 'Reset',
              active: false,
              onTap: () => _confirmReset(context),
            ),
            if (kDebugMode) ...[
              const SizedBox(width: 6),
              _StripToggle(
                icon: Icons.save_as_outlined,
                label: 'Make default',
                active: false,
                onTap: () => _confirmPromoteToDefaults(context),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildTab(
    BuildContext context,
    Workspace ws,
    bool active,
    int index,
    int total,
  ) {
    final canDelete =
        (ref.read(workspaceProvider).value?.workspaces.length ?? 1) > 1;

    // Full strip height so the active underline sits flush on the strip's
    // bottom hairline and every tab aligns identically.
    Widget tabContent({bool dragging = false}) => Container(
          height: double.infinity,
          margin: const EdgeInsets.only(right: 4),
          decoration: active
              ? BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: AppColors.pink, width: 2.5),
                  ),
                )
              : null,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(
              message: index < 9
                  ? '${ws.name} (Ctrl+${index + 1}, drag to reorder, right-click for options)'
                  : '${ws.name} (drag to reorder, right-click for options)',
              child: InkWell(
                // Renaming lives in the right-click menu only — double-click is
                // reserved for canvas interactions, not the tab strip.
                onTap: () =>
                    ref.read(workspaceProvider.notifier).setActive(ws.id),
                mouseCursor: SystemMouseCursors.click,
                onSecondaryTapUp: (details) => _workspaceContextMenu(
                    context, ws, index, total, details.globalPosition),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(
                        opacity: dragging ? 0.4 : 1.0,
                        child: Text(
                          ws.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w500,
                            color: active
                                ? AppColors.foreground
                                : AppColors.mutedForeground,
                          ),
                        ),
                      ),
                      if (_editMode && canDelete) ...[
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: () => ref
                              .read(workspaceProvider.notifier)
                              .deleteWorkspace(ws.id),
                          mouseCursor: SystemMouseCursors.click,
                          child: Icon(
                            Icons.close,
                            size: 13,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

    // Drag-to-reorder: dropping a tab onto another moves it to that slot.
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != ws.id,
      onAcceptWithDetails: (details) => ref
          .read(workspaceProvider.notifier)
          .moveWorkspace(details.data, index),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return Container(
          decoration: hovering
              ? BoxDecoration(
                  border: Border.all(color: AppColors.pink, width: 1.5),
                  borderRadius: BorderRadius.circular(6),
                )
              : null,
          child: Draggable<String>(
            data: ws.id,
            feedback: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.pink, width: 1.5),
                ),
                child: Text(
                  ws.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
              ),
            ),
            childWhenDragging: tabContent(dragging: true),
            child: tabContent(),
          ),
        );
      },
    );
  }

  void _workspaceContextMenu(
    BuildContext context,
    Workspace ws,
    int index,
    int total,
    Offset position,
  ) {
    final notifier = ref.read(workspaceProvider.notifier);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'move-left',
          enabled: index > 0,
          child: const _MenuRow(
              icon: Icons.arrow_back, label: 'Move left'),
        ),
        PopupMenuItem(
          value: 'move-right',
          enabled: index < total - 1,
          child: const _MenuRow(
              icon: Icons.arrow_forward, label: 'Move right'),
        ),
        PopupMenuItem(
          value: 'rename',
          child: const _MenuRow(icon: Icons.edit, label: 'Rename'),
        ),
        PopupMenuItem(
          value: 'duplicate',
          child: const _MenuRow(icon: Icons.copy, label: 'Duplicate'),
        ),
        if ((ref.read(workspaceProvider).value?.workspaces.length ?? 0) > 1)
          PopupMenuItem(
            value: 'delete',
            child: _MenuRow(
              icon: Icons.delete_outline,
              label: 'Delete',
              danger: true,
            ),
          ),
      ],
    ).then((value) {
      if (!mounted) return;
      switch (value) {
        case 'move-left':
          notifier.moveWorkspace(ws.id, index - 1);
        case 'move-right':
          notifier.moveWorkspace(ws.id, index + 1);
        case 'rename':
          _renameWorkspaceDialog(this.context, ws);
        case 'duplicate':
          notifier.duplicateWorkspace(ws.id);
        case 'delete':
          notifier.deleteWorkspace(ws.id);
      }
    });
  }

  // ── Dialogs ─────────────────────────────────────────────────────────────────

  Future<void> _createWorkspaceDialog(BuildContext context) {
    final workspaces =
        ref.read(workspaceProvider).value?.workspaces ?? const <Workspace>[];
    return _nameDialog(
      context,
      'New workspace',
      _nextNewLayoutName(workspaces),
      (name) => ref.read(workspaceProvider.notifier).createWorkspace(name),
    );
  }

  /// Next free "New workspace N" name (1, 2, 3, …).
  static String _nextNewLayoutName(List<Workspace> existing) {
    var n = 1;
    while (existing.any((w) => w.name == 'New workspace $n')) {
      n++;
    }
    return 'New workspace $n';
  }

  Future<void> _renameWorkspaceDialog(BuildContext context, Workspace ws) =>
      _nameDialog(
        context,
        'Rename workspace',
        ws.name,
        (name) =>
            ref.read(workspaceProvider.notifier).renameWorkspace(ws.id, name),
      );

  Future<void> _nameDialog(
    BuildContext context,
    String title,
    String initial,
    ValueChanged<String> onDone,
  ) {
    final controller = TextEditingController(text: initial);
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) onDone(value.trim());
            Navigator.of(dialogContext).pop();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                onDone(controller.text.trim());
              }
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) {
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset all layouts?'),
        content: const Text(
          'This restores the factory workspaces and discards every custom '
          'arrangement. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.destructive,
            ),
            onPressed: () {
              ref.read(workspaceProvider.notifier).resetToDefaults();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmPromoteToDefaults(BuildContext context) {
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Make current workspaces the app default?'),
        content: const Text(
          'Developer tool: This takes all current workspaces and writes them '
          'into lib/state/default_layouts.dart as the new factory default configuration.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.pink,
            ),
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final err = await ref
                  .read(workspaceProvider.notifier)
                  .promoteToDefaults();
              if (!context.mounted) return;
              if (err == null) {
                ref.successToast(
                    'Current workspaces saved to default_layouts.dart!');
              } else {
                ref.warningToast('Warning: $err');
              }
            },
            child: const Text('Make default'),
          ),
        ],
      ),
    );
  }
}

// ── Small strip building blocks ───────────────────────────────────────────────

class _StripButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _StripButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 16, color: AppColors.mutedForeground),
          ),
        ),
      ),
    );
  }
}

class _StripToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _StripToggle({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Material(
        color: active ? AppColors.pink : AppColors.card,
        shape: StadiumBorder(
          side: BorderSide(color: active ? AppColors.pink : AppColors.border),
        ),
        child: InkWell(
          onTap: onTap,
          mouseCursor:
              enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: active
                      ? AppColors.primaryForeground
                      : AppColors.foreground,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active
                        ? AppColors.primaryForeground
                        : AppColors.foreground,
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

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool danger;

  const _MenuRow({
    required this.icon,
    required this.label,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: danger ? AppColors.destructive : AppColors.mutedForeground,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: danger ? AppColors.destructive : AppColors.foreground,
          ),
        ),
      ],
    );
  }
}
