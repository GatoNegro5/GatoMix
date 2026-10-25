import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_ai_align.dart';

// Letra sintética (sin letras con copyright): 30 versos de 4 palabras
// inventadas, uno cada 6 s desde los 20 s.
final Random _r = Random(7);
String _w() =>
    String.fromCharCodes(List<int>.generate(6, (_) => 97 + _r.nextInt(26)));
final List<List<String>> _verses = List<List<String>>.generate(
  30,
  (_) => List<String>.generate(4, (_) => _w()),
);
String _ts(int ms) =>
    '[${(ms ~/ 60000).toString().padLeft(2, '0')}:'
    '${((ms % 60000) / 1000).toStringAsFixed(2).padLeft(5, '0')}]';
String _lrc(int Function(int i) at) => List<String>.generate(
  30,
  (int i) => '${_ts(at(i))}${_verses[i].join(' ')}',
).join('\n');
String _json(int Function(int i) at, {bool other = false}) {
  final List<List<Object>> w = <List<Object>>[];
  for (int i = 0; i < 30; i++) {
    for (int k = 0; k < 4; k++) {
      final double s = (at(i) + k * 400) / 1000;
      w.add(<Object>[s, s + 0.3, ' ${other ? _w() : _verses[i][k]}']);
    }
  }
  return jsonEncode(<String, Object>{'dur': 220.0, 'words': w});
}

int _first(String lrc) {
  final m = RegExp(r'^\[(\d+):(\d+\.\d+)\]').firstMatch(lrc)!;
  return int.parse(m[1]!) * 60000 + (double.parse(m[2]!) * 1000).round();
}

void main() {
  int base(int i) => 20000 + i * 6000;
  test('letra bien puesta: no cambia nada', () {
    final r = alignLyricToWords(
      lrc: _lrc(base),
      words: parseTimedWordsJson(_json(base)),
      durationMs: 220000,
    );
    expect(r.kind, LyricAiKind.none);
    expect(r.lrc, isNull);
  });
  test('A: desfase constante confirmado se corrige entero', () {
    final r = alignLyricToWords(
      lrc: _lrc((i) => base(i) + 1800),
      words: parseTimedWordsJson(_json(base)),
      durationMs: 220000,
    );
    expect(r.kind, LyricAiKind.constantShift);
    expect(_first(r.lrc!), 20000);
  });
  test('B: dos bloques con desfases distintos se realinean por partes', () {
    int audio(int i) => i < 15 ? base(i) : base(i) + 12000; // puente largo
    final r = alignLyricToWords(
      lrc: _lrc(base),
      words: parseTimedWordsJson(_json(audio)),
      durationMs: 220000,
    );
    expect(r.kind, LyricAiKind.segments);
    expect(r.lrc!.split('\n')[15].startsWith(_ts(base(15) + 12000)), isTrue);
    expect(r.lrc!.split('\n')[0].startsWith(_ts(base(0))), isTrue);
  });
  test('C: letra de otra canción → FAIL:lyric_wrong_song', () {
    final r = alignLyricToWords(
      lrc: _lrc(base),
      words: parseTimedWordsJson(_json(base, other: true)),
      durationMs: 220000,
    );
    expect(r.kind, LyricAiKind.wrongSong);
    expect(r.lrc, isNull);
    expect(r.failReason, startsWith('FAIL:lyric_wrong_song'));
  });
  test('pocas palabras: no inventa, queda en duda', () {
    final r = alignLyricToWords(
      lrc: _lrc(base),
      words: parseTimedWordsJson(_json(base)).take(20).toList(),
      durationMs: 220000,
    );
    expect(r.kind, LyricAiKind.unsure);
    expect(r.lrc, isNull);
    expect(r.failReason, startsWith('FAIL:lyric_ai_unsure'));
  });
}
