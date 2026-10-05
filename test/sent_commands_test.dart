import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/services/flight_trim.dart';

Future<Directory> _tempDir() =>
    Directory.systemTemp.createTemp('sent_commands_test');

String _path(Directory dir, String name) =>
    '${dir.path}${Platform.pathSeparator}$name';

/// One wire-valid packet with a 3D fix.
Uint8List _packet({required int seq, double baro = 0}) =>
    FrameCodec.encodePacket(TelemetryFrame(
      sequence: seq,
      flags: FrameFlags.gpsFix,
      latitude: 50.0,
      longitude: 14.0,
      baroAltitude: baro,
      velocityUp: 10,
    ));

const _launch = LaunchRef(
  latitude: 49.5,
  longitude: 16.5,
  mslM: 378,
  name: 'Test site',
);

void main() {
  group('SentCommand codec', () {
    test('round-trips every field', () {
      const cmd = SentCommand(
        tsUs: 1700000000000000,
        bytes: [0x54, 0x43, 0x01, 0x00],
        status: CommandStatus.sent,
        source: CommandSource.controlPanel,
      );
      final back = SentCommand.decode(cmd.encode())!;
      expect(back.tsUs, 1700000000000000);
      expect(back.tsMs, 1700000000000);
      expect(back.bytes, [0x54, 0x43, 0x01, 0x00]);
      expect(back.status, CommandStatus.sent);
      expect(back.source, CommandSource.controlPanel);
    });

    test('round-trips failed FSM attempts', () {
      final cmd = SentCommand(
        tsUs: 1700000001000000,
        bytes: Uint8List.fromList(FsmStateCommands.bytesFor(FsmState.ascent)),
        status: CommandStatus.failed,
        source: CommandSource.fsm,
      );
      final back = SentCommand.decode(cmd.encode())!;
      expect(back.status, CommandStatus.failed);
      expect(back.source, CommandSource.fsm);
      expect(back.bytes, [0x54, 0x43, 0x07, 0x02]);
    });

    test('rejects short records and nonzero reserved bytes', () {
      expect(SentCommand.decode(Uint8List(15)), isNull);
      final cmd = SentCommand(tsUs: 1, bytes: [1, 2, 3, 4]).encode();
      final corrupt = Uint8List.fromList(cmd)..[15] = 0xFF;
      expect(SentCommand.decode(corrupt), isNull);
    });

    test('wire values default safely', () {
      expect(CommandStatus.fromValue(0), CommandStatus.sent);
      expect(CommandStatus.fromValue(99), CommandStatus.failed);
      expect(CommandSource.fromValue(1), CommandSource.controlPanel);
      expect(CommandSource.fromValue(2), CommandSource.fsm);
      expect(CommandSource.fromValue(99), CommandSource.unknown);
    });
  });

  group('describeCommand', () {
    test('resolves the mock catalog', () {
      final arm = mockConnector.describeCommand([0x54, 0x43, 0x01, 0x00]);
      expect(arm.label, 'Arm');
      expect(arm.danger, isTrue);

      final beep = mockConnector.describeCommand([0x54, 0x43, 0x05, 0x00]);
      expect(beep.label, 'Beep');
      expect(beep.danger, isFalse);
    });

    test('resolves FSM set-state commands', () {
      final set = mockConnector
          .describeCommand(FsmStateCommands.bytesFor(FsmState.ascent));
      expect(set.label, 'Set Ascent');
      expect(set.danger, isFalse);
    });

    test('falls back for unknown frames', () {
      expect(mockConnector.describeCommand([0x54, 0x43, 0x09, 0x00]).label,
          'Unknown command');
      // Well-formed set-state prefix but unmapped state id.
      expect(mockConnector.describeCommand([0x54, 0x43, 0x07, 0x42]).label,
          'Unknown command');
    });

    test('mock connector resolves its catalog the same way', () {
      expect(
        mockConnector.describeCommand([0x54, 0x43, 0x01, 0x00]).label,
        'Arm',
      );
      expect(
        mockConnector.describeCommand(mockConnector.bytesForState(2)!).label,
        'Set Ascent',
      );
      expect(
        mockConnector.describeCommand([0x54, 0x43, 0x09, 0x00]).label,
        'Unknown command',
      );
    });
  });

  group('v3 header section directory', () {
    test('round-trips the directory + connector id', () {
      const header = RecordingHeader(
        payloadLength: TelemetryFraming.payloadLength,
        hasLaunchSite: true,
        hasStats: true,
        packetCount: 12,
        telemetryByteLen: 1234,
        commandsOffset: 1370,
        commandCount: 3,
        connectorId: 'mock',
      );
      final back = RecordingHeader.decode(header.encode())!;
      expect(back.telemetryByteLen, 1234);
      expect(back.commandsOffset, 1370);
      expect(back.commandCount, 3);
      expect(back.packetCount, 12);
      expect(back.connectorId, 'mock');
    });

    test('rejects v1/v2 magic and corrupt CRCs', () {
      // v1-style header: old magic, valid body CRC, padded to v3 length.
      final v1 = ByteData(recordingHeaderLength);
      v1.setUint32(0, 0x54435243, Endian.big); // 'TCRC'
      v1.setUint16(4, TelemetryFraming.payloadLength, Endian.big);
      v1.setUint16(104, crc16CCITT(v1.buffer.asUint8List(), 0, 104),
          Endian.big);
      expect(
          RecordingHeader.decode(v1.buffer.asUint8List()), isNull);

      // v2 magic is equally rejected (migrate with the v3 tool).
      final v2magic = ByteData(recordingHeaderLength);
      v2magic.setUint32(0, recordingMagicV2, Endian.big); // 'TCR2'
      expect(
          RecordingHeader.decode(v2magic.buffer.asUint8List()), isNull);

      final v3 = const RecordingHeader(
        payloadLength: TelemetryFraming.payloadLength,
        connectorId: 'mock',
      ).encode();
      final corruptDir = Uint8List.fromList(v3)..[115] ^= 0xFF;
      expect(RecordingHeader.decode(corruptDir), isNull);
      final corruptConnector = Uint8List.fromList(v3)..[140] ^= 0xFF;
      expect(RecordingHeader.decode(corruptConnector), isNull);
      final corruptBody = Uint8List.fromList(v3)..[30] ^= 0xFF;
      expect(RecordingHeader.decode(corruptBody), isNull);
    });
  });

  group('command section file I/O', () {
    test('write/read round-trips telemetry + commands', () async {
      final dir = await _tempDir();
      try {
        final path = _path(dir, 'flight.bin');
        final chunks = [
          RecordingChunk(tsUs: 1000000, payload: _packet(seq: 1, baro: 10)),
          RecordingChunk(tsUs: 2000000, payload: _packet(seq: 2, baro: 20)),
        ];
        final commands = [
          const SentCommand(
            tsUs: 1500000,
            bytes: [0x54, 0x43, 0x01, 0x00],
            source: CommandSource.controlPanel,
          ),
          SentCommand(
            tsUs: 1800000,
            bytes:
                Uint8List.fromList(FsmStateCommands.bytesFor(FsmState.armed)),
            status: CommandStatus.failed,
            source: CommandSource.fsm,
          ),
        ];
        await writeRecordingFile(
          path,
          const RecordingHeader(
            payloadLength: TelemetryFraming.payloadLength,
            connectorId: 'mock',
          ),
          chunks,
          commands: commands,
        );

        final header = (await tryReadRecordingHeader(path))!;
        expect(header.commandCount, 2);
        expect(header.commandsOffset,
            recordingHeaderLength + header.telemetryByteLen);
        expect(header.telemetryByteLen, greaterThan(0));

        final backChunks = await readRecordingChunks(path);
        expect(backChunks.length, 2);

        final backCommands = await readRecordingCommands(path);
        expect(backCommands.length, 2);
        expect(backCommands[0].tsUs, 1500000);
        expect(backCommands[0].bytes, [0x54, 0x43, 0x01, 0x00]);
        expect(backCommands[0].source, CommandSource.controlPanel);
        expect(backCommands[1].status, CommandStatus.failed);

        // The telemetry parser never sees command bytes.
        final frames =
            await FileParser().parseFile(path, connector: mockConnector).toList();
        expect(
          [for (final f in frames) f.sequence],
          [1, 2],
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('recorder files attempts on stop', () async {
      final dir = await _tempDir();
      final recorder = Recorder();
      try {
        final path = _path(dir, 'flight.bin');
        await recorder.start(path, launch: _launch, connectorId: 'mock');
        recorder.recordBytes(_packet(seq: 1, baro: 100));
        recorder.recordCommand(const SentCommand(
          tsUs: 1700000000000000,
          bytes: [0x54, 0x43, 0x01, 0x00],
          source: CommandSource.controlPanel,
        ));
        recorder.recordCommand(SentCommand(
          tsUs: 1700000001000000,
          bytes: Uint8List.fromList([0x54, 0x43, 0x02, 0x00]),
          status: CommandStatus.failed,
          source: CommandSource.controlPanel,
        ));
        await recorder.stop();

        final header = (await tryReadRecordingHeader(path))!;
        expect(header.hasStats, isTrue);
        expect(header.commandCount, 2);
        final commands = await readRecordingCommands(path);
        expect(commands.length, 2);
        expect(commands[1].status, CommandStatus.failed);
      } finally {
        await recorder.stop();
        await dir.delete(recursive: true);
      }
    });

    test('finalize preserves commands when replacing nothing', () async {
      final dir = await _tempDir();
      try {
        final path = _path(dir, 'flight.bin');
        await writeRecordingFile(
          path,
          const RecordingHeader(
            payloadLength: TelemetryFraming.payloadLength,
            connectorId: 'mock',
          ),
          [RecordingChunk(tsUs: 1000000, payload: _packet(seq: 9, baro: 42))],
          commands: const [
            SentCommand(
              tsUs: 1000500,
              bytes: [0x54, 0x43, 0x05, 0x00],
            ),
          ],
        );
        final first = (await finalizeRecordingFile(path,
            launch: _launch, connectorId: 'mock'))!;
        expect(first.packetCount, 1);
        expect(first.commandCount, 1);
        expect(first.connectorId, 'mock');

        // Re-finalizing without an explicit list keeps the filed commands.
        final second = (await finalizeRecordingFile(path,
            launch: _launch, connectorId: 'mock'))!;
        expect(second.commandCount, 1);
        expect(await readRecordingCommands(path), hasLength(1));

        // An explicit list replaces the section.
        final third = (await finalizeRecordingFile(path,
            launch: _launch, connectorId: 'mock', commands: const []))!;
        expect(third.commandCount, 0);
        expect(await readRecordingCommands(path), isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('trim slices the command log to the window', () async {
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
          commands: const [
            // Before the window (t0 - 1 s).
            SentCommand(tsUs: 999000000, bytes: [0x54, 0x43, 0x01, 0x00]),
            // Inside 2000..5000 ms.
            SentCommand(tsUs: 1002500000, bytes: [0x54, 0x43, 0x01, 0x00]),
            SentCommand(tsUs: 1004500000, bytes: [0x54, 0x43, 0x05, 0x00]),
            // After the window.
            SentCommand(tsUs: 1008000000, bytes: [0x54, 0x43, 0x02, 0x00]),
          ],
        );
        await finalizeRecordingFile(src, launch: _launch, connectorId: 'mock');

        final dst = _path(dir, 'clip.bin');
        final kept = await trimRecording(
          srcPath: src,
          dstPath: dst,
          startMs: 2000,
          endMs: 5000,
        );
        expect(kept, 4);

        final header = (await tryReadRecordingHeader(dst))!;
        expect(header.commandCount, 2);
        final commands = await readRecordingCommands(dst);
        expect(
          [for (final c in commands) c.tsUs],
          [1002500000, 1004500000],
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
