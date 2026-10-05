import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('Mock connector commands', () {
    test('owns five uplink commands with valid framing', () {
      expect(
        [for (final cmd in mockConnector.commands) cmd.id],
        ['arm', 'disarm', 'fire_parachute', 'beep', 'reset_fsm'],
      );
      for (final cmd in mockConnector.commands) {
        expect(cmd.bytes.length, 4);
        expect(cmd.bytes[0], rocketMagicT);
        expect(cmd.bytes[1], rocketMagicC);
        expect(cmd.bytes[0], 0x54);
        expect(cmd.bytes[1], 0x43);
      }
    });

    test('expected command bytes are defined', () {
      final byId = {
        for (final cmd in mockConnector.commands) cmd.id: cmd,
      };
      expect(byId['arm']!.bytes, [0x54, 0x43, 0x01, 0x00]);
      expect(byId['arm']!.danger, isTrue);

      expect(byId['disarm']!.bytes, [0x54, 0x43, 0x02, 0x00]);
      expect(byId['disarm']!.danger, isFalse);

      expect(byId['fire_parachute']!.bytes, [0x54, 0x43, 0x03, 0x00]);
      expect(byId['fire_parachute']!.danger, isTrue);

      expect(byId['beep']!.bytes, [0x54, 0x43, 0x05, 0x00]);
      expect(byId['beep']!.danger, isFalse);

      expect(byId['reset_fsm']!.bytes, [0x54, 0x43, 0x06, 0x00]);
      expect(byId['reset_fsm']!.danger, isTrue);
    });
  });

  group('FsmStateCommands', () {
    test('bytesFor generates valid magic and command byte', () {
      for (final state in FsmState.values) {
        final bytes = FsmStateCommands.bytesFor(state);
        expect(bytes.length, 4);
        expect(bytes[0], 0x54);
        expect(bytes[1], 0x43);
        expect(bytes[2], 0x07);
        expect(bytes[3], state.id);
      }
    });
  });
}
