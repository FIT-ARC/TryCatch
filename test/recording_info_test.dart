import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/screens/recording_info.dart';

Future<RecordingInfo> _file(Directory dir, String name) async {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(const [1, 2, 3]);
  final stat = await file.stat();
  return RecordingInfo(path: file.path, sizeBytes: 3, modified: stat.modified);
}

void main() {
  group('RecordingInfo.renameTo', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('rename_test_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('renames and adds the .bin suffix', () async {
      final info = await _file(dir, 'a.bin');
      final next = await info.renameTo('b');
      expect(next.endsWith('b.bin'), isTrue);
      expect(await File(next).exists(), isTrue);
      expect(await File(info.path).exists(), isFalse);
    });

    test('same name is a no-op', () async {
      final info = await _file(dir, 'a.bin');
      expect(await info.renameTo('a.bin'), info.path);
      expect(await info.renameTo('a'), info.path);
    });

    test('refuses existing files and bare names', () async {
      final info = await _file(dir, 'a.bin');
      await _file(dir, 'b.bin');
      expect(() => info.renameTo('b.bin'), throwsStateError);
      expect(() => info.renameTo('  '), throwsStateError);
      expect(() => info.renameTo('../evil'), throwsStateError);
    });

    test('bundled recordings are read-only', () async {
      final info = RecordingInfo(
        path: 'assets/recordings/sample.bin',
        sizeBytes: 1,
        modified: DateTime(2026),
        origin: RecordingOrigin.bundled,
      );
      expect(info.isBundled, isTrue);
      expect(info.name, 'sample.bin');
      expect(() => info.renameTo('other'), throwsStateError);
      await info.delete(); // No-op, never touches the asset.
    });
  });

  group('groupRecordingsByDay', () {
    RecordingInfo at(DateTime modified) => RecordingInfo(
      path: '/x/${modified.millisecondsSinceEpoch}.bin',
      sizeBytes: 0,
      modified: modified,
    );

    test('groups newest day first, keeps within-day order', () {
      final now = DateTime(2026, 9, 27, 12);
      final list = [
        at(DateTime(2026, 9, 27, 10)),
        at(DateTime(2026, 9, 27, 9)),
        at(DateTime(2026, 9, 26, 23)),
        at(DateTime(2026, 9, 20, 8)),
      ];
      final grouped = groupRecordingsByDay(list);
      expect(grouped.keys.toList(), [
        DateTime(2026, 9, 27),
        DateTime(2026, 9, 26),
        DateTime(2026, 9, 20),
      ]);
      expect(grouped[DateTime(2026, 9, 27)]!.length, 2);
      expect(recordingDayLabel(DateTime(2026, 9, 27), now), 'Today');
      expect(recordingDayLabel(DateTime(2026, 9, 26), now), 'Yesterday');
      expect(recordingDayLabel(DateTime(2026, 9, 20), now), '20. 9. 2026');
    });
  });
}
