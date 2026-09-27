import 'package:flutter/foundation.dart';

/// Central log sink. Debug prints in dev, silent in release.
abstract final class AppLog {
  static void warn(String message) {
    if (kDebugMode) debugPrint('[trycatch] $message');
  }
}
