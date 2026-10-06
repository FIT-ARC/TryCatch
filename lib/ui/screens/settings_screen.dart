import '../../state/connector_provider.dart';
import '../../state/theme_mode_provider.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../theme/app_colors.dart';
import '../../session/feedback.dart';
import '../../session/flight_reset.dart';
import '../components/copy_button.dart';
import '../components/live_output_card.dart';
import '../components/launch_site_dialog.dart';
import '../components/option_row.dart';
import '../tiles/shared/map_tiles.dart';
import '../../core/format.dart';
import '../../state/launch_site_store.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';

/// Settings screen, VSCode style: one scrolling page with a session banner
/// on top, an about hero card, then one flat section per group in task order.
///
/// Sections carry their own header and are split by hairlines instead of
/// cards, so the page reads as a single flow: flight memory, about, launch
/// site, connector, offline maps, live sharing, display. Only the banner is
/// a session action; everything below it is persisted (sites, connector,
/// bridge config, theme) or the on-disk tile cache.
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

  /// Clears the flight buffers via FlightReset: telemetry, commands,
  /// channel history. Disabled with no data or mid-replay by the caller.
  Future<void> _confirmClearFlight(BuildContext context) {
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear packet buffer?'),
        content: const Text(
          'Clears the in-memory buffer of packets, maxima, trends. Does not affect recordings.',
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
              // Drop focus first: yanking a focused subtree out from under
              // the engine while every tile flips to "waiting" at once.
              FocusManager.instance.primaryFocus?.unfocus();
              FlightReset.clearFlight(ref);
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
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
      .map(
        (p) =>
            '${p.name}|${p.latitude.toStringAsFixed(5)}|${p.longitude.toStringAsFixed(5)}',
      )
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
  /// the section always reflects the current cache state).
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

    final replaying = ref.watch(replayProvider.select((s) => s.isActive));
    // Clearing mid-replay would corrupt the replay state.
    final hasData = ref.watch(
      telemetryStoreProvider.select((s) => s.packetCount > 0),
    );
    final canClear = hasData && !replaying;

    // The scrollbar sits at the screen edge; the column + side padding
    // live inside it.
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.pagePadding),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.pagePadding,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. Session banner: the only non-setting on the screen,
                // visually distinct from the persisted sections below.
                _ClearStrip(
                  canClear: canClear,
                  onClear: () => _confirmClearFlight(context),
                ),
                const SizedBox(height: 48),
                // 2. About hero as a card so it reads apart from the
                // session banner above and the flat sections below.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '{TryCatch}',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Ground station for model rocket telemetry, control and post flight analysis.',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const _SectionDivider(),
                _launchSiteSection(siteState),
                const _SectionDivider(),
                _connectorSection(),
                const _SectionDivider(),
                _offlineMapsSection(siteState),
                const _SectionDivider(),
                _liveSharingSection(),
                const _SectionDivider(),
                _displaySection(),
                // Bottom breathing room so the last section clears the
                // window edge.
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _launchSiteSection(LaunchSiteState siteState) {
    final serialStatus = ref.watch(serialStatusProvider).value;
    final recording = serialStatus?.isRecording ?? false;
    final site = siteState.selected;
    return _Section(
      title: 'LAUNCH SITE',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Locked while recording: the file stamps this site.
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
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final preset in siteState.presets) ...[
                      OptionRow(
                        selected: preset.name == site?.name,
                        onTap: recording
                            ? null
                            : () => _selectSite(preset.name),
                        radioValue: preset.name,
                        title: isMockLaunchSite(preset)
                            ? '${preset.name} · debug, not saved'
                            : preset.name,
                        subtitle:
                            '${formatLatLon(preset.latitude, preset.longitude)} · ${preset.altitudeMsl.toStringAsFixed(0)} m MSL',
                        subtitleStyle: AppText.mono.copyWith(
                          fontSize: 11,
                          color: AppColors.mutedForeground,
                        ),
                        showCheck: false,
                        actions: [
                          CopyButton(
                            text: preset.toShareString(),
                            iconOnly: true,
                          ),
                          if (!isMockLaunchSite(preset)) ...[
                            _RowAction(
                              tooltip: 'Edit site',
                              icon: Icons.edit_outlined,
                              onTap: recording
                                  ? null
                                  : () => showEditSiteDialog(context, preset),
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
                        style: _Type.secondary,
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Site actions sit with the list they act on, not up in the
          // header, so it is clear what they belong to.
          if (recording) ...[
            Text('Cannot be changed while recording.', style: _Type.secondary),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: recording ? null : () => showAddSiteDialog(context),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
              ),
              TextButton.icon(
                onPressed: recording
                    ? null
                    : () => showImportSiteDialog(context),
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Import'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _connectorSection() {
    final connectorId =
        ref.watch(activeConnectorIdProvider).value ?? defaultVisibleConnectorId;
    final replaying = ref.watch(replayProvider.select((s) => s.isActive));
    final serialStatus = ref.watch(serialStatusProvider).value;
    final connected = serialStatus?.isConnected ?? false;
    final recording = serialStatus?.isRecording ?? false;
    // Locked while replaying, recording, or connected: switching
    // mid-stream wipes the live flight, and mid-recording it mixes
    // framings under one header stamp. Disconnect (or close the replay)
    // to switch.
    final locked = replaying || connected || recording;
    return _Section(
      title: 'CONNECTOR',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The picker: compact bordered rows, selected row carries
          // the accent border + tint.
          AbsorbPointer(
            absorbing: locked,
            child: Opacity(
              opacity: locked ? 0.45 : 1.0,
              child: RadioGroup<String>(
                groupValue: connectorId,
                onChanged: (id) {
                  if (!locked && id != null) {
                    ref.read(serialConfigProvider.notifier).setConnector(id);
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
          // Lock reason only while locked; unlocked needs no explainer.
          if (locked) ...[
            Text(
              recording
                  ? 'Cannot be changed while recording.'
                  : 'Cannot be changed while connected to a port.',
              style: _Type.secondary,
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _offlineMapsSection(LaunchSiteState siteState) {
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
    final double overallFraction = total <= 0
        ? 0
        : (cached / total).clamp(0.0, 1.0);
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
          : (overallFraction <= 0
                ? AppColors.mutedForeground
                : AppColors.warning);
    } else if (checking) {
      statusText = 'Checking…';
      statusColor = AppColors.mutedForeground;
      barValue = null;
      barColor = AppColors.mutedForeground;
    } else if (total <= 0 || cached <= 0) {
      statusText = 'Nothing cached yet';
      statusColor = AppColors.mutedForeground;
      barValue = 0;
      barColor = AppColors.mutedForeground;
    } else if (cached >= total) {
      statusText = '100% cached offline';
      statusColor = AppColors.success;
      barValue = 1;
      barColor = AppColors.success;
    } else {
      statusText = 'Partly cached offline';
      statusColor = AppColors.warning;
      barValue = overallFraction;
      barColor = AppColors.warning;
    }
    final statusStyle = _Type.status(statusColor);
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

    return _Section(
      title: 'OFFLINE MAPS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Which sites + how ready each one is. Rows are built from
          // presets (known immediately) so they exist from the first
          // frame and only the trailing label changes.
          if (hasSites)
            for (final site in siteState.presets)
              Builder(
                builder: (context) {
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
                    final pct = ((cov.cached / cov.total) * 100).round();
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
                            style: _Type.itemTitle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(label, style: _Type.status(labelColor)),
                      ],
                    ),
                  );
                },
              )
          else
            Text('Add a launch site to get started.', style: _Type.secondary),
          const SizedBox(height: 8),
          // Overall state: one line + one bar for every state. Only
          // text, value and colour change, so nothing shifts.
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
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
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
                label: Text(
                  _downloading ? 'Downloading…' : 'Download offline maps',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _liveSharingSection() {
    return const _Section(title: 'LIVE SHARING', child: LiveSharingControls());
  }

  Widget _displaySection() {
    return _Section(
      title: 'DISPLAY',
      child: ValueListenableBuilder<bool>(
        valueListenable: AppThemeMode.instance,
        builder: (_, isDark, _) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Dark mode', style: _Type.itemTitle),
          value: isDark,
          onChanged: (v) => ref.read(themeModeProvider.notifier).setDark(v),
        ),
      ),
    );
  }
}

/// Shared type voices for the settings page: one item title, one
/// secondary line, one mono status readout. Every section uses these so
/// the page reads as one surface instead of a mix of sizes.
abstract final class _Type {
  static const itemTitle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);

  static TextStyle get secondary =>
      TextStyle(fontSize: 12.5, color: AppColors.mutedForeground);

  static TextStyle status(Color color) => AppText.mono.copyWith(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: color,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// One flat settings group: title, then content. Hairlines between
/// groups come from [_SectionDivider]. Actions live inside the content
/// they act on, never in the header.
class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.microLabel.copyWith(letterSpacing: 1.1),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Hairline splitting one flat section from the next.
class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(height: 1, thickness: 1, color: AppColors.border);
  }
}

/// Session-only banner: destructive hairline, never a card, so the one
/// action on the screen cannot be mistaken for a persisted setting.
class _ClearStrip extends StatelessWidget {
  final bool canClear;
  final VoidCallback onClear;

  const _ClearStrip({required this.canClear, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.dangerSoft.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        border: Border.all(
          color: AppColors.destructive.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.delete_outline, size: 18, color: AppColors.destructive),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Packet buffer', style: _Type.itemTitle),
                Text(
                  'Clears the in-memory buffer of packets, maxima, trends. Does not affect recordings.',
                  style: _Type.secondary,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: canClear ? onClear : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.destructive,
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
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
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 17),
      color: AppColors.mutedForeground,
      style: IconButton.styleFrom(
        minimumSize: const Size(28, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );
  }
}
