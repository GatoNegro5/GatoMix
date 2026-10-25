import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_timing_check.dart';
import 'package:gatomix/core/lrc_timeline.dart';

String lrc(List<int> secs) =>
    secs.map((s) => '[${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}.00]linea $s').join('\n');

String _lrc(List<int> secs) => secs
    .map((int s) => '[${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}.00]verso $s')
    .join('\n');

void main() {
  group('1.0.9+23 rescate antes de REVIEW', () {
    test('letra que arranca antes de la voz se mueve entera', () {
      final String lrc = _lrc(<int>[1, 30, 60, 150]);
      final String? out = realignLrcToVoice(
          lrc: lrc, durationMs: 200000, voiceOnsetMs: 15000);
      expect(out, isNotNull);
      expect(firstVerseMs(out!), 15000);
      expect(lastVerseMs(out!), 164000);
    });
    test('letra que empieza tarde pero cabe se adelanta', () {
      final String lrc = _lrc(<int>[100, 180, 250]);
      expect(checkLyricTiming(lrc: lrc, durationMs: 240000).ok, isFalse);
      final String? out = realignLrcToVoice(
          lrc: lrc, durationMs: 240000, voiceOnsetMs: 20000);
      expect(firstVerseMs(out!), 20000);
    });
    test('no se mueve si después se pasa del final', () {
      final String lrc = _lrc(<int>[1, 190]);
      expect(realignLrcToVoice(lrc: lrc, durationMs: 200000, voiceOnsetMs: 15000), isNull);
    });
    test('letra manual nunca se mueve', () {
      final String lrc = '[gmx_manual]\n${_lrc(<int>[1, 60])}';
      expect(realignLrcToVoice(lrc: lrc, durationMs: 200000, voiceOnsetMs: 15000), isNull);
    });
    test('sin voz medida o desfase chico: null', () {
      final String lrc = _lrc(<int>[10, 60]);
      expect(realignLrcToVoice(lrc: lrc, durationMs: 200000, voiceOnsetMs: null), isNull);
      expect(realignLrcToVoice(lrc: lrc, durationMs: 200000, voiceOnsetMs: 10500), isNull);
    });
    test('conserva la marca gmx_shift', () {
      final String lrc = '[gmx_shift:800]\n${_lrc(<int>[1, 60, 150])}';
      final String? out = realignLrcToVoice(lrc: lrc, durationMs: 200000, voiceOnsetMs: 12000);
      expect(out!.startsWith('[gmx_shift:800]'), isTrue);
    });
    test('prueba todos los candidatos y toma el primero que pasa', () {
      final String bad = _lrc(<int>[10, 60]); // termina a la mitad
      final String good = _lrc(<int>[12, 100, 190]);
      final String? out = firstPassingLyric(
        candidates: <String>[bad, _lrc(<int>[10, 260]), good],
        current: bad, trimMs: 0, durationMs: 200000);
      expect(out, good);
    });
    test('aplica el recorte antes de chequear', () {
      final String cand = _lrc(<int>[12, 100, 203]);
      final String? out = firstPassingLyric(
        candidates: <String>[cand], current: '', trimMs: 3000, durationMs: 200000);
      expect(out, isNotNull);
      expect(out!.contains('[gmx_shift:3000]'), isTrue);
      expect(lastVerseMs(out), 200000);
    });
    test('ningún candidato sirve: null', () {
      expect(firstPassingLyric(candidates: <String>[_lrc(<int>[5, 40])],
          current: '', trimMs: 0, durationMs: 200000), isNull);
    });
  });

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
