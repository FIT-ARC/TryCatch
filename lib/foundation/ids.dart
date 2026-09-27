/// Single ID generator. Prefixes disambiguate domain in saved JSON.
abstract final class Ids {
  static int _counter = 0;

  static String next([String prefix = 'id']) {
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final c = (_counter++).toRadixString(36);
    return '${prefix}_${t}_$c';
  }

  static void resetForTests() => _counter = 0;
}
