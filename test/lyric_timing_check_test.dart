import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_timing_check.dart';

String lrc(List<int> secs) =>
    secs.map((s) => '[${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}.00]linea $s').join('\n');

void main() {
  test('letra completa = ok', () {
    final v = checkLyricTiming(lrc: lrc([12, 60, 180, 220]), durationMs: 240000);
    expect(v.ok, isTrue);
  });
  test('termina a la mitad', () {
    final v = checkLyricTiming(lrc: lrc([10, 60, 110]), durationMs: 240000);
    expect(v.issue, LyricTimingIssue.endsEarly);
  });
  test('outro largo de bachata no es aviso (falta < 45 s)', () {
    final v = checkLyricTiming(lrc: lrc([15, 100, 140]), durationMs: 180000);
    expect(v.ok, isTrue);
  });
  test('pasa del final', () {
    final v = checkLyricTiming(lrc: lrc([10, 200, 245]), durationMs: 240000);
    expect(v.issue, LyricTimingIssue.pastEnd);
  });
  test('2 s de tolerancia al final', () {
    final v = checkLyricTiming(lrc: lrc([10, 200, 241]), durationMs: 240000);
    expect(v.ok, isTrue);
  });
  test('empieza tarde (El Malo 1:50)', () {
    final v = checkLyricTiming(lrc: lrc([110, 150, 230]), durationMs: 250000);
    expect(v.issue, LyricTimingIssue.startsLate);
  });
  test('arranca en 0 con intro instrumental', () {
    final v = checkLyricTiming(
        lrc: lrc([1, 60, 200]), durationMs: 240000, voiceOnsetMs: 15000);
    expect(v.issue, LyricTimingIssue.startsBeforeVoice);
  });
  test('arranca en 0 sin dato de voz = ok', () {
    final v = checkLyricTiming(lrc: lrc([1, 60, 200]), durationMs: 240000);
    expect(v.ok, isTrue);
  });
  test('letra plana y marcas gmx se ignoran', () {
    expect(checkLyricTiming(lrc: '[gmx_plain:1]\nhola', durationMs: 200000).ok, isTrue);
    expect(lastVerseMs('[gmx_shift:500]\n[00:10.00]hola\n[03:00.00]'), 10000);
  });
}
