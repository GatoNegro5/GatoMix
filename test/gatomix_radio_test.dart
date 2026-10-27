import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_radio.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/core/livedj_order.dart';
import 'package:gatomix/core/queue_bpm.dart';
import 'package:gatomix/services/track_tags.dart';

double bpmOf(String p) {
  final RegExpMatch? m = RegExp(r'(\d+)bpm').firstMatch(p);
  return m == null ? 0 : double.parse(m.group(1)!);
}

String artistOf(String p) {
  var name = p.replaceAll('\\', '/').split('/').last;
  final int dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  final int i = name.indexOf(' - ');
  if (i <= 0) return '';
  return name.substring(0, i).toLowerCase().trim();
}

void main() {
  test('apagar la radio devuelve la misma cola, orden y posición', () {
    const LiveQueueFreeze freeze = LiveQueueFreeze(
      queue: <String>['/dj/a.mp3', '/dj/b.mp3', '/dj/c.mp3'],
      current: '/dj/sonando.mp3',
      positionMs: 32500,
      wasPlaying: true,
    );
    final LiveQueueFreeze back = resumeLiveQueue(freeze);
    expect(back.queue, freeze.queue);
    expect(back.current, '/dj/sonando.mp3');
    expect(back.positionMs, 32500);
    expect(back.wasPlaying, isTrue);
    expect(back.queue.contains('/radio/otra.mp3'), isFalse);
  });

  test('bailables junta salsa, cumbia y merengue en un solo fondo', () {
    const Map<String, List<String>> folders = <String, List<String>>{
      '/Musica/Salsa': <String>['/Musica/Salsa/a.mp3', '/Musica/Salsa/b.mp3'],
      '/Musica/Cumbias': <String>['/Musica/Cumbias/c.mp3'],
      '/Musica/Merengues': <String>['/Musica/Merengues/d.mp3'],
      '/Musica/Rock': <String>['/Musica/Rock/e.mp3'],
    };
    const Map<String, String> genre = <String, String>{
      '/Musica/Salsa': 'bailable',
      '/Musica/Cumbias': 'bailable',
      '/Musica/Merengues': 'bailable',
      '/Musica/Rock': 'rock',
    };
    final List<String> bailables = radioPool(
      byFolder: folders,
      folderGenre: genre,
      genres: <String>{'bailable'},
    );
    expect(bailables, <String>[
      '/Musica/Salsa/a.mp3',
      '/Musica/Salsa/b.mp3',
      '/Musica/Cumbias/c.mp3',
      '/Musica/Merengues/d.mp3',
    ]);
    final List<String> todo = radioPool(
      byFolder: folders,
      folderGenre: genre,
      genres: <String>{},
    );
    expect(todo.length, 5);
    expect(todo.contains('/Musica/Rock/e.mp3'), isTrue);
  });

  test('la siguiente respeta BPM, Camelot, artista, explorador e historial', () {
    const String now = '/now/sonando 100bpm 8A.mp3';
    const String buena = '/bail/una 100bpm 8A.mp3';
    const String otra = '/bail/dos 102bpm 9A.mp3';
    const String tercera = '/bail/tres 103bpm 8B.mp3';
    const String usada = '/bail/usada 101bpm 8A.mp3';
    const String lejos = '/bail/lejos 104bpm 3A.mp3';
    final List<String> pool = <String>[buena, otra, tercera, usada, lejos];
    final RadioChoice pick = chooseRadioTrack(
      pool: pool,
      memory: RadioMemory(
        pairs: <String>[shufflePairKey(now, usada)],
        previousBpm: 100,
      ),
      bpmOf: bpmOf,
      keyOf: camelotFromPath,
      artistOf: artistOf,
      anchorPath: now,
      anchorBpm: 100,
      playing: now,
      rng: Random(1),
    );
    expect(<String>[buena, otra, tercera].contains(pick.path), isTrue);
    expect(pick.path == usada, isFalse);
    expect(pick.path == lejos, isFalse);

    const String mismo = '/bail/Salsa Band - tema 102bpm 8A.mp3';
    const String cambio = '/bail/Otra Gente - tema 103bpm 8A.mp3';
    final RadioChoice artista = chooseRadioTrack(
      pool: <String>[mismo, cambio],
      memory: const RadioMemory(lastArtist: 'salsa band'),
      bpmOf: bpmOf,
      keyOf: camelotFromPath,
      artistOf: artistOf,
      anchorPath: now,
      anchorBpm: 100,
      playing: now,
      rng: Random(2),
    );
    expect(artista.path, cambio);

    final RadioChoice explorador = chooseRadioTrack(
      pool: <String>[
        '/music/salsa/abierta 102bpm 8A.mp3',
        '/music/cumbia/libre 103bpm 8A.mp3',
      ],
      memory: RadioMemory.empty,
      bpmOf: bpmOf,
      keyOf: camelotFromPath,
      artistOf: artistOf,
      anchorPath: now,
      anchorBpm: 100,
      explorerPrefix: '/music/salsa/',
      playing: now,
      rng: Random(3),
    );
    expect(explorador.path, '/music/cumbia/libre 103bpm 8A.mp3');

    final RadioChoice historial = chooseRadioTrack(
      pool: <String>[
        '/bail/ya 102bpm 8A.mp3',
        '/bail/nueva 103bpm 8A.mp3',
      ],
      memory: const RadioMemory(history: <String>['/bail/ya 102bpm 8A.mp3']),
      bpmOf: bpmOf,
      keyOf: camelotFromPath,
      artistOf: artistOf,
      anchorPath: now,
      anchorBpm: 100,
      playing: now,
      rng: Random(4),
    );
    expect(historial.path, '/bail/nueva 103bpm 8A.mp3');
  });

  test('una pareja A→B ya usada no vuelve mientras haya otra cerca', () {
    const String now = '/now/sonando 100bpm 8A.mp3';
    const String usada = '/bail/usada 101bpm 8A.mp3';
    const String libre = '/bail/libre 102bpm 8A.mp3';
    final RadioMemory mem = noteRadioPlayed(
      const RadioMemory(previousBpm: 100),
      usada,
      bpm: 101,
      artist: '',
    );
    final RadioMemory conPar = RadioMemory(
      history: mem.history,
      pairs: <String>[shufflePairKey(now, usada)],
      previousBpm: 100,
      lastPath: now,
    );
    final RadioChoice next = chooseRadioTrack(
      pool: <String>[
        usada,
        libre,
        '/bail/otra 103bpm 9A.mp3',
        '/bail/mas 100bpm 8A.mp3',
        '/bail/cuatro 104bpm 8B.mp3',
      ],
      memory: conPar,
      bpmOf: bpmOf,
      keyOf: camelotFromPath,
      artistOf: artistOf,
      anchorPath: now,
      anchorBpm: 100,
      playing: now,
      rng: Random(7),
    );
    expect(next.path == usada, isFalse);
    final RadioMemory played = noteRadioPlayed(
      conPar,
      next.path!,
      bpm: bpmOf(next.path!),
      artist: '',
    );
    expect(played.pairs.contains(shufflePairKey(now, usada)), isTrue);
    expect(played.pairs.contains(shufflePairKey(now, next.path!)), isTrue);
  });

  test('el historial viejo pasa a la sección radio y el json viejo se borra', () {
    final Directory root = Directory.systemTemp.createTempSync('gmx_radio_');
    final String s = Platform.pathSeparator;
    final Directory salsa = Directory('${root.path}${s}Salsa');
    salsa.createSync();
    final String tema = '${salsa.path}${s}Tema.mp3';
    writeDjMetadata(salsa.path, <String, dynamic>{tema: 110});
    final File legacy = File('${root.path}${s}DjPlaylists${s}_livedj_radio.json');
    legacy.parent.createSync(recursive: true);
    legacy.writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'history': <String>['/old/a.mp3', '/old/b.mp3'],
      }),
    );
    final RadioMemory migrated = GatomixRadio.load(
      root.path,
      legacyPaths: <String>[legacy.path],
    );
    expect(migrated.history, <String>['/old/a.mp3', '/old/b.mp3']);
    expect(legacy.existsSync(), isFalse);
    expect(
      File('${root.path}$s$retiredRadioFileName').existsSync(),
      isFalse,
    );
    final Map<String, dynamic> doc =
        jsonDecode(File('${root.path}$s.gatomix.json').readAsStringSync())
            as Map<String, dynamic>;
    final Map<String, dynamic> radio = doc['radio'] as Map<String, dynamic>;
    expect(radio['history'], <String>['/old/a.mp3', '/old/b.mp3']);
    expect(radio.containsKey('order'), isFalse);
    expect(doc.containsKey('plans'), isFalse);
    expect(readDjMetadata(salsa.path)[tema], 110);
    final RadioMemory again = GatomixRadio.load(
      root.path,
      legacyPaths: <String>[legacy.path],
    );
    expect(again.history, migrated.history);
    root.deleteSync(recursive: true);
  });

  test('el BPM guardado se lee con la clave canónica', () {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_bpm_key_');
    final String s = Platform.pathSeparator;
    final String real = '${dir.path}${s}Tema.mp3';
    File(real).writeAsBytesSync(<int>[1]);
    writeDjMetadata(dir.path, <String, dynamic>{
      '${dir.path}$s.${s}Tema.mp3': 118,
    });
    TrackTags.clear();
    expect(knownBpm(real), 118);
    expect(TrackTags.peek('${dir.path}/otra/../Tema.mp3')?.bpm, 118);
    dir.deleteSync(recursive: true);
    TrackTags.clear();
  });
}
