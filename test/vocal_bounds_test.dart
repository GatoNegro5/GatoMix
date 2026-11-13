import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/vocal_bounds.dart';

// Casos con los números reales medidos el 2026-11-12 (T152).
void main() {
  test('letra de otra versión: no se escriben cues (Bacilos - Tabaco Y Chanel)', () {
    expect(vocalBounds(firstMs: 10000, lastMs: 285380, exactMs: 254783), isNull);
  });
  test('letra hasta el final: mixOut = exacto - 4 s (Whats Up, Santorini)', () {
    expect(vocalBounds(firstMs: 10000, lastMs: 300100, exactMs: 300144)!.mixOutMs, 296144);
    expect(vocalBounds(firstMs: 10000, lastMs: 153110, exactMs: 154391)!.mixOutMs, 150391);
  });
  test('ramas normal y outro largo sin cambio', () {
    expect(vocalBounds(firstMs: 10000, lastMs: 228690, exactMs: 236135)!.mixOutMs, 229690);
    expect(vocalBounds(firstMs: 10000, lastMs: 291690, exactMs: 326495)!.mixOutMs, 295690);
  });
  test('cueIn = primera línea - 5 s, nunca negativo; sin medición queda last + 1000', () {
    expect(vocalBounds(firstMs: 18580, lastMs: 100000, exactMs: 160000)!.cueInMs, 13580);
    expect(vocalBounds(firstMs: 3000, lastMs: 100000, exactMs: 160000)!.cueInMs, 0);
    expect(vocalBounds(firstMs: 3000, lastMs: 100000, exactMs: 0)!.mixOutMs, 101000);
  });
  test('lyricPastAudio: Bacilos sí, Santorini no, sin medición no', () {
    expect(lyricPastAudio(lastLyricMs: 285380, exactMs: 254783), isTrue);
    expect(lyricPastAudio(lastLyricMs: 153110, exactMs: 154391), isFalse);
    expect(lyricPastAudio(lastLyricMs: 153110, exactMs: 0), isFalse);
  });
}
