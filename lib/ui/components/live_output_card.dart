import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/live_bridge/bridge_config.dart';
import '../../state/bridge_provider.dart';
import '../../theme/app_colors.dart';
import './app_card.dart';

/// Settings controls for the read-only live telemetry bridge.
///
/// Serves the last known live packet (`GET /latest`, `GET /events`) from a
/// dedicated isolate for a public display. The app binds localhost and the
/// public site sits behind a reverse proxy — the app itself never faces the
/// internet, and there is no inbound command path.
///
/// The status light beside the top-bar quick nav mirrors this state; the
/// Configure dialog lives in [LiveSharingSettingsDialog], so embedding this
/// never disturbs dialog finders elsewhere on the page. [LiveOutputCard]
/// wraps this in the standard card for standalone use.
class LiveSharingControls extends ConsumerWidget {
  const LiveSharingControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(bridgeConfigProvider);
    final config = configAsync.value ?? const BridgeConfig();
    final status = ref.watch(bridgeStatusProvider);

    final String statusText;
    final Color statusColor;
    final clients = status.clients == 1
        ? '1 client'
        : '${status.clients} clients';
    if (status.error != null) {
      statusText = 'Error — ${status.error}';
      statusColor = AppColors.destructive;
    } else if (status.running) {
      if (status.hasFrame) {
        statusText = 'Live · $clients';
        statusColor = AppColors.success;
      } else {
        statusText = 'Running · $clients — waiting for live data';
        statusColor = AppColors.mutedForeground;
      }
    } else if (config.enabled) {
      statusText = 'Starting…';
      statusColor = AppColors.mutedForeground;
    } else {
      statusText = 'Off';
      statusColor = AppColors.mutedForeground;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Serve live data'),
            subtitle: Text(
              'Latest packet only — replays and old flights never publish.',
              style: TextStyle(
                  fontSize: 12.5, color: AppColors.mutedForeground),
            ),
            value: config.enabled,
            onChanged: (v) =>
                ref.read(bridgeConfigProvider.notifier).setEnabled(v),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                statusText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.mono.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (status.error != null) ...[
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () =>
                    ref.read(bridgeConfigProvider.notifier).touch(),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Card wrapper around [LiveSharingControls] for standalone use.
class LiveOutputCard extends ConsumerWidget {
  const LiveOutputCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCard(
      title: 'LIVE SHARING',
      trailing: OutlinedButton(
        onPressed: () => showDialog(
          context: context,
          builder: (_) => const LiveSharingSettingsDialog(),
        ),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        child: const Text('Configure'),
      ),
      child: const LiveSharingControls(),
    );
  }
}

/// Configure dialog: port, bind address and CORS origin.
///
/// One `AlertDialog` shape (title, body, Cancel + Save). Invalid values
/// stay in the dialog as an inline error; nothing is written until Save.
class LiveSharingSettingsDialog extends ConsumerStatefulWidget {
  const LiveSharingSettingsDialog({super.key});

  @override
  ConsumerState<LiveSharingSettingsDialog> createState() =>
      _LiveSharingSettingsDialogState();
}

class _LiveSharingSettingsDialogState
    extends ConsumerState<LiveSharingSettingsDialog> {
  late final TextEditingController _port;
  late final TextEditingController _bind;
  late final TextEditingController _cors;
  String? _error;

  @override
  void initState() {
    super.initState();
    final config =
        ref.read(bridgeConfigProvider).value ?? const BridgeConfig();
    _port = TextEditingController(text: '${config.port}');
    _bind = TextEditingController(text: config.bindAddress);
    _cors = TextEditingController(text: config.corsOrigin);
  }

  @override
  void dispose() {
    _port.dispose();
    _bind.dispose();
    _cors.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || !BridgeConfig.isValidPort(port)) {
      setState(() => _error = 'Port must be a number from 1 to 65535.');
      return;
    }
    final bind = _bind.text.trim();
    if (!BridgeConfig.isValidBindAddress(bind)) {
      setState(() => _error = 'Bind address must not be empty.');
      return;
    }
    final cors = _cors.text.trim();
    if (cors.isEmpty) {
      setState(() => _error = 'Origin must not be empty — use * for any site.');
      return;
    }
    final store = ref.read(bridgeConfigProvider.notifier);
    if (!await store.setPort(port)) {
      setState(() => _error = 'Port must be a number from 1 to 65535.');
      return;
    }
    await store.setBindAddress(bind);
    await store.setCorsOrigin(cors);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Live sharing settings'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _bind,
              decoration:
                  const InputDecoration(labelText: 'Bind address'),
              style: AppText.mono.copyWith(fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _cors,
              decoration: const InputDecoration(
                labelText: 'Allowed origin (CORS)',
              ),
              style: AppText.mono.copyWith(fontSize: 12),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: AppColors.destructive, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Bind localhost and put a reverse proxy in front; '
              'the proxy needs buffering off for the event stream.',
              style: TextStyle(
                  fontSize: 12, color: AppColors.mutedForeground),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
