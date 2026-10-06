import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_colors.dart';
import '../foundation/store.dart';
import '../services/prefs_keys.dart';

/// Persisted theme selection; AppThemeMode adapts it to renderer palette access.
final themeModeProvider = AsyncNotifierProvider<ThemeModeStore, bool>(
  ThemeModeStore.new,
);

class ThemeModeStore extends PersistedStore<bool> {
  @override
  String get prefsKey => PrefsKeys.darkMode;
  @override
  bool get defaults => false;
  @override
  String encode(bool state) => state.toString();
  @override
  bool decode(String raw) => switch (raw) {
    'true' => true,
    'false' => false,
    _ => throw const FormatException('Invalid theme mode.'),
  };
  @override
  Future<bool> build() async {
    final dark = await loadPersisted();
    AppThemeMode.instance.value = dark;
    return dark;
  }

  Future<void> setDark(bool dark) async {
    AppThemeMode.instance.value = dark;
    await save(dark);
  }

  @override
  Future<void> resetToDefaults() => setDark(defaults);
}
