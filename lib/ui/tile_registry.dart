import 'package:flutter/material.dart';

import './tiles/acceleration_chart_tile.dart';
import './tiles/altitude_chart_tile.dart';
import './tiles/battery_chart_tile.dart';
import './tiles/channel_health_tile.dart';
import './tiles/commands_tile.dart';
import './tiles/control_panel_tile.dart';
import './tiles/flight_3d_satellite_tile.dart';
import './tiles/flight_3d_tile.dart';
import './tiles/fsm_tile.dart';
import './tiles/hall_sensor_tile.dart';
import './tiles/highlights_tile.dart';
import './tiles/map_tile.dart';
import './tiles/max_altitude_tile.dart';
import './tiles/nosecone_tile.dart';
import './tiles/onboard_camera_tile.dart';
import './tiles/rocket_3d_tile.dart';
import './tiles/dead_reckoning_tile.dart';
import './tiles/events_tile.dart';
import './tiles/stats_tile.dart';
import './tiles/velocity_chart_tile.dart';

/// Broad category used by the tile picker's filter chips.
enum TileCategory {
  views,
  charts,
  sensors,
  control;

  String get label => switch (this) {
        TileCategory.views => 'Views',
        TileCategory.charts => 'Charts',
        TileCategory.sensors => 'Sensors',
        TileCategory.control => 'Control',
      };
}

/// Data-driven description of a dashboard tile type.
///
/// Adding a new tile to the whole app = create the tile class and append
/// one descriptor here; the "Add tile" picker and the default layouts pick
/// it up automatically.
class TileDescriptor {
  /// Stable registry id, persisted in workspace layouts.
  final String id;

  final String title;

  /// One-line description shown in the picker.
  final String description;

  /// Picker glyph.
  final IconData icon;

  /// Minimum usable size in logical pixels — the layout tree's divider drag
  /// never squeezes a tile below this.
  final Size minSize;

  /// Immersive tiles (map, 3D views) render edge-to-edge: the card drops its
  /// content padding so the render touches the card border (the header
  /// strip stays).
  final bool immersive;

  /// Category for the tile-picker filter chips.
  final TileCategory category;

  final WidgetBuilder builder;

  const TileDescriptor({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.minSize,
    this.immersive = false,
    required this.category,
    required this.builder,
  });
}


