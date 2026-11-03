import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio_path.dart';
import 'package:gatomix/core/dj_trace.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/providers/livedj_provider.dart';

class _Live extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

void main() {
  late Directory dir;
  final String sep = Platform.pathSeparator;

  List<String> make(Directory d, int n, {String tag = 't'}) => <String>[
    for (var i = 0; i < n; i++)
      (File(
        '${d.path}$sep$tag$i ${100 + i % 60}bpm.mp3',
      )..writeAsBytesSync(<int>[0])).path,
  ];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('gmx_batch3035_');
    djTraceFileOverride = '${dir.path}${sep}trace.txt';
  });

  tearDown(() {
    djTraceFileOverride = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('200 pistas = 1 escritura por carpeta', () async {
    final List<String> paths = make(dir, 200);
    final int before = GatomixStore.debugDiskWrites;
    await saveTrackMusicBatch(<TrackMusic>[
      for (var i = 0; i < paths.length; i++)
        (path: paths[i], bpm: 100.0 + i % 60, camelot: i.isEven ? '8A' : null),
    ]);
    expect(GatomixStore.debugDiskWrites - before, 1);
    final Map<String, dynamic> doc =
        jsonDecode(GatomixStore.fileOf(dir.path).readAsStringSync())
            as Map<String, dynamic>;
    final Map<String, dynamic> meta = doc['djMetadata'] as Map<String, dynamic>;
    expect(meta.length, 200);
    expect(meta[paths[0]], <String, dynamic>{'bpm': 100.0, 'key': '8A'});
    expect(meta[paths[1]], 101.0);
    expect(
      File('${GatomixStore.fileOf(dir.path).path}.tmp').existsSync(),
      isFalse,
    );

    await saveTrackMusicBatch(<TrackMusic>[
      (path: paths[1], bpm: 101.0, camelot: null),
      (path: paths[2], bpm: 0, camelot: null),
    ]);
    expect(GatomixStore.debugDiskWrites - before, 1, reason: 'sin cambios');
  });

  test('dos carpetas = dos escrituras; un BPM 0 no pisa el guardado', () async {
    final Directory other = Directory('${dir.path}${sep}otra')..createSync();
    final List<String> a = make(dir, 5);
    final List<String> b = make(other, 5, tag: 'o');
    final int before = GatomixStore.debugDiskWrites;
    await saveTrackMusicBatch(<TrackMusic>[
      for (final String p in <String>[...a, ...b])
        (path: p, bpm: 120.5, camelot: null),
    ]);
    expect(GatomixStore.debugDiskWrites - before, 2);
    await saveTrackMusicBatch(<TrackMusic>[
      (path: a[0], bpm: 0, camelot: '9B'),
    ]);
    final Map<String, dynamic> meta = readDjMetadata(dir.path);
    expect(meta[a[0]], <String, dynamic>{'bpm': 120.5, 'key': '9B'});
  });

  group('Live DJ', () {
    late ProviderContainer box;
    late LiveDjNotifier dj;

    setUp(() {
      box = ProviderContainer(
        overrides: <Override>[liveDjProvider.overrideWith(_Live.new)],
      );
      dj = box.read(liveDjProvider.notifier);
      dj.useSessionFile('${dir.path}${sep}liveDj.json');
      dj.useRadioLibrary(dir.path);
    });

    tearDown(() => box.dispose());

    test('shuffle deja el modo random al instante y arma por detrás', () async {
      final List<String> paths = make(dir, 30);
      dj.seedOffAirQueue(queue: paths);
      expect(
        box.read(liveDjProvider).mixStrategy,
        LiveDjMixStrategy.sequential,
      );
      dj.shuffleQueue();
      expect(box.read(liveDjProvider).mixStrategy, LiveDjMixStrategy.random);
      expect(
        box.read(liveDjProvider).queue.map((File f) => f.path).toList(),
        paths,
        reason: 'la lista todavía no se armó',
      );
      await dj.shuffleSettled;
      final List<String> after = box
          .read(liveDjProvider)
          .queue
          .map((File f) => f.path)
          .toList();
      expect(after.length, 30);
      expect(after.map(audioPathKey).toSet().length, 30);
      expect(after.toSet(), paths.toSet());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(File('${dir.path}${sep}liveDj.json').existsSync(), isTrue);
    });

    test(
      'addAllTracks de 200 pistas en random escribe una vez la carpeta',
      () async {
        final List<String> paths = make(dir, 200);
        dj.shuffleQueue();
        await dj.shuffleSettled;
        expect(box.read(liveDjProvider).mixStrategy, LiveDjMixStrategy.random);
        final int before = GatomixStore.debugDiskWrites;
        dj.addAllTracks(<File>[for (final String p in paths) File(p)]);
        await dj.addSettled;
        expect(box.read(liveDjProvider).queue.length, 200);
        expect(GatomixStore.debugDiskWrites - before, 1);
        final Map<String, dynamic> meta = readDjMetadata(dir.path);
        expect(meta.length, 200);
      },
    );
  });
}
