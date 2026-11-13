import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/bpm_backfill_worker.dart';

void main() {
  test('candidatos: solo desde index + 2, sin BPM, sin _K ni repetidas', () {
    final List<String> q = <String>['a.mp3', 'b.mp3', 'c.mp3', 'd.mp3', 'c.mp3', 'e_K.mp3', 'f.mp3'];
    final Map<String, double> bpm = <String, double>{'d.mp3': 120};
    final List<String> c = backfillCandidates(q, 2, (String p) => bpm[p] ?? 0);
    expect(c, <String>['c.mp3', 'f.mp3']);
  });

  test('reorden: actual y siguiente fijas, misma cantidad de pistas', () {
    final List<String> q = <String>['cur.mp3', 'next.mp3', 'x.mp3', 'y.mp3', 'z.mp3', 'y.mp3'];
    String? from;
    final List<String>? out = reorderQueueTail(q, 2, (List<String> tail, String? f) {
      from = f;
      return <String>['z.mp3', 'y.mp3', 'otra.mp3'];
    });
    expect(from, 'next.mp3');
    expect(out, <String>['cur.mp3', 'next.mp3', 'z.mp3', 'y.mp3', 'x.mp3', 'y.mp3']);
    expect(reorderQueueTail(<String>['a', 'b', 'c'], 2, (_, _) => <String>[]), isNull);
  });

  test('queueEpoch: otra lista (agregar, mover, quitar) descarta el lote', () {
    final List<String> q = <String>['a', 'b'];
    expect(sameQueueEpoch(q, q), isTrue);
    expect(sameQueueEpoch(q, List<String>.from(q)), isFalse);
    expect(sameQueueEpoch(null, q), isFalse);
  });

  test('worker: espera el cruce, lotes de 5 y al terminar', () async {
    var paused = 3;
    final List<String> measured = <String>[];
    final List<int> batches = <int>[];
    final BpmBackfillWorker w = BpmBackfillWorker(
      measure: (String p) async {
        measured.add(p);
        return 120;
      },
      isPaused: () => paused-- > 0,
      onBatch: batches.add,
      gap: const Duration(milliseconds: 1),
    );
    w.enqueue(<String>[for (var i = 0; i < 7; i++) '/tmp/gmx3114_w$i.mp3']);
    w.enqueue(<String>['/tmp/gmx3114_w0.mp3']);
    for (var i = 0; i < 200 && w.isRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(paused, lessThan(0));
    expect(measured.length, 7);
    expect(batches, <int>[5, 2]);
    expect(w.takeUnapplied(), 0);
  });

  test('worker: cancel corta y no mide lo pendiente', () async {
    final List<String> measured = <String>[];
    late BpmBackfillWorker w;
    w = BpmBackfillWorker(
      measure: (String p) async {
        measured.add(p);
        w.cancel();
        return 0;
      },
      isPaused: () => false,
      onBatch: (_) {},
      gap: const Duration(milliseconds: 1),
    );
    w.enqueue(<String>['/tmp/gmx3114_c1.mp3', '/tmp/gmx3114_c2.mp3']);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(measured, <String>['/tmp/gmx3114_c1.mp3']);
    expect(w.pendingCount, 0);
  });
}
