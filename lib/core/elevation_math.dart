/// Pure Terrarium DEM tile helpers (data in, data out).
///
/// Shared by the 3D satellite drape and its tile precache, so the URL and
/// pixel decode stay one implementation.
library;

/// Decodes one Terrarium pixel to metres above sea level.
double terrariumHeight(int r, int g, int b) =>
    r * 256.0 + g + b / 256.0 - 32768.0;

/// AWS Terrain Tiles URL (Terrarium encoding, no API key).
String demTileUrl(int x, int y, int z) =>
    'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/$z/$x/$y.png';