/// All dashboard tile types and the default workspace layouts.
abstract final class TileRegistry {
  static final List<TileDescriptor> all = [
    TileDescriptor(
      id: 'rocket_3d',
      title: '3D Rocket',
      description: 'Live orientation',
      icon: Icons.rocket_launch_outlined,
      minSize: const Size(150, 110),
      immersive: true,
      category: TileCategory.views,
      builder: (context) => Rocket3dTile(),
    ),
    TileDescriptor(
      id: 'map',
      title: 'Map',
      description: 'GPS track, dead reckoning and launch site',
      icon: Icons.map_outlined,
      minSize: const Size(150, 110),
      immersive: true,
      category: TileCategory.views,
      builder: (context) => MapTile(),
    ),
    TileDescriptor(
      id: 'flight_3d',
      title: 'Flight path',
      description: '3D flight trail with launch site and camera modes',
      icon: Icons.view_in_ar_outlined,
      minSize: const Size(170, 120),
      immersive: true,
      category: TileCategory.views,
      builder: (context) => Flight3dTile(),
    ),
    TileDescriptor(
      id: 'flight_3d_sat',
      title: '3D Flight',
      description: '3D flight trail over satellite imagery (needs internet)',
      icon: Icons.satellite_alt_outlined,
      minSize: const Size(170, 120),
      immersive: true,
      category: TileCategory.views,
      builder: (context) => Flight3dSatelliteTile(),
    ),
    TileDescriptor(
      id: 'onboard_camera',
      title: 'Onboard camera',
      description: "Rocket's-eye view over satellite imagery (needs internet)",
      icon: Icons.videocam_outlined,
      minSize: const Size(170, 120),
      immersive: true,
      category: TileCategory.views,
      builder: (context) => OnboardCameraTile(),
    ),
    TileDescriptor(
      id: 'stats',
      title: 'GPS position',
      description: 'GPS position with copy',
      icon: Icons.place_outlined,
      minSize: const Size(130, 80),
      category: TileCategory.sensors,
      builder: (context) => StatsTile(),
    ),
    TileDescriptor(
      id: 'dead_reckoning',
      title: 'Dead reckoning',
      description: 'Estimated position during packet loss (live only)',
      icon: Icons.explore_outlined,
      minSize: const Size(130, 80),
      category: TileCategory.sensors,
      builder: (context) => DeadReckoningTile(),
    ),
    TileDescriptor(
      id: 'max_alt',
      title: 'Max altitude',
      description: 'Peak barometric altitude this session',
      icon: Icons.arrow_upward,
      minSize: const Size(110, 64),
      category: TileCategory.sensors,
      builder: (context) => MaxAltitudeTile(),
    ),
    TileDescriptor(
      id: 'highlights',
      title: 'Highlights',
      description: 'Flight extremes: ascent, descent, speed, acceleration (+ replay drift/altitude)',
      icon: Icons.emoji_events_outlined,
      minSize: const Size(140, 80),
      category: TileCategory.charts,
      builder: (context) => HighlightsTile(),
    ),
    TileDescriptor(
      id: 'altitude_chart',
      title: 'Altitude',
      description: 'Barometric altitude over time',
      icon: Icons.show_chart,
      minSize: const Size(130, 70),
      category: TileCategory.charts,
      builder: (context) => AltitudeChartTile(),
    ),
    TileDescriptor(
      id: 'velocity_chart',
      title: 'Velocity',
      description: 'Horizontal, vertical and total speed',
      icon: Icons.speed_outlined,
      minSize: const Size(130, 70),
      category: TileCategory.charts,
      builder: (context) => VelocityChartTile(),
    ),
    TileDescriptor(
      id: 'acceleration_chart',
      title: 'Acceleration',
      description: 'Vertical and total acceleration',
      icon: Icons.trending_up,
      minSize: const Size(130, 70),
      category: TileCategory.charts,
      builder: (context) => AccelerationChartTile(),
    ),
    TileDescriptor(
      id: 'battery_chart',
      title: 'Battery',
      description: 'Battery voltage over time',
      icon: Icons.battery_charging_full_outlined,
      minSize: const Size(130, 70),
      category: TileCategory.charts,
      builder: (context) => BatteryChartTile(),
    ),
    TileDescriptor(
      id: 'fsm',
      title: 'State machine',
      description: 'Flight software state and timeline',
      icon: Icons.account_tree_outlined,
      minSize: const Size(150, 120),
      category: TileCategory.views,
      builder: (context) => FsmTile(),
    ),
    TileDescriptor(
      id: 'events',
      title: 'Events',
      description: 'Flight milestones: launch, apogee, parachute, touchdown',
      icon: Icons.flag_outlined,
      minSize: const Size(140, 90),
      category: TileCategory.views,
      builder: (context) => EventsTile(),
    ),
    TileDescriptor(
      id: 'commands',
      title: 'Commands',
      description: 'Uplink commands sent to the rocket, sent and failed',
      icon: Icons.outbox_outlined,
      minSize: const Size(140, 90),
      category: TileCategory.views,
      builder: (context) => CommandsTile(),
    ),
    TileDescriptor(
      id: 'nosecone',
      title: 'Nose cone',
      description: 'Nose-cone lock state',
      icon: Icons.lock_outlined,
      minSize: const Size(110, 64),
      category: TileCategory.sensors,
      builder: (context) => NoseconeTile(),
    ),
    TileDescriptor(
      id: 'hall_sensor',
      title: 'Hall sensor',
      description: 'Breakaway wire sensor readout',
      icon: Icons.sensors_outlined,
      minSize: const Size(130, 70),
      category: TileCategory.sensors,
      builder: (context) => HallSensorTile(),
    ),
    TileDescriptor(
      id: 'channel_health',
      title: 'Channel health',
      description: 'Undecodable traffic on this frequency',
      icon: Icons.wifi_tethering_outlined,
      minSize: const Size(140, 80),
      category: TileCategory.sensors,
      builder: (context) => ChannelHealthTile(),
    ),
    TileDescriptor(
      id: 'control_panel',
      title: 'Control panel',
      description: 'Two-click commands to the rocket',
      icon: Icons.gamepad_outlined,
      minSize: const Size(190, 110),
      category: TileCategory.control,
      builder: (context) => ControlPanelTile(),
    ),
  ];


  static TileDescriptor? byId(String id) {
    for (final d in all) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Hard floor under every tile so dividers never squeeze a tile into
  /// an unpaintable strip. Kept deliberately low — tiles shed chrome
  /// (legends, grids collapse) instead of overflowing.
  static const Size absoluteFloor = Size(110, 64);

  static Size minSizeOf(String tileType) {
    final min = byId(tileType)?.minSize ?? const Size(120, 70);
    return Size(
      min.width > absoluteFloor.width ? min.width : absoluteFloor.width,
      min.height > absoluteFloor.height ? min.height : absoluteFloor.height,
    );
  }
}
