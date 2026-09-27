import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

/// Regression pin for the silent-connect bug: a failed `ConnectCommand`
/// must surface an [ErrorEvent] on [SerialWorker.errorStream].
///
/// The forwarder previously destructured the event's `message` String field
/// and cast it back to [ErrorEvent] (`message as ErrorEvent`), throwing
/// `type 'String' is not a subtype of type 'ErrorEvent'` inside
/// `_handleMessage` — so every worker error died as an unhandled async
/// exception and the UI never toasted anything (connect to a bad port:
/// no error, no state change, nothing).
void main() {
  group('SerialWorker error forwarding', () {
    test('failed connect emits an ErrorEvent', () async {
      final worker = await SerialWorker.spawn();
      addTearDown(worker.dispose);

      // Wait for the isolate handshake (command SendPort exchange) instead
      // of a blind delay: sends before it are buffered, but the test must
      // not race the worker's first scan either.
      await worker.ready;

      // Liveness lease: ping like the app does, so the worker cannot
      // self-exit mid-test on a slow runner.
      final ping = Timer.periodic(
        const Duration(seconds: 2),
        (_) => worker.send(const PingCommand()),
      );
      addTearDown(ping.cancel);

      final errors = worker.errorStream.take(1).toList();
      worker.send(const ConnectCommand('__BOGUS_PORT_XYZ__'));

      final first = await errors.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TestFailure(
          'No ErrorEvent arrived for a failed connect — '
          'error forwarding is broken.',
        ),
      );
      expect(first, hasLength(1));
      expect(first.single.message, contains('__BOGUS_PORT_XYZ__'));
    });

    test('failed connect names the port exactly once', () async {
      final worker = await SerialWorker.spawn();
      addTearDown(worker.dispose);
      await worker.ready;
      final ping = Timer.periodic(
        const Duration(seconds: 2),
        (_) => worker.send(const PingCommand()),
      );
      addTearDown(ping.cancel);

      final errors = worker.errorStream.take(1).toList();
      worker.send(const ConnectCommand('__BOGUS_PORT_XYZ__'));

      final first = await errors.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TestFailure('No ErrorEvent arrived.'),
      );
      final message = first.single.message;
      final occurrences =
          '__BOGUS_PORT_XYZ__'.allMatches(message).length;
      expect(occurrences, 1, reason: 'message: $message');
    });
  });
}
