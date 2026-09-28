import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Top-level screens reachable from the top-bar quick nav.
enum AppScreen {
  dashboard('Dashboard', Icons.rocket_outlined),
  flights('Recorded flights', Icons.history),
  monitor('Channel health', Icons.monitor_heart_outlined),
  settings('Settings', Icons.settings_outlined);

  const AppScreen(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Currently displayed screen. Simple switcher — the app has exactly four
/// flat screens, so a full router is not warranted.
final appRouterProvider =
    NotifierProvider<AppRouter, AppScreen>(AppRouter.new);

class AppRouter extends Notifier<AppScreen> {
  @override
  AppScreen build() => AppScreen.dashboard;

  void go(AppScreen screen) => state = screen;
}
