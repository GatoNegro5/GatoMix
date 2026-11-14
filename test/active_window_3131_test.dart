import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/providers/mix_formula.dart';

// 3.1.31: ventana activa 60-80 %, entrada adelantada y costuras de seda.
// Puro: sin Player, sin archivos, sin ReGenial.
void main() {
  const List<int> durs = <int>[60000, 120000, 200000, 300000, 600000];
  const List<double> bpms = <double>[0, 90, 117, 128];
  const int g0 = 250;

  test('entrada >= max(10 %, 8 s), <= 20 % y en la rejilla', () {
    for (final int d in durs) {
      for (final double b in bpms) {
        final int cue = activeCueInMs(durationMs: d, bpm: b, gridMs: g0);
        expect(cue, greaterThanOrEqualTo(max((d * 0.10).round(), 8000)));
        expect(cue, lessThanOrEqualTo((d * 0.20).round()));
        final int beat = activeBeatMs(b);
        if (beat > 0) expect((cue - g0) % beat, 0, reason: 'd=$d b=$b');
      }
    }
  });

  test('tramo mixOut - cueIn entre 60 % y 80 %, fundido antes del final', () {
    var cases = 0;
    for (final int d in durs) {
      for (final double b in bpms) {
        final int cueMin = activeCueMinMs(durationMs: d);
        final int cue = activeCueInMs(durationMs: d, bpm: b, gridMs: g0);
        final int beat = activeBeatMs(b);
        for (final MixFormula f in MixFormula.values) {
          for (final bool vocal in <bool>[true, false]) {
            final MixPersonality look = mixPersonality(f, b, vocal: vocal);
            for (final int cand in <int>[0, d ~/ 2, (d * 0.75).round(), d]) {
              final ActiveWindow w = activeWindow(
                durationMs: d,
                cueInMs: cue,
                fadeMs: look.fadeMs,
                candidateMs: cand,
                bpm: b,
                gridMs: g0,
                cueMinMs: cueMin,
              );
              final String why = 'd=$d b=$b f=$f v=$vocal cand=$cand';
              final int span = w.mixOutMs - w.cueInMs;
              expect(span, greaterThanOrEqualTo((d * 0.60).round()), reason: why);
              expect(span, lessThanOrEqualTo((d * 0.80).round()), reason: why);
              expect(w.mixOutMs + w.fadeMs, lessThanOrEqualTo(d), reason: why);
              expect(w.fadeMs, greaterThan(0), reason: why);
              expect(w.cueInMs, greaterThanOrEqualTo(cueMin), reason: why);
              if (beat > 0) {
                expect((w.mixOutMs - g0) % beat, 0, reason: why);
              }
              cases++;
            }
          }
        }
      }
    }
    expect(cases, 5 * 4 * 3 * 2 * 4);
  });

  test('ejemplo del diagnostico: 200 s a 117 BPM, primer golpe 0,3 s', () {
    final int cue = activeCueInMs(durationMs: 200000, bpm: 117, gridMs: 300);
    expect(cue, 300 + 2 * 513 * 32); // 33,1 s, en frase
    final MixPersonality larga =
        mixPersonality(MixFormula.phraseGrid, 117, vocal: false);
    final ActiveWindow w = activeWindow(
      durationMs: 200000,
      cueInMs: cue,
      fadeMs: larga.fadeMs,
      candidateMs: 150000,
      bpm: 117,
      gridMs: 300,
      cueMinMs: 20000,
    );
    expect(w.mixOutMs, 300 + 10 * 513 * 32); // 164,5 s, en frase
    expect(w.fadeMs, larga.fadeMs);
  });

  test('Mix largo, duracion desconocida, pista corta y entrada de la formula', () {
    expect(activeCueInMs(durationMs: 900000, bypass: true), 0);
    expect(activeCueInMs(durationMs: 0, bpm: 117), 0);
    expect(activeCueInMs(durationMs: 15000, leadMs: 2000), 2000);
    expect(activeCueInMs(durationMs: 15000), 0);
    expect(activeCueInMs(durationMs: 200000, preferMs: 30000), 30000);
    expect(
      activeCueInMs(durationMs: 200000, preferMs: 500, bpm: 117),
      greaterThanOrEqualTo(20000),
    );
    final ActiveWindow by = activeWindow(
      durationMs: 900000,
      cueInMs: 0,
      fadeMs: 4000,
      candidateMs: 870000,
      bypass: true,
    );
    expect(by.mixOutMs, 870000);
  });

  test('seamGain: sin escalon ni bulto, pendiente 0 en los extremos', () {
    for (final double edge in <double>[0, 0.25]) {
      expect(seamGain(0, edge: edge), 0);
      expect(seamGain(1, edge: edge), closeTo(1, 1e-12));
      expect(seamGain(0.02, edge: edge), lessThan(0.01));
      expect(seamGain(0.98, edge: edge), greaterThan(0.9999));
      double prev = 0;
      double maxStep = 0;
      for (var i = 0; i <= 1000; i++) {
        final double p = i / 1000;
        final double a = seamGain(p, edge: edge);
        final double o = seamGain(1 - p, edge: edge);
        expect(a * a + o * o, closeTo(1, 1e-9), reason: 'p=$p edge=$edge');
        expect(a, greaterThanOrEqualTo(prev - 1e-12));
        maxStep = max(maxStep, (a - prev).abs());
        prev = a;
      }
      expect(maxStep, lessThan(0.01));
    }
    double slope(double edge) =>
        (seamProgress(0.501, edge: edge) - seamProgress(0.499, edge: edge)) /
        0.002;
    expect(slope(0), closeTo(1.5, 1e-3));
    expect(slope(0.25), lessThan(slope(0)));
  });

  test('seamVolume compensa la ley cubica de mpv', () {
    expect(seamVolume(0), 0);
    expect(seamVolume(-1), 0);
    expect(seamVolume(1), 100);
    expect(seamVolume(2), 100);
    expect(seamVolume(0.125), closeTo(50, 1e-9));
    for (var i = 1; i < 100; i++) {
      final double g = i / 100;
      expect(pow(seamVolume(g) / 100, 3), closeTo(g, 1e-9));
    }
  });

  test('mixPersonality: 3 duraciones y swaps distintos (117 BPM)', () {
    final MixPersonality corta =
        mixPersonality(MixFormula.stealthGap, 117, vocal: true);
    final MixPersonality clasV =
        mixPersonality(MixFormula.dnaEnergy, 117, vocal: true);
    final MixPersonality clasI =
        mixPersonality(MixFormula.dnaEnergy, 117, vocal: false);
    final MixPersonality largaV =
        mixPersonality(MixFormula.phraseGrid, 117, vocal: true);
    final MixPersonality largaI =
        mixPersonality(MixFormula.phraseGrid, 117, vocal: false);
    expect(corta.fadeMs, 513 * 8);
    expect(clasV.fadeMs, 513 * 16);
    expect(clasI.fadeMs, 513 * 32);
    expect(largaV.fadeMs, 513 * 32);
    expect(largaI.fadeMs, 513 * 64);
    expect(corta.swapMs(fadeMs: corta.fadeMs, bpm: 117), 513 * 4); // golpe 5
    expect(clasV.swapMs(fadeMs: clasV.fadeMs, bpm: 117), 513 * 8);
    expect(clasI.swapMs(fadeMs: clasI.fadeMs, bpm: 117), 513 * 16);
    expect(largaV.swapMs(fadeMs: largaV.fadeMs, bpm: 117), 513 * 20);
    expect(largaI.swapMs(fadeMs: largaI.fadeMs, bpm: 117), 513 * 40);
    expect(largaI.fadeMs / corta.fadeMs, greaterThanOrEqualTo(4));
    expect(<String>{corta.label, clasV.label, largaV.label}.length, 3);
    expect(mixPersonality(MixFormula.phraseGrid, 60, vocal: false).fadeMs, 40000);
    expect(mixPersonality(MixFormula.stealthGap, 0, vocal: true).fadeMs, 4000);
    expect(mixPersonality(MixFormula.dnaEnergy, 0, vocal: false).fadeMs, 16000);
    expect(mixPersonality(MixFormula.phraseGrid, 0, vocal: false).fadeMs, 32000);
  });
}
