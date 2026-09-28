import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:serial/serial.dart';

import '../core/channel_health.dart';
import './flight_trim.dart';

/// Single owner of recording file I/O + decode (layer 3 service).
///
/// State (`ReplayController`) and UI (`recording_card`, `trim_dialog`,
/// `lab_tab`, `recordings_screen`) must go through here instead of calling
/// `FileParser` / `readRecordingChunks` directly, so chunk framing, header
/// validation and connector decode stay in one place.
///
/// Recordings come from two sources with one decode path: user files on disk
/// and read-only bundled assets under `assets/recordings/`. Assets are
/// decoded from bytes in memory and never copied to disk.
abstract final class RecordingRepository {
  /// Loads a recording in a single pass: header + chunks are read once,
  /// then frames/profile are derived in memory. The trailing
  /// command log is loaded alongside (empty for command-free files).
  ///
  /// The header's [RecordingHeader.connectorId] selects the connector that
  /// decodes the chunk stream; unknown connector ids yield `null` (the
  /// recording needs a connector this build doesn't ship).
  static Future<LoadedRecording?> loadReplay(String path) async {
    final header = await tryReadRecordingHeader(path);
    if (header == null) return null;
    final connector = connectorById(header.connectorId);
    if (connector == null) return null;
    if (header.launchRef == null) return null;
    final chunks = await readRecordingChunks(path);
    if (chunks.isEmpty) return null;
    final commands = await readRecordingCommands(path);
    return _assemble(header, connector, chunks, commands);
  }

  /// [loadReplay] for a bundled asset (bytes in memory, never on disk).
  static Future<LoadedRecording?> loadReplayFromAsset(String assetKey) async {
    final data = decodeRecordingBytes(await readAssetBytes(assetKey));
    if (data == null) return null;
    final connector = connectorById(data.header.connectorId);
    if (connector == null || data.header.launchRef == null) return null;
    return _assemble(data.header, connector, data.chunks, data.commands);
  }

  /// Preview decode for cards/dialogs/lab (reuses `flight_trim` logic).
  static Future<DecodedFlight> decodePreview(String path) =>
      decodeRecordingFrames(path);

  /// [decodePreview] for a bundled asset (bytes in memory, never on disk).
  static Future<DecodedFlight> decodePreviewFromAsset(String assetKey) async =>
      decodeRecordingFramesFromBytes(await readAssetBytes(assetKey));

  /// Raw bytes of a bundled recording asset.
  static Future<Uint8List> readAssetBytes(String assetKey) async {
    final data = await rootBundle.load(assetKey);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// Asset keys of every bundled recording shipped under `assets/recordings/`,
  /// sorted for stable display. Empty when the manifest is unavailable.
  static Future<List<String>> bundledRecordingKeys() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      return manifest
          .listAssets()
          .where((a) => a.startsWith('assets/recordings/') && a.endsWith('.bin'))
          .toList()
        ..sort();
    } catch (_) {
      return const [];
    }
  }

  static LoadedRecording? _assemble(
    RecordingHeader header,
    TelemetryConnector connector,
    List<RecordingChunk> chunks,
    List<SentCommand> commands,
  ) {
    if (chunks.isEmpty) return null;
    final parser = connector.createParser();
    final frames = <TelemetryFrame>[];
    for (final chunk in chunks) {
      frames.addAll(parser.feed(chunk.payload, timestampMs: chunk.tsMs));
    }
    if (frames.isEmpty) return null;
    return LoadedRecording(
      header: header,
      connector: connector,
      frames: frames,
      channelProfile: buildChannelProfile(chunks, connector: connector),
      commands: commands,
    );
  }
}

/// Fully decoded recording for replay (frames drive the ticker, fix
/// chart axes and carry the recording's connector; profile drives the
/// channel-health view, commands drive the commands tile).
class LoadedRecording {
  final RecordingHeader header;

  /// Connector the recording was made with (from the header stamp).
  final TelemetryConnector connector;
  final List<TelemetryFrame> frames;
  final List<ChannelBin> channelProfile;

  /// Operator uplink attempts filed during the recording, oldest first.
  /// Empty for command-free files.
  final List<SentCommand> commands;

  const LoadedRecording({
    required this.header,
    required this.connector,
    required this.frames,
    required this.channelProfile,
    this.commands = const [],
  });
}
