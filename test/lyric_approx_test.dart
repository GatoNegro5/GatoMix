import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_approx.dart';
import 'package:gatomix/core/master_skip.dart';

void main() {
  const studio = '[00:10.00]Linea uno\n[00:12.50]Linea dos\n';
  test('alinea el primer verso a la voz y pone la marca', () {
    final out = buildApproxLrc(studio, voiceOnsetMs: 3000);
    expect(lrcIsApprox(out), isTrue);
    expect(out, contains('[00:03.00]Linea uno'));
    expect(out, contains('[00:05.50]Linea dos'));
  });
  test('sin onset no mueve', () {
    expect(buildApproxLrc(studio), contains('[00:10.00]Linea uno'));
  });
  test('ajuste del usuario quita la marca', () {
    expect(lrcIsApprox('[00:03.00]Linea uno'), isFalse);
  });
  test('consulta limpia y mashup con primer artista', () {
    final q = approxQuery(
      artist: '',
      title: "Keepin' Magic Alive (Intro Mashup)",
      fileStem: 'Bee Gees Vs. Bruno Mars',
    );
    expect(q.artist, 'Bee Gees');
    expect(q.title, "Keepin' Magic Alive");
    final q2 = approxQuery(
      artist: '2 Unlimited',
      title: 'No Limit (Alejandro Dark Intro & Outro) 140 Bpm',
      fileStem: '',
    );
    expect(q2.title, 'No Limit');
  });
  test('elige la de estudio más cercana en duración y descarta karaoke', () {
    final rows = <Map<String, dynamic>>[
      {
        'artistName': 'America',
        'trackName': 'You Can Do Magic (Karaoke)',
        'duration': 223,
        'syncedLyrics': '[00:01.00]x',
      },
      {
        'artistName': 'America',
        'trackName': 'You Can Do Magic',
        'duration': 237,
        'syncedLyrics': '[00:01.00]a',
      },
      {
        'artistName': 'America',
        'trackName': 'You Can Do Magic',
        'duration': 234,
        'syncedLyrics': '[00:01.00]b',
      },
      {
        'artistName': 'Otro',
        'trackName': 'You Can Do Magic',
        'duration': 223,
        'syncedLyrics': '[00:01.00]c',
      },
    ];
    final r = pickApproxRow(
      rows,
      artist: 'America',
      title: 'You Can Do Magic',
      durationSec: 223,
    );
    expect(r!['syncedLyrics'], '[00:01.00]b');
  });
  test(
    'título parcial «Should Be Dancing» encaja con «You Should Be Dancing»',
    () {
      final rows = <Map<String, dynamic>>[
        {
          'artistName': 'Bee Gees',
          'trackName': 'You Should Be Dancing',
          'duration': 258,
          'syncedLyrics': '[00:01.00]y',
        },
      ];
      expect(
        pickApproxRow(
          rows,
          artist: 'Bee Gees',
          title: 'Should Be Dancing',
          durationSec: 100,
        ),
        isNotNull,
      );
    },
  );
  test('APPROX cuenta como completa para el salto rápido', () {
    final tags = {
      'GMX_TRIM_MS': '0',
      'GMX_LUFS_DONE': '-14',
      'GMX_BPM_OK': '1',
      '__SEAL': '1',
      'GMX_NAME_OK': '1',
      'GMX_BACKUP': '1',
      'GMX_LYR': 'APPROX',
      'GMX_LYR_CHECK': 'SKIP',
      'GMX_ANALYSIS': '3031',
    };
    expect(missingWork(tags, karaoke: false), isNull);
  });

  group('1.0.20+38 marca viaja', () {
    const ap = '[gmx_approx]\n[00:01.00]a\n';
    const ok = '[00:02.00]a\n';
    test('_K usa la letra de la canción normal', () {
      expect(approxLrcPath(r'C:\M\A - B_K.mp3'), r'C:\M\A - B.lrc');
      expect(approxOwnerAudio('/m/A - B_K.mp3'), '/m/A - B.mp3');
      expect(approxLrcPath('/m/A - B.mp3'), '/m/A - B.lrc');
    });
    test('quitar marca deja la letra', () {
      expect(stripApproxMark(ap), '[00:01.00]a\n');
      expect(stripApproxMark(ok), ok);
    });
    test('confirmado gana y nunca vuelve a APPROX', () {
      expect(
        lrcSyncShouldReplace(existing: ok, incoming: ap, overwrite: true),
        isFalse,
      );
      expect(
        lrcSyncShouldReplace(existing: ap, incoming: ok, overwrite: false),
        isTrue,
      );
      expect(
        lrcSyncShouldReplace(existing: null, incoming: ap, overwrite: false),
        isTrue,
      );
      expect(
        lrcSyncShouldReplace(existing: ap, incoming: ap, overwrite: false),
        isFalse,
      );
      expect(
        lrcSyncShouldReplace(existing: ok, incoming: ok, overwrite: true),
        isTrue,
      );
    });
  });
}
