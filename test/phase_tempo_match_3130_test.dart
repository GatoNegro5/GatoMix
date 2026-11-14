import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio/phase_lock.dart';

// 3.1.30: la base del lazo de fase iguala el tempo que se oye (rejilla real),
// no el BPM entero del nombre. Simulacion pura: sin Player, sin archivos.

const double _outBpm = 117;
const double _inBpm = 109;
const double _rampRate = 1.0318;

class _Run {
  final double finalMs;
  final double maxAbsMs;
  const _Run(this.finalMs, this.maxAbsMs);
}

/// 11 s en pasos de 100 ms. La entrante arranca en su golpe y la saliente a
/// [startMs] (negativo = entrante adelantada).
_Run _simulate({
  required double outRate,
  required bool lock,
  required bool match,
  double startMs = 0,
  int steps = 110,
}) {
  double outPos = 60000.0 / _outBpm + startMs * outRate;
  double inPos = 0;
  double inRate = _rampRate;
  double offset = 0;
  double maxAbs = 0;
  for (int i = 0; i <= steps; i++) {
    offset = beatPhaseOffsetMs(
      outPosMs: outPos,
      outBeatMs: 0,
      outBpm: _outBpm,
      outRate: outRate,
      inPosMs: inPos,
      inBeatMs: 0,
      inBpm: _inBpm,
      inRate: inRate,
    );
    if (offset.abs() > maxAbs) maxAbs = offset.abs();
    if (i == steps) break;
    if (lock) {
      final double base = match
          ? tempoMatchRate(_outBpm, outRate, _inBpm, _rampRate)
          : _rampRate;
      inRate = phaseCorrectionPlan(offsetMs: offset, rampRate: base)
          .appliedRate;
    }
    outPos += phaseSampleMs * outRate;
    inPos += phaseSampleMs * inRate;
  }
  return _Run(offset, maxAbs);
}

void main() {
  test('saliente 117x0.970, rejilla 109: rate fijo deriva, igualado se queda', () {
    final _Run fixed = _simulate(outRate: 0.970, lock: false, match: false);
    expect(fixed.finalMs, greaterThan(90));
    final _Run matched = _simulate(
      outRate: 0.970,
      lock: true,
      match: true,
      startMs: -22,
    );
    expect(matched.finalMs.abs(), lessThan(5));
  });

  test('rampa de la saliente a medio camino: el 1 % no alcanza, la base si', () {
    final _Run fixed = _simulate(
      outRate: 0.985,
      lock: true,
      match: false,
      startMs: -22,
    );
    expect(fixed.maxAbsMs, greaterThan(100));
    final _Run matched = _simulate(
      outRate: 0.985,
      lock: true,
      match: true,
      startMs: -22,
    );
    expect(matched.finalMs.abs(), lessThan(5));
  });

  test('rejilla al doble o a la mitad: misma octava', () {
    final double want = _outBpm * 0.970 / _inBpm;
    expect(tempoMatchRate(_outBpm, 0.970, _inBpm, _rampRate), closeTo(want, 1e-9));
    expect(tempoMatchRate(_outBpm, 0.970, _inBpm * 2, _rampRate), closeTo(want, 1e-9));
    expect(tempoMatchRate(_outBpm, 0.970, _inBpm / 2, _rampRate), closeTo(want, 1e-9));
  });

  test('guardia del 4 % y entradas invalidas: rampRate exacto', () {
    expect(tempoMatchRate(_outBpm, 0.970, 100, _rampRate), _rampRate);
    expect(tempoMatchRate(_outBpm, 0.970, 0, _rampRate), _rampRate);
    expect(tempoMatchRate(_outBpm, 0.970, double.nan, _rampRate), _rampRate);
    expect(tempoMatchRate(double.nan, 0.970, _inBpm, _rampRate), _rampRate);
    expect(tempoMatchRate(_outBpm, 0, _inBpm, _rampRate), _rampRate);
    expect(tempoMatchRate(double.infinity, 0.970, _inBpm, _rampRate), _rampRate);
  });

  test('la bitacora PHASE lleva bpm, rates y base', () {
    expect(
      phaseTraceLine(
        initialMs: 12,
        finalMs: -1.5,
        latencyMs: 37,
        steps: 4,
        outBpm: 117,
        inBpm: 109,
        outRate: 0.97,
        inRate: 1.0412,
        base: 1.0412,
      ),
      'PHASE inicial=12.0 final=-1.5 latencia=37.0 pasos=4 outBpm=117.00 '
      'inBpm=109.00 outRate=0.9700 inRate=1.0412 base=1.0412',
    );
  });
}
