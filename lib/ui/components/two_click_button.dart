import 'dart:async';

import 'package:flutter/material.dart';

enum TwoClickState { idle, confirm, sent }

/// One confirmation group: choosing another action cancels the first arm.
class TwoClickController<T> extends ChangeNotifier {
  T? _armed;
  T? _sent;
  Timer? _timer;
  TwoClickState stateFor(T id) => _sent == id
      ? TwoClickState.sent
      : _armed == id
      ? TwoClickState.confirm
      : TwoClickState.idle;

  void tap(T id, bool Function() onConfirm) {
    _timer?.cancel();
    if (_armed != id) {
      _armed = id;
      _sent = null;
      _timer = Timer(const Duration(seconds: 3), clear);
    } else {
      _armed = null;
      _sent = onConfirm() ? id : null;
      if (_sent != null) _timer = Timer(const Duration(seconds: 1), clear);
    }
    notifyListeners();
  }

  void clear() {
    _timer?.cancel();
    _timer = null;
    _armed = null;
    _sent = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Shared confirmation behaviour with presentation supplied by each surface.
class TwoClickButton<T> extends StatelessWidget {
  final T id;
  final TwoClickController<T> controller;
  final bool enabled;
  final bool Function() onConfirm;
  final Widget Function(BuildContext, TwoClickState, VoidCallback?) builder;
  const TwoClickButton({
    super.key,
    required this.id,
    required this.controller,
    required this.enabled,
    required this.onConfirm,
    required this.builder,
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => builder(
      context,
      controller.stateFor(id),
      enabled ? () => controller.tap(id, onConfirm) : null,
    ),
  );
}
