import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../theme/app_colors.dart';
import '../../session/feedback.dart';
import '../components/app_card.dart';
import '../components/copy_button.dart';
import '../components/launch_site_dialog.dart';
import '../components/option_row.dart';
import '../tiles/shared/map_tiles.dart';
import '../../core/format.dart';
import '../../state/launch_site_store.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';

/// Settings screen: connector, offline maps, appearance and about.
/// Launch sites live in the top-bar site dialog.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _loadingCoverage = false;
  bool _downloading = false;
  int _done = 0;
  int _total = 0;
  String? _notice;
  Timer? _noticeTimer;
  List<SiteCacheCoverage> _coverage = const [];
  bool _coverageReady = false;

  /// Selects a preset by name (settings rows select inline; the dialog
  /// only adds/edits).
  Future<void> _selectSite(String name) async {
    final presets =
        ref.read(launchSiteProvider).value?.presets ?? const <LaunchSite>[];
    for (final preset in presets) {
      if (preset.name != name) continue;
      await ref.read(launchSiteProvider.notifier).select(preset);
      return;
    }
  }

  /// Deletes a preset, offering undo on the toast.
  Future<void> _deleteSite(LaunchSite preset) async {
    final store = ref.read(launchSiteProvider.notifier);
    final wasSelected =
        ref.read(currentLaunchSiteProvider)?.name == preset.name;
    await store.deletePreset(preset.name);
    ref.successToast(
      'Deleted "${preset.name}".',
      actionLabel: 'Undo',
      onAction: () {
        store.savePreset(preset);
        if (wasSelected) store.select(preset);
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshIfNeeded());
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    super.dispose();
  }

  static String _presetsKey(List<LaunchSite> presets) => presets
      .map((p) =>
          '${p.name}|${p.latitude.toStringAsFixed(5)}|${p.longitude.toStringAsFixed(5)}')
      .join(';');

  void _refreshIfNeeded() {
    final asyncVal = ref.read(launchSiteProvider);
    if (!asyncVal.hasValue) return;
    final presets = asyncVal.value?.presets ?? const <LaunchSite>[];
    if (presets.isEmpty) {
      if (mounted && !_coverageReady) {
        setState(() {
          _coverage = const [];
          _coverageReady = true;
        });
      }
      return;
    }
    unawaited(_refreshCoverage(presets));
  }

  /// Reads cache coverage and keeps it visible persistently (no auto-clear:
  /// the card always reflects the current cache state).
  Future<void> _refreshCoverage(List<LaunchSite> presets) async {
    if (_loadingCoverage || _downloading) return;
    if (!mounted) return;
    setState(() => _loadingCoverage = true);
    try {
      final coverage = await tileCacheCoverage(presets);
      if (!mounted) return;
      setState(() {
        _coverage = coverage;
        _coverageReady = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _coverageReady = true);
      _flashNotice('Could not check downloads.');
    } finally {
      if (mounted) setState(() => _loadingCoverage = false);
    }
  }

  void _flashNotice(String message) {
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted) return;
      setState(() => _notice = null);
    });
  }

  Future<void> _downloadAll(List<LaunchSite> presets) async {
    if (_downloading) return;
    _noticeTimer?.cancel();
    setState(() {
      _downloading = true;
      _done = 0;
      _total = 0;
      _notice = null;
    });
    try {
      final (:fetched, :total) = await precacheLaunchSites(
        presets,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      // Success needs no extra message — the status below flips to Ready.
      // Only surface failures, inline in the status line.
      if (fetched == 0 && total == 0) {
        _flashNotice('Nothing to download.');
      }
    } catch (_) {
      if (!mounted) return;
      _flashNotice('Download stopped — check connection.');
    } finally {
      if (mounted) setState(() => _downloading = false);
      // Re-read the cache so the always-visible state reflects the download.
      if (mounted) await _refreshCoverage(presets);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(launchSiteProvider);
    final siteState = state.value ?? const LaunchSiteState();

    // Refresh the persistent cache state when the saved sites change
    // (including the first load). Listener fires outside build, so
    // setState inside [_refreshCoverage] is safe.
    ref.listen(launchSiteProvider, (prev, next) {
      final p = next.value?.presets ?? const <LaunchSite>[];
      final pp = prev?.value?.presets ?? const <LaunchSite>[];
      if (_presetsKey(p) != _presetsKey(pp)) {
        if (p.isEmpty) {
          _noticeTimer?.cancel();
          setState(() {
            _coverage = const [];
            _coverageReady = true;
            _notice = null;
          });
        } else {
          unawaited(_refreshCoverage(p));
        }
      }
    });

    var cached = 0;
    var total = 0;
    for (final c in _coverage) {
      cached += c.cached;
      total += c.total;
    }
    final busy = _downloading || _loadingCoverage;
    final hasSites = siteState.presets.isNotEmpty;
    final checking = _loadingCoverage || !_coverageReady;

    // One status line + one bar for every state. Only the text, fraction
    // and colours change — the widgets stay put, so no layout shift.
    final double overallFraction =
        total <= 0 ? 0 : (cached / total).clamp(0.0, 1.0);
    final String statusText;
    final Color statusColor;
    final double? barValue;
    final Color barColor;
    if (!hasSites) {
      statusText = 'No launch sites yet';
      statusColor = AppColors.mutedForeground;
      barValue = 0;
      barColor = AppColors.mutedForeground;
    } else if (_downloading) {
      final f = _total > 0 ? (_done / _total).clamp(0.0, 1.0) : null;
      statusText = f == null
          ? 'Starting download…'
          : 'Downloading… ${(f * 100).round()}%';
      statusColor = AppColors.mutedForeground;
      barValue = f;
      barColor = AppColors.info;
    } else if (_notice != null) {
      statusText = _notice!;
      statusColor = AppColors.destructive;
      barValue = overallFraction;
      barColor = overallFraction >= 1
          ? AppColors.success
          : (overallFraction <= 0 ? AppColors.mutedForeground : AppColors.warning);
    } else if (checking) {
      statusText = 'Checking…';
      statusColor = AppColors.mutedForeground;
      barValue = null;
      barColor = AppColors.mutedForeground;
    } else if (total <= 0 || cached <= 0) {
      statusText = 'Nothing saved yet';
      statusColor = AppColors.mutedForeground;
      barValue = 0;
      barColor = AppColors.mutedForeground;
    } else if (cached >= total) {
      statusText = 'Ready for offline use';
      statusColor = AppColors.success;
      barValue = 1;
      barColor = AppColors.success;
    } else {
      statusText = 'Partly ready — still works offline';
      statusColor = AppColors.warning;
      barValue = overallFraction;
      barColor = AppColors.warning;
    }
    final statusStyle = AppText.mono.copyWith(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: statusColor,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // Rows are built from presets (known immediately) with coverage looked
    // up per site, so rows exist from the first frame and only their
    // trailing label changes — no pop-in shift while checking.
    SiteCacheCoverage? coverageFor(LaunchSite site) {
      for (final c in _coverage) {
        if (c.site.name == site.name &&
            (c.site.latitude - site.latitude).abs() < 1e-9 &&
            (c.site.longitude - site.longitude).abs() < 1e-9) {
          return c;
        }
      }
      return null;
    }

    final connectorId =
        ref.watch(activeConnectorIdProvider).value ?? defaultVisibleConnectorId;
    final replaying = ref.watch(replayProvider.select((s) => s.isActive));
    final serialStatus = ref.watch(serialStatusProvider).value;
    final connected = serialStatus?.isConnected ?? false;
    final recording = serialStatus?.isRecording ?? false;
    final site = siteState.selected;
    // Locked whenever the link is up or a replay owns the session: switching
    // mid-stream wipes the live flight, and mid-recording it mixes framings
    // under one header stamp. Disconnect (or close the replay) to switch.
    final locked = replaying || connected;

    // Scroll viewport spans the full width so the scrollbar sits at the
    // screen edge; the 640 column + side padding live inside it.
    return ListView(
      padding:
          const EdgeInsets.symmetric(vertical: AppDimens.pagePadding),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.pagePadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
            AppCard(
              title: 'LAUNCH SITE',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: recording
                        ? null
                        : () => showAddSiteDialog(context),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    icon: const Icon(Icons.add, size: 15),
                    label: const Text('Add'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: recording
                        ? null
                        : () => showImportSiteDialog(context),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    icon:
                        const Icon(Icons.download_outlined, size: 15),
                    label: const Text('Import'),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Locked while recording: the file stamps this site.
                  Text(
                    recording
                        ? 'Locked while recording — the file stamps this site.'
                        : 'Recordings stamp this site into the file header. '
                            'Recording stays disabled until one is set.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.mutedForeground),
                  ),
                  const SizedBox(height: 10),
                  AbsorbPointer(
                    absorbing: recording,
                    child: Opacity(
                      opacity: recording ? 0.45 : 1.0,
                      child: RadioGroup<String>(
                        groupValue: site?.name,
                        onChanged: (name) {
                          if (!recording && name != null) {
                            _selectSite(name);
                          }
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment:
                              CrossAxisAlignment.stretch,
                          children: [
                            for (final preset in siteState.presets) ...[
                              OptionRow(
                                selected: preset.name == site?.name,
                                onTap: recording
                                    ? null
                                    : () => _selectSite(preset.name),
                                radioValue: preset.name,
                                title: preset.name,
                                subtitle:
                                    '${formatLatLon(preset.latitude, preset.longitude)} · ${preset.altitudeMsl.toStringAsFixed(0)} m MSL',
                                subtitleStyle: AppText.mono.copyWith(
                                  fontSize: 10.5,
                                  color: AppColors.mutedForeground,
                                ),
                                showCheck: false,
                                actions: [
                                  CopyButton(
                                      text: preset.toShareString(),
                                      iconOnly: true),
                                  if (!isMockLaunchSite(preset)) ...[
                                    _RowAction(
                                      tooltip: 'Edit site',
                                      icon: Icons.edit_outlined,
                                      onTap: recording
                                          ? null
                                          : () => showEditSiteDialog(
                                              context,
                                              preset),
                                    ),
                                    _RowAction(
                                      tooltip: 'Remove site',
                                      icon: Icons.delete_outline,
                                      onTap: recording
                                          ? null
                                          : () => _deleteSite(preset),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                            ],
                            if (siteState.presets.isEmpty)
                              Text(
                                'No saved sites yet — add the first one.',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: AppColors.mutedForeground),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.gap),
            AppCard(
              title: 'CONNECTOR',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. What this is — replaced by the lock reason while
                  // locked, so the card never grows a footer line.
                  Text(
                    locked
                        ? (replaying
                            ? 'Locked while replaying — the recording picks its own connector.'
                            : 'Locked while connected — disconnect to switch.')
                        : 'How the ground station reads the rocket. States, '
                            'commands and tiles follow the selected connector.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.mutedForeground),
                  ),
                  const SizedBox(height: 10),
                  // 2. The picker: compact bordered rows, selected row carries
                  // the accent border + tint.
                  AbsorbPointer(
                    absorbing: locked,
                    child: Opacity(
                      opacity: locked ? 0.45 : 1.0,
                      child: RadioGroup<String>(
                        groupValue: connectorId,
                        onChanged: (id) {
                          if (!locked && id != null) {
                            ref
                                .read(serialConfigProvider.notifier)
                                .setConnector(id);
                          }
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final connector in visibleConnectors) ...[
                              OptionRow(
                                selected: connector.id == connectorId,
                                onTap: locked
                                    ? null
                                    : () => ref
                                        .read(serialConfigProvider.notifier)
                                        .setConnector(connector.id),
                                radioValue: connector.id,
                                title: connector.displayName,
                                subtitle: connector.description,
                              ),
                              const SizedBox(height: 6),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.gap),
            AppCard(
              title: 'OFFLINE MAPS',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. What this is.
                  Text(
                    'Save maps for your launch sites so they work '
                    'without internet in the field.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.mutedForeground),
                  ),
                  const SizedBox(height: 12),
                  // 2. Which sites + how ready each one is. Rows are built
                  // from presets (known immediately) so they exist from the
                  // first frame and only the trailing label changes.
                  if (hasSites)
                    for (final site in siteState.presets)
                      Builder(builder: (context) {
                        final cov = coverageFor(site);
                        final String label;
                        final Color dot;
                        final Color labelColor;
                        if (cov == null) {
                          label = '…';
                          dot = AppColors.faint;
                          labelColor = AppColors.mutedForeground;
                        } else if (cov.total <= 0 || cov.cached >= cov.total) {
                          label = 'Ready';
                          dot = AppColors.success;
                          labelColor = AppColors.success;
                        } else if (cov.cached <= 0) {
                          label = 'Empty';
                          dot = AppColors.faint;
                          labelColor = AppColors.mutedForeground;
                        } else {
                          final pct =
                              ((cov.cached / cov.total) * 100).round();
                          label = '$pct%';
                          dot = AppColors.warning;
                          labelColor = AppColors.warning;
                        }
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: dot,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  site.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                label,
                                style: AppText.mono.copyWith(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: labelColor,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      })
                  else
                    Text(
                      'No launch sites yet — add one with the flag '
                      'button above to get started.',
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.mutedForeground),
                    ),
                  const SizedBox(height: 8),
                  // 3. Overall state: one line + one bar for every state.
                  // Only text, value and colour change, so nothing shifts.
                  Text(
                    statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: statusStyle,
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: barValue,
                      minHeight: 5,
                      backgroundColor: AppColors.muted,
                      valueColor: AlwaysStoppedAnimation<Color>(barColor),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 4. The action.
                  FilledButton.icon(
                    onPressed: busy || !hasSites
                        ? null
                        : () => _downloadAll(siteState.presets),
                    icon: _downloading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined, size: 16),
                    label: Text(_downloading
                        ? 'Downloading…'
                        : 'Download offline maps'),
                  ),
                  const SizedBox(height: 8),
                  // 5. What to expect: static, so it never shifts layout.
                  Text(
                    'Detailed maps are not available everywhere. '
                    'Missing areas fill in automatically with less detail.',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.mutedForeground),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.gap),
            AppCard(
              title: 'APPEARANCE',
              child: ValueListenableBuilder<bool>(
                valueListenable: AppThemeMode.instance,
                builder: (_, isDark, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Own Material: a ListTile paints its splash on the
                    // nearest Material ancestor, and AppCard's decorated
                    // container would swallow it (framework assert).
                    Material(
                      color: Colors.transparent,
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Dark mode'),
                        subtitle: Text(
                          'Charts, panels and chrome follow. Map tiles stay light.',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.mutedForeground),
                        ),
                        value: isDark,
                        onChanged: (v) =>
                            AppThemeMode.instance.setDark(v),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppDimens.gap),
            AppCard(
              title: 'ABOUT',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '{TryCatch} ground station',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Testing in Production — model rocket telemetry, '
                    'replay and control.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.mutedForeground),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
      ),
      ],
    );
  }
}

/// Small icon action inside an [OptionRow]'s trailing slot.
class _RowAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  const _RowAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      mouseCursor: onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(4),
      child: Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 17),
        ),
      ),
    );
  }
}
