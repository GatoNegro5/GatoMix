import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_match.dart';

Map<String, dynamic> row(String a, String t) => <String, dynamic>{
  'artistName': a,
  'trackName': t,
  'duration': 239.0,
};

void main() {
  test(
    'Yuri: campos al revés con año → respaldo intercambiado y sin año',
    () async {
      const id = LyricIdentity(
        artist: 'ESTE AMOR YA NO SE TOCA',
        title: 'YURI - 1983',
        durationSec: 239,
      );
      final asked = <String>[];
      final r = await lyricPoolWithFallback(id, (one, primary) async {
        asked.add('${one.artist}|${one.title}|$primary');
        return one.artist == 'YURI'
            ? [row('Yuri', 'Este Amor Ya No Se Toca')]
            : [];
      });
      expect(asked, <String>[
        'ESTE AMOR YA NO SE TOCA|YURI - 1983|true',
        'ESTE AMOR YA NO SE TOCA|YURI|false',
        'YURI - 1983|ESTE AMOR YA NO SE TOCA|false',
        'YURI|ESTE AMOR YA NO SE TOCA|false',
      ]);
      expect(r.pool, hasLength(1));
      expect(
        lyricFallbackLabel(r.fallback!),
        'Resultados para: YURI – ESTE AMOR YA NO SE TOCA',
      );
      // Los campos del usuario no cambian.
      expect(id.artist, 'ESTE AMOR YA NO SE TOCA');
      expect(id.title, 'YURI - 1983');
    },
  );

  test('con filas en la búsqueda original no hay respaldo', () async {
    const id = LyricIdentity(
      artist: 'Yuri',
      title: 'Este Amor Ya No Se Toca',
      durationSec: 239,
    );
    var calls = 0;
    final r = await lyricPoolWithFallback(id, (one, primary) async {
      calls++;
      return [row('Yuri', 'Este Amor Ya No Se Toca')];
    });
    expect(calls, 1);
    expect(r.fallback, isNull);
  });

  test('para en el primer respaldo con filas', () async {
    const id = LyricIdentity(
      artist: 'Don Medardo y sus Players',
      title: 'Este Amor no se toca - 2023',
      durationSec: 272,
    );
    var calls = 0;
    final r = await lyricPoolWithFallback(id, (one, primary) async {
      calls++;
      return primary ? [] : [row(one.artist, one.title)];
    });
    expect(calls, 2);
    expect(
      lyricFallbackLabel(r.fallback!),
      'Resultados para: Don Medardo y sus Players – Este Amor no se toca',
    );
  });

  test('todo vacío: sin respaldo y 0 filas', () async {
    const id = LyricIdentity(artist: 'A', title: 'B - 1999', durationSec: 200);
    final r = await lyricPoolWithFallback(id, (one, primary) async => []);
    expect(r.pool, isEmpty);
    expect(r.fallback, isNull);
  });
}
