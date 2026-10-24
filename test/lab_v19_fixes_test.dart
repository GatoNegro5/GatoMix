import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_files.dart';
import 'package:gatomix/core/lyric_match.dart';
import 'package:gatomix/core/track_name_clean.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('lab19'));
  tearDown(() async => dir.delete(recursive: true));

  group('1) .lrc.bak guarda el original', () {
    test(
      'aplicar dos veces no pisa el .bak; deshacer vuelve al original',
      () async {
        final lrc = '${dir.path}/a.lrc';
        File(lrc).writeAsStringSync('ORIGINAL');
        await writeLrcKeepingBak(lrc, 'PRIMERA');
        await writeLrcKeepingBak(lrc, 'SEGUNDA');
        expect(File('$lrc.bak').readAsStringSync(), 'ORIGINAL');
        expect(File(lrc).readAsStringSync(), 'SEGUNDA');
        expect(await undoAppliedLrc(lrc), isTrue);
        expect(File(lrc).readAsStringSync(), 'ORIGINAL');
      },
    );
    test(
      'sin .lrc previo: marca sin-original y deshacer borra el nuevo',
      () async {
        final lrc = '${dir.path}/b.lrc';
        await writeLrcKeepingBak(lrc, 'X');
        await writeLrcKeepingBak(lrc, 'Y');
        expect(File('$lrc.bak').readAsStringSync().trim(), kLrcNoOriginalMark);
        expect(await undoAppliedLrc(lrc), isTrue);
        expect(File(lrc).existsSync(), isFalse);
        expect(File('$lrc.bak').existsSync(), isFalse);
      },
    );
  });

  group('2) Destruir limpia .lrc y .lrc.bak de cualquier audio', () {
    for (final ext in kLabAudioExts) {
      test(ext, () {
        final audio = '${dir.path}/Song.$ext';
        File('${dir.path}/Song.lrc').writeAsStringSync('l');
        File('${dir.path}/Song.lrc.bak').writeAsStringSync('b');
        File('${dir.path}/Other.lrc').writeAsStringSync('keep');
        expect(deleteLrcSidecarsSync(audio).length, 2);
        expect(File('${dir.path}/Song.lrc').existsSync(), isFalse);
        expect(File('${dir.path}/Song.lrc.bak').existsSync(), isFalse);
        expect(File('${dir.path}/Other.lrc').existsSync(), isTrue);
      });
    }
    test('lrcPathForAudio', () {
      expect(lrcPathForAudio('/x/A.M4A'), '/x/A.lrc');
      expect(lrcPathForAudio('/x/A.ogg'), '/x/A.lrc');
    });
  });

  group('3) Restaurar no sobrescribe', () {
    test('destino existe: no mueve ni pisa', () async {
      final src = File('${dir.path}/lab.mp3')..writeAsStringSync('LAB');
      final dst = File('${dir.path}/orig.mp3')..writeAsStringSync('ORIGEN');
      expect(await moveFileNoOverwrite(src.path, dst.path), LabMove.destExists);
      expect(src.readAsStringSync(), 'LAB');
      expect(dst.readAsStringSync(), 'ORIGEN');
    });
    test('destino libre: mueve', () async {
      final src = File('${dir.path}/lab.mp3')..writeAsStringSync('LAB');
      final dst = '${dir.path}/sub_orig.mp3';
      expect(await moveFileNoOverwrite(src.path, dst), LabMove.moved);
      expect(src.existsSync(), isFalse);
      expect(File(dst).readAsStringSync(), 'LAB');
    });
    test('.lrc en origen existente se conserva', () async {
      File('${dir.path}/lab.lrc').writeAsStringSync('LAB');
      File('${dir.path}/o.lrc').writeAsStringSync('ORIGEN');
      final r = await moveLabLrcToOrigin(
        labLrcPath: '${dir.path}/lab.lrc',
        originLrcPath: '${dir.path}/o.lrc',
      );
      expect(r, LabLrcRestore.keptOrigin);
      expect(File('${dir.path}/o.lrc').readAsStringSync(), 'ORIGEN');
      expect(File('${dir.path}/lab.lrc').existsSync(), isTrue);
    });
  });

  group('4) colas de YouTube al final', () {
    final cases = <String, (String, String)>{
      'Duncan Dhu  a un minuto de ti letra': (
        '',
        'Duncan Dhu a un minuto de ti',
      ),
      'Duncan Dhu - A Un Minuto De Ti (Letra)': (
        'Duncan Dhu',
        'A Un Minuto De Ti',
      ),
      'Mana - Rayando el sol [letra]': ('Mana', 'Rayando el sol'),
      'Shakira - Antologia - letra': ('Shakira', 'Antologia'),
      'Juanes - A Dios le pido con letra': ('Juanes', 'A Dios le pido'),
      'Soda Stereo - De musica ligera lyric video': (
        'Soda Stereo',
        'De musica ligera',
      ),
      'Karol G - Provenza Video Oficial': ('Karol G', 'Provenza'),
      'Queen - Bohemian Rhapsody (Lyrics)': ('Queen', 'Bohemian Rhapsody'),
      'Ricardo Arjona - Letra de la cancion': (
        'Ricardo Arjona',
        'Letra de la cancion',
      ),
      'Letra': ('', 'Letra'),
    };
    cases.forEach((input, want) {
      test(input, () {
        final c = cleanTrackFileName('$input.mp3');
        expect((c.artist, c.title), want);
      });
    });
  });

  group('4b) sin artista busca por q=', () {
    test('URI q= con el título completo', () {
      const id = LyricIdentity(
        artist: '',
        title: 'Duncan Dhu a un minuto de ti',
        durationSec: 240,
      );
      final u = lrclibTitleOnlyUri(id)!;
      expect(u.queryParameters['q'], 'Duncan Dhu a un minuto de ti');
      expect(
        lrclibTitleOnlyUri(
          const LyricIdentity(artist: 'X', title: 'Y', durationSec: 1),
        ),
        isNull,
      );
    });
    test('elige el resultado cuyo artista está en el título', () {
      const id = LyricIdentity(
        artist: '',
        title: 'Duncan Dhu a un minuto de ti',
        durationSec: 240,
      );
      final c = chooseLrclibLyric(
        id,
        searched: [
          {
            'artistName': 'Otro',
            'trackName': 'A un minuto de ti',
            'duration': 240,
            'plainLyrics': 'NO',
          },
          {
            'artistName': 'Duncan Dhu',
            'trackName': 'A Un Minuto De Ti',
            'duration': 241,
            'plainLyrics': 'SI',
          },
        ],
      );
      expect(c.hasText, isTrue);
      expect(c.fileText, contains('SI'));
    });
  });
}
