/// Re-anchors a converter-synthesized recording onto true wall time.
///
/// Legacy `.bin` files converted from `flight_data.js` carry a fabricated
/// clock (exact 40 ms grid from a round hour) with resampled duplicates.
/// Given the OG packet log (UTC receipt times + decoded fields), this tool:
///   1. picks the flight session (highest max altitude),
///   2. anchors each distinct file sample to log rows by trajectory match,
///   3. re-times every frame by piecewise interpolation (no more metronome),
///   4. collapses duplicate runs and optionally prepends pre-launch pad rows
///      the file never covered,
///   5. rewrites chunks + header stats, preserving the command log.
///
/// Usage:
/// ```sh
/// dart run tool/recorrect_times.dart <input.bin> <output.bin> <log.csv>
///     [--no-prepend] [--list-sessions]
/// ```
/// `--list-sessions` only prints the CSV sessions and exits. Outputs are
/// written to a NEW file; inputs are never modified.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:serial/serial.dart';

import 'package:trycatch/services/time_correction.dart';

const _matchThreshold = 30.0;
const _flightBoxLat = 0.02;
const _flightBoxLon = 0.02;

/// OG sensor scales (same firmware the SegFault codec documents).
const _gPerLsb = 1 / 2048.0;
const _gravity = 9.80665;
const _dpsPerLsb = 16.4;

class _Row {
  final DateTime time;
  final double lat;
  final double lon;
  final double alt;
  final double battery;
  final String fsm;
  final double roll;
  final double pitch;
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final double valt;
  final int ky;
  final int pid;
  final int tms;
  final bool hasFix;

  _Row(
    this.time,
    this.lat,
    this.lon,
    this.alt,
    this.battery,
    this.fsm,
    this.roll,
    this.pitch, {
    this.ax = 0,
    this.ay = 0,
    this.az = 2048,
    this.gx = 0,
    this.gy = 0,
    this.gz = 0,
    this.valt = 0,
    this.ky = 0,
    this.pid = 0,
    this.tms = 0,
    this.hasFix = true,
  });
}

