import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio/phase_lock.dart';

void main() {
  const double beat = 0;

  test('desfase +12 ms: la entrante va tarde y se acelera sobre la rampa', () {
    final double offset = beatPhaseOffsetMs(
      outPosMs: 0,
      outBeatMs: beat,
      outBpm: 120,
      outRate: 1,
      inPosMs: 488,
      inBeatMs: beat,
      inBpm: 120,
      inRate: 1,
    );
    expect(offset, closeTo(12, 0.001));
    final PhaseCorrection plan = phaseCorrectionPlan(
      offsetMs: offset,
      rampRate: 1.08,
    );
    expect(plan.settled, isFalse);
    expect(plan.nudge, phaseMaxNudge);
    expect(plan.appliedRate, closeTo(1.08 + 1.08 * phaseMaxNudge, 1e-12));
  });

  test('desfase -12 ms: la entrante va adelantada y se frena', () {
    final double offset = beatPhaseOffsetMs(
      outPosMs: 0,
      outBeatMs: beat,
      outBpm: 120,
      outRate: 1,
      inPosMs: 12,
      inBeatMs: beat,
      inBpm: 120,
      inRate: 1,
    );
    expect(offset, closeTo(-12, 0.001));
    final PhaseCorrection plan = phaseCorrectionPlan(
      offsetMs: offset,
      rampRate: 1.05,
    );
    expect(plan.nudge, -phaseMaxNudge);
    expect(plan.appliedRate, closeTo(1.05 + 1.05 * -phaseMaxNudge, 1e-12));
  });

  test('cerca de medio periodo se queda el arco más corto', () {
    final double early = beatPhaseOffsetMs(
      outPosMs: 0,
      outBeatMs: beat,
      outBpm: 120,
      outRate: 1,
      inPosMs: 249,
      inBeatMs: beat,
      inBpm: 120,
      inRate: 1,
    );
    final double late = beatPhaseOffsetMs(
      outPosMs: 0,
      outBeatMs: beat,
      outBpm: 120,
      outRate: 1,
      inPosMs: 251,
      inBeatMs: beat,
      inBpm: 120,
      inRate: 1,
    );
    expect(early, closeTo(-249, 0.001));
    expect(late, closeTo(249, 0.001));
    expect(
      beatPhaseOffsetMs(
        outPosMs: 0,
        outBeatMs: beat,
        outBpm: 120,
        outRate: 1,
        inPosMs: 250,
        inBeatMs: beat,
        inBpm: 120,
        inRate: 1,
      ),
      closeTo(250, 0.001),
    );
  });

  test('rates distintos en cada deck', () {
    // 100 BPM a 1.2 suena a 120. 14.4 ms de archivo son 12 ms reales.
    final double offset = beatPhaseOffsetMs(
      outPosMs: 10000,
      outBeatMs: 0,
      outBpm: 120,
      outRate: 1,
      inPosMs: 585.6,
      inBeatMs: 0,
      inBpm: 100,
      inRate: 1.2,
    );
    expect(offset, closeTo(12, 0.001));

    // El arco se mide con el periodo oído de la saliente (rate 2 → 250 ms).
    final double wrapped = beatPhaseOffsetMs(
      outPosMs: 0,
      outBeatMs: 0,
      outBpm: 120,
      outRate: 2,
      inPosMs: 360,
      inBeatMs: 0,
      inBpm: 120,
      inRate: 1,
    );
    expect(wrapped, closeTo(-110, 0.001));
  });

  test('por debajo de 5 ms se devuelve el rate de la rampa', () {
    final PhaseCorrection held = phaseCorrectionPlan(
      offsetMs: 4.9,
      rampRate: 0.94,
    );
    expect(held.settled, isTrue);
    expect(held.nudge, 0);
    expect(held.appliedRate, 0.94);
    final PhaseCorrection open = phaseCorrectionPlan(
      offsetMs: 5,
      rampRate: 1.12,
    );
    expect(open.settled, isFalse);
    expect(open.appliedRate, closeTo(1.12 * 1.01, 1e-12));
  });

  test('la espera al golpe descuenta el hueco de la entrante', () {
    expect(
      phaseAlignWaitMs(
        nowOutMs: 1100,
        outBeatMs: 0,
        outBpm: 120,
        outRate: 1,
        inPosMs: 0,
        inBeatMs: 0,
        inBpm: 120,
        inRate: 1,
        startupMs: 20,
      ),
      380,
    );
    expect(
      phaseAlignWaitMs(
        nowOutMs: 1100,
        outBeatMs: 0,
        outBpm: 120,
        outRate: 1,
        inPosMs: 450,
        inBeatMs: 0,
        inBpm: 120,
        inRate: 1,
        startupMs: 20,
      ),
      330,
    );
  });

  test('un paso de 1 % cierra un milisegundo', () {
    expect(phaseSampleMs * phaseMaxNudge, 1);
  });

  test('el promedio móvil suelta la muestra vieja', () {
    final LatencyAverage avg = LatencyAverage();
    for (int i = 0; i < 8; i++) {
      avg.add(10);
    }
    expect(avg.ms, 10);
    avg.add(90);
    expect(avg.ms, closeTo((10 * 7 + 90) / 8, 1e-9));
    avg.add(-1);
    expect(avg.ms, closeTo((10 * 7 + 90) / 8, 1e-9));
  });

  test('la bitácora de fase', () {
    expect(
      phaseTraceLine(
        initialMs: 12,
        finalMs: -1.5,
        latencyMs: 37,
        steps: 4,
      ),
      'PHASE inicial=12.0 final=-1.5 latencia=37.0 pasos=4',
    );
  });

  test('parsea los segundos de libmpv', () {
    expect(parseMpvSeconds('12.5'), 12.5);
    expect(parseMpvSeconds(3), 3);
    expect(parseMpvSeconds('none'), isNull);
    expect(parseMpvSeconds(''), isNull);
  });
}
