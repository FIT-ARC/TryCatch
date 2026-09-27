import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/toast_store.dart';

/// Single entry for user-facing feedback. All toasts go through these
/// extensions — never push to `toastStoreProvider` directly.
///
/// Style: title is a short Title Case noun (`Serial error`,
/// `Port disconnected`, `Command failed`, `Ports refreshed`); the message
/// is one plain sentence naming the subject once, ending with what to do
/// next (`check the cable and retry`, `select a port first`). Port names,
/// filenames and counts appear exactly once per message.
extension AppFeedbackRef on Ref {
  int errorToast(
    String message, {
    String? title,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      AppFeedback.push(
        read(toastStoreProvider.notifier),
        message,
        severity: ToastSeverity.error,
        title: title,
        actionLabel: actionLabel,
        onAction: onAction,
      );

  int warningToast(
    String message, {
    String? title,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      AppFeedback.push(
        read(toastStoreProvider.notifier),
        message,
        severity: ToastSeverity.warning,
        title: title,
        actionLabel: actionLabel,
        onAction: onAction,
      );

  int infoToast(
    String message, {
    String? title,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      AppFeedback.push(
        read(toastStoreProvider.notifier),
        message,
        severity: ToastSeverity.info,
        title: title,
        actionLabel: actionLabel,
        onAction: onAction,
      );

  int successToast(
    String message, {
    String? title,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      AppFeedback.push(
        read(toastStoreProvider.notifier),
        message,
        severity: ToastSeverity.success,
        title: title,
        actionLabel: actionLabel,
        onAction: onAction,
      );
}

/// Widget-side mirror of [AppFeedbackRef] (`WidgetRef` no longer extends
/// `Ref`, so both need their own extension with identical verbs).
extension AppFeedbackWidgetRef on WidgetRef {
  int errorToast(
    String message, {
    String? title,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      AppFeedback.push(
        read(toastStoreProvider.notifier),
        message,
        severity: ToastSeverity.error,
        title: title,
        actionLabel: actionLabel,
        onAction: onAction,
      );

  int warningToast(
    String message, {
    String? title,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      AppFeedback.push(
        read(toastStoreProvider.notifier),
        message,
        severity: ToastSeverity.warning,
        title: title,
        actionLabel: actionLabel,
        onAction: onAction,
      );

  int infoToast(
    String message, {
    String? title,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      AppFeedback.push(
        read(toastStoreProvider.notifier),
        message,
        severity: ToastSeverity.info,
        title: title,
        actionLabel: actionLabel,
        onAction: onAction,
      );

  int successToast(
    String message, {
    String? title,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      AppFeedback.push(
        read(toastStoreProvider.notifier),
        message,
        severity: ToastSeverity.success,
        title: title,
        actionLabel: actionLabel,
        onAction: onAction,
      );
}

/// Shared push core behind the two ref extensions.
abstract final class AppFeedback {
  static int push(
    ToastStore store,
    String message, {
    required ToastSeverity severity,
    String? title,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      store.push(
        message,
        severity: severity,
        title: title,
        actionLabel: actionLabel,
        onAction: onAction,
      );
}