double? _num(String s) => double.tryParse(s);

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final flags = args.where((a) => a.startsWith('--')).toSet();
  if (positional.length < 3 && !flags.contains('--list-sessions')) {
    stderr.writeln(
        'Usage: dart run tool/recorrect_times.dart <input.bin> <output.bin> <log.csv> [--no-prepend] [--list-sessions]');
    exitCode = 2;
    return;
  }

  final csvPath = flags.contains('--list-sessions')
      ? positional.first
      : positional[2];
  final sessions = await _readSessions(csvPath);
  if (flags.contains('--list-sessions')) {
    for (var i = 0; i < sessions.length; i++) {
      final s = sessions[i];
      final alts = [for (final r in s) r.alt];
      stdout.writeln('session $i: n=${s.length} '
          '${s.first.time.toIso8601String()} -> ${s.last.time.toIso8601String()} '
          'alt=[${alts.reduce(math.min).toStringAsFixed(1)},'
          '${alts.reduce(math.max).toStringAsFixed(1)}]');
    }
    return;
  }

  final inputPath = positional[0];
  final outputPath = positional[1];
  final prepend = !flags.contains('--no-prepend');

  // Overwrites must not depend on OS rename-over-existing semantics
  // (finalize swaps a tmp file into place): clear first.
  final existing = File(outputPath);
  if (await existing.exists()) {
    await existing.delete();
    stdout.writeln('removed previous $outputPath');
  }

  // Flight session = highest max altitude.
  sessions.sort((a, b) => _maxAlt(b).compareTo(_maxAlt(a)));
  final flight = sessions.first;
  stdout.writeln('flight session: n=${flight.length} '
      '${flight.first.time.toIso8601String()} -> '
      '${flight.last.time.toIso8601String()}');

  final header = await tryReadRecordingHeader(inputPath);
  if (header == null) {
    stderr.writeln('Not a recording: $inputPath');
    exitCode = 2;
    return;
  }
  final launch = header.launchRef;
  if (launch == null) {
    stderr.writeln('Recording has no launch site; refusing.');
    exitCode = 2;
    return;
  }
  final connector = connectorById(header.connectorId) ?? mockConnector;
  final parser = connector.createParser();
  final chunks = await readRecordingChunks(inputPath);
  final frames = <TelemetryFrame>[];
  for (final chunk in chunks) {
    frames.addAll(parser.feed(chunk.payload, timestampMs: chunk.tsMs));
  }
  if (frames.isEmpty) {
    stderr.writeln('No decodable frames.');
    exitCode = 2;
    return;
  }
  stdout.writeln('decoded ${frames.length} frames, '
      'grid span ${(frames.first.receivedAtMs / 1000).round()}s -> '
      '${(frames.last.receivedAtMs / 1000).round()}s');

  // Distinct samples (collapse runs later; anchors need distinct indices).
  final distinctIdx = <int>[];
  for (var k = 0; k < frames.length; k++) {
    if (k == 0 || !_sameSample(frames[k - 1], frames[k])) {
      distinctIdx.add(k);
    }
  }
  stdout.writeln('distinct samples: ${distinctIdx.length}');

  // Anchors by trajectory match.
  final rawAnchors = <TimeAnchor>[];
  for (final row in flight) {
    var best = double.infinity;
    var bestGrid = -1;
    for (final k in distinctIdx) {
      final f = frames[k];
      final dLat = (row.lat - f.latitude) * 111000;
      final dLon = (row.lon - f.longitude) * 88000;
      final dAlt = row.alt - f.baroAltitude;
      final d = math.sqrt(dAlt * dAlt + dLat * dLat + dLon * dLon);
      if (d < best) {
        best = d;
        bestGrid = f.receivedAtMs;
      }
    }
    if (best <= _matchThreshold) {
      rawAnchors.add(TimeAnchor(bestGrid, row.time.millisecondsSinceEpoch));
    }
  }
  // Anchors arrive in log time order already (flight rows sorted).
  final anchors = enforceMonotonic(rawAnchors);
  stdout.writeln('anchors: ${rawAnchors.length} kept ${anchors.length} '
      '(dropped ${rawAnchors.length - anchors.length})');
  if (anchors.length < 2) {
    stderr.writeln('Too few anchors; refusing.');
    exitCode = 2;
    return;
  }

  // Re-time + collapse runs, keeping first-of-run.
  final retimed = <TelemetryFrame>[];
  TelemetryFrame? prev;
  for (final f in frames) {
    final t = mapGridToTrue(anchors, f.receivedAtMs);
    if (prev != null && _sameSample(prev, f)) continue;
    final nf = _withTime(f, t);
    retimed.add(nf);
    prev = f;
  }
  stdout.writeln('collapsed to ${retimed.length} frames '
      '(${(100 * (frames.length - retimed.length) / frames.length).toStringAsFixed(1)}% duplicates)');

  // Prepend pad prologue when the file starts at launch. Every value is
  // measured: dynamics use the OG raw scales (verified 1 g at rest).
  var prepended = 0;
  if (prepend && (frames.first.fsmStateId == 0 || frames.first.fsmStateId == 1)) {
    final liftoff = _liftoffTrueMs(retimed);
    final prologue = selectPadPrologue(
      [
        for (final sessionsRow in sessions)
          for (final r in sessionsRow)
            CsvSiteSample(
              trueMs: r.time.millisecondsSinceEpoch,
              latitude: r.lat,
              longitude: r.lon,
              baroAltitude: r.alt,
              batteryVoltage: r.battery,
              fsm: r.fsm,
              rollDeg: r.roll,
              pitchDeg: r.pitch,
              accelX: r.ax * _gPerLsb * _gravity,
              accelY: r.ay * _gPerLsb * _gravity,
              accelZ: r.az * _gPerLsb * _gravity,
              gyroX: r.gx / _dpsPerLsb,
              gyroY: r.gy / _dpsPerLsb,
              gyroZ: r.gz / _dpsPerLsb,
              velocityDown: -r.valt,
              hallRaw: r.ky.round(),
              packetId: r.pid,
              wireTimestampMs: r.tms & 0xFFFF,
              hasFix: r.hasFix,
            ),
      ],
      liftoff,
    );
    final built = <TelemetryFrame>[];
    for (var i = 0; i < prologue.length; i++) {
      final fsmId = ogFsmToMock(prologue[i].fsm);
      if (fsmId == null) continue;
      built.add(padFrameFrom(
        row: prologue[i],
        sequence: -1, // resequenced below
        fsmStateId: fsmId,
      ));
    }
    prepended = built.length;
    if (built.isNotEmpty) {
      // Clean splice: prologue rows at/after the first mapped frame time
      // would share (or invert) a timestamp with it — drop them. They are
      // redundant pad samples milliseconds from the boundary either way.
      final boundary = retimed.first.receivedAtMs;
      built.removeWhere((f) => f.receivedAtMs >= boundary);
      prepended = built.length;
    }
    retimed.insertAll(0, built);
    stdout.writeln('prepended $prepended pad frames back to '
        '${DateTime.fromMillisecondsSinceEpoch(retimed.first.receivedAtMs, isUtc: true).toIso8601String()}');
  } else if (prepend) {
    stdout.writeln('prepend skipped: file does not start at launch '
        '(first fsm=${frames.first.fsmStateId}).');
  }

  // Resequence + rechunk one frame per chunk.
  for (var i = 0; i < retimed.length; i++) {
    retimed[i] = _withSeq(retimed[i], i);
  }
  final outChunks = [
    for (final f in retimed)
      RecordingChunk(
          tsUs: f.receivedAtMs * 1000,
          payload: FrameCodec.encodePacket(f)),
  ];

  final commands = await readRecordingCommands(inputPath);
  stdout.writeln('preserved ${commands.length} filed commands.');
  await writeRecordingFile(
    outputPath,
    RecordingHeader(
      payloadLength: connector.framingPayloadLength,
      connectorId: header.connectorId,
    ),
    outChunks,
    commands: commands,
  );
  final finalHeader = await finalizeRecordingFile(
    outputPath,
    launch: launch,
    connectorId: header.connectorId,
    commands: commands,
  );
  if (finalHeader == null) {
    stderr.writeln('Finalize failed.');
    exitCode = 2;
    return;
  }
  stdout.writeln('wrote $outputPath: ${retimed.length} frames, '
      '${finalHeader.packetCount} packets, '
      'start=${DateTime.fromMicrosecondsSinceEpoch(finalHeader.startMicros, isUtc: true).toIso8601String()} '
      'end=${DateTime.fromMicrosecondsSinceEpoch(finalHeader.endMicros, isUtc: true).toIso8601String()} '
      'maxAlt=${finalHeader.maxBaroAltM.toStringAsFixed(1)}m');
}

