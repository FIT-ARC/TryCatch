import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/live_bridge/bridge_config.dart';
import '../../state/bridge_provider.dart';
import '../../theme/app_colors.dart';
import './app_card.dart';
import './settings_inputs.dart';

/// Settings controls for the read-only live telemetry bridge.
///
/// Serves the last known live packet (`GET /latest`, `GET /events`) from a
/// dedicated isolate for a public display. The app binds localhost and the
/// public site sits behind a reverse proxy — the app itself never faces the
/// internet, and there is no inbound command path.
///
/// Toggle, status and connection fields live together so nothing is hidden
/// behind a dialog. Fields lock while serving, and the toggle stays
/// disabled over invalid input, so the server can never run on a config
/// error. The status light beside the top-bar quick nav mirrors
/// this state.
class LiveSharingControls extends ConsumerStatefulWidget {
  const LiveSharingControls({super.key});

  @override
  ConsumerState<LiveSharingControls> createState() =>
      _LiveSharingControlsState();
}

class _LiveSharingControlsState extends ConsumerState<LiveSharingControls> {
  late final TextEditingController _port;
  late final TextEditingController _bind;
  late final TextEditingController _cors;
  late final FocusNode _portFocus;
  late final FocusNode _bindFocus;
  late final FocusNode _corsFocus;
  String? _error;

  @override
  void initState() {
    super.initState();
    final config = ref.read(bridgeConfigProvider).value ?? const BridgeConfig();
    _port = TextEditingController(text: '${config.port}');
    _bind = TextEditingController(text: config.bindAddress);
    _cors = TextEditingController(text: config.corsOrigin);
    _portFocus = FocusNode();
    _bindFocus = FocusNode();
    _corsFocus = FocusNode();
    // Persist on focus loss so typing then clicking elsewhere sticks
    // without an extra button.
    _portFocus.addListener(() {
      if (!_portFocus.hasFocus) _savePort();
    });
    _bindFocus.addListener(() {
      if (!_bindFocus.hasFocus) _saveBind();
    });
    _corsFocus.addListener(() {
      if (!_corsFocus.hasFocus) _saveCors();
    });
  }

  @override
  void dispose() {
    _port.dispose();
    _bind.dispose();
    _cors.dispose();
    _portFocus.dispose();
    _bindFocus.dispose();
    _corsFocus.dispose();
    super.dispose();
  }

  /// Applies an external config change to fields the user is not editing,
  /// so the initial async load (and outside edits) show up without
  /// clobbering in-progress typing.
  void _syncFrom(BridgeConfig config) {
    final portText = '${config.port}';
    if (!_portFocus.hasFocus && _port.text != portText) {
      _port.text = portText;
    }
    if (!_bindFocus.hasFocus && _bind.text != config.bindAddress) {
      _bind.text = config.bindAddress;
    }
    if (!_corsFocus.hasFocus && _cors.text != config.corsOrigin) {
      _cors.text = config.corsOrigin;
    }
  }

