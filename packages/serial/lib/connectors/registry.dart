/// Registry of every available telemetry connector.
///
/// Adding a connector = one class + one entry here. The settings toggle,
/// the worker isolate and the recording readers all resolve through
/// [connectorById].
///
/// Decoding stays complete in every build ([allConnectors]/[connectorById]
/// always know `mock`, so old recordings still replay in release). Only the
/// *user-visible* surface is dev-gated — see [visibleConnectors] and
/// [defaultVisibleConnectorId].
library;

import 'brno_connector.dart';
import 'connector.dart';
import 'mock_connector.dart';
import 'segfault_connector.dart';
import 'segfault_demo_connector.dart';

/// Mirrors Flutter's `kDebugMode` without taking a Flutter dependency
/// (this package is pure Dart): true in debug, false in profile/release.
const bool isDevMode =
    !bool.fromEnvironment('dart.vm.product') &&
        !bool.fromEnvironment('dart.vm.profile');

/// The MOCK connector instance (original TryCatch format).
const TelemetryConnector mockConnector = MockConnector();

/// The SegFault connector instance (OG rocket firmware).
const TelemetryConnector segfaultConnector = SegfaultConnector();

/// The SegFault Demo connector instance (minimal event firmware).
const TelemetryConnector segfaultDemoConnector = SegfaultDemoConnector();

/// The Brno connector instance (static pad with 1 m nudge commands).
const TelemetryConnector brnoConnector = BrnoConnector();

/// Every available connector, in settings display order.
///
/// Full list for decoding — always includes `mock` so v3 recordings stamped
/// with it still load in release builds. The settings picker must use
/// [visibleConnectors] instead.
const List<TelemetryConnector> allConnectors = [
  mockConnector,
  brnoConnector,
  segfaultConnector,
  segfaultDemoConnector,
];

/// Connectors the settings picker may offer. The MOCK and Brno connectors
/// are dev tools and only show in debug builds; release builds offer the
/// SegFault firmwares alone.
List<TelemetryConnector> get visibleConnectors => [
      if (isDevMode) mockConnector,
      if (isDevMode) brnoConnector,
      segfaultConnector,
      segfaultDemoConnector,
    ];

/// Whether [id] is the dev-only MOCK connector.
bool isMockConnectorId(String id) => id == mockConnector.id;

/// Whether [id] is the dev-only Brno connector.
bool isBrnoConnectorId(String id) => id == brnoConnector.id;

/// Whether [id] names a dev-only connector (MOCK or Brno).
bool isDevOnlyConnectorId(String id) =>
    isMockConnectorId(id) || isBrnoConnectorId(id);

/// Default connector id (used before the persisted setting loads and as a
/// fallback for corrupt preferences).
///
/// Decoding default — stays `mock` so the worker and replay have a stable
/// fallback in every build.
const String defaultConnectorId = 'mock';

/// Default connector for *user selection*. Debug starts on MOCK, release on
/// SegFault (MOCK is hidden there).
String get defaultVisibleConnectorId =>
    isDevMode ? mockConnector.id : segfaultConnector.id;

/// Resolves a connector by its stable [id], or `null` when unknown
/// (e.g. a recording from a connector this build doesn't ship).
TelemetryConnector? connectorById(String id) {
  for (final connector in allConnectors) {
    if (connector.id == id) return connector;
  }
  return null;
}

/// Whether [id] names a connector this build ships.
bool isKnownConnectorId(String id) => connectorById(id) != null;
