import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_match.dart';

void main() {
  test('q= sin artista acepta el alias entre paréntesis de LRCLIB', () {
    expect(
        lyricTitleOnlyScore('Duncan Dhu a un minuto de ti',
            'MIKEL ERENTXUN (DUNCAN DHU)', 'A UN MINUTO DE TI'),
        greaterThan(0));
    expect(
        lyricTitleOnlyScore('Mikel Erentxun a un minuto de ti',
            'MIKEL ERENTXUN (DUNCAN DHU)', 'A UN MINUTO DE TI'),
        greaterThan(0));
    expect(
        lyricTitleOnlyScore('Duncan Dhu en algun lugar',
            'MIKEL ERENTXUN (DUNCAN DHU)', 'A UN MINUTO DE TI'),
        0);
  });

  test('Duncan sin artista elige la letra de LRCLIB', () {
    final ids = lyricIdentities(
        path: '/x/Duncan Dhu a un minuto de ti.m4a', durationSec: 241);
    final ch = chooseLrclibLyric(ids.first, searched: [
      {
        'artistName': 'MIKEL ERENTXUN (DUNCAN DHU)',
        'trackName': 'A UN MINUTO DE TI',
        'duration': 235.0,
        'plainLyrics': 'Antes de tres lunas volvería por ti',
        'syncedLyrics': '',
      }
    ]);
    expect(ch.hasText, isTrue);
  });
}
