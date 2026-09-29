import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/services/flight_trim.dart';

Future<Directory> _tempDir() =>
    Directory.systemTemp.createTemp('rec_header_test');

String _path(Directory dir, String name) =>
    '${dir.path}${Platform.pathSeparator}$name';

/// One wire-valid packet with a 3D fix.
Uint8List _packet({
  required int seq,
  double baro = 0,
  double velDown = -10,
  double lat = 50.0,
  double lon = 14.0,
  bool fix = true,
}) =>
    FrameCodec.encodePacket(TelemetryFrame(
      sequence: seq,
      flags: fix ? FrameFlags.gpsFix : 0,
      latitude: lat,
      longitude: lon,
      baroAltitude: baro,
      velocityUp: -velDown,
    ));

void main() {
  group('RecordingHeader codec', () {
    test('round-trips every field', () async {
      const header = RecordingHeader(
        payloadLength: TelemetryFraming.payloadLength,
        hasLaunchSite: true,
        hasStats: true,
        startMicros: 1700000000000000,
        endMicros: 1700000146360000,
        packetCount: 3660,
        maxBaroAltM: 488.6,
        maxSpeedMps: 73.4,
        maxAccelMps2: 97.1,
        launchLatitude: 49.7994533,
        launchLongitude: 16.6928967,
        launchMslM: 378.4,
        launchName: 'Prague',
        connectorId: 'mock',
      );
      final back = RecordingHeader.decode(header.encode())!;
      expect(back.payloadLength, TelemetryFraming.payloadLength);
      expect(back.hasLaunchSite, isTrue);
      expect(back.hasStats, isTrue);
      expect(back.startMicros, 1700000000000000);
      expect(back.endMicros, 1700000146360000);
      expect(back.durationMs, 146360);
      expect(back.packetCount, 3660);
      expect(back.maxBaroAltM, closeTo(488.6, 0.01));
      expect(back.maxSpeedMps, closeTo(73.4, 0.01));
      expect(back.maxAccelMps2, closeTo(97.1, 0.01));
      expect(back.launchLatitude, closeTo(49.7994533, 1e-7));
      expect(back.launchLongitude, closeTo(16.6928967, 1e-7));
      expect(back.launchMslM, closeTo(378.4, 0.01));
      expect(back.launchName, 'Prague');
      expect(back.launchRef!.name, 'Prague');
      expect(back.connectorId, 'mock');
    });

    test('rejects v2 headers (migrate with the v3 tool)', () async {
      final v2 = ByteData(recordingHeaderLength);
      v2.setUint32(0, recordingMagicV2, Endian.big); // 'TCR2'
      expect(RecordingHeader.decode(v2.buffer.asUint8List()), isNull);
    });

    test('rejects a corrupt connector id', () async {
      const header = RecordingHeader(connectorId: 'mock');
      final corrupt = Uint8List.fromList(header.encode())
        ..[140] ^= 0xFF; // inside the connector-id field
      expect(RecordingHeader.decode(corrupt), isNull);
    });

    test('truncates long names without splitting UTF-8 runes', () async {
      const header = RecordingHeader(
        launchName: 'Příbram launch site — a very long name, way too long',
      );
      final back = RecordingHeader.decode(header.encode())!;
      expect(back.launchName.length, lessThan(header.launchName.length));
      // Valid string round-trip: re-encoding yields identical bytes.
      expect(
        RecordingHeader.decode(back.encode())!.launchName,
        back.launchName,
      );
      expect(back.launchName, startsWith('Příbram'));
    });

    test('rejects corruption, short input and wrong magic', () async {
      const header = RecordingHeader(packetCount: 7);
      final bytes = header.encode();
      expect(RecordingHeader.decode(bytes)!.packetCount, 7);

      final corrupt = Uint8List.fromList(bytes);
      corrupt[30] ^= 0xFF; // flip a bit inside packetCount
      expect(RecordingHeader.decode(corrupt), isNull);

      expect(
        RecordingHeader.decode(bytes.sublist(0, 100)),
        isNull,
      );

      final noMagic = Uint8List.fromList(bytes)..[0] = 0x00;
      expect(RecordingHeader.decode(noMagic), isNull);
    });

    test('body offset skips the header, rejects non-recordings', () async {
      const header = RecordingHeader();
      final headered = [...header.encode(), 1, 2, 3];
      expect(
        recordingBodyOffsetOf(Uint8List.fromList(headered), headered.length),
        recordingHeaderLength,
      );
      final raw = Uint8List.fromList(
          [0x00, 0x06, 0x0E, 0x4E, 0, 0, 0, 0, 0, 0, 0, 55, 1, 2]);
      expect(recordingBodyOffsetOf(raw, raw.length), 0);
      expect(recordingBodyOffsetOf(Uint8List(0), 0), 0);
    });

    test('tryRead returns null for non-recordings and missing files', () async {
      final dir = await _tempDir();
      try {
        final raw = _path(dir, 'body.bin');
        await File(raw).writeAsBytes([1, 2, 3, 4]);
        expect(await tryReadRecordingHeader(raw), isNull);
        expect(
          await tryReadRecordingHeader(_path(dir, 'nope.bin')),
          isNull,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('Recorder header finalize', () {
    test('stop prepends stats + launch site, body stays parseable',
        () async {
      final dir = await _tempDir();
      final recorder = Recorder();
      try {
        final path = _path(dir, 'flight.bin');
        await recorder.start(
          path,
          launch: const LaunchRef(
            latitude: 49.5,
            longitude: 16.5,
            mslM: 378,
            name: 'Test site',
          ),
          connectorId: mockConnector.id,
        );
        recorder.recordBytes(_packet(seq: 1, baro: 100));
        recorder.recordBytes(_packet(seq: 2, baro: 300));
        recorder.recordBytes(_packet(seq: 3, baro: 200, fix: false));
        await recorder.stop();

        final header = (await tryReadRecordingHeader(path))!;
        expect(header.hasStats, isTrue);
        expect(header.hasLaunchSite, isTrue);
        expect(header.payloadLength, TelemetryFraming.payloadLength);
        expect(header.packetCount, 3);
        expect(header.maxBaroAltM, closeTo(300, 0.01));
        expect(header.maxSpeedMps, closeTo(10, 0.01));
        expect(header.startMicros, greaterThan(0));
        expect(header.endMicros, greaterThanOrEqualTo(header.startMicros));
        expect(header.launchLatitude, closeTo(49.5, 1e-7));
        expect(header.launchName, 'Test site');
        expect(header.connectorId, 'mock');

        final frames = await FileParser()
            .parseFile(path, connector: mockConnector)
            .toList();
        expect(
          [for (final f in frames) f.sequence],
          [1, 2, 3],
        );
      } finally {
        await recorder.stop();
        await dir.delete(recursive: true);
      }
    });

    test('finalize stamps the required launch site', () async {
      final dir = await _tempDir();
      final recorder = Recorder();
      try {
        final path = _path(dir, 'flight.bin');
        await recorder.start(
          path,
          launch: const LaunchRef(
            latitude: 49.5,
            longitude: 16.5,
            mslM: 378,
            name: 'Test site',
          ),
          connectorId: mockConnector.id,
        );
        recorder.recordBytes(
            _packet(seq: 1, baro: 50, lat: 50.001, lon: 14.001));
        await recorder.stop();

        final header = (await tryReadRecordingHeader(path))!;
        expect(header.hasLaunchSite, isTrue);
        expect(header.launchLatitude, closeTo(49.5, 1e-7));
        expect(header.launchMslM, closeTo(378, 0.01));
        expect(header.launchName, 'Test site');
      } finally {
        await recorder.stop();
        await dir.delete(recursive: true);
      }
    });

    test('finalize is idempotent', () async {
      final dir = await _tempDir();
      try {
        final path = _path(dir, 'flight.bin');
        await writeRecordingFile(
          path,
          const RecordingHeader(
            payloadLength: TelemetryFraming.payloadLength,
            connectorId: 'mock',
          ),
          [
            RecordingChunk(tsUs: 1000000, payload: _packet(seq: 9, baro: 42)),
          ],
        );

        final first = (await finalizeRecordingFile(
          path,
          launch: const LaunchRef(
            latitude: 1.0,
            longitude: 2.0,
            mslM: 3.0,
            name: 'Pad',
          ),
          connectorId: 'mock',
        ))!;
        expect(first.packetCount, 1);
        expect(first.hasLaunchSite, isTrue);
        expect(first.launchName, 'Pad');
        expect(first.connectorId, 'mock');
        final sizeOnce = await File(path).length();

        final second = (await finalizeRecordingFile(
          path,
          launch: const LaunchRef(
            latitude: 1.0,
            longitude: 2.0,
            mslM: 3.0,
            name: 'Pad',
          ),
          connectorId: 'mock',
        ))!;
        expect(second.packetCount, 1);
        expect(await File(path).length(), sizeOnce);

        final frames = await FileParser()
            .parseFile(path, connector: mockConnector)
            .toList();
        expect(frames.length, 1);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('trim keeps headers', () {
    test('trimmed clip gets fresh stats + propagated launch site', () async {
      final dir = await _tempDir();
      try {
        final src = _path(dir, 'src.bin');
        await writeRecordingFile(
          src,
          const RecordingHeader(
            payloadLength: TelemetryFraming.payloadLength,
            connectorId: 'mock',
          ),
          [
            for (var i = 0; i < 10; i++)
              RecordingChunk(
                tsUs: (1000 + i) * 1000000,
                payload: _packet(seq: i, baro: i * 10.0),
              ),
          ],
        );
        await finalizeRecordingFile(
          src,
          launch: const LaunchRef(
            latitude: 1.0,
            longitude: 2.0,
            mslM: 3.0,
            name: 'Pad',
          ),
          connectorId: 'mock',
        );

        final dst = _path(dir, 'clip.bin');
        final kept = await trimRecording(
          srcPath: src,
          dstPath: dst,
          startMs: 2000,
          endMs: 5000,
        );
        expect(kept, 4);

        final header = (await tryReadRecordingHeader(dst))!;
        expect(header.packetCount, 4);
        expect(header.maxBaroAltM, closeTo(50, 0.01));
        expect(header.launchName, 'Pad');
        expect(header.launchMslM, closeTo(3.0, 0.01));
        expect(header.connectorId, 'mock');

        final chunks = await readRecordingChunks(dst);
        expect(chunks.length, 4);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('readers reject files without a header, even with valid packets',
        () async {
      final dir = await _tempDir();
      try {
        final path = _path(dir, 'body.bin');
        await writeRecordingChunks(path, [
          RecordingChunk(
              tsUs: 1700000000000000, payload: _packet(seq: 1, baro: 5)),
        ]);
        expect(await tryReadRecordingHeader(path), isNull);
        expect(
            await FileParser()
                .parseFile(path, connector: mockConnector)
                .toList(),
            isEmpty);
        expect(
          (await decodeRecordingFrames(path)).isEmpty,
          isTrue,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
