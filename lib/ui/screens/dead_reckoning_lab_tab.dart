import 'dart:io';
import 'dart:math' as math;

import 'package:dead_reckoning/dead_reckoning.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart' show TelemetryFrame;

import '../../core/dead_reckoning_adapter.dart';
import '../../core/elevation_math.dart';
import '../../core/format.dart';
import '../../core/path_utils.dart';
import '../../services/recording_repository.dart';
import '../../state/dead_reckoning_tune_store.dart';
import '../../session/feedback.dart';
import '../../services/elevation_service.dart';
import '../../state/recording_provider.dart';
import '../../theme/app_colors.dart';
import '../components/app_card.dart';
import '../components/copy_button.dart';
import './dead_reckoning_lab_masks.dart';
import './dead_reckoning_lab_preview.dart';
import './dead_reckoning_manual_dialog.dart';

/// Dead reckoning tuning page: an overview home state plus a short
/// guided wizard.
///
/// Overview is one tune line (copy morphs to apply on paste) with the
/// Generate and Manual doors. The wizard is a left rail (Flight →
/// Results) with live node states; Flight picks the flight and runs the
/// search, Results compares, previews (legend + carousel) and applies.
/// Outages are fully automatic synthetic windows; grounded phases are
/// never scored, and only scored outages preview. Scoring hides GPS
/// fixes inside outage windows and replays every rotated heading of the
/// flight, so one wind direction cannot rig the tune.
class DeadReckoningLabTab extends ConsumerStatefulWidget {
  /// Injected flight for widget tests (skips folder scan + decode).
  final List<DeadReckoningSample>? debugSamples;

  /// Frames parallel to [debugSamples] (FSM phases + flight summary).
  final List<TelemetryFrame>? debugFrames;

  final String? debugName;

  /// Skips tile queries (tests run offline).
  final bool loadTerrain;

  const DeadReckoningLabTab({
    super.key,
    this.debugSamples,
    this.debugFrames,
    this.debugName,
    this.loadTerrain = true,
  });

  @override
  ConsumerState<DeadReckoningLabTab> createState() =>
      _DeadReckoningLabTabState();
}

class _DeadReckoningLabTabState extends ConsumerState<DeadReckoningLabTab> {
  final _tuneController = TextEditingController();
  String? _fieldError;

  /// Whether the tune field holds user-pasted text instead of the live
  /// tune (drives the copy → apply button morph; guards the live sync).
  bool _tuneEdited = false;

  // Guided position. The wizard is entered from the overview via
  // [Generate new tune]; applying returns to the overview.
  _LabStep _step = _LabStep.flight;
  bool _wizardActive = false;

  /// Page scroll: reset to the top on every step change so the rail and
  /// the step content stay in place instead of inheriting a deep offset.
  final _scrollController = ScrollController();

  // Flight section.
  Future<List<_LabRecording>>? _recordingsFuture;
  String? _selectedPath;
  String _selectedName = '';
  List<DeadReckoningSample>? _samples;
  List<TelemetryFrame>? _frames;
  bool _loading = false;
  String? _loadError;

  // Run state.
  bool _working = false;
  bool _cancel = false;
  String _status = '';
  double? _progress;

  // Results section.
  DeadReckoningTune? _newTune;

  /// Rotation-averaged, duration-weighted mean horizontal miss in metres,
  /// current vs candidate. Compared directly (lower wins) — no unit-free
  /// scores. Short windows weigh more per second of outage.
  double? _currentMeanM;
  double? _newMeanM;
  double? _currentVertical;
  double? _newVertical;
  List<OutagePreview> _previews = const [];
  int _previewIndex = 0;
  String? _resultNote;
  bool get _hasResults => _newTune != null || _appliedSummary != null;

  /// Short description of the last applied tune, kept so the card
  /// confirms what happened instead of going blank.
  String? _appliedSummary;

  @override
  void initState() {
    super.initState();
    if (widget.debugSamples != null) {
      _samples = widget.debugSamples;
      _frames = widget.debugFrames ?? const [];
      _selectedName = widget.debugName ?? 'test flight';
    } else {
      _recordingsFuture = _listRecordings();
    }
  }

