import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart' as fs;

/// One-time initialization gate for Flutter Scene's static resources (base
/// shader bundle, BRDF LUT, material variants).
///
/// Since 0.21 the base shader bundle is built by a build hook and loaded
/// asynchronously; constructing geometry or materials that touch the base
/// shader library before it is loaded throws, and `SceneView` skips frames
/// until it is ready. The future is memoized engine-side, so every view can
/// await the same instance (and a later call retries after a failure).
///
/// Note: the engine logs a failed load and completes the future normally,
/// so callers must check [fs.Scene.isReadyToRender] afterwards — awaiting
/// alone does not prove the resources loaded.
Future<void> ensureSceneResources() => fs.Scene.initializeStaticResources();

/// Defers building the GPU subtree until [ensureSceneResources] completes
/// **and** the engine reports ready.
///
/// `SceneView` already skips frames while the engine is not ready, but it
/// cannot protect geometry/material constructors that touch the base shader
/// library synchronously (e.g. `LineSegmentsGeometry`). Mounting the 3D
/// views behind this gate removes the crash and the skipped-frame spam, so
/// the first painted GPU frame is complete.
///
/// If initialization fails (stale shader bundle from a pre-upgrade build:
/// `flutter clean` and rebuild), the gate shows a small error with
/// tap-to-retry instead of mounting a view that would throw mid-frame.
class SceneGate extends StatefulWidget {
  final Widget Function(BuildContext context) builder;

  const SceneGate({super.key, required this.builder});

  @override
  State<SceneGate> createState() => _SceneGateState();
}

class _SceneGateState extends State<SceneGate> {
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _waitForResources();
  }

  void _waitForResources() {
    ensureSceneResources().then((_) {
      if (!mounted) return;
      // The engine swallows load failures into a normally-completing
      // future, so readiness — not completion — is the mount condition.
      setState(() {
        if (fs.Scene.isReadyToRender) {
          _ready = true;
        } else {
          _failed = true;
        }
      });
    }).catchError((Object _) {
      if (!mounted) return;
      setState(() => _failed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.builder(context);
    if (!_failed) return const SizedBox.expand();
    return GestureDetector(
      onTap: () {
        setState(() => _failed = false);
        _waitForResources();
      },
      child: const Center(
        child: Text(
          '3D engine failed to start — tap to retry',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
