import 'package:flutter/material.dart';
import 'package:serial/serial.dart';

import './waiting_for_data.dart';

/// Human field name for the [NotProvidedByConnector] placeholder.
String telemetryFieldLabel(TelemetryField field) => switch (field) {
      TelemetryField.gpsPosition => 'GPS position',
      TelemetryField.baroAltitude => 'Baro altitude',
      TelemetryField.velocityHorizontal => 'Horizontal velocity',
      TelemetryField.velocityVertical => 'Vertical velocity',
      TelemetryField.acceleration => 'Acceleration',
      TelemetryField.gyro => 'Gyro',
      TelemetryField.attitude => 'Attitude',
      TelemetryField.battery => 'Battery',
      TelemetryField.hall => 'Hall sensor',
      TelemetryField.fsm => 'Flight state',
    };

/// Capability gate for data tiles.
///
/// Returns a [NotProvidedByConnector] placeholder when this connector never
/// populates [field], else `null` (the tile renders normally — possibly
/// still [WaitingForData] when nothing arrived yet).
extension ConnectorGate on TelemetryConnector {
  Widget? unsupportedPlaceholder(
    TelemetryField field, {
    bool compact = false,
  }) {
    if (capabilities.supports(field)) return null;
    return Center(
      child: NotProvidedByConnector(
        field: telemetryFieldLabel(field),
        connectorName: displayName,
        compact: compact,
      ),
    );
  }
}
