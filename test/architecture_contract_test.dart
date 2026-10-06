import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  Iterable<File> dartFiles(String path) =>
      Directory(path)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
  test('state does not import UI or re-export neighboring state', () {
    for (final file in dartFiles('lib/state')) {
      final source = file.readAsStringSync();
      expect(
        RegExp(r'''import\s+['"][^'"]*/ui/''').hasMatch(source),
        isFalse,
        reason: file.path,
      );
      expect(
        RegExp(r"^export\s", multiLine: true).hasMatch(source),
        isFalse,
        reason: file.path,
      );
    }
  });
  test('UI uses theme colors and chronological series access', () {
    for (final file in dartFiles('lib/ui')) {
      final source = file.readAsStringSync();
      expect(
        RegExp(r'(?<![a-zA-Z])Colors\.').hasMatch(source),
        isFalse,
        reason: file.path,
      );
      expect(source.contains('.getChronological('), isFalse, reason: file.path);
    }
  });
}
