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
      final String sep = Platform.pathSeparator;
      final a = File('${dir.path}${sep}Elvis Presley - Always On My Mind.mp3')
        ..writeAsStringSync('x');
      final b = File('${dir.path}${sep}Queen - Jump.mp3')
        ..writeAsStringSync('x');
      final out = resolveSessionPaths([
        '${dir.path}${sep}Elvis_Presley_-_Always_On_My_Mind (Official Video).mp3',
        b.path,
        '${dir.path}${sep}Borrada - Del Todo.mp3',
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

  group('Shuffle armónico', () {
    final lib = [
      for (var i = 0; i < 100; i++) '/m/song$i ${80 + i}bpm.mp3',
      '/m/sinbpm1.mp3',
      '/m/sinbpm2.mp3',
    ];

    test('sin BPM al final, sin perder pistas, saltos cortos', () {
      final HarmonicOrder order = buildHarmonicShuffle(
        lib,
        bpmFromName,
        fixedFirst: lib.first,
        rng: Random(7),
      );
      final List<String> flat = order.tracks;
      expect(flat.length, lib.length);
      expect(flat.toSet(), lib.toSet());
      expect(flat.sublist(flat.length - 2).toSet(), {
        '/m/sinbpm1.mp3',
        '/m/sinbpm2.mp3',
      });
      final List<double> bpm = flat
          .map(bpmFromName)
          .where((double b) => b > 0)
          .toList();
      var close = 0;
      for (var i = 1; i < bpm.length; i++) {
        if ((bpm[i] - bpm[i - 1]).abs() <= 4) close++;
      }
      expect(close / (bpm.length - 1), greaterThan(0.9));
    });

    test('dos shuffles no repiten el par A→B', () {
      final HarmonicOrder first = buildHarmonicShuffle(
        lib,
        bpmFromName,
        fixedFirst: '/m/song20 100bpm.mp3',
        rng: Random(1),
      );
      final Set<String> pairs = <String>{};
      for (var i = 1; i < first.tracks.length; i++) {
        if (bpmFromName(first.tracks[i]) <= 0) continue;
        if (bpmFromName(first.tracks[i - 1]) <= 0) continue;
        pairs.add(shufflePairKey(first.tracks[i - 1], first.tracks[i]));
      }
      final HarmonicOrder second = buildHarmonicShuffle(
        lib,
        bpmFromName,
        fixedFirst: '/m/song20 100bpm.mp3',
        usedPairs: pairs,
        rng: Random(2),
      );
      var shared = 0;
      var steps = 0;
      for (var i = 1; i < second.tracks.length; i++) {
        if (bpmFromName(second.tracks[i]) <= 0) continue;
        if (bpmFromName(second.tracks[i - 1]) <= 0) continue;
        steps++;
        if (pairs.contains(
          shufflePairKey(second.tracks[i - 1], second.tracks[i]),
        )) {
          shared++;
        }
      }
      expect(shared / steps, lessThan(0.15));
    });
  });
}
