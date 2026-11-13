import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/providers/dsp_provider.dart' show enCarpetaOriginal;
import 'package:gatomix/providers/pipeline_provider.dart' show HeavyWorkGate;

// 3.1.19: el candado termico serializa los trabajos pesados y el escaneo de
// BPM ignora `.gatomix_original` (sinteticos en %TEMP%, sin Rust).
void main() {
  test('HeavyWorkGate: nunca 2 a la vez, orden FIFO y libera tras error',
      () async {
    var running = 0;
    var maxRunning = 0;
    final List<String> order = <String>[];
    Future<int> job(String id, int ms) => HeavyWorkGate.run(id, () async {
          running++;
          if (running > maxRunning) maxRunning = running;
          order.add(id);
          expect(HeavyWorkGate.holder, id);
          await Future<void>.delayed(Duration(milliseconds: ms));
          running--;
          if (id == 'karaoke') throw StateError('falla simulada');
          return ms;
        });
    final Future<int> a = job('dsp-bpm', 30);
    final Future<int> b = job('karaoke', 10);
    final Future<int> c = job('bpm-backfill', 5);
    expect(HeavyWorkGate.waiting, greaterThan(0));
    expect(await a, 30);
    await expectLater(b, throwsStateError);
    expect(await c, 5);
    expect(maxRunning, 1);
    expect(order, <String>['dsp-bpm', 'karaoke', 'bpm-backfill']);
    expect(HeavyWorkGate.holder, isNull);
    expect(HeavyWorkGate.waiting, 0);
  });

  test('.gatomix_original se salta y pruneMissingBpmKeys poda sus claves',
      () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('gmx_3119_');
    try {
      final String sep = Platform.pathSeparator;
      final File live = File('${dir.path}${sep}a.mp3')..writeAsBytesSync([0]);
      final Directory bak =
          Directory('${dir.path}$sep.gatomix_original')..createSync();
      final File backup = File('${bak.path}${sep}a.mp3')
        ..writeAsBytesSync([0]);
      // Mismo filtro que el escaneo de BPM de dsp_provider.
      final List<String> present = <String>[
        for (final FileSystemEntity e in dir.listSync(recursive: true))
          if (e is File &&
              !enCarpetaOriginal(e.path) &&
              e.path.toLowerCase().endsWith('.mp3'))
            e.path,
      ];
      expect(present, <String>[live.path]);
      expect(enCarpetaOriginal(backup.path), isTrue);
      expect(enCarpetaOriginal(bak.path), isTrue);
      final Map<String, dynamic> out = pruneMissingBpmKeys(
        <String, dynamic>{live.path: 120.0, backup.path: 120.0},
        directoryPath: dir.path,
        presentPaths: present,
      );
      expect(out.keys, <String>[live.path]);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
