import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/livedj_order.dart';
import 'package:gatomix/core/session_store.dart';

double bpmFromName(String p) {
  final m = RegExp(r'(\d{2,3})bpm').firstMatch(p);
  return m == null ? 0 : double.parse(m.group(1)!);
}

void main() {
  group('SessionStore (sobrevive cortes y updates)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('gmx_sess'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('escrituras seguidas no dejan JSON roto', () async {
      final path = '${dir.path}/_livedj_session.json';
      final futures = <Future<void>>[];
      for (var i = 0; i < 50; i++) {
        futures.add(
          SessionStore.writeJson(path, {
            'queue': List.generate(50 - i, (k) => 'song$k.mp3'),
            'n': i,
          }),
        );
      }
      await Future.wait(futures);
      final data = jsonDecode(File(path).readAsStringSync());
      expect(data['n'], 49);
    });

    test('archivo principal dañado → se lee la copia .bak', () async {
      final path = '${dir.path}/s.json';
      await SessionStore.writeJson(path, {
        'queue': ['a.mp3'],
        'mixStrategy': 1,
      });
      await SessionStore.writeJson(path, {
        'queue': ['b.mp3'],
        'mixStrategy': 1,
      });
      File(path).writeAsStringSync('{"queue": ["b.mp3"]}}garbage');
      final data = SessionStore.readJson(path);
      expect(data['mixStrategy'], 1);
      expect(data['queue'], ['a.mp3']);
    });

    test('sesión de la versión anterior (sin schema ni sortMode) se lee', () {
      final path = '${dir.path}/old.json';
      File(path).writeAsStringSync(
        jsonEncode({
          'queue': ['x.mp3'],
          'mixStrategy': 1,
          'positionMs': 5,
        }),
      );
      final data = SessionStore.readJson(path) as Map;
      expect(data['queue'], ['x.mp3']);
      expect(data['sortMode'], isNull);
      final mode = LiveDjSortMode.values.firstWhere(
        (m) => m.name == data['sortMode'],
        orElse: () => LiveDjSortMode.manual,
      );
      expect(mode, LiveDjSortMode.manual);
    });

    test('pista renombrada por Masterizar se reencuentra', () {
      final a = File('${dir.path}/Elvis Presley - Always On My Mind.mp3')
        ..writeAsStringSync('x');
      final b = File('${dir.path}/Queen - Jump.mp3')..writeAsStringSync('x');
      final out = resolveSessionPaths([
        '${dir.path}/Elvis_Presley_-_Always_On_My_Mind (Official Video).mp3',
        b.path,
        '${dir.path}/Borrada - Del Todo.mp3',
      ]);
      expect(out, [a.path, b.path]);
    });
  });

  group('Orden Secuencial', () {
    final paths = [
      '/m/c 128bpm.mp3',
      '/m/a 90bpm.mp3',
      '/m/b.mp3',
      '/m/d 100bpm.mp3',
    ];
    test('A-Z', () {
      expect(sortLiveDjPaths(paths, LiveDjSortMode.alphabetical, bpmFromName), [
        '/m/a 90bpm.mp3',
        '/m/b.mp3',
        '/m/c 128bpm.mp3',
        '/m/d 100bpm.mp3',
      ]);
    });
    test('BPM ascendente y descendente (sin BPM al final)', () {
      expect(sortLiveDjPaths(paths, LiveDjSortMode.bpmAsc, bpmFromName), [
        '/m/a 90bpm.mp3',
        '/m/d 100bpm.mp3',
        '/m/c 128bpm.mp3',
        '/m/b.mp3',
      ]);
      expect(sortLiveDjPaths(paths, LiveDjSortMode.bpmDesc, bpmFromName), [
        '/m/c 128bpm.mp3',
        '/m/d 100bpm.mp3',
        '/m/a 90bpm.mp3',
        '/m/b.mp3',
      ]);
    });
    test('manual no toca el orden', () {
      expect(sortLiveDjPaths(paths, LiveDjSortMode.manual, bpmFromName), paths);
    });
  });

  group('Shuffle por grupos de 20', () {
    final lib = [
      for (var i = 0; i < 100; i++) '/m/song$i ${80 + i}bpm.mp3',
      '/m/sinbpm1.mp3',
      '/m/sinbpm2.mp3',
    ];

    test(
      'grupos de 20, alterna sube/baja, sin BPM al final, sin perder pistas',
      () {
        final g = buildShuffleGroups(lib, bpmFromName, 7);
        expect(g.take(5).every((x) => x.length == 20), isTrue);
        for (var i = 0; i < 5; i++) {
          final b = g[i].map(bpmFromName).toList();
          final sorted = List<double>.from(b)..sort();
          expect(
            b,
            i.isEven ? sorted : sorted.reversed.toList(),
            reason: 'grupo $i',
          );
        }
        expect(g.last.toSet(), {'/m/sinbpm1.mp3', '/m/sinbpm2.mp3'});
        final flat = g.expand((x) => x).toList();
        expect(flat.length, lib.length);
        expect(flat.toSet(), lib.toSet());
      },
    );

    test('los grupos se mantienen cerca en BPM (vecinos)', () {
      final g = buildShuffleGroups(lib, bpmFromName, 3);
      for (final x in g.take(5)) {
        final b = x.map(bpmFromName);
        expect(
          b.reduce((a, c) => a > c ? a : c) - b.reduce((a, c) => a < c ? a : c),
          lessThan(60),
        );
      }
    });

    test('cada Shuffle arma grupos nuevos (nunca repite)', () {
      final history = <String>{};
      for (var press = 0; press < 30; press++) {
        final r = pickFreshShuffle(lib, bpmFromName, history, Random(press));
        for (final x in r.groups.where((x) => x.length > 1 && x.length >= 20)) {
          final sig = groupSignature(x);
          expect(
            history.contains(sig),
            isFalse,
            reason: 'press $press repitió',
          );
          history.add(sig);
        }
      }
    });
  });
}
