import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_provider.dart';
import '../../state/toast_store.dart';

/// Headless bridge: watches serial worker events and pushes toasts.
///
/// Mounted once in [AppShell] (renders nothing). Three sources:
/// - [serialErrorsProvider]: every worker [ErrorEvent] → toast (also
///   resolves an in-flight connect mark). Messages about a lost port surface
///   as a "Port disconnected" warning, everything else as "Serial error".
/// - [availablePortsProvider]: one "Ports refreshed" toast per explicit
///   rescan (armed by [SerialConfigNotifier.refreshPorts]; startup scans
///   stay silent).
/// - [commandEventsProvider]: newly filed *failed* uplink attempts → error
///   toast with the resolved command label.
///
/// Deliberately silent on user-initiated disconnects: [DisconnectCommand]
/// emits no [ErrorEvent], so nothing toasts — the top-bar pill flipping
/// back to the port picker is the whole signal.
///
/// Dedupes via the toast store (consecutive identical messages refresh one
/// card).
class SerialToastBridge extends ConsumerWidget {
  const SerialToastBridge({super.key});

  /// Unexpected link-loss messages read as warnings, not errors.
  static bool isDisconnectMessage(String message) {
    final lower = message.toLowerCase();
    return lower.contains('disconnect') ||
        lower.contains('port closed') ||
        lower.contains('port error') ||
        lower.contains('port lost');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(serialErrorsProvider, (_, next) {
      next.whenData((event) {
        // Any worker error resolves an in-flight connect attempt (the toast
        // below is the visible answer); then surface it.
        ref.read(serialConfigProvider.notifier).clearConnecting();
        final disconnect = isDisconnectMessage(event.message);
        ref.read(toastStoreProvider.notifier).push(
              event.message,
              severity: disconnect
                  ? ToastSeverity.warning
                  : ToastSeverity.error,
              title: disconnect ? 'Port disconnected' : 'Serial error',
            );
      });
    });

    ref.listen(availablePortsProvider, (_, next) {
      next.whenData((ports) {
        // Exactly one toast per explicit rescan: the flag is armed by
        // [SerialConfigNotifier.refreshPorts], so startup scans stay silent.
        if (!ref.read(serialConfigProvider).refreshPending) return;
        ref.read(serialConfigProvider.notifier).consumeRefresh();
        final notifier = ref.read(toastStoreProvider.notifier);
        if (ports.isEmpty) {
          notifier.push(
            'No serial ports found — plug in the radio and rescan.',
            severity: ToastSeverity.warning,
            title: 'Ports refreshed',
          );
        } else {
          notifier.push(
            'Ports refreshed — ${ports.length} found.',
            severity: ToastSeverity.info,
            title: 'Ports refreshed',
          );
        }
      });
    });

    ref.listen(commandEventsProvider, (_, next) {
      next.whenData((event) {
        if (!event.ok) {
          final label = describeUplink(event.bytes.toList()).label;
          ref.read(toastStoreProvider.notifier).push(
                'Uplink "$label" was not sent — check the link and retry.',
                severity: ToastSeverity.error,
                title: 'Command failed',
              );
        }
      });
    });

    return const SizedBox.shrink();
  }
}
