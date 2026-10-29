import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio_path.dart';
import 'package:gatomix/core/gatomix_radio.dart';
import 'package:gatomix/core/livedj_next.dart';
import 'package:gatomix/core/net/artist_info.dart';
import 'package:gatomix/core/session_store.dart';
import 'package:gatomix/services/adaptive_eq.dart';

double bpmOf(String p) {
  final RegExpMatch? m = RegExp(r'(\d+)bpm').firstMatch(p);
  return m == null ? 0 : double.parse(m.group(1)!);
}

List<String> spread(int n) => <String>[
  for (var i = 0; i < n; i++) '/m/Tema $i ${80 + (i % 70)}bpm.mp3',
];

List<String> flatBpm(int n, {String artist = 'Artista'}) => <String>[
  for (var i = 0; i < n; i++) '/m/$artist - Tema $i 120bpm.mp3',
];

void expectPermutation(List<String> order, List<String> pool) {
  expect(order.length, pool.length);
  expect(order.toSet().length, pool.length);
  for (final String p in pool) {
    expect(order.contains(p), isTrue, reason: p);
  }
}

void main() {
  test('pool de 1 y de 2 termina y no se queda sin pista', () {
    expect(
      buildDifferentRound(
        pool: <String>['/m/solo 100bpm.mp3'],
        bpmOf: bpmOf,
        rng: Random(1),
      ),
      <String>['/m/solo 100bpm.mp3'],
    );
    final List<String> two = <String>['/m/a 100bpm.mp3', '/m/b 104bpm.mp3'];
    final List<String> built = buildDifferentRound(
      pool: two,
      bpmOf: bpmOf,
      rng: Random(2),
    );
    expectPermutation(built, two);
    expect(
      radioQuickNext(pool: two, anchor: two.first, rng: Random(1)),
      two[1],
    );
    expect(
      radioQuickNext(pool: <String>[two.first], anchor: two.first),
      isNull,
    );
    expect(radioQuickNext(pool: const <String>[], anchor: null), isNull);
  });

  test('mismo BPM, mismo artista, todo en la vuelta anterior: termina', () {
    final List<String> pool = flatBpm(6000);
    final Stopwatch sw = Stopwatch()..start();
    final List<String> first = buildDifferentRound(
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(3),
    );
    final List<String> second = buildDifferentRound(
      pool: pool,
      bpmOf: bpmOf,
      previousOrder: first,
      previousPairs: radioPairsOf(first),
      rng: Random(9),
    );
    sw.stop();
    expectPermutation(first, pool);
    expectPermutation(second, pool);
    expect(
      sw.elapsedMilliseconds,
      lessThan(8000),
      reason: '${sw.elapsedMilliseconds} ms',
    );
  });

  test('8000 pistas con BPM repartido y saltos de 40 BPM: permutación', () {
    final List<String> pool = <String>[
      for (var i = 0; i < 8000; i++) '/m/t$i ${40 + (i % 5) * 40}bpm.mp3',
    ];
    final Stopwatch sw = Stopwatch()..start();
    final List<String> order = buildDifferentRound(
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(4),
    );
    sw.stop();
    expectPermutation(order, pool);
    expect(
      sw.elapsedMilliseconds,
      lessThan(8000),
      reason: '${sw.elapsedMilliseconds} ms',
    );
  });

  test('1500 pistas: el índice gana al bucle que llamaba audioPathKey por candidato', () {
    final List<String> pool = spread(1500);
    final Stopwatch neu = Stopwatch()..start();
    final List<String> order = buildDifferentRound(
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(7),
    );
    neu.stop();
    final Stopwatch old = Stopwatch()..start();
    var ops = 0;
    for (var left = pool.length; left > 1; left--) {
      for (var j = 0; j < left; j++) {
        audioPathKey(pool[j]);
        ops++;
      }
    }
    old.stop();
    expectPermutation(order, pool);
    expect(
      neu.elapsedMicroseconds,
      lessThan(old.elapsedMicroseconds),
      reason:
          'nuevo ${neu.elapsedMilliseconds} ms, '
          'bucle viejo $ops claves en ${old.elapsedMilliseconds} ms',
    );
  });

  test('300 pistas: la ola sigue siendo de saltos cortos', () {
    final List<String> pool = <String>[
      for (var i = 0; i < 300; i++) '/m/t$i ${80 + i}bpm.mp3',
    ];
    final List<String> order = buildDifferentRound(
      pool: pool,
      bpmOf: bpmOf,
      fixedFirst: pool[40],
      rng: Random(5),
    );
    expectPermutation(order, pool);
    expect(order.first, pool[40]);
    var close = 0;
    for (var i = 1; i < order.length; i++) {
      if ((bpmOf(order[i]) - bpmOf(order[i - 1])).abs() <= 12) close++;
    }
    expect(close / (order.length - 1), greaterThan(0.9));
  });

  test('la lista abierta no se rearma; la terminada sí pide otra vuelta', () {
    final List<String> pool = spread(12);
    final RadioSync built = syncRadioPlan(
      saved: null,
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(1),
    );
    expect(radioPlanIsOpen(built.plan, pool), isTrue);
    expect(
      radioPlanIsOpen(built.plan.copy(position: pool.length), pool),
      isFalse,
    );
    expect(radioPlanIsOpen(null, pool), isFalse);
    final List<String> grown = <String>[...pool, '/m/nueva 90bpm.mp3'];
    expect(radioPlanIsOpen(built.plan, grown), isFalse);
  });

  test('el armado en isolate devuelve la vuelta y no lanza', () async {
    final List<String> pool = spread(1500);
    final Stopwatch sw = Stopwatch()..start();
    final Map<String, Object?> raw = await compute(
      assembleRadioOffUi,
      <String, Object?>{'pool': pool, 'hasSaved': false, 'seed': 11},
    );
    sw.stop();
    expect(raw['ok'], isTrue, reason: '${raw['error']}');
    final List<String> order = <String>[
      for (final Object? p in raw['order'] as List) p.toString(),
    ];
    expectPermutation(order, pool);
    expect(
      sw.elapsedMilliseconds,
      lessThan(15000),
      reason: '${sw.elapsedMilliseconds} ms',
    );
  });

  test('Todo arma la lista completa y deja fuera la que suena', () async {
    final List<String> pool = spread(40);
    final String playing = pool[3];
    final String pinned = pool[7];
    final Map<String, Object?> raw = await assembleRadioOffUi(<String, Object?>{
      'pool': pool,
      'hasSaved': false,
      'seed': 3,
      'playing': playing,
      'pinned': pinned,
      'readTags': false,
    });
    expect(raw['ok'], isTrue, reason: '${raw['error']}');
    final List<String> order = <String>[
      for (final Object? p in raw['order'] as List) p.toString(),
    ];
    expect(order.contains(playing), isFalse);
    expect(order.length, pool.length - 1);
    expect(order.first, pinned);
    final List<String> upcoming = radioUpcomingPaths(
      plan: RadioPlan(order: order, position: 0),
      nextPath: pinned,
    );
    expect(upcoming.length, order.length);
    expect(upcoming, isNot(<String>[pinned]));
  });

  test('un plan de una canción no impide armar Todo', () {
    final List<String> pool = spread(12);
    final RadioPlan stub = RadioPlan(order: <String>[pool.first]);
    expect(radioPlanIsOpen(stub, pool), isFalse);
    final RadioResolve resolve = radioResolveNext(
      memory: RadioMemory.empty.putPlan('todo', stub),
      key: 'todo',
      pool: pool,
      playing: pool.first,
      bpmOf: bpmOf,
      allowRebuild: false,
      rng: Random(1),
    );
    expect(resolve.needsAssemble, isTrue);
    expect(resolve.next, isNot(pool.first));
    expect(resolve.followedPlan, isFalse);
  });

  test('un glitch de posición 0 no reescribe la sesión en bucle', () {
    var last = 0;
    var saves = 0;
    for (var i = 0; i < 4000; i++) {
      final int pos = i.isEven ? 0 : 180000;
      if (sessionPositionShouldSave(pos, last)) {
        saves++;
        last = pos;
      }
    }
    expect(saves, 1);
    expect(sessionPositionShouldSave(20000, 0), isTrue);
    expect(sessionPositionShouldSave(5000, 0), isFalse);
    expect(sessionPositionShouldSave(1000, 20000), isTrue);
  });

  test('sonoridad: masterizada se mide igual y no se anula a 0 dB', () {
    final List<int> done = AdaptiveEq.integratedLoudnessStarts(lufsDone: true);
    final List<int> open = AdaptiveEq.integratedLoudnessStarts(lufsDone: false);
    expect(done, open);
    expect(done.length, 40);
    expect(done.first, 0);
    expect(done.last, 1170);
    // Dentro de ±1 LU de −14, la ganancia es 0. Fuera, se corrige.
    expect(
      AdaptiveEq.soundCheckGainDb(lufs: -14.2, peakDb: -1.2, lufsDone: true),
      0,
    );
    expect(
      AdaptiveEq.soundCheckGainDb(lufs: -10, peakDb: -1.2, lufsDone: true),
      isNot(0),
    );
  });

  test('un fallo de artista no se reintenta en cada frame', () {
    final DateTime fail = DateTime.utc(2026, 10, 27, 12);
    expect(
      artistLookupCoolingDown(fail, fail.add(const Duration(seconds: 1))),
      isTrue,
    );
    expect(
      artistLookupCoolingDown(fail, fail.add(const Duration(minutes: 4))),
      isFalse,
    );
    expect(artistLookupCoolingDown(null, fail), isFalse);
  });
}
