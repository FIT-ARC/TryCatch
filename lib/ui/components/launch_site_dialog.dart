import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/launch_site_store.dart';
import '../../theme/app_colors.dart';
import '../tiles/shared/map_tiles.dart';

/// Opens the add-site dialog: manual name + coordinates.
Future<void> showAddSiteDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Add site', style: TextStyle(fontSize: 16)),
      content: _SiteFormBody(key: _formSaveRef),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _formSaveRef.currentState?.save(),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Opens the import-site dialog: paste a share string, save it.
Future<void> showImportSiteDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Import site', style: TextStyle(fontSize: 16)),
      content: _SiteFormBody(key: _formSaveRef, importMode: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _formSaveRef.currentState?.save(),
          child: const Text('Import'),
        ),
      ],
    ),
  );
}

/// Opens the edit-site dialog: manual fields prefilled.
Future<void> showEditSiteDialog(BuildContext context, LaunchSite edit) {
  return showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Edit site', style: TextStyle(fontSize: 16)),
      content: _SiteFormBody(edit: edit),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _formSaveRef.currentState?.save(),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

final _formSaveRef = GlobalKey<_SiteFormBodyState>();

class _SiteFormBody extends ConsumerStatefulWidget {
  final LaunchSite? edit;

  /// Import mode: paste field only, no manual entry.
  final bool importMode;

  const _SiteFormBody({super.key, this.edit, this.importMode = false});

  @override
  ConsumerState<_SiteFormBody> createState() => _SiteFormBodyState();
}

class _SiteFormBodyState extends ConsumerState<_SiteFormBody> {
  final _name = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final _alt = TextEditingController();
  final _share = TextEditingController();
  String? _error;

  /// Original preset name when editing (`null` when adding a new site).
  String? _editOriginal;

  @override
  void initState() {
    super.initState();
    final edit = widget.edit;
    if (edit != null) {
      _editOriginal = edit.name;
      _fill(edit);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lon.dispose();
    _alt.dispose();
    _share.dispose();
    super.dispose();
  }

  void _fill(LaunchSite site) {
    _name.text = site.name;
    _lat.text = site.latitude.toStringAsFixed(6);
    _lon.text = site.longitude.toStringAsFixed(6);
    _alt.text = site.altitudeMsl.toStringAsFixed(1);
  }

  double? _num(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  LaunchSite? _parseManual() {
    final name = _name.text.trim();
    final lat = _num(_lat);
    final lon = _num(_lon);
    final alt = _num(_alt) ?? 0;
    if (name.isEmpty) {
      setState(() => _error = 'Give the site a name.');
      return null;
    }
    if (lat == null || lat < -90 || lat > 90) {
      setState(() => _error = 'Latitude must be between -90 and 90.');
      return null;
    }
    if (lon == null || lon < -180 || lon > 180) {
      setState(() => _error = 'Longitude must be between -180 and 180.');
      return null;
    }
    setState(() => _error = null);
    return LaunchSite(
      name: name,
      latitude: lat,
      longitude: lon,
      altitudeMsl: alt,
    );
  }

  /// Validates + saves, closing the dialog on success. Import mode saves
  /// the pasted string; manual mode saves the fields (a rename deletes the
  /// original preset first — presets are keyed by name).
  Future<void> save() async {
    if (widget.importMode) {
      final site = LaunchSite.parseShareString(_share.text);
      if (site == null) {
        setState(() => _error = 'Not a site — paste a copied site string.');
        return;
      }
      await ref.read(launchSiteProvider.notifier).savePreset(site);
      unawaited(precacheLaunchSites([site]));
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }
    final site = _parseManual();
    if (site == null) return;
    final repo = ref.read(launchSiteProvider.notifier);
    final original = _editOriginal;
    if (original != null && original != site.name) {
      await repo.deletePreset(original);
    }
    await repo.savePreset(site);
    // Warm the tile cache around the site so the field map works offline.
    unawaited(precacheLaunchSites([site]));
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: widget.importMode ? _importView() : _manualView(),
      ),
    );
  }

  /// Manual name + coordinates.
  Widget _manualView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _lat,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Latitude (°)'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _lon,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Longitude (°)'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _alt,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Alt MSL (m)'),
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: AppColors.destructive, fontSize: 12),
          ),
        ],
      ],
    );
  }

  /// Paste-a-share-string only.
  Widget _importView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Paste a copied site string to save it as a preset.',
          style:
              TextStyle(fontSize: 12.5, color: AppColors.mutedForeground),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _share,
          decoration: const InputDecoration(
            labelText: 'LAUNCHSITE1.…',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          style: AppText.mono.copyWith(fontSize: 11.5),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: AppColors.destructive, fontSize: 12),
          ),
        ],
      ],
    );
  }
}
