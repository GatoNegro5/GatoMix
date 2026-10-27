import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio_path.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/core/livedj_order.dart';
import 'package:gatomix/core/master_skip.dart';
import 'package:gatomix/core/queue_bpm.dart';
import 'package:gatomix/services/track_tags.dart';

void main() {
  test(
    'caché vacía: otra forma de ruta sigue teniendo BPM y el salto es corto',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync('gmx_shuf_');
      final String sep = Platform.pathSeparator;
      final List<String> names = <String>[
        for (var i = 0; i < 40; i++) 'Tema $i.mp3',
        'Sin dato.mp3',
      ];
      final Map<String, double> bpm = <String, double>{
        for (var i = 0; i < 40; i++) 'Tema $i.mp3': 90 + i.toDouble(),
      };
      final Map<String, dynamic> meta = <String, dynamic>{};
      for (var i = 0; i < 40; i++) {
        final String real = '${dir.path}$sep${names[i]}';
        File(real).writeAsBytesSync(<int>[0]);
        meta['${dir.path}$sep.$sep${names[i]}'] = bpm[names[i]];
      }
      File('${dir.path}${sep}Sin dato.mp3').writeAsBytesSync(<int>[0]);
      File('${dir.path}${sep}_dj_metadata.json')
          .writeAsStringSync(jsonEncode(meta));
      TrackTags.clear();
      final List<String> queue = <String>[
        for (final String n in names) '${dir.path}$sep$n',
      ];
      await preloadQueueBpm(queue);
      expect(File('${dir.path}${sep}_dj_metadata.json').existsSync(), isFalse);
      final String alias = '${dir.path}${sep}otra${sep}..${sep}Tema 0.mp3';
      expect(TrackTags.peek(alias)?.bpm, 90);
      expect(TrackTags.peek(queue[10])?.bpm, 100);

      final HarmonicOrder first = buildHarmonicShuffle(
        queue,
        (String p) => TrackTags.peek(p)?.bpm ?? 0,
        keyOf: (String p) {
          final int i = queue.indexOf(p);
          if (i < 0 || i >= 40) return null;
          return '${(i % 12) + 1}${i.isEven ? 'A' : 'B'}';
        },
        fixedFirst: queue.first,
        playing: queue[3],
        rng: Random(4),
      );
      expect(first.tracks.contains(queue[3]), isFalse);
      expect(first.tracks.length, 40);
      expect(first.tracks.last, queue.last);
      final List<double> seq = first.tracks
          .map((String p) => TrackTags.peek(p)?.bpm ?? 0)
          .where((double b) => b > 0)
          .toList();
      var close = 0;
      var up = 0;
      var down = 0;
      for (var i = 1; i < seq.length; i++) {
        final double d = seq[i] - seq[i - 1];
        if (d.abs() <= 4) close++;
        if (i <= 20) {
          if (d > 0) up++;
          if (d < 0) down++;
        }
      }
      expect(close / (seq.length - 1), greaterThan(0.85));
      expect(up, greaterThan(down));

      GatomixStore.commitShuffleMemory(first.tracks, anchor: queue[3]);
      final ShuffleMemory mem = GatomixStore.loadShuffleMemory(queue);
      final HarmonicOrder second = buildHarmonicShuffle(
        queue,
        (String p) => TrackTags.peek(p)?.bpm ?? 0,
        keyOf: (String p) {
          final int i = queue.indexOf(p);
          if (i < 0 || i >= 40) return null;
          return '${(i % 12) + 1}${i.isEven ? 'A' : 'B'}';
        },
        fixedFirst: queue.first,
        playing: queue[3],
        usedPairs: mem.pairs,
        recentAge: mem.age,
        rng: Random(9),
      );
      final Set<String> again = <String>{};
      var shared = 0;
      var steps = 0;
      for (var i = 1; i < second.tracks.length; i++) {
        if ((TrackTags.peek(second.tracks[i])?.bpm ?? 0) <= 0) continue;
        if ((TrackTags.peek(second.tracks[i - 1])?.bpm ?? 0) <= 0) continue;
        steps++;
        final String pair = shufflePairKey(
          second.tracks[i - 1],
          second.tracks[i],
        );
        if (mem.pairs.contains(pair)) shared++;
        again.add(pair);
      }
      expect(steps, greaterThan(10));
      expect(shared / steps, lessThan(0.2));
      expect(again.length, steps);
      dir.deleteSync(recursive: true);
      TrackTags.clear();
    },
  );

  test('olas: 20 hacia arriba y las siguientes hacia abajo', () {
    final List<String> lib = <String>[
      for (var i = 0; i < 61; i++) '/m/t$i ${80 + i}bpm.mp3',
    ];
    double bpm(String p) {
      final RegExpMatch? m = RegExp(r'(\d+)bpm').firstMatch(p);
      return double.parse(m!.group(1)!);
    }

    final HarmonicOrder order = buildHarmonicShuffle(
      lib,
      bpm,
      fixedFirst: '/m/t20 100bpm.mp3',
      rng: Random(3),
      waveLength: 20,
    );
    final List<double> seq = order.tracks.map(bpm).toList();
    expect(seq.first, 100);
    double net(int from, int to) {
      var s = 0.0;
      for (var i = from + 1; i <= to && i < seq.length; i++) {
        s += seq[i] - seq[i - 1];
      }
      return s;
    }

    expect(net(0, 19), greaterThan(8));
    expect(net(19, 39), lessThan(-8));
    var close = 0;
    for (var i = 1; i < seq.length; i++) {
      if ((seq[i] - seq[i - 1]).abs() <= 4) close++;
    }
    expect(close / (seq.length - 1), greaterThan(0.85));
  });

  test(
    'Camelot compatible gana a un vecino de BPM igual sin tonalidad afín',
    () {
      final List<String> lib = <String>[
        '/m/ahora.mp3',
        '/m/bien.mp3',
        '/m/mal.mp3',
      ];
      double bpm(String p) => p.contains('mal') ? 104 : 100;
      String? key(String p) {
        if (p.contains('ahora')) return '8A';
        if (p.contains('bien')) return '8B';
        if (p.contains('mal')) return '3A';
        return null;
      }

      var compat = 0;
      for (var seed = 0; seed < 20; seed++) {
        final HarmonicOrder order = buildHarmonicShuffle(
          lib,
          bpm,
          keyOf: key,
          fixedFirst: lib.first,
          rng: Random(seed),
        );
        if (order.tracks[1].contains('bien')) compat++;
      }
      expect(compat, greaterThan(15));
      expect(camelotCompatible('8A', '8B'), isTrue);
      expect(camelotCompatible('8A', '9A'), isTrue);
      expect(camelotCompatible('12A', '1A'), isTrue);
      expect(camelotCompatible('8A', '3A'), isFalse);
    },
  );

  test('migración a .gatomix.json no pierde datos y no toca audio', () {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_json_');
    final String s = Platform.pathSeparator;
    File('${dir.path}${s}tema.mp3').writeAsStringSync('audio');
    File('${dir.path}${s}tema.lrc').writeAsStringSync('[00:01.00]hola');
    File('${dir.path}${s}tema_K.mp3').writeAsStringSync('karaoke');
    File('${dir.path}${s}.dj_master_checkpoint.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'schema': 2,
        'status': 'in_progress',
        'processed': <String>['tema.mp3'],
        'failed': <String>[],
      }),
    );
    File('${dir.path}${s}.gatomix_master_index.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'schema': 1,
        'entries': <String, dynamic>{
          'tema.mp3': <String, dynamic>{'state': 'OK', 'size': 5},
        },
      }),
    );
    File('${dir.path}${s}.gatomix_lyric_fail.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{'tema.mp3': 'FAIL:lyric'}),
    );
    File('${dir.path}${s}_dj_metadata.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{'${dir.path}${s}tema.mp3': 118}),
    );
    File('${dir.path}${s}_dj_timestamps.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{'${dir.path}${s}tema.mp3': 42}),
    );
    File('${dir.path}${s}_lyrics_auto.json')
        .writeAsStringSync(jsonEncode(<String, dynamic>{'tema.lrc': 12}));
    File('${dir.path}${s}shuffle_banks.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{'spin': 3, 'lists': <String, dynamic>{}}),
    );
    File('${dir.path}${s}.pass1.log')
        .writeAsStringSync('linea vieja de pass1\n');
    File('${dir.path}${s}.gatomix_master_headless.log')
        .writeAsStringSync('headless\n');

    expect(GatomixStore.migrate(dir.path), isTrue);
    final File store = File('${dir.path}${s}.gatomix.json');
    expect(store.existsSync(), isTrue);
    final Map<String, dynamic> doc =
        jsonDecode(store.readAsStringSync()) as Map<String, dynamic>;
    expect(doc['checkpoint'], isA<Map>());
    expect((doc['checkpoint'] as Map)['processed'], <dynamic>['tema.mp3']);
    expect((doc['masterIndex'] as Map)['entries'], isA<Map>());
    expect((doc['lyricFail'] as Map)['tema.mp3'], 'FAIL:lyric');
    expect((doc['djMetadata'] as Map)['${dir.path}${s}tema.mp3'], 118);
    expect((doc['djTimestamps'] as Map)['${dir.path}${s}tema.mp3'], 42);
    expect((doc['lyricsAuto'] as Map)['tema.lrc'], 12);
    expect((doc['shuffle'] as Map)['legacyAutomix'], isA<Map>());
    expect((doc['imported'] as Map)['.pass1.log'], isNull);
    for (final String name in <String>[
      '.dj_master_checkpoint.json',
      '.gatomix_master_index.json',
      '.gatomix_lyric_fail.json',
      '_dj_metadata.json',
      '_dj_timestamps.json',
      '_lyrics_auto.json',
      'shuffle_banks.json',
      '.pass1.log',
      '.gatomix_master_headless.log',
    ]) {
      expect(File('${dir.path}$s$name').existsSync(), isFalse, reason: name);
    }
    expect(File('${dir.path}${s}tema.mp3').readAsStringSync(), 'audio');
    expect(
      File('${dir.path}${s}tema.lrc').readAsStringSync(),
      contains('hola'),
    );
    expect(File('${dir.path}${s}tema_K.mp3').readAsStringSync(), 'karaoke');
    final String log = File('${dir.path}${s}.gatomix.log').readAsStringSync();
    expect(log, contains('linea vieja de pass1'));
    expect(log, contains('headless'));
    expect(utf8.encode(log).length, lessThan(gatomixLogMaxBytes));

    final MasterSkipIndex idx = MasterSkipIndex.load(dir.path);
    expect(idx.entries['tema.mp3']!['state'], 'OK');
    expect(readDjMetadata(dir.path)['${dir.path}${s}tema.mp3'], 118);
    expect(readLyricsAuto(dir.path)['tema.lrc'], 12);
    expect(
      audioPathKey('${dir.path}/./tema.mp3'),
      audioPathKey('${dir.path}${s}tema.mp3'),
    );
    dir.deleteSync(recursive: true);
  });

  double bpmOf(String p) {
    final RegExpMatch? m = RegExp(r'(\d+)bpm').firstMatch(p);
    return m == null ? 0 : double.parse(m.group(1)!);
  }

  String? keyOf(String p) => camelotFromPath(p);

  test('inserta una canción en el hueco de BPM y no mueve la actual ni la siguiente', () {
    final List<String> queue = <String>[
      '/q/siguiente 100bpm 8A.mp3',
      '/q/a 104bpm 8A.mp3',
      '/q/b 112bpm 9A.mp3',
      '/q/c 120bpm 9A.mp3',
    ];
    final List<String> next = insertHarmonicTracks(
      queue: queue,
      incoming: <String>['/q/nueva 108bpm 8A.mp3'],
      bpmOf: bpmOf,
      keyOf: keyOf,
      lockedPrefix: 1,
      playing: '/q/sonando 98bpm 8A.mp3',
      pinned: queue.first,
    );
    expect(next.first, queue.first);
    expect(next[1], queue[1]);
    expect(next[2], '/q/nueva 108bpm 8A.mp3');
    expect(next.contains('/q/sonando 98bpm 8A.mp3'), isFalse);
    expect(next.length, queue.length + 1);
  });

  test('inserta un lote en los huecos, sin duplicados y sin BPM al final', () {
    final List<String> queue = <String>[
      '/q/siguiente 100bpm 8A.mp3',
      '/q/a 104bpm 8A.mp3',
      '/q/b 112bpm 9A.mp3',
      '/q/c 120bpm 9A.mp3',
    ];
    final List<String> next = insertHarmonicTracks(
      queue: queue,
      incoming: <String>[
        '/q/nueva 108bpm 8A.mp3',
        '/q/otra 116bpm 9A.mp3',
        '/q/a 104bpm 8A.mp3',
        '/q/nueva 108bpm 8A.mp3',
        '/q/sin.mp3',
        '/q/tema_K.mp3',
      ],
      bpmOf: bpmOf,
      keyOf: keyOf,
      lockedPrefix: 1,
      playing: '/q/sonando 98bpm 8A.mp3',
      pinned: queue.first,
    );
    expect(next, <String>[
      queue[0],
      queue[1],
      '/q/nueva 108bpm 8A.mp3',
      queue[2],
      '/q/otra 116bpm 9A.mp3',
      queue[3],
      '/q/sin.mp3',
    ]);
    expect(next.toSet().length, next.length);
  });

  test('BPM y tonalidad se escriben al momento en .gatomix.json', () {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_tag_');
    final String s = Platform.pathSeparator;
    final String path = '${dir.path}${s}Tema 118bpm 8A.mp3';
    File(path).writeAsBytesSync(<int>[1, 2, 3]);
    saveTrackMusic(path, bpm: 118, camelot: '8A');
    final File store = File('${dir.path}${s}.gatomix.json');
    expect(store.existsSync(), isTrue);
    final Map<String, dynamic> doc =
        jsonDecode(store.readAsStringSync()) as Map<String, dynamic>;
    final Map<dynamic, dynamic> meta = doc['djMetadata'] as Map<dynamic, dynamic>;
    final dynamic row = meta[path];
    expect(row, isA<Map>());
    expect((row as Map)['bpm'], 118);
    expect(row['key'], '8A');
    expect(File(path).readAsBytesSync(), <int>[1, 2, 3]);
    expect(readStoredCamelot(path), '8A');
    expect(harmonicKeyOf(path), '8A');
    dir.deleteSync(recursive: true);
  });
}
