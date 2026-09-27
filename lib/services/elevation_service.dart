import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter_map/flutter_map.dart'
    show BuiltInMapCachingProvider, CachedMapTileMetadata;

import '../core/app_config.dart';
import '../core/elevation_math.dart'
    show
        demTileUrl,
        elevationPixelX,
        elevationPixelY,
        elevationTileX,
        elevationTileY,
        terrariumHeight;

/// Lightweight MSL elevation look-up using the same AWS Terrarium tiles as
/// the 3D satellite view (zoom 12, ≈24 m/px at 50° lat — well within the
/// precision needed for a dead-reckoning ground-collision clamp).
///
/// ### Cache behaviour
/// 1. Checks flutter_map's shared disk cache first — preloaded launch sites
///    ([precacheLaunchSites]) already include z=12 DEM tiles, so field
///    sessions never hit the network.
/// 2. On a miss, fetches the single tile from AWS S3 (no key required) and
///    writes it back to the shared disk cache so the next session is warm.
/// 3. Decoded tile bytes are kept in a per-session memory cache — repeated
///    queries over the same ≈6 km tile area (typical for a model rocket
///    flight) are instant after the first resolve.
///
/// Returns `null` on any failure; the caller falls back to the GPS-minimum
/// heuristic.

// ── In-memory tile cache ─────────────────────────────────────────────────────

// Keyed by "$zoom/$x/$y" → decoded RGBA bytes of the 256×256 tile.
// Futures are stored so concurrent queries for the same tile coalesce.
// Bounded: failures are not cached, oldest entries evicted past 128.
final Map<String, Future<Uint8List?>> _pixelCache = {};

Future<Uint8List?> _loadTilePixels(int tx, int ty) async {
  const zoom = 12; // matches the 3D DEM zoom
  final url = demTileUrl(tx, ty, zoom);

  Uint8List? rawBytes;

  // 1. Disk cache (shared with the 3D view and the map precacher). Cache
  // creation itself can throw on platforms without a backing store — treat
  // that as "no disk cache", not a fatal error (the network path below
  // still applies).
  BuiltInMapCachingProvider? cache;
  try {
    cache = BuiltInMapCachingProvider.getOrCreateInstance();
  } catch (_) {
    cache = null;
  }
  if (cache != null && cache.isSupported) {
    try {
      final hit = await cache.getTile(url);
      if (hit != null && hit.bytes.isNotEmpty) rawBytes = hit.bytes;
    } catch (_) {
      // Corrupt entry — fall through to a fresh download.
    }
  }

  // 2. Network fetch.
  if (rawBytes == null) {
    try {
      final client = HttpClient();
      client.connectionTimeout = AppConfig.tileConnectionTimeout;
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('User-Agent', AppConfig.tileUserAgent);
        final response =
            await request.close().timeout(AppConfig.tileResponseTimeout);
        if (response.statusCode == 200) {
          final bytes = await consolidateHttpClientResponseBytes(response);
          if (bytes.isNotEmpty) rawBytes = bytes;
        }
      } finally {
        client.close();
      }
    } catch (_) {
      return null;
    }

    // Write back to disk cache (same TTL as map tiles) so future sessions hit.
    if (rawBytes != null && cache != null && cache.isSupported) {
      try {
        await cache.putTile(
          url: url,
          metadata: CachedMapTileMetadata(
            staleAt: DateTime.timestamp().add(AppConfig.tileCacheTtl),
            lastModified: null,
            etag: null,
          ),
          bytes: rawBytes,
        );
      } catch (_) {
        // Non-fatal — we still have the bytes in memory.
      }
    }
  }

  if (rawBytes == null) return null;

  // Decode PNG → raw RGBA so we can read individual pixel values.
  try {
    final codec = await ui.instantiateImageCodec(rawBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// Returns the MSL elevation (metres) at [lat]/[lon], or `null` on failure.
///
/// One z=12 Terrarium tile covers ≈6 km at 50° lat (≈24 m/px) — adequate
/// for a ground-collision clamp.  The result reflects absolute terrain height
/// above the WGS84 geoid; for model rockets that fly a few km this is
/// virtually identical to the GPS altitude datum.
///
/// The tile is fetched at most once per session (memory-cached); subsequent
/// calls inside the same ≈6 km tile area are synchronous after the first
/// resolve.
Future<double?> elevationMsl(double lat, double lon) async {
  const zoom = 12;
  final tx = elevationTileX(lon, zoom);
  final ty = elevationTileY(lat, zoom);
  final key = '$zoom/$tx/$ty';

  var future = _pixelCache[key];
  future ??= _loadTilePixels(tx, ty).then((pixels) {
    if (pixels == null) {
      _pixelCache.remove(key);
      return null;
    }
    if (_pixelCache.length > 128) {
      _pixelCache.remove(_pixelCache.keys.first);
    }
    return pixels;
  });
  _pixelCache[key] = future;
  final pixels = await future;
  if (pixels == null) return null;

  final px = elevationPixelX(lon, zoom, tx);
  final py = elevationPixelY(lat, zoom, ty);

  final i = (py * 256 + px) * 4;
  if (i + 2 >= pixels.length) return null;

  return terrariumHeight(pixels[i], pixels[i + 1], pixels[i + 2]);
}
