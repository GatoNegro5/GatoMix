import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_match.dart';
import 'package:gatomix/core/track_name_clean.dart';

Map<String, dynamic> row(String a, String t, double d) => <String, dynamic>{
      'artistName': a,
      'trackName': t,
      'duration': d,
      'plainLyrics': 'Estalla la tormenta',
      'syncedLyrics': '[00:10.00] Estalla la tormenta',
    };

void main() {
  group('(c) separadores antes de quitar prohibidos', () {
    test('Don Medardo / 2023', () {
      expect(ytTitleToStem('Don Medardo y sus Players - Este Amor no se toca / 2023'),
          'Don Medardo y sus Players - Este Amor no se toca - 2023');
    });
    test('AC/DC sin espacios no es separador', () {
      expect(ytTitleToStem('AC/DC - Thunderstruck (Official Video)'),
          'ACDC - Thunderstruck');
    });
    test('Yuri con asteriscos y (REMASTERIZADO)', () {
      expect(ytTitleToStem('*ESTE AMOR YA NO SE TOCA* - YURI - 1983 (REMASTERIZADO)'),
          'ESTE AMOR YA NO SE TOCA - YURI - 1983');
    });
  });

  group('(b) año final', () {
    test('separadores válidos', () {
      expect(lyricStripYearSuffix('YURI - 1983'), 'YURI');
      expect(lyricStripYearSuffix('Este Amor no se toca - 2023'), 'Este Amor no se toca');
      expect(lyricStripYearSuffix('Este Amor no se toca / 2023'), 'Este Amor no se toca');
      expect(lyricStripYearSuffix('Tema | 1999'), 'Tema');
      expect(lyricStripYearSuffix('Tema (1983)'), 'Tema');
    });
    test('no toca títulos que son un año ni años sin separador', () {
      expect(lyricStripYearSuffix('1979'), '1979');
      expect(lyricStripYearSuffix('Año 2000'), 'Año 2000');
      expect(lyricStripYearSuffix('Summer of 69'), 'Summer of 69');
    });
    test('Smashing Pumpkins 1979 conserva nombre y título', () {
      final CleanTrackName n = cleanTrackFileName('1979 - The Smashing Pumpkins - 1979.mp3');
      expect(n.stem, '1979 - The Smashing Pumpkins - 1979');
      final id = lyricIdentities(
              path: '/x/The Smashing Pumpkins - 1979.mp3', durationSec: 265)
          .first;
      expect(id.title, '1979');
      expect(lyricFallbackIdentities(id).map((e) => '${e.artist}|${e.title}'),
          <String>['1979|The Smashing Pumpkins']);
    });
  });

  group('(a) reintentos', () {
    test('Yuri: sin año, intercambiado, ambos', () {
      final id = lyricIdentities(
              path: '/x/ESTE AMOR YA NO SE TOCA - YURI - 1983.m4a', durationSec: 239)
          .first;
      expect('${id.artist}|${id.title}', 'ESTE AMOR YA NO SE TOCA|YURI - 1983');
      final fb = lyricFallbackIdentities(id).map((e) => '${e.artist}|${e.title}').toList();
      expect(fb, <String>[
        'ESTE AMOR YA NO SE TOCA|YURI',
        'YURI - 1983|ESTE AMOR YA NO SE TOCA',
        'YURI|ESTE AMOR YA NO SE TOCA',
      ]);
      final ch = chooseLrclibLyric(lyricFallbackIdentities(id).last,
          searched: [row('Yuri', 'Este Amor Ya No Se Toca', 238)]);
      expect(ch.hasText, isTrue);
    });
    test('Don Medardo 2023: reintento sin año primero', () {
      final id = lyricIdentities(
              path: '/x/Don Medardo y sus Players - Este Amor no se toca - 2023.m4a',
              durationSec: 272)
          .first;
      final first = lyricFallbackIdentities(id).first;
      expect('${first.artist}|${first.title}', 'Don Medardo y sus Players|Este Amor no se toca');
      // Otra versión (222 s, 50 s de diferencia) no se acepta.
      expect(chooseLrclibLyric(first,
          searched: [row('Don Medardo y sus Players', 'Este Amor No Se Toca', 222)]).hasText,
          isFalse);
      expect(chooseLrclibLyric(first,
          searched: [row('Don Medardo y sus Players', 'Este Amor No Se Toca', 271)]).hasText,
          isTrue);
    });
    test('sin artista ni año no hay reintentos', () {
      final id = lyricIdentities(path: '/x/Duncan Dhu a un minuto de ti.m4a', durationSec: 241).first;
      expect(lyricFallbackIdentities(id), isEmpty);
    });
  });
}
