import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_radio.dart';
import 'package:gatomix/core/gatomix_store.dart';

double bpmOf(String p) {
  final RegExpMatch? m = RegExp(r'(\d+)bpm').firstMatch(p);
  return m == null ? 0 : double.parse(m.group(1)!);
}

List<String> poolOf(String dir, int n) => <String>[
  for (var i = 0; i < n; i++) '$dir/t$i ${100 + i}bpm.mp3',
];

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

  test('cambiar de opción conserva la lista y la posición de cada una', () {
    final List<String> bailables = poolOf('/b', 8);
    final List<String> ochentas = poolOf('/o', 8);
    final RadioSync baila = syncRadioPlan(
      saved: null,
      pool: bailables,
      bpmOf: bpmOf,
      rng: Random(3),
    );
    final RadioSync ochenta = syncRadioPlan(
      saved: null,
      pool: ochentas,
      bpmOf: bpmOf,
      rng: Random(4),
    );
    final RadioPlan bailaEn2 = baila.plan.copy(position: 2);
    final RadioMemory mem = RadioMemory.empty
        .putPlan('bailable', bailaEn2)
        .putPlan('ochenteras', ochenta.plan);
    final RadioSync todo = syncRadioPlan(
      saved: mem.planOf('todo'),
      pool: <String>[...bailables, ...ochentas],
      bpmOf: bpmOf,
      rng: Random(5),
    );
    final RadioMemory withTodo = mem.putPlan('todo', todo.plan);
    final RadioSync otraVez = syncRadioPlan(
      saved: withTodo.planOf('ochenteras'),
      pool: ochentas,
      bpmOf: bpmOf,
      rng: Random(99),
    );
    expect(otraVez.rebuilt, isFalse);
    expect(sameRadioOrder(otraVez.plan.order, ochenta.plan.order), isTrue);
    expect(otraVez.plan.position, ochenta.plan.position);
    expect(
      sameRadioOrder(withTodo.planOf('bailable')!.order, bailaEn2.order),
      isTrue,
    );
    expect(withTodo.planOf('bailable')!.position, 2);
    expect(sameRadioOrder(withTodo.planOf('todo')!.order, todo.plan.order), isTrue);
  });

  test('encender y apagar no rearma la lista', () {
    final List<String> pool = poolOf('/m', 8);
    final RadioSync built = syncRadioPlan(
      saved: null,
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(1),
    );
    final RadioPlan mid = built.plan.copy(position: 3);
    final RadioSync on = syncRadioPlan(
      saved: mid,
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(8),
    );
    final RadioSync off = syncRadioPlan(
      saved: on.plan,
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(11),
    );
    expect(on.rebuilt, isFalse);
    expect(off.rebuilt, isFalse);
    expect(sameRadioOrder(off.plan.order, built.plan.order), isTrue);
    expect(off.plan.position, 3);
  });

  test('una vuelta cubre el fondo una vez y la siguiente es distinta', () {
    final List<String> pool = poolOf('/v', 10);
    final RadioSync first = syncRadioPlan(
      saved: null,
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(2),
    );
    expect(first.plan.order.toSet().length, pool.length);
    expect(first.plan.order.length, pool.length);
    for (final String p in pool) {
      expect(first.plan.order.any((String q) => q == p), isTrue);
    }
    final RadioPlan done = first.plan.copy(position: first.plan.order.length);
    final RadioSync second = syncRadioPlan(
      saved: done,
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(6),
    );
    expect(second.rebuilt, isTrue);
    expect(sameRadioOrder(second.plan.order, first.plan.order), isFalse);
    expect(second.plan.order.first == first.plan.order.first, isFalse);
    expect(second.plan.position, 0);
    expect(second.plan.previousPairs, isNotEmpty);
    expect(second.plan.order.toSet().length, pool.length);
  });

  test('lo nuevo entra en lo que falta y lo borrado sale', () {
    final List<String> pool = poolOf('/n', 6);
    final RadioSync built = syncRadioPlan(
      saved: null,
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(1),
    );
    final RadioPlan mid = built.plan.copy(position: 2);
    final String extra = '/n/extra 109bpm.mp3';
    final RadioSync grew = syncRadioPlan(
      saved: mid,
      pool: <String>[...pool, extra],
      bpmOf: bpmOf,
      rng: Random(1),
    );
    expect(grew.rebuilt, isFalse);
    expect(grew.plan.order.sublist(0, 2), mid.order.sublist(0, 2));
    expect(grew.plan.order.contains(extra), isTrue);
    expect(grew.plan.position, 2);
    final String gone = grew.plan.order[4];
    final List<String> left = <String>[
      for (final String p in grew.plan.order)
        if (p != gone) p,
    ];
    final RadioSync shrunk = syncRadioPlan(
      saved: grew.plan,
      pool: left,
      bpmOf: bpmOf,
      rng: Random(1),
    );
    expect(shrunk.plan.order.contains(gone), isFalse);
    expect(shrunk.rebuilt, isFalse);
  });

  test('la lista, la posición y las parejas quedan en LiveDj_Radio.json', () {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_radio_');
    final String s = Platform.pathSeparator;
    final File legacy = File('${dir.path}${s}DjPlaylists${s}_livedj_radio.json');
    legacy.parent.createSync(recursive: true);
    legacy.writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'history': <String>['/old/a.mp3', '/old/b.mp3'],
      }),
    );
    final RadioMemory migrated = GatomixRadio.load(
      dir.path,
      legacyPaths: <String>[legacy.path],
    );
    expect(migrated.history, <String>['/old/a.mp3', '/old/b.mp3']);
    expect(legacy.existsSync(), isFalse);
    final RadioSync plan = syncRadioPlan(
      saved: null,
      pool: poolOf('/z', 6),
      bpmOf: bpmOf,
      rng: Random(4),
    );
    final RadioPlan done = plan.plan.copy(position: plan.plan.order.length);
    final RadioSync next = syncRadioPlan(
      saved: done,
      pool: poolOf('/z', 6),
      bpmOf: bpmOf,
      rng: Random(9),
    );
    GatomixRadio.save(
      dir.path,
      migrated.putPlan('bailable', plan.plan).putPlan('ochenteras', next.plan),
      activeKey: 'ochenteras',
    );
    final RadioMemory loaded = GatomixRadio.load(dir.path);
    expect(loaded.planOf('bailable')!.position, plan.plan.position);
    expect(
      sameRadioOrder(loaded.planOf('bailable')!.order, plan.plan.order),
      isTrue,
    );
    expect(
      sameRadioOrder(loaded.planOf('ochenteras')!.order, next.plan.order),
      isTrue,
    );
    expect(loaded.planOf('ochenteras')!.previousPairs, isNotEmpty);
    final Map<String, dynamic> doc =
        jsonDecode(File('${dir.path}${s}LiveDj_Radio.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(doc['plans'], isA<Map>());
    expect(doc.containsKey('djMetadata'), isFalse);
    dir.deleteSync(recursive: true);
  });

  test('la sección radio de .gatomix.json pasa al archivo y se quita', () {
    final Directory root = Directory.systemTemp.createTempSync('gmx_sec_');
    final String s = Platform.pathSeparator;
    final Directory salsa = Directory('${root.path}${s}Salsa');
    salsa.createSync();
    final String tema = '${salsa.path}${s}Tema.mp3';
    writeDjMetadata(salsa.path, <String, dynamic>{
      tema: <String, dynamic>{'bpm': 118, 'key': '8A'},
    });
    File('${root.path}$s.gatomix.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'schema': 1,
        'djMetadata': <String, dynamic>{
          '/musica/otra.mp3': <String, dynamic>{'bpm': 100, 'key': '5B'},
        },
        'radio': <String, dynamic>{
          'history': <String>['/old/a.mp3', '/old/b.mp3'],
          'pairs': <String>['a\u0001b'],
          'waveUp': false,
          'inWave': 4,
          'previousBpm': 108,
        },
      }),
    );
    final RadioMemory moved = GatomixRadio.load(root.path);
    expect(moved.history, <String>['/old/a.mp3', '/old/b.mp3']);
    expect(moved.carriedPairs, <String>['a\u0001b']);
    expect(moved.waveUp, isFalse);
    expect(moved.previousBpm, 108);
    final Map<String, dynamic> folder =
        jsonDecode(File('${root.path}$s.gatomix.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(folder.containsKey('radio'), isFalse);
    expect(
      (folder['djMetadata'] as Map)['/musica/otra.mp3'],
      <String, dynamic>{'bpm': 100, 'key': '5B'},
    );
    expect(readDjMetadata(salsa.path)[tema], <String, dynamic>{
      'bpm': 118,
      'key': '8A',
    });
    expect(File('${root.path}${s}LiveDj_Radio.json').existsSync(), isTrue);
    final RadioMemory again = GatomixRadio.load(root.path);
    expect(again.history, moved.history);
    expect(
      jsonDecode(File('${root.path}$s.gatomix.json').readAsStringSync())
          .containsKey('radio'),
      isFalse,
    );
    root.deleteSync(recursive: true);
  });
}