  Future<void> _savePort() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || !BridgeConfig.isValidPort(port)) {
      if (mounted) {
        setState(() => _error = 'Port must be a number from 1 to 65535.');
      }
      return;
    }
    if (!await ref.read(bridgeConfigProvider.notifier).setPort(port)) {
      if (mounted) {
        setState(() => _error = 'Port must be a number from 1 to 65535.');
      }
      return;
    }
    if (mounted) setState(() => _error = null);
  }

  Future<void> _saveBind() async {
    final bind = _bind.text.trim();
    if (!await ref.read(bridgeConfigProvider.notifier).setBindAddress(bind)) {
      if (mounted) setState(() => _error = 'Bind address must not be empty.');
      return;
    }
    if (mounted) setState(() => _error = null);
  }

  Future<void> _saveCors() async {
    final cors = _cors.text.trim();
    if (!await ref.read(bridgeConfigProvider.notifier).setCorsOrigin(cors)) {
      if (mounted) {
        setState(
          () => _error = 'Origin must not be empty — use * for any site.',
        );
      }
      return;
    }
    if (mounted) setState(() => _error = null);
  }

  /// First validation failure across the three fields, if any.
  /// Independent of what is persisted: the toggle stays disabled until
  /// every field parses, so the server can never be enabled on top of
  /// a config error.
  String? _validationMessage() {
    final port = int.tryParse(_port.text.trim());
    if (port == null || !BridgeConfig.isValidPort(port)) {
      return 'Port must be a number from 1 to 65535.';
    }
    if (_bind.text.trim().isEmpty) return 'Bind address must not be empty.';
    if (_cors.text.trim().isEmpty) {
      return 'Origin must not be empty — use * for any site.';
    }
    return null;
  }

  bool get _fieldsValid => _validationMessage() == null;

  /// Flips the server, flushing pending field edits first so enabling
  /// can never outrun invalid input: with a validation error the server
  /// stays off and the message explains why.
  Future<void> _setEnabled(bool enabled) async {
    if (enabled) {
      await _savePort();
      await _saveBind();
      await _saveCors();
      if (!mounted || !_fieldsValid) return;
    }
    await ref.read(bridgeConfigProvider.notifier).setEnabled(enabled);
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(bridgeConfigProvider);
    final config = configAsync.value ?? const BridgeConfig();
    final status = ref.watch(bridgeStatusProvider);

    ref.listen(bridgeConfigProvider, (_, next) {
      final nextConfig = next.value;
      if (nextConfig != null && mounted) {
        _syncFrom(nextConfig);
        setState(() => _error = _validationMessage());
      }
    });

    final clients = status.clients == 1
        ? '1 client'
        : '${status.clients} clients';

    // Status box: server state only — running with its client count,
    // or the error with a retry. Off and not-yet-running need no box:
    // the toggle already says off, and waiting for packets is not
    // a state worth showing.
    final Widget? statusBox;
    if (status.error != null) {
      statusBox = _StatusBox(
        text: 'Error: ${status.error}',
        accent: AppColors.destructive,
        wash: AppColors.dangerSoft,
        onRetry: () => ref.read(bridgeConfigProvider.notifier).touch(),
      );
    } else if (config.enabled && status.running) {
      statusBox = _StatusBox(
        text: 'Running · $clients connected',
        accent: AppColors.success,
        wash: AppColors.successSoft,
      );
    } else {
      statusBox = null;
    }

    const fieldGap = SizedBox(width: 8);

    // Locked while serving via readOnly (not `enabled: false`, which
    // would restyle the fields): the row below dims via Opacity, so a
    // locked field keeps its layout and only turns grayish.
    final bool locked = config.enabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Live sharing server',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            value: config.enabled,
            // Locked while serving (edit after switching off), and
            // disabled over invalid input (fix the error to enable).
            // Turning off always stays available, including on error.
            onChanged: _fieldsValid || config.enabled
                ? (v) => _setEnabled(v)
                : null,
          ),
        ),
        Opacity(
          opacity: locked ? 0.45 : 1.0,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _bind,
                focusNode: _bindFocus,
                readOnly: locked,
                canRequestFocus: !locked,
                mouseCursor: locked ? SystemMouseCursors.basic : null,
                decoration:
                    settingsFieldDecoration(context, 'Bind address'),
                style: settingsFieldStyle,
                onChanged: (_) {
                  if (mounted) {
                    setState(() => _error = _validationMessage());
                  }
                },
                onSubmitted: (_) => _saveBind(),
                onTapOutside: (_) => _saveBind(),
              ),
            ),
            fieldGap,
            SizedBox(
              width: 96,
              child: TextField(
                controller: _port,
                focusNode: _portFocus,
                readOnly: locked,
                canRequestFocus: !locked,
                mouseCursor: locked ? SystemMouseCursors.basic : null,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: settingsFieldDecoration(context, 'Port'),
                style: settingsFieldStyle,
                onChanged: (_) {
                  if (mounted) {
                    setState(() => _error = _validationMessage());
                  }
                },
                onSubmitted: (_) => _savePort(),
                onTapOutside: (_) => _savePort(),
              ),
            ),
            fieldGap,
            Expanded(
              child: TextField(
                controller: _cors,
                focusNode: _corsFocus,
                readOnly: locked,
                canRequestFocus: !locked,
                mouseCursor: locked ? SystemMouseCursors.basic : null,
                decoration:
                    settingsFieldDecoration(context, 'Allowed origin'),
                style: settingsFieldStyle,
                onChanged: (_) {
                  if (mounted) {
                    setState(() => _error = _validationMessage());
                  }
                },
                onSubmitted: (_) => _saveCors(),
                onTapOutside: (_) => _saveCors(),
              ),
            ),
            ],
          ),
        ),
        if (statusBox != null) ...[const SizedBox(height: 12), statusBox],
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

/// Tinted status box for the bridge: running reads green, failure red
/// with a retry. Only shown for live server states — the toggle already
/// communicates off.
class _StatusBox extends StatelessWidget {
  final String text;
  final Color accent;
  final Color wash;
  final VoidCallback? onRetry;

  const _StatusBox({
    required this.text,
    required this.accent,
    required this.wash,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.mono.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: accent,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: AppColors.destructive,
              ),
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Card wrapper around [LiveSharingControls] for standalone use.
class LiveOutputCard extends ConsumerWidget {
  const LiveOutputCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const AppCard(title: 'LIVE SHARING', child: LiveSharingControls());
  }
}