bool _sameSample(TelemetryFrame a, TelemetryFrame b) =>
    a.latitude == b.latitude &&
    a.longitude == b.longitude &&
    a.baroAltitude == b.baroAltitude;

TelemetryFrame _withTime(TelemetryFrame f, int ms) => TelemetryFrame(
      receivedAtMs: ms,
      flags: f.flags,
      sequence: f.sequence,
      latitude: f.latitude,
      longitude: f.longitude,
      gpsAltitude: f.gpsAltitude,
      baroAltitude: f.baroAltitude,
      velocityNorth: f.velocityNorth,
      velocityEast: f.velocityEast,
      velocityDown: f.velocityDown,
      accelX: f.accelX,
      accelY: f.accelY,
      accelZ: f.accelZ,
      gyroX: f.gyroX,
      gyroY: f.gyroY,
      gyroZ: f.gyroZ,
      heading: f.heading,
      roll: f.roll,
      pitch: f.pitch,
      yaw: f.yaw,
      batteryVoltage: f.batteryVoltage,
      hallRaw: f.hallRaw,
      fsmStateId: f.fsmStateId,
    );

TelemetryFrame _withSeq(TelemetryFrame f, int seq) => TelemetryFrame(
      receivedAtMs: f.receivedAtMs,
      flags: f.flags,
      sequence: seq,
      latitude: f.latitude,
      longitude: f.longitude,
      gpsAltitude: f.gpsAltitude,
      baroAltitude: f.baroAltitude,
      velocityNorth: f.velocityNorth,
      velocityEast: f.velocityEast,
      velocityDown: f.velocityDown,
      accelX: f.accelX,
      accelY: f.accelY,
      accelZ: f.accelZ,
      gyroX: f.gyroX,
      gyroY: f.gyroY,
      gyroZ: f.gyroZ,
      heading: f.heading,
      roll: f.roll,
      pitch: f.pitch,
      yaw: f.yaw,
      batteryVoltage: f.batteryVoltage,
      hallRaw: f.hallRaw,
      fsmStateId: f.fsmStateId,
    );

