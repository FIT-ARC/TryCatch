import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/launch_site_store.dart';
import '../../theme/app_colors.dart';
import '../tiles/shared/map_tiles.dart';

/// Opens the add/edit site dialog.
///
/// Add mode ([edit] null) starts blank; edit mode prefills the preset.
/// Selection lives in Settings — this dialog never selects. Values are
/// entered manually or pasted from a share string.
Future<void> showLaunchSiteDialog(BuildContext context,
    {LaunchSite? edit}) {
  return showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(edit == null ? 'Add site' : 'Edit site',
          style: const TextStyle(fontSize: 16)),
      content: _LaunchSiteDialogBody(edit: edit),
      actions: const [_CloseButton()],
    ),
  );
}

class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => Navigator.of(context).pop(),
      child: const Text('Close'),
    );
  }
}

class _LaunchSiteDialogBody extends ConsumerStatefulWidget {
  final LaunchSite? edit;

  const _LaunchSiteDialogBody({this.edit});

  @override
  ConsumerState<_LaunchSiteDialogBody> createState() =>
      _LaunchSiteDialogBodyState();
}

class _LaunchSiteDialogBodyState extends ConsumerState<_LaunchSiteDialogBody> {
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

  /// Saves the form. A rename deletes the original preset first
  /// (presets are keyed by name); the saved site ends up selected.
  Future<void> _saveForm() async {
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

  /// Fills the manual fields from a pasted share string.
  void _fillFromShare() {
    final site = LaunchSite.parseShareString(_share.text);
    if (site == null) {
      setState(() => _error = 'Not a site — paste a copied site string.');
      return;
    }
    setState(() {
      _error = null;
      _editOriginal = null;
      _fill(site);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
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
            const SizedBox(height: 12),
            Text(
              'OR PASTE A SHARE STRING',
              style: AppText.microLabel.copyWith(letterSpacing: 1.1),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _share,
                    decoration: const InputDecoration(
                      labelText: 'LAUNCHSITE1.…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: AppText.mono.copyWith(fontSize: 11.5),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _fillFromShare,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Fill'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style:
                    TextStyle(color: AppColors.destructive, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _saveForm,
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text('Save'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
