import 'dart:async';

import 'package:flutter/gestures.dart'
    show PointerPanZoomUpdateEvent, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/tool_button.dart';
import '../../screens/tile_leaf_scope.dart';
import './orbit_camera.dart';
import './trackpad_zoom.dart' show scrollZoomFactor;

/// Shared camera state for the 3D flight views: chase / orbit-field / free
/// mode, wheel-zoom, and the slow auto-rotation ticker for the orbit-field
/// camera (shared angles, so every view follows).
mixin Flight3dShellState<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  FlightCameraMode mode = FlightCameraMode.chase;
  double zoom = 1.0;

  Timer? _orbitTicker;
  bool _leafModeRestored = false;

  @override
  void initState() {
    super.initState();
    _orbitTicker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || mode != FlightCameraMode.orbit) return;
      ref.read(orbitCameraProvider.notifier).autoRotate(0.35);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Restore the persisted camera mode once (fresh tiles without a scope,
    // or leaves storing none, keep the default chase view).
    if (!_leafModeRestored) {
      _leafModeRestored = true;
      final initial = TileLeafScope.of(context)?.cameraMode;
      if (initial != null) mode = initial;
    }
  }

  @override
  void dispose() {
    _orbitTicker?.cancel();
    super.dispose();
  }

  void orbitBy(Offset delta) {
    ref.read(orbitCameraProvider.notifier).orbit(delta, minEl: -15, maxEl: 80);
  }

  void zoomBy(double factor) {
    setState(() => zoom = (zoom * factor).clamp(0.2, 8.0));
  }

  void resetZoom() => setState(() => zoom = 1.0);

  void setShellMode(FlightCameraMode next) {
    // Switching cameras resets the zoom but keeps the orbit rotation, so the
    // view direction never jumps unexpectedly. The selection is reported to
    // the workspace leaf so the save file (and the promote-to-defaults
    // output) follows the live UI.
    setState(() {
      mode = next;
      zoom = 1.0;
    });
    TileLeafScope.of(context)?.onCameraMode?.call(next);
  }
}

/// Shared chrome around the satellite 3D flight painters: gesture canvas
/// (drag orbits, wheel/pinch zooms, double-tap resets zoom) and the
/// camera-mode tool column. [modes] selects which mode buttons show — empty
/// for the fixed onboard lens. Imagery credit and other extras go in
/// [extraOverlays].
///
/// Trackpad gestures arrive as pointer pan/zoom events rather than wheel
/// scrolls, and the framework routes their swipe component to drag
/// recognizers — without suppression a two-finger swipe would both zoom
/// (here) and tilt (via [onOrbit]). While a trackpad gesture is active the
/// swipe/pinch zooms and drag-orbit is ignored; a real press always clears
/// the flag so a lost gesture-end can never wedge orbiting off.
class Flight3dShell extends StatefulWidget {
  final CustomPainter painter;

  /// Active mode and tap handler for the picker buttons; both are unused
  /// when [modes] is empty (the fixed onboard lens).
  final FlightCameraMode? mode;
  final ValueChanged<FlightCameraMode>? onMode;

  /// Mode buttons to show; empty hides the tool column (fixed lens).
  final List<FlightCameraMode> modes;

  final ValueChanged<double> onZoomBy;
  final VoidCallback onResetZoom;
  final ValueChanged<Offset> onOrbit;
  final List<Widget> extraOverlays;

  const Flight3dShell({
    super.key,
    required this.painter,
    this.mode,
    this.onMode,
    this.modes = FlightCameraMode.values,
    required this.onZoomBy,
    required this.onResetZoom,
    required this.onOrbit,
    this.extraOverlays = const [],
  });

  @override
  State<Flight3dShell> createState() => _Flight3dShellState();
}

class _Flight3dShellState extends State<Flight3dShell> {
  bool _trackpadZooming = false;
  double _lastScale = 1.0;

  void _trackpadZoom(PointerPanZoomUpdateEvent event) {
    _trackpadZooming = true;
    final factor =
        scrollZoomFactor(event.panDelta.dy) * (event.scale / _lastScale);
    _lastScale = event.scale;
    if (factor != 1.0) widget.onZoomBy(factor);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            // Scroll up zooms in, scroll down zooms out.
            widget.onZoomBy(event.scrollDelta.dy > 0 ? 1 / 1.1 : 1.1);
          },
          onPointerPanZoomStart: (_) {
            _trackpadZooming = true;
            _lastScale = 1.0;
          },
          onPointerPanZoomUpdate: _trackpadZoom,
          onPointerPanZoomEnd: (_) => _trackpadZooming = false,
          onPointerDown: (_) => _trackpadZooming = false,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) {
              if (_trackpadZooming) return;
              widget.onOrbit(details.delta);
            },
            onDoubleTap: widget.onResetZoom,
            child: CustomPaint(
              painter: widget.painter,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        // Camera mode buttons (zoom lives in wheel/pinch/double-tap only).
        if (widget.modes.isNotEmpty)
          Positioned(
            right: 8,
            top: 8,
            child: Column(
              children: [
                for (final m in widget.modes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ToolFab(
                      icon: m.icon,
                      tooltip: m.label,
                      active: widget.mode == m,
                      onTap: () => widget.onMode?.call(m),
                    ),
                  ),
              ],
            ),
          ),
        ...widget.extraOverlays,
      ],
    );
  }
}