  @override
  void dispose() {
    _tuneController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<List<_LabRecording>> _listRecordings() async {
    final dirPath = await ref.read(recordingsDirectoryProvider.future);
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.bin')) files.add(entity);
    }
    final mtimes = <File, DateTime>{};
    for (final file in files) {
      try {
        mtimes[file] = await file.lastModified();
      } catch (_) {
        mtimes[file] = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    files.sort((a, b) => mtimes[b]!.compareTo(mtimes[a]!));
    return [
      for (final file in files)
        _LabRecording(file.path, basename(file.path)),
    ];
  }

  /// Clears run results; a new flight or a fresh wizard run starts clean.
  void _clearResults() {
    _newTune = null;
    _appliedSummary = null;
    _currentMeanM = null;
    _newMeanM = null;
    _currentVertical = null;
    _newVertical = null;
    _previews = const [];
    _previewIndex = 0;
    _resultNote = null;
  }

  Future<void> _loadFlight(String path, String name) async {
    setState(() {
      _selectedPath = path;
      _selectedName = name;
      _samples = null;
      _frames = null;
      _loading = true;
      _loadError = null;
      // A new flight invalidates previous runs and results.
      _clearResults();
    });
    try {
      final flight = await RecordingRepository.decodePreview(path);
      if (!mounted) return;
      if (flight.frames.isEmpty) {
        setState(() {
          _loading = false;
          _loadError = 'No decodable frames — not a valid recording.';
        });
        return;
      }
      setState(() {
        _samples = [
          for (final frame in flight.frames)
            deadReckoningSampleFromFrame(frame),
        ];
        _frames = flight.frames;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not decode this recording.';
      });
    }
  }

  bool get _hasFlight =>
      _samples != null && _samples!.isNotEmpty;

  bool _stepUnlocked(_LabStep step) {
    return switch (step) {
      _LabStep.flight => true,
      _LabStep.results => _hasFlight,
    };
  }

  void _goStep(_LabStep step) {
    if (!_stepUnlocked(step)) return;
    setState(() => _step = step);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  /// Outage windows for the loaded flight (pure helper in
  /// `dead_reckoning_lab_masks.dart`, tested without widgets).
  List<DeadReckoningGapMask> _buildMasks(List<DeadReckoningSample> samples) =>
      buildLabMasks(samples, _frames ?? const <TelemetryFrame>[]);

  Future<List<DeadReckoningTerrainSample>> _terrainFor(
    List<DeadReckoningSample> samples,
  ) async {
    try {
      final keys = <String>{};
      for (final sample in samples) {
        if (sample.hasFix) {
          keys.add(elevationTileKey(sample.latitude, sample.longitude));
        }
      }
      final out = <DeadReckoningTerrainSample>[];
      for (final key in keys.take(24)) {
        final center = elevationTileCenter(key);
        final msl = await elevationMsl(center.latitude, center.longitude);
        if (msl != null) {
          out.add(DeadReckoningTerrainSample(
            latitude: center.latitude,
            longitude: center.longitude,
            elevationMsl: msl,
          ));
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _submit() async {
    final samples = _samples;
    final frames = _frames ?? const <TelemetryFrame>[];
    if (samples == null || samples.isEmpty || _working) return;
    final currentTune = ref.read(deadReckoningTuneProvider);
    setState(() {
      _working = true;
      _cancel = false;
      _progress = null;
      _status = 'Finding outages…';
    });
    try {
      final masks = _buildMasks(samples);
      if (masks.isEmpty) {
        if (!mounted) return;
        setState(() => _working = false);
        ref.warningToast('No scorable outages in this flight.');
        return;
      }
      if (!mounted) return;
      setState(() => _status = 'Reading terrain…');
      // Transition-spanning outages are excluded from tuning and from
      // the preview: they need future knowledge by construction (e.g.
      // when the chute opens mid-outage), so tuning on them rewards
      // gaming the touchdown freeze instead of better tracking. Falls
      // back to all masks when every outage spans a transition.
      final tuneMasks = [
        for (final mask in masks)
          if (!labSpansTransition(mask, frames)) mask,
      ];
      final effectiveMasks = tuneMasks.isEmpty ? masks : tuneMasks;
      final terrain = widget.loadTerrain
          ? await _terrainFor(samples)
          : const <DeadReckoningTerrainSample>[];
      final result = await optimizeDeadReckoning(
        samples: samples,
        masks: effectiveMasks,
        // 4 headings: means match 8 to measurement noise (verified
        // rotation spread ≈ 0) at half the search cost.
        rotationCount: 4,
        start: currentTune,
        terrain: terrain,
        shouldCancel: () => _cancel,
        onProgress: (progress) async {
          if (!mounted) return;
          setState(() {
            _progress =
                (progress.stepsDone / progress.stepsTotal).clamp(0.0, 1.0);
            _status = 'Trying candidate ${progress.stepsDone}'
                '/${progress.stepsTotal}';
          });
        },
      );
      if (!mounted || _cancel) {
        if (mounted) setState(() => _working = false);
        return;
      }
      setState(() => _status = 'Scoring…');
      final baseline = await Future(() => evaluateDeadReckoningRotationInvariant(
            samples: samples,
            tune: currentTune,
            masks: effectiveMasks,
            rotationCount: 4,
            terrain: terrain,
          ));
      final candidate = await Future(
          () => evaluateDeadReckoningRotationInvariant(
                samples: samples,
                tune: result.tune,
                masks: effectiveMasks,
                rotationCount: 4,
                terrain: terrain,
              ));
      // Flown-heading diagnostics on the scored windows (vertical
      // error for the comparison rows below).
      final baseTune = evaluateDeadReckoning(
        samples: samples,
        tune: currentTune,
        masks: effectiveMasks,
        terrain: terrain,
      );
      final candTune = evaluateDeadReckoning(
        samples: samples,
        tune: result.tune,
        masks: effectiveMasks,
        terrain: terrain,
      );
      if (!mounted) return;
      setState(() {
        _newTune = result.tune;
        _currentMeanM = baseline.weightedMeanHorizontalErrorM;
        _newMeanM = candidate.weightedMeanHorizontalErrorM;
        _currentVertical = baseTune.weightedVerticalRmseM;
        _newVertical = candTune.weightedVerticalRmseM;
        _previews = _buildPreviews(
            samples, effectiveMasks, result.tune, frames, terrain);
        _previewIndex = 0;
        _resultNote = !result.completed
            ? 'Stopped early — best candidate so far is shown.'
            : (result.tune == currentTune
                ? 'Already optimal — no better tune found for this flight.'
                : null);
        _working = false;
        _appliedSummary = null;
        _step = _LabStep.results;
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    } catch (_) {
      if (!mounted) return;
      setState(() => _working = false);
      ref.errorToast('Tuning failed.');
    }
  }

  List<OutagePreview> _buildPreviews(
    List<DeadReckoningSample> samples,
    List<DeadReckoningGapMask> masks,
    DeadReckoningTune tune,
    List<TelemetryFrame> frames,
    List<DeadReckoningTerrainSample> terrain,
  ) {
    final previews = <OutagePreview>[];
    for (final mask in masks) {
      // Origin: last fix at or before the cutout.
      DeadReckoningSample? origin;
      for (final sample in samples) {
        if (sample.receivedAtMs > mask.startMs) break;
        if (sample.hasFix) origin = sample;
      }
      origin ??= samples.first;
      final lat0 = origin.latitude;
      final lon0 = origin.longitude;
      final cosLat = math.cos(lat0 * math.pi / 180);
      Enu enu(double lat, double lon, double alt) => (
            e: (lon - lon0) * metresPerDegreeLat * cosLat,
            n: (lat - lat0) * metresPerDegreeLat,
            u: alt - origin!.gpsAltitude,
          );
      final before = <Enu>[];
      final real = <Enu>[];
      for (final sample in samples) {
        if (!sample.hasFix) continue;
        if (sample.receivedAtMs < mask.startMs - 10000) continue;
        if (sample.receivedAtMs < mask.startMs) {
          before.add(enu(sample.latitude, sample.longitude, sample.gpsAltitude));
        } else if (sample.receivedAtMs <= mask.endMs) {
          real.add(enu(sample.latitude, sample.longitude, sample.gpsAltitude));
        } else {
          break;
        }
      }
      final estimate = <Enu>[];
      final estimateRegimes = <String?>[];
      for (final prediction in predictDeadReckoningTrack(
        samples: samples,
        tune: tune,
        masks: [mask],
        terrain: terrain,
      )) {
        for (final position in prediction.track) {
          estimate.add(
              enu(position.latitude, position.longitude, position.altitude));
          estimateRegimes.add(position.regime);
        }
      }
      if (real.length < 2 || estimate.length < 2) continue;
      final windowS = (mask.endMs - mask.startMs) ~/ 1000;
      previews.add(OutagePreview(
        label:
            '+${formatMinSec(mask.startMs - samples.first.receivedAtMs)} · ${labScenarioAt(frames, mask.startMs)} · ${windowS}s',
        before: decimateLab(before, 150),
        estimate: decimateLab(estimate, 150),
        real: decimateLab(real, 150),
        estimateRegimes: decimateLab(estimateRegimes, 150),
      ));
    }
    return previews;
  }

  Future<void> _apply() async {
    final tune = _newTune;
    if (tune == null) return;
    await ref.read(deadReckoningTuneProvider.notifier).setTune(tune);
    if (!mounted) return;
    ref.successToast('New tune applied.');
    setState(() {
      _clearResults();
      _appliedSummary = describeDeadReckoningTune(tune);
      // Back home: the overview now describes the applied tune.
      _wizardActive = false;
      _step = _LabStep.flight;
    });
  }

  void _discardResults() {
    setState(() {
      _clearResults();
      // Discarding leaves the wizard: back to the overview.
      _wizardActive = false;
      _step = _LabStep.flight;
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeTune = ref.watch(deadReckoningTuneProvider);
    if (!_wizardActive) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppDimens.pagePadding),
            child: _overviewBody(context, activeTune),
          ),
        ),
      );
    }
    return _WizardShell(
      scrollController: _scrollController,
      rail: _rail(),
      stepBody: _stepBody(),
    );
  }

  /// Home state: the tune as one copy/paste line, front and center.
  /// The field always shows the live tune until pasted over — then its
  /// button turns from copy into apply.
  Widget _overviewBody(BuildContext context, DeadReckoningTune activeTune) {
    final compact = activeTune.toCompactString();
    if (!_tuneEdited && _tuneController.text != compact) {
      _tuneController.text = compact;
    }
    final edited = _tuneController.text.trim() != compact;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: AppDimens.pagePadding),
        Text(
          'Dead reckoning',
          textAlign: TextAlign.center,
          style: textTheme.titleLarge?.copyWith(
                fontSize: 20,
                letterSpacing: -0.3,
              ) ??
              const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppDimens.pagePadding),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Copy / Paste tune',
            style: textTheme.titleSmall,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: _tuneController,
                maxLines: 1,
                onChanged: (_) => setState(() => _tuneEdited = true),
                style: AppText.monoValue.copyWith(fontSize: 12),
                decoration: InputDecoration(
                  errorText: _fieldError,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (!edited)
              CopyButton(text: compact, formatName: 'tune string')
            else
              FilledButton.tonal(
                onPressed: _applyField,
                child: const Text('Apply'),
              ),
          ],
        ),
        if (_appliedSummary != null) ...[
          const SizedBox(height: 8),
          Text(
            'Applied: ${_appliedSummary!}.',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: AppDimens.gap),
        FilledButton(
          onPressed: _startWizard,
          child: const Text('Generate new tune'),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _openManual,
          child: const Text('Manual tune…'),
        ),
        const SizedBox(height: AppDimens.pagePadding),
      ],
    );
  }

  void _applyField() {
    final tune = DeadReckoningTuneController.parsePersisted(
      _tuneController.text,
    );
    if (tune == null) {
      setState(
          () => _fieldError = 'Not a tune — paste a copied tune string.');
      return;
    }
    setState(() {
      _fieldError = null;
      _tuneEdited = false;
    });
    ref.read(deadReckoningTuneProvider.notifier).setTune(tune);
    ref.successToast('Tune loaded.');
  }

  void _startWizard() {
    setState(() {
      _wizardActive = true;
      _step = _LabStep.flight;
      // A fresh run starts clean; the live tune stays untouched.
      _clearResults();
    });
  }

  void _exitWizard() {
    setState(() {
      _wizardActive = false;
      _step = _LabStep.flight;
    });
  }

  /// The step rail: every node shows its live state, so the process
  /// hierarchy (Flight → Results) is always visible.
  /// Tapping an unlocked node jumps to it.
  Widget _rail() {
    const steps = _LabStep.values;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.only(left: 21.5, top: 3, bottom: 3),
                child: SizedBox(
                  width: 1,
                  height: 14,
                  child: ColoredBox(color: AppColors.border),
                ),
              ),
            _railNode(steps[i]),
          ],
        ],
      ),
    );
  }

  Widget _railNode(_LabStep step) {
    final enabled = _stepUnlocked(step);
    final current = step == _step;
    final done = _stepDone(step);
    final title = switch (step) {
      _LabStep.flight => 'Flight',
      _LabStep.results => 'Results',
    };
    Widget numberMarker(Color color) => Text(
          '${step.index + 1}',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: color),
        );
    final Color ring;
    final Widget marker;
    if (!enabled) {
      ring = AppColors.faint;
      marker = numberMarker(AppColors.faint);
    } else if (done) {
      ring = AppColors.success;
      marker = const Icon(Icons.check, size: 14, color: Colors.white);
    } else {
      ring = current ? AppColors.pink : AppColors.faint;
      marker = numberMarker(ring);
    }
    return InkWell(
      onTap: enabled ? () => _goStep(step) : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done && enabled ? ring : Colors.transparent,
                border: done && enabled
                    ? null
                    : Border.all(color: ring, width: current ? 2 : 1),
              ),
              alignment: Alignment.center,
              child: marker,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          current ? FontWeight.w700 : FontWeight.w500,
                      color: !enabled
                          ? AppColors.faint
                          : current
                              ? AppColors.foreground
                              : AppColors.mutedForeground,
                    ),
                  ),
                  Text(
                    _stepStatus(step),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _stepDone(_LabStep step) {
    return switch (step) {
      _LabStep.flight => _hasFlight,
      _LabStep.results => _newTune != null || _appliedSummary != null,
    };
  }

  String _stepStatus(_LabStep step) {
    if (step == _LabStep.flight) {
      if (_loading) return 'Loading…';
      if (_loadError != null) return 'Could not decode';
      if (_hasFlight) return _selectedName;
      return 'Pick a recording';
    }
    // Only flight + results exist, so results is the fallback.
    if (_working) return 'Searching…';
    if (_appliedSummary != null) return 'Applied';
    if (_newTune == null) return 'Not run yet';
    return _verdictShort();
  }

  /// Short verdict for the rail; the full sentence lives in Results.
  /// States the misses in metres — no adjectives to decode.
  String _verdictShort() {
    if (_resultNote != null) {
      return _resultNote!.startsWith('Stopped early')
          ? 'Stopped early'
          : 'Already optimal';
    }
    final current = _currentMeanM;
    final candidate = _newMeanM;
    if (current == null || candidate == null) return 'Compared';
    return '${current.toStringAsFixed(0)} → ${candidate.toStringAsFixed(0)} m';
  }

  Widget _stepHeadline(String title, String helper) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          helper,
          style: textTheme.bodySmall,
        ),
        const SizedBox(height: AppDimens.gap),
      ],
    );
  }

  Widget _stepBody() {
    return switch (_step) {
      _LabStep.flight => _flightBody(),
      _LabStep.results => _resultsStepBody(),
    };
  }

  /// Step 1: the flight under test.
  Widget _flightBody() {
    final samples = _samples;
    final hasFlight = _hasFlight;
    final masks = hasFlight ? _buildMasks(samples!) : const <DeadReckoningGapMask>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _stepHeadline(
          'Flight',
          'Pick the flight to fit. Longer flights with parachute time '
          'tune better.',
        ),
          if (widget.debugSamples == null)
            FutureBuilder<List<_LabRecording>>(
              future: _recordingsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final recordings = snapshot.data ?? const <_LabRecording>[];
                if (recordings.isEmpty) {
                  return const Text(
                    'No recordings yet — connect a port, hit Record, '
                    'then come back.',
                    style: TextStyle(fontSize: 13),
                  );
                }
                return DropdownButtonFormField<String>(
                  initialValue: _selectedPath,
                  decoration: const InputDecoration(
                    labelText: 'Flight recording',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final recording in recordings)
                      DropdownMenuItem(
                        value: recording.path,
                        child: Text(
                          recording.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _working
                      ? null
                      : (path) {
                          if (path == null) return;
                          _loadFlight(
                            path,
                            recordings
                                .firstWhere((r) => r.path == path)
                                .name,
                          );
                        },
                );
              },
            ),
          if (widget.debugSamples != null && _selectedName.isNotEmpty)
            Text(_selectedName, style: const TextStyle(fontSize: 13)),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_loadError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _loadError!,
                style:
                    TextStyle(fontSize: 12.5, color: AppColors.destructive),
              ),
            ),
          if (hasFlight && masks.isEmpty && !_working)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'No scorable outages in this flight.',
                style: TextStyle(
                    fontSize: 12, color: AppColors.destructive),
              ),
            ),
          if (_working) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 5,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _status,
                    style: AppText.mono.copyWith(
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _cancel = true),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton(
                onPressed: _working ? null : _exitWizard,
                child: const Text('Close'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: (!hasFlight ||
                        masks.isEmpty ||
                        _working ||
                        _loading)
                    ? null
                    : _submit,
                child: const Text('Find best tune'),
              ),
            ],
          ),
        ],
      );
  }

  /// Step 2: what the search found. Empty until the first run.
  Widget _resultsStepBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _stepHeadline(
          'Results',
          'The fitted tune against the current one.',
        ),
        if (!_hasResults)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Nothing here yet — pick a flight one step back, '
                'then run the search.',
                style: TextStyle(
                    fontSize: 13, color: AppColors.mutedForeground),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: _hasFlight ? _submit : null,
                  child: const Text('Find best tune'),
                ),
              ),
            ],
          )
        else
          _resultsBody(),
      ],
    );
  }

  Widget _resultsBody() {
    final applied = _appliedSummary;
    if (applied != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Applied: $applied.',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Run a search above to compare again.',
            style:
                TextStyle(fontSize: 13, color: AppColors.mutedForeground),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _discardResults,
              child: const Text('Clear'),
            ),
          ),
        ],
      );
    }
    final current = _currentMeanM;
    final candidate = _newMeanM;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_resultNote != null) ...[
          Text(
            _resultNote!,
            style:
                TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
          const SizedBox(height: 8),
        ],
        _ComparisonRow(
          label: 'Average miss',
          current: formatLabMeanM(current),
          candidate: formatLabMeanM(candidate),
        ),
        _ComparisonRow(
          label: 'Vertical error',
          current: formatLabVerticalM(_currentVertical),
          candidate: formatLabVerticalM(_newVertical),
        ),
        if (_previews.isNotEmpty) ...[
          const SizedBox(height: 10),
          const PreviewLegend(),
          const SizedBox(height: 6),
          OutagePreview3d(preview: _previews[_previewIndex]),
          const SizedBox(height: 6),
          OutageCarousel(
            count: _previews.length,
            index: _previewIndex,
            label: _previews[_previewIndex].label,
            onPrevious: _previewIndex > 0
                ? () => setState(() => _previewIndex--)
                : null,
            onNext: _previewIndex < _previews.length - 1
                ? () => setState(() => _previewIndex++)
                : null,
            onSelect: (index) => setState(() => _previewIndex = index),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _apply,
              child: const Text('Apply new tune'),
            ),
            TextButton(
              onPressed: _discardResults,
              child: const Text('Discard'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _openManual() async {
    final tune = await showDialog<DeadReckoningTune>(
      context: context,
      builder: (_) => ManualTuneDialog(
        initial: ref.read(deadReckoningTuneProvider),
      ),
    );
    if (tune == null || !mounted) return;
    await ref.read(deadReckoningTuneProvider.notifier).setTune(tune);
    if (!mounted) return;
    if (tune == DeadReckoningTune.defaults) {
      ref.successToast('Factory defaults restored.');
    } else {
      ref.successToast('Tune applied live and saved.');
    }
  }
}

/// Plain label + current → candidate row for the results card.
class _ComparisonRow extends StatelessWidget {
  final String label;
  final String current;
  final String candidate;

  const _ComparisonRow({
    required this.label,
    required this.current,
    required this.candidate,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$current → $candidate',
            style: AppText.monoValue.copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _LabRecording {
  final String path;
  final String name;

  const _LabRecording(this.path, this.name);
}

/// The guided steps, in order. The page opens on an overview (the current
/// tune + a door into the wizard) instead; each rail node reflects the
/// live state (done / current / disabled) so the UI shows where the user
/// is: overview ⇄ Flight (input + run) → Results (output). The search runs
/// from Flight; applying or discarding returns to the overview.
enum _LabStep { flight, results }

/// Full-height wizard row: the rail stays vertically centered while the
/// step card scrolls on its own next to it.
class _WizardShell extends StatelessWidget {
  final ScrollController scrollController;
  final Widget rail;
  final Widget stepBody;

  const _WizardShell({
    required this.scrollController,
    required this.rail,
    required this.stepBody,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Padding(
              padding: const EdgeInsets.all(AppDimens.pagePadding),
              child: SizedBox(
                height: constraints.maxHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 208,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.max,
                        children: [rail],
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      // Viewport-aware scroll: the card stays horizontally
                      // centered, and vertically centered while it fits.
                      // Once it overflows, the scroll takes over from the
                      // top (reset via the scroll controller on step change).
                      child: LayoutBuilder(
                        builder: (context, viewport) {
                          return SingleChildScrollView(
                            controller: scrollController,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: viewport.maxHeight,
                                minWidth: viewport.maxWidth,
                              ),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 600),
                                  child: AppCard(child: stepBody),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

