/// Persisted camera behaviour shared by layouts and flight views.
enum FlightCameraMode {
  chase('Chase rocket'),
  orbit('Orbit field'),
  free('Free orbit');

  final String label;
  const FlightCameraMode(this.label);
}

FlightCameraMode? tryParseFlightCameraMode(String? name) {
  for (final mode in FlightCameraMode.values) {
    if (mode.name == name) return mode;
  }
  return null;
}
