import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../foundation/store.dart';
import '../services/prefs_keys.dart';

/// A launch site: coordinates, MSL altitude and a display name.
class LaunchSite {
  final String name;
  final double latitude;
  final double longitude;

  /// Altitude above mean sea level in metres (used to convert barometric
  /// AGL readings to absolute position and to anchor the map).
  final double altitudeMsl;

  const LaunchSite({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.altitudeMsl,
  });

  LaunchSite copyWith({String? name, double? latitude, double? longitude, double? altitudeMsl}) =>
      LaunchSite(
        name: name ?? this.name,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        altitudeMsl: altitudeMsl ?? this.altitudeMsl,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'altitudeMsl': altitudeMsl,
      };

  factory LaunchSite.fromJson(Map<String, dynamic> json) => LaunchSite(
        name: json['name'] as String? ?? '',
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
        altitudeMsl: (json['altitudeMsl'] as num?)?.toDouble() ?? 0,
      );

  /// Short copy-pasteable string: `<prefix><base64url(json)>`, mirroring
  /// the dead-reckoning tune share string.
  String toShareString() {
    final raw = utf8.encode(jsonEncode(toJson()));
    return '$launchSiteSharePrefix${base64Url.encode(raw)}';
  }

  /// Parses [toShareString] output. Returns `null` on any format error.
  static LaunchSite? parseShareString(String input) {
    final text = input.trim();
    if (!text.startsWith(launchSiteSharePrefix)) return null;
    try {
      final raw =
          base64Url.decode(text.substring(launchSiteSharePrefix.length));
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map<String, dynamic>) return null;
      final site = LaunchSite.fromJson(decoded);
      if (site.name.isEmpty) return null;
      return site;
    } catch (_) {
      return null;
    }
  }
}

/// Share-string prefix for copy-pasteable launch sites.
const String launchSiteSharePrefix = 'LAUNCHSITE1.';

/// Selected launch site + saved presets.
class LaunchSiteState {
  final LaunchSite? selected;
  final List<LaunchSite> presets;

  const LaunchSiteState({this.selected, this.presets = const []});

  static const _absent = Object();

  /// `selected` uses a sentinel so callers can explicitly clear it with
  /// `copyWith(selected: null)`.
  LaunchSiteState copyWith({Object? selected = _absent, List<LaunchSite>? presets}) =>
      LaunchSiteState(
        selected: identical(selected, _absent)
            ? this.selected
            : selected as LaunchSite?,
        presets: presets ?? this.presets,
      );

  Map<String, dynamic> toJson() => {
        'selected': selected?.toJson(),
        'presets': presets.map((p) => p.toJson()).toList(),
      };

