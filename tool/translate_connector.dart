/// Translates a MOCK-framed recording into the Rocket v1 (SegFault) framing.
///
/// The flight's own samples are re-encoded field by field; nothing is
/// invented except what the SegFault wire format itself derives (roll/pitch
/// from the accel vector on decode). Dropped without replacement:
/// horizontal velocity, yaw/heading, GPS altitude — the format has no
/// fields for them. Quantum notes: GPS 1e-5 deg (~1.1 m), altitude and
/// vertical speed 0.1, battery 20 mV, packetId wraps at u8.
///
/// Usage:
/// ```sh
/// dart run tool/translate_connector.dart <mock-input.bin> <segfault-output.bin>
/// ```
/// The output keeps chunk timestamps, launch site and command log of the
/// input; only the bytestream framing and connector stamp change. Inputs
/// are never modified.
library;

import 'dart:io';

import 'package:serial/serial.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
        'Usage: dart run tool/translate_connector.dart <mock-input.bin> <segfault-output.bin>');
    exitCode = 2;
    return;
  }
  final inputPath = args[0];
  final outputPath = args[1];

  final header = await tryReadRecordingHeader(inputPath);
  if (header == null) {
    stderr.writeln('Not a recording: $inputPath');
    exitCode = 2;
    return;
  }
  if (header.connectorId != mockConnector.id) {
    stderr.writeln(
        'Expected a ${mockConnector.id}-framed input, found ${header.connectorId}; refusing.');
    exitCode = 2;
    return;
  }
  final launch = header.launchRef;
  if (launch == null) {
    stderr.writeln('Recording has no launch site; refusing.');
    exitCode = 2;
    return;
  }

  final parser = mockConnector.createParser();
  final frames = <TelemetryFrame>[];
  for (final chunk in await readRecordingChunks(inputPath)) {
    frames.addAll(parser.feed(chunk.payload, timestampMs: chunk.tsMs));
  }
  if (frames.isEmpty) {
    stderr.writeln('No decodable frames.');
    exitCode = 2;
    return;
  }

  final outChunks = <RecordingChunk>[];
  for (final f in frames) {
    outChunks.add(RecordingChunk(
      tsUs: f.receivedAtMs * 1000,
      payload: SegfaultPacketCodec.encodePacket(
        timestampMs: f.receivedAtMs,
        packetId: f.sequence,
        stateFlags: f.fsmStateId,
        accelXMps2: f.accelX,
        accelYMps2: f.accelY,
        accelZMps2: f.accelZ,
        gyroXDps: f.gyroX,
        gyroYDps: f.gyroY,
        gyroZDps: f.gyroZ,
        aglM: f.baroAltitude,
        batteryV: f.batteryVoltage,
        latitude: f.latitude,
        longitude: f.longitude,
        verticalUpMps: f.velocityUp,
        ky024: f.hallRaw,
      ),
    ));
  }

  final commands = await readRecordingCommands(inputPath);
  await writeRecordingFile(
    outputPath,
    RecordingHeader(
      payloadLength: segfaultConnector.framingPayloadLength,
      connectorId: segfaultConnector.id,
    ),
    outChunks,
    commands: commands,
  );
  final finalHeader = await finalizeRecordingFile(
    outputPath,
    launch: launch,
    connectorId: segfaultConnector.id,
    commands: commands,
  );
  if (finalHeader == null) {
    stderr.writeln('Finalize failed.');
    exitCode = 2;
    return;
  }
  stdout.writeln('translated ${frames.length} frames -> $outputPath '
      'packets=${finalHeader.packetCount} '
      'maxAlt=${finalHeader.maxBaroAltM.toStringAsFixed(1)}m');
}
