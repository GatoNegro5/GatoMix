import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_timing_check.dart';
import 'package:gatomix/core/lrc_timeline.dart';

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

  group('1.0.20 letra nueva sobre audio ya recortado', () {
    const String fresh = '[00:23.30]Rain begins\n[00:30.00]to fall';
    test('Jermaine Rain: TRIM 300 guardado, letra bajada hoy → 300', () {
      expect(
        freshLyricShiftMs(
          lrcBefore: null,
          lrcAfter: fresh,
          storedTrimMs: 300,
          trimmedThisPass: false,
        ),
        300,
      );
    });
    test('idempotente: con [gmx_shift] no se vuelve a mover', () {
      final String once = shiftLrcText(fresh, 300).text;
      expect(once.startsWith('[gmx_shift:300]'), isTrue);
      expect(once.contains('[00:23.00]Rain begins'), isTrue);
      expect(
        freshLyricShiftMs(
          lrcBefore: fresh,
          lrcAfter: once,
          storedTrimMs: 300,
          trimmedThisPass: false,
        ),
        isNull,
      );
      expect(shiftLrcText(once, 300).changed, isFalse);
    });
    test('no aplica: sin cambio, corte de esta pasada, manual, plana, 0', () {
      int? f(String? b, String a, int t, bool now) => freshLyricShiftMs(
        lrcBefore: b,
        lrcAfter: a,
        storedTrimMs: t,
        trimmedThisPass: now,
      );
      expect(f(fresh, fresh, 970, false), isNull);
      expect(f(null, fresh, 970, true), isNull);
      expect(f(null, '[gmx_manual:1]\n$fresh', 970, false), isNull);
      expect(f(null, '[gmx_plain:1]\nhola', 970, false), isNull);
      expect(f(null, fresh, 0, false), isNull);
      expect(f(null, fresh, -1, false), isNull);
    });
  });
}