  factory LaunchSiteState.fromJson(Map<String, dynamic> json) =>
      LaunchSiteState(
        selected: json['selected'] == null
            ? null
            : LaunchSite.fromJson(json['selected'] as Map<String, dynamic>),
        presets: (json['presets'] as List<dynamic>? ?? [])
            .map((e) => LaunchSite.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Persisted launch-site settings ([shared_preferences], JSON-encoded).
final launchSiteProvider =
    AsyncNotifierProvider<LaunchSiteStore, LaunchSiteState>(
  LaunchSiteStore.new,
);

/// Synchronous convenience view of the currently selected site.
final currentLaunchSiteProvider = Provider<LaunchSite?>(
  (ref) => ref.watch(launchSiteProvider).value?.selected,
);

/// Dev-only seeded launch site matching the mock flight simulator's pad
/// (Prague, MSL 403 m). Only ever seeded/visible in debug builds — release
/// builds start empty and strip this entry when reading prefs written by
/// a debug build.
const LaunchSite mockLaunchSite = LaunchSite(
  name: 'MOCK Pad',
  latitude: 50.0755,
  longitude: 14.4378,
  altitudeMsl: 403,
);

/// Whether [site] is the dev-only mock launch site.
bool isMockLaunchSite(LaunchSite? site) =>
    site != null && site.name == mockLaunchSite.name;

/// Fresh state for first launch: debug shows the mock pad (selected),
/// release starts empty. In-memory only — the mock is never written to disk.
LaunchSiteState _freshState() => kDebugMode
    ? const LaunchSiteState(selected: mockLaunchSite, presets: [mockLaunchSite])
    : const LaunchSiteState();

/// Adds the mock pad to [state]'s presets (sorted, as if added via
/// [LaunchSiteStore.savePreset]) when missing. Dev-only, in-memory only —
/// the mock is never persisted. Selection is left untouched.
LaunchSiteState _injectMock(LaunchSiteState state) {
  if (state.presets.any((p) => p.name == mockLaunchSite.name)) return state;
  final presets = [...state.presets, mockLaunchSite]
    ..sort((a, b) => a.name.compareTo(b.name));
  return state.copyWith(presets: presets);
}

/// Removes the mock pad from [state] (presets + selection). Used by release
/// builds reading prefs that a debug build wrote.
LaunchSiteState _stripMock(LaunchSiteState state) {
  if (!state.presets.any((p) => p.name == mockLaunchSite.name) &&
      !isMockLaunchSite(state.selected)) {
    return state;
  }
  final remaining =
      state.presets.where((p) => p.name != mockLaunchSite.name).toList();
  final selected =
      isMockLaunchSite(state.selected) ? null : state.selected;
  // When the mock was selected but real presets remain, fall through to the
  // first one so the app still has a site; otherwise leave empty.
  return state.copyWith(
    presets: remaining,
    selected: selected ?? (remaining.isNotEmpty ? remaining.first : null),
  );
}

class LaunchSiteStore extends JsonPersistedStore<LaunchSiteState> {
  @override
  String get prefsKey => PrefsKeys.launchSites;

  @override
  LaunchSiteState get defaults => _freshState();

  @override
  Map<String, dynamic> toJson(LaunchSiteState state) => state.toJson();

  @override
  LaunchSiteState fromJson(Map<String, dynamic> json) =>
      LaunchSiteState.fromJson(json);

  @override
  Future<LaunchSiteState> build() async {
    // Release builds never show the dev-only mock site, even when the
    // prefs file was written by a debug build. Debug builds inject it
    // in memory (never persisted) so it always appears in the list.
    final loaded = await loadPersisted();
    if (!kDebugMode) return _stripMock(loaded);
    return _injectMock(loaded);
  }

  /// Writes [next] to disk without the mock pad (dev-only, in-memory only)
  /// while keeping it in the live state.
  Future<void> _persist(LaunchSiteState next) async {
    final disk = _stripMock(next);
    state = AsyncData(kDebugMode ? _injectMock(next) : disk);
    await writeRaw(encode(disk));
  }

  /// Selects the active launch site (does not add a preset). A site is
  /// always selected — there is no "no site" state.
  Future<void> select(LaunchSite site) async =>
      _persist((state.value ?? const LaunchSiteState()).copyWith(selected: site));

  /// Adds or updates (by name) a preset and selects it. The dev-only mock
  /// pad is read-only: saving under its name just selects the canonical
  /// mock without altering it.
  Future<void> savePreset(LaunchSite site) async {
    if (isMockLaunchSite(site)) {
      final current = state.value ?? const LaunchSiteState();
      await _persist(current.copyWith(selected: mockLaunchSite));
      return;
    }
    final current = state.value ?? const LaunchSiteState();
    final presets = [...current.presets]
      ..removeWhere((p) => p.name == site.name)
      ..add(site)
      ..sort((a, b) => a.name.compareTo(b.name));
    await _persist(current.copyWith(presets: presets, selected: site));
  }

  /// Deletes a preset by name. The dev-only mock pad is read-only and
  /// cannot be deleted (no-op). When the deleted preset was the selected
  /// site, selection falls through to the first remaining preset — or to
  /// nothing when none remain (the empty state that prompts adding a site).
  Future<void> deletePreset(String name) async {
    if (name == mockLaunchSite.name) return;
    final current = state.value ?? const LaunchSiteState();
    final remaining =
        current.presets.where((p) => p.name != name).toList();
    final wasSelected = current.selected?.name == name;
    await _persist(current.copyWith(
      presets: remaining,
      selected: wasSelected
          ? (remaining.isNotEmpty ? remaining.first : null)
          : current.selected,
    ));
  }
}