double _maxAlt(List<_Row> s) {
  var m = double.negativeInfinity;
  for (final r in s) {
    if (r.alt > m) m = r.alt;
  }
  return m;
}

/// Liftoff reference: true time of the first ascent frame.
int _liftoffTrueMs(List<TelemetryFrame> frames) {
  for (final f in frames) {
    if (f.fsmStateId == 2) return f.receivedAtMs;
  }
  return frames.first.receivedAtMs;
}

Future<List<List<_Row>>> _readSessions(String csvPath) async {
  final lines = await File(csvPath).readAsLines();
  if (lines.isEmpty) return const [];
  final header = lines.first.split(',');
  int col(String name) {
    final i = header.indexOf(name);
    if (i == -1) throw StateError('missing column $name');
    return i;
  }

  final cRa = col('receivedAt');
  final cLat = col('position_latitude');
  final cLon = col('position_longitude');
  final cAlt = col('barometricAltitude');
  final cBatt = col('batteryVoltage');
  final cFsm = col('fsmState');
  final cRoll = col('orientation_roll');
  final cPitch = col('orientation_pitch');
  final cAx = col('raw_accelX');
  final cAy = col('raw_accelY');
  final cAz = col('raw_accelZ');
  final cGx = col('raw_gyroX');
  final cGy = col('raw_gyroY');
  final cGz = col('raw_gyroZ');
  final cValt = col('velocity_altitude');
  final cKy = col('raw_ky024Analog');
  final cPid = col('packetId');
  final cTms = col('timestampMs');

  final rows = <_Row>[];
  for (var i = 1; i < lines.length; i++) {
    final c = lines[i].split(',');
    if (c.length != header.length) continue;
    final time = DateTime.tryParse(c[cRa].replaceAll('Z', '+00:00'));
    final lat = _num(c[cLat]);
    final lon = _num(c[cLon]);
    final alt = _num(c[cAlt]);
    if (time == null || lat == null || lon == null || alt == null) continue;
    if ((lat - 49.797).abs() > _flightBoxLat ||
        (lon - 16.697).abs() > _flightBoxLon ||
        alt < -50 ||
        alt > 1500) {
      continue;
    }
    int intCol(int ci, int fallback) =>
        int.tryParse(c[ci].trim()) ?? fallback;
    rows.add(_Row(
      time.toUtc(),
      lat,
      lon,
      alt,
      _num(c[cBatt]) ?? 0,
      c[cFsm],
      _num(c[cRoll]) ?? 0,
      _num(c[cPitch]) ?? 0,
      ax: _num(c[cAx]) ?? 0,
      ay: _num(c[cAy]) ?? 0,
      az: _num(c[cAz]) ?? 2048,
      gx: _num(c[cGx]) ?? 0,
      gy: _num(c[cGy]) ?? 0,
      gz: _num(c[cGz]) ?? 0,
      valt: _num(c[cValt]) ?? 0,
      ky: intCol(cKy, 0),
      pid: intCol(cPid, 0),
      tms: intCol(cTms, 0),
      hasFix: c[cLat].trim().isNotEmpty && c[cLon].trim().isNotEmpty,
    ));
  }
  rows.sort((a, b) => a.time.compareTo(b.time));
  final sessions = <List<_Row>>[];
  var cur = <_Row>[];
  for (final r in rows) {
    if (cur.isNotEmpty &&
        r.time.difference(cur.last.time).inSeconds > 60) {
      sessions.add(cur);
      cur = [];
    }
    cur.add(r);
  }
  if (cur.isNotEmpty) sessions.add(cur);
  return sessions;
}
