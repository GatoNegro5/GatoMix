import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio_path.dart';
import 'package:gatomix/core/livedj_order.dart';
import 'package:gatomix/core/session_restore.dart';
import 'package:gatomix/core/session_store.dart';
import 'package:gatomix/ui/widgets/app_version_label.dart';

void main() {
  const bool win = true;

  test('version visible 3.0.29', () {
    final String pub = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? m = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pub);
    expect(m?.group(1), '3.0.29+48');
    final String visible = 'v${AppVersionLabel.format('3.0.29', '48')}';
    expect(visible.startsWith('v3.0.29'), isTrue);
    expect(visible, contains('build 48'));
  });

  test('clave absoluta: separadores, mayúsculas y NFC', () {
    const String a = r'C:\Music\80s Ingles\2 Unlimited - No Limit.mp3';
    const String b = 'C:/music/80s ingles/2 unlimited - no limit.mp3';
    final String nfd = 'C:/Music/80s Inge\u0301s/Canción.mp3';
    final String nfc = 'C:/music/80s ingés/canción.mp3';
    expect(audioPathKey(a, foldCase: win), audioPathKey(b, foldCase: win));
    expect(audioPathKey(nfd, foldCase: win), audioPathKey(nfc, foldCase: win));
    expect(
      audioPathKey(r'C:\Music\80s\..\80s\A.mp3', foldCase: win),
      audioPathKey(r'C:\Music\80s\A.mp3', foldCase: win),
    );
    expect(sameAudioPath(a, b, foldCase: win), isTrue);
    // Linux/Android distinguen mayúsculas: no se fusionan dos archivos distintos.
    expect(sameAudioPath('/m/A.mp3', '/m/a.mp3', foldCase: false), isFalse);
  });

  test('dedupe de carpeta y cola no usa mtime', () {
    final List<String> files = dedupeAudioPaths(
      <String>[
        r'C:\Music\80s\Aerosmith - Walk This Way.mp3',
        r'c:/music/80s/aerosmith - walk this way.mp3',
        r'C:\Music\80s\Alice Cooper - Clones.mp3',
        r'C:\Music\80s\Alice Cooper - Clones_K.mp3',
      ],
      foldCase: win,
      dropKaraoke: true,
    );
    expect(files, <String>[
      r'C:\Music\80s\Aerosmith - Walk This Way.mp3',
      r'C:\Music\80s\Alice Cooper - Clones.mp3',
    ]);
  });

  test('restaurar Automix: cola, modo y posición sin duplicados', () {
    final AutomixSessionRestore r = restoreAutomixSession(
      <String, dynamic>{
        'playlist': <String>[
          r'C:\Music\80s\2 Unlimited - No Limit.mp3',
          r'c:/music/80s/2 unlimited - no limit.mp3',
          r'C:\Music\80s\2 Unlimited - No Limit_K.mp3',
          r'C:\Music\80s\Aerosmith - Walk This Way.mp3',
        ],
        'currentIndex': 1,
        'positionMs': 12000,
        'mixStrategy': 1,
        'autoMixArmed': true,
        'wasPlaying': false,
      },
      exists: (_) => true,
      foldCase: win,
    );
    expect(r.playlist, <String>[
      r'C:\Music\80s\2 Unlimited - No Limit.mp3',
      r'C:\Music\80s\Aerosmith - Walk This Way.mp3',
    ]);
    expect(r.playlist.where(isKaraokeAudioPath), isEmpty);
    expect(r.index, 0);
    expect(r.positionMs, 12000);
    expect(r.mixStrategyIndex, 1);
    expect(r.wasPlaying, isFalse);
  });

  test('restaurar Live DJ: cola, modo y posición sin duplicados', () {
    final LiveDjSessionRestore r = restoreLiveDjSession(
      <String, dynamic>{
        'queue': <String>[
          r'C:\Music\80s\2 Unlimited - No Limit.mp3',
          r'c:/music/80s/2 unlimited - no limit.mp3',
          r'C:\Music\80s\Alice Cooper - Clones_K.mp3',
          r'C:\Music\80s\Alice Cooper - Clones.mp3',
        ],
        'currentTrackPath': r'c:/music/80s/2 unlimited - no limit.mp3',
        'positionMs': 8000,
        'mixStrategy': 0,
        'mixMode': 1,
        'wasPlaying': true,
      },
      exists: (_) => true,
      foldCase: win,
    );
    expect(
      sameAudioPath(
        r.currentTrackPath,
        r'C:\Music\80s\2 Unlimited - No Limit.mp3',
        foldCase: win,
      ),
      isTrue,
    );
    expect(r.queue, <String>[r'C:\Music\80s\Alice Cooper - Clones.mp3']);
    expect(
      r.queue.any((p) => sameAudioPath(p, r.currentTrackPath, foldCase: win)),
      isFalse,
    );
    expect(r.queue.where(isKaraokeAudioPath), isEmpty);
    expect(r.positionMs, 8000);
    expect(r.mixStrategyIndex, 0);
    expect(r.mixModeIndex, 1);
    expect(r.wasPlaying, isTrue);
    expect(r.currentFromQueue, isFalse);
  });

  test(
    'Live DJ sin actual: la primera sale de la cola y no hereda posición',
    () {
      final LiveDjSessionRestore r = restoreLiveDjSession(
        <String, dynamic>{
          'queue': <String>[r'C:\Music\A.mp3', r'C:\Music\B.mp3'],
          'positionMs': 4000,
          'mixStrategy': 1,
        },
        exists: (_) => true,
        foldCase: win,
      );
      expect(r.currentTrackPath, r'C:\Music\A.mp3');
      expect(r.queue, <String>[r'C:\Music\B.mp3']);
      expect(r.positionMs, isNull);
      expect(r.currentFromQueue, isTrue);
      expect(r.mixStrategyIndex, 1);
    },
  );

  test('ninguna pista _K entra en cola restaurada ni en Shuffle', () {
    final List<String> saved = <String>[
      '/m/80s/A - Uno.mp3',
      '/m/80s/A - Uno_K.mp3',
      '/m/80s/B - Dos_k.MP3',
      '/m/80s/C - Tres.mp3',
    ];
    final List<String> restored = resolvePlayableSessionPaths(
      saved,
      exists: (_) => true,
    );
    expect(restored.where(isKaraokeSessionPath), isEmpty);
    expect(restored, <String>['/m/80s/A - Uno.mp3', '/m/80s/C - Tres.mp3']);

    final List<String> lib = <String>[
      for (var i = 0; i < 45; i++) '/m/song$i ${80 + (i % 25)}bpm.mp3',
      '/m/song0 80bpm_K.mp3',
      '/m/song1_k.mp3',
    ];
    final HarmonicOrder order = buildHarmonicShuffle(
      <String>[...lib, lib.first, lib.first.toUpperCase()],
      (String p) {
        final RegExpMatch? m = RegExp(r'(\d{2,3})bpm').firstMatch(p);
        return m == null ? 0 : double.parse(m.group(1)!);
      },
      playing: lib.first,
      rng: Random(4),
      foldCase: win,
    );
    final List<String> flat = order.tracks;
    expect(flat.where(isKaraokeAudioPath), isEmpty);
    final Set<String> keys = flat
        .map((p) => audioPathKey(p, foldCase: win))
        .toSet();
    expect(keys.length, flat.length);
    expect(flat.length, 44);
    expect(
      flat.any((p) => sameAudioPath(p, lib.first, foldCase: win)),
      isFalse,
    );
  });

  test('la siguiente nunca es la ruta que suena', () {
    const List<String> playlist = <String>[
      r'C:\Music\80s\No Limit.mp3',
      r'c:/music/80s/no limit.mp3',
      r'C:\Music\80s\Walk This Way.mp3',
    ];
    final int next = nextDifferentAudioIndex(
      playlist,
      0,
      playlist[0],
      foldCase: win,
    );
    expect(next, 2);
    expect(sameAudioPath(playlist[next], playlist[0], foldCase: win), isFalse);
    expect(
      nextDifferentAudioIndex(
        <String>[playlist[0], playlist[1]],
        0,
        playlist[0],
        foldCase: win,
      ),
      -1,
    );
  });
}
