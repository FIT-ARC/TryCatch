import 'package:flutter/foundation.dart' show kDebugMode;

/// Single dev/release switch. Replaces scattered kDebugMode branches.
abstract final class AppFlavor {
  static bool get isDev => kDebugMode;

  static bool isMockPortName(String name) =>
      name == 'MOCK' || name == 'MOCK-BQ' || name == 'MOCK-DC';
}
