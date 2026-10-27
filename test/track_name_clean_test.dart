import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/track_name_clean.dart';

void main() {
  test('quita prefijo BPM, Camelot, sufijo y basura de YouTube', () {
    final CleanTrackName a = cleanTrackFileName(
      '85 Bpm - Artista - Titulo.mp3',
    );
    expect(a.stem, 'Artista - Titulo');
    expect(a.bpmHint, 85);

    final CleanTrackName b = cleanTrackFileName('120 - Artista - Tema.mp3');
    expect(b.stem, 'Artista - Tema');
    expect(b.bpmHint, 120);

    final CleanTrackName c = cleanTrackFileName(
      '137 - 6a - Artista - Song [extended] (official video) (lyrics).mp3',
    );
    expect(c.stem, 'Artista - Song');
    expect(c.camelot, '6A');
    expect(c.bpmHint, 137);

    final CleanTrackName d = cleanTrackFileName('Artista - Tema 74bpm.mp3');
    expect(d.stem, 'Artista - Tema');
    expect(d.bpmHint, 74);
  });

  test('un año de 4 cifras no se trata como BPM', () {
    final CleanTrackName n = cleanTrackFileName(
      '1979 - The Smashing Pumpkins - 1979.mp3',
    );
    expect(n.stem, '1979 - The Smashing Pumpkins - 1979');
    expect(n.bpmHint, isNull);
  });

  test('endereza Título - Artista con el ID3', () {
    final CleanTrackName n = cleanTrackFileName(
      'September - Earth Wind.mp3',
      id3Artist: 'Earth Wind',
      id3Title: 'September',
    );
    expect(n.artist, 'Earth Wind');
    expect(n.title, 'September');
    expect(n.stem, 'Earth Wind - September');
  });

  test('quita el sello o el canal entre paréntesis, en cualquier caja', () {
    expect(
      cleanTrackFileName(
        'Los Mirlos - La Danza de los Mirlos (Infopesa).mp3',
      ).stem,
      'Los Mirlos - La Danza de los Mirlos',
    );
    expect(
      cleanTrackFileName('Los Mirlos - La Danza (infopesa).mp3').stem,
      'Los Mirlos - La Danza',
    );
    expect(
      cleanTrackFileName('Artista - Tema [INFOPESA].mp3').stem,
      'Artista - Tema',
    );
    expect(
      cleanTrackFileName('Artista - Tema (Discos Fuentes).mp3').stem,
      'Artista - Tema',
    );
    expect(
      cleanTrackFileName('Artista - Tema (Vevo).mp3').stem,
      'Artista - Tema',
    );
    expect(
      cleanTrackFileName('Artista - Tema (En Vivo).mp3').stem,
      'Artista - Tema (En Vivo)',
    );
  });

  test('si el nombre choca, agrega (2) y no pisa', () {
    final String name = uniqueMp3Name(
      'Artista - Titulo',
      (String fileName) => fileName == 'Artista - Titulo.mp3',
    );
    expect(name, 'Artista - Titulo (2).mp3');
  });
}
