import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/services/live_bridge/bridge_config.dart';
import 'package:trycatch/services/prefs_keys.dart';
import 'package:trycatch/state/bridge_provider.dart';

void main() {
  group('BridgeConfig', () {
    test('defaults to disabled localhost:6767 for proxy setups', () {
      const config = BridgeConfig();
      expect(config.enabled, false);
      expect(config.port, 6767);
      expect(config.bindAddress, '127.0.0.1');
      expect(config.corsOrigin, '*');
    });

    test('round-trips through JSON', () {
      const config = BridgeConfig(
        enabled: true,
        port: 8080,
        bindAddress: '0.0.0.0',
        corsOrigin: 'https://example.com',
      );
      final revived =
          BridgeConfig.fromJson(Map<String, dynamic>.from(config.toJson()));
      expect(revived.enabled, true);
      expect(revived.port, 8080);
      expect(revived.bindAddress, '0.0.0.0');
      expect(revived.corsOrigin, 'https://example.com');
    });

    test('falls back per key on corrupt values', () {
      final config = BridgeConfig.fromJson({
        'enabled': 'yes',
        'port': 99999,
        'bind': '  ',
        'cors': '',
      });
      expect(config.enabled, false);
      expect(config.port, BridgeConfig.defaultPort);
      expect(config.bindAddress, BridgeConfig.defaultBindAddress);
      expect(config.corsOrigin, BridgeConfig.defaultCorsOrigin);
    });

    test('validates ports', () {
      expect(BridgeConfig.isValidPort(1), true);
      expect(BridgeConfig.isValidPort(6767), true);
      expect(BridgeConfig.isValidPort(65535), true);
      expect(BridgeConfig.isValidPort(0), false);
      expect(BridgeConfig.isValidPort(65536), false);
    });
  });

  group('BridgeConfigStore', () {
    test('persists and reloads', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      try {
        await container.read(bridgeConfigProvider.future);
        final store = container.read(bridgeConfigProvider.notifier);
        await store.setEnabled(true);
        await store.setPort(6767);
        await store.setBindAddress('127.0.0.1');
        final reloaded = await container.read(bridgeConfigProvider.future);
        expect(reloaded.enabled, true);
        expect(reloaded.port, 6767);
        expect(reloaded.bindAddress, '127.0.0.1');

        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(PrefsKeys.liveBridge);
        expect(raw, isNotNull);
        expect(
          BridgeConfig.fromJson(
            jsonDecode(raw!) as Map<String, dynamic>,
          ).enabled,
          true,
        );
      } finally {
        container.dispose();
      }
    });

    test('falls back to defaults on corrupt prefs', () async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.liveBridge: 'not-json{{{',
      });
      final container = ProviderContainer();
      try {
        final config = await container.read(bridgeConfigProvider.future);
        expect(config.enabled, false);
        expect(config.port, BridgeConfig.defaultPort);
      } finally {
        container.dispose();
      }
    });

    test('rejects invalid writes without changing state', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      try {
        await container.read(bridgeConfigProvider.future);
        final store = container.read(bridgeConfigProvider.notifier);
        expect(await store.setPort(0), false);
        expect(await store.setPort(70000), false);
        expect(await store.setBindAddress('   '), false);
        final config = await container.read(bridgeConfigProvider.future);
        expect(config.port, BridgeConfig.defaultPort);
        expect(config.bindAddress, BridgeConfig.defaultBindAddress);
      } finally {
        container.dispose();
      }
    });
  });

  group('BridgeStatusStore', () {
    test('clear returns to stopped and never throws', () {
      final container = ProviderContainer();
      try {
        final store = container.read(bridgeStatusProvider.notifier);
        store.report(
          running: true,
          port: 6767,
          bind: '127.0.0.1',
          clients: 2,
          hasFrame: true,
          error: null,
        );
        expect(container.read(bridgeStatusProvider).running, true);
        store.clear();
        final cleared = container.read(bridgeStatusProvider);
        expect(cleared.running, false);
        expect(cleared.clients, 0);
        expect(cleared.error, isNull);
        store.clear();
      } finally {
        container.dispose();
      }
    });
  });
}
