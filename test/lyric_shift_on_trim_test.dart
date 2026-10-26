import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_timing_check.dart';

void main() {
  group('1.0.18 letra corrida', () {
    test('letra sincronizada no registrada como auto igual se desplaza', () {
      expect(shouldShiftLrcOnTrim('[00:12.00]hola\n[00:20.00]mundo'), isTrue);
    });
    test('letra plana o vacía no se desplaza', () {
      expect(shouldShiftLrcOnTrim(''), isFalse);
      expect(shouldShiftLrcOnTrim('hola\nmundo'), isFalse);
    });
    test(
      'letra correcta corrida se mueve entera (mismo texto, offset global)',
      () {
        final String l = <int>[1, 30, 60, 150]
            .map(
              (int x) =>
                  '[${(x ~/ 60).toString().padLeft(2, '0')}:${(x % 60).toString().padLeft(2, '0')}.00]verso $x',
            )
            .join('\n');
        final String? out = realignLrcToVoice(
          lrc: l,
          durationMs: 200000,
          voiceOnsetMs: 15000,
        );
        expect(out, isNotNull);
        expect(out!.split('\n').first, '[00:15.00]verso 1');
        expect(
          out.replaceAll(RegExp(r'\[[^\]]*\]'), ''),
          l.replaceAll(RegExp(r'\[[^\]]*\]'), ''),
        );
      },
    );
  });
}
