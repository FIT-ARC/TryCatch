import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_map/flutter_map.dart'
    show BuiltInMapCachingProvider, CachedMapTileMetadata;

import '../../../../core/app_config.dart';

/// Shared Esri tile I/O for the 2D map and the 3D satellite drape: URL
/// builders, single-shot downloads and the shared flutter_map disk cache.
///
/// Both map precaching (`map_tiles.dart`) and the 3D patch fetcher
/// (`satellite_ground.dart`) go through here, so the User-Agent, timeouts,
/// image validation and cache TTL can't drift apart.

const String tileUserAgent = AppConfig.tileUserAgent;

const String streetAttribution = '© Esri, OpenStreetMap contributors';
const String satelliteAttribution = 'Imagery © Esri';

/// Esri tile URL template for flutter_map (`{z}/{y}/{x}`).
String esriTileUrlTemplate(String style) =>
    'https://server.arcgisonline.com/ArcGIS/rest/services/$style/MapServer/tile/{z}/{y}/{x}';

/// Esri tile URL for a map style (`World_Street_Map` / `World_Imagery`).
String esriTileUrl(String style, int x, int y, int z) =>
    'https://server.arcgisonline.com/ArcGIS/rest/services/$style/MapServer/tile/$z/$y/$x';

/// Esri street-map URL for a tile (single host, no subdomains).
String streetTileUrl(int x, int y, int z) =>
    esriTileUrl('World_Street_Map', x, y, z);

/// Esri World Imagery URL for a tile.
String satelliteTileUrl(int x, int y, int z) =>
    esriTileUrl('World_Imagery', x, y, z);

/// Downloads [url] (`null` on any failure or empty body). Creates its own
/// client unless [client] is given (precache passes a shared one).
Future<Uint8List?> fetchTileBytes(Uri url, {HttpClient? client}) async {
  final owned = client == null;
  final http = client ?? HttpClient();
  HttpClientRequest? request;
  try {
    http.connectionTimeout = AppConfig.tileConnectionTimeout;
    request = await http.getUrl(url).timeout(AppConfig.tileConnectionTimeout);
    request.headers.set('User-Agent', tileUserAgent);
    final response = await request.close().timeout(
      AppConfig.tileResponseTimeout,
    );
    if (response.statusCode != 200) {
      request.abort();
      return null;
    }
    final bytes = await () async {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (builder.length + chunk.length > AppConfig.tileMaxResponseBytes) {
          throw const FormatException('Tile response exceeds size limit');
        }
        builder.add(chunk);
      }
      return builder.takeBytes();
    }().timeout(AppConfig.tileResponseTimeout);
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    request?.abort();
    return null;
  } finally {
    if (owned) http.close(force: true);
  }
}

/// PNG or JPEG magic bytes — keeps HTML error pages out of the tile cache
/// (Esri imagery is JPEG, street tiles are PNG).
bool looksLikeImage(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final png =
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;
  final jpeg = bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
  return png || jpeg;
}

/// SHA-256 of Esri's static "Map data not yet available" tile served with
/// HTTP 200 where World_Imagery has no coverage at that zoom (2521 bytes).
const String _imageryPlaceholderSha256 =
    '9eafd300d61393184a4abc1d458564cfd1cd9b6f9c4e9c74687045c0a0e5b858';

/// SHA-256 of Esri's static blank tile served where World_Street_Map has no
/// coverage at that zoom (2421 bytes).
const String _streetPlaceholderSha256 =
    '36622585df6263b641747047ed97fa11b55d89b2cd33af98e8c2865eee6000d5';

/// Whether [bytes] are one of Esri's static "no data here" placeholder tiles.
///
/// Esri answers HTTP 200 with a real image for missing detail zooms, so magic
/// bytes alone can't filter them — without this check the precache would
/// store (and the map would render) "Map data not yet available" instead of
/// falling back to lower-res cached imagery. Exact SHA-256 match, so real
/// imagery never false-positives; worst case if Esri ever redesigns the
/// placeholder is the old behaviour (placeholder shown).
bool isEsriPlaceholderTile(Uint8List bytes) {
  if (bytes.length != 2521 && bytes.length != 2421) return false;
  final digest = sha256.convert(bytes).toString();
  return digest == _imageryPlaceholderSha256 ||
      digest == _streetPlaceholderSha256;
}

/// Valid, storable tile bytes: decodable image magic and not an Esri
/// no-data placeholder.
bool isUsableTileBytes(Uint8List bytes) =>
    looksLikeImage(bytes) && !isEsriPlaceholderTile(bytes);

/// Stores [bytes] in flutter_map's shared disk cache for 30 days.
/// Best-effort: cache write failures are swallowed.
Future<void> putTileCached(String url, Uint8List bytes) async {
  final cache = BuiltInMapCachingProvider.getOrCreateInstance();
  if (!cache.isSupported) return;
  try {
    await cache.putTile(
      url: url,
      metadata: CachedMapTileMetadata(
        staleAt: DateTime.timestamp().add(AppConfig.tileCacheTtl),
        lastModified: null,
        etag: null,
      ),
      bytes: bytes,
    );
  } catch (_) {
    // Cache write failure is non-fatal; the tile still displays.
  }
}
