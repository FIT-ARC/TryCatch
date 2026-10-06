import 'dart:ui' show Size;

/// Layout constraints shared by state and tile descriptors.
abstract final class TileConstraints {
  static const sizes = <String, Size>{
    'rocket_3d': Size(150, 110),
    'map': Size(150, 110),
    'flight_3d': Size(170, 120),
    'flight_3d_sat': Size(170, 120),
    'onboard_camera': Size(170, 120),
    'stats': Size(130, 80),
    'dead_reckoning': Size(130, 80),
    'max_alt': Size(110, 64),
    'highlights': Size(140, 80),
    'altitude_chart': Size(130, 70),
    'altitude_value': Size(110, 64),
    'velocity_chart': Size(130, 70),
    'velocity_value': Size(110, 64),
    'acceleration_chart': Size(130, 70),
    'acceleration_value': Size(110, 64),
    'battery_chart': Size(130, 70),
    'battery_value': Size(110, 64),
    'fsm': Size(150, 120),
    'events': Size(140, 90),
    'commands': Size(140, 90),
    'nosecone': Size(110, 64),
    'hall_sensor': Size(130, 70),
    'hall_sensor_value': Size(110, 64),
    'channel_health': Size(140, 80),
    'channel_health_value': Size(110, 64),
    'control_panel': Size(190, 110),
  };
  static Size minSizeOf(String id) => sizes[id] ?? const Size(120, 90);
}
