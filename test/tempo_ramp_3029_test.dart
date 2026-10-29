import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio/tempo_drift.dart';
import 'package:gatomix/core/exact_mix.dart';

void expectMarks(List<TempoMark> marks, List<(int, double)> want) {
  expect(marks.length, want.length);
  for (var i = 0; i < want.length; i++) {
    expect(marks[i].offsetMs, want[i].$1, reason: 'offset $i');
    expect(marks[i].bpm, closeTo(want[i].$2, 1e-9), reason: 'bpm $i');
  }
}

void main() {
  test('44 → 40: dos pasos de 1 antes y dos después', () {
    final MidpointTempoPlan p = midpointTempoPlan(44, 40);
    expect(p.midpoint, 42);
    expect(p.rateLimited, isFalse);
    expect(p.outgoingRate, closeTo(42 / 44, 1e-12));
    expect(p.incomingRate, closeTo(42 / 40, 1e-12));
    expectMarks(p.outgoing, <(int, double)>[(-10000, 43), (-5000, 42)]);
    expectMarks(p.incoming, <(int, double)>[(5000, 41), (10000, 40)]);
  });

  test('48 → 40: dos pasos de 2', () {
    final MidpointTempoPlan p = midpointTempoPlan(48, 40);
    expect(p.midpoint, 44);
    expect(p.rateLimited, isFalse);
    expectMarks(p.outgoing, <(int, double)>[(-10000, 46), (-5000, 44)]);
    expectMarks(p.incoming, <(int, double)>[(5000, 42), (10000, 40)]);
  });

  test('52 → 40: pesos 1-1-2-2 y tres pasos de vuelta', () {
    final MidpointTempoPlan p = midpointTempoPlan(52, 40);
    expect(p.midpoint, 46);
    expectMarks(p.outgoing, <(int, double)>[
      (-12000, 51),
      (-9000, 50),
      (-6000, 48),
      (-3000, 46),
    ]);
    expectMarks(p.incoming, <(int, double)>[(5000, 44), (10000, 42), (14000, 40)]);
    // 46/40 = 1.15 queda fuera de 1.12. Se informa, no se recorta.
    expect(p.rateLimited, isTrue);
    expect(p.incomingRate, closeTo(1.15, 1e-12));
  });

  test('40 → 48 invierte el signo', () {
    final MidpointTempoPlan p = midpointTempoPlan(40, 48);
    expect(p.midpoint, 44);
    expect(p.rateLimited, isFalse);
    expectMarks(p.outgoing, <(int, double)>[(-10000, 42), (-5000, 44)]);
    expectMarks(p.incoming, <(int, double)>[(5000, 46), (10000, 48)]);
  });

  test('d = 16 extiende el mismo espaciado', () {
    final MidpointTempoPlan p = midpointTempoPlan(56, 40);
    expect(p.midpoint, 48);
    expect(p.span, 16);
    expect(p.outgoing.length, 6);
    expect(p.outgoing.first.offsetMs, -18000);
    expect(p.outgoing.last.offsetMs, -3000);
    expect(p.outgoing.last.bpm, closeTo(48, 1e-9));
    for (var i = 1; i < p.outgoing.length; i++) {
      expect(
        p.outgoing[i].offsetMs - p.outgoing[i - 1].offsetMs,
        3000,
      );
    }
    expect(p.incoming.length, 4);
    expectMarks(p.incoming, <(int, double)>[
      (5000, 46),
      (10000, 44),
      (14000, 42),
      (18000, 40),
    ]);
  });

  test('una fracción se reparte en los mismos dos pasos', () {
    final MidpointTempoPlan p = midpointTempoPlan(44.5, 40);
    expect(p.midpoint, closeTo(42.25, 1e-12));
    expect(p.outgoing.length, 2);
    expect(p.outgoing.first.bpm, closeTo(43.375, 1e-9));
    expect(p.outgoing.last.bpm, closeTo(42.25, 1e-9));
    expect(p.incoming.last.bpm, closeTo(40, 1e-9));
  });

  test('la rampa de tempo no entra en la ganancia del cruce', () {
    final double mid = dawnCrossfadeGain(0.5);
    expect(mid, closeTo(pow(0.9, 1.2).toDouble(), 1e-12));
    expect(dawnCrossfadeGain(0.4), dawnCrossfadeGain(0.4));
    final MidpointTempoPlan slow = midpointTempoPlan(44, 40);
    final MidpointTempoPlan fast = midpointTempoPlan(40, 48);
    expect(slow.incomingRate, isNot(fast.incomingRate));
    expect(dawnCrossfadeGain(0.5), mid);
    final TempoDrift drift = TempoDrift();
    drift.begin(40, slow.incomingRate);
    drift.tick(
      posMs: 0,
      durMs: 200000,
      mixOutMs: 180000,
      rate: slow.incomingRate,
      nextBpm: 0,
    );
    final double? rate = drift.tick(
      posMs: 5000,
      durMs: 200000,
      mixOutMs: 180000,
      rate: slow.incomingRate,
      nextBpm: 0,
    );
    expect(rate, isNotNull);
    expect(dawnCrossfadeGain(0.5), mid);
  });

  test('un punto a 2 s del final no se corre a 4 s', () {
    const int dur = 10000;
    final int point = (dur * 0.75).round();
    final FittedFade fit = fitMixFade(
      exactDurationMs: dur,
      mixOutMs: point,
      wantedFadeMs: 8000,
      structuralMs: const <int>[8000, 9000],
    );
    expect(point, 7500);
    expect(fit.mixOutMs, 7500);
    expect(fit.mixOutMs, isNot(dur - 4000));
    expect(fit.fadeMs, 2500);
    expect(fit.shortened, isTrue);
    expect(fit.note, contains('wanted=8000'));
    expect(fit.note, contains('fade=2500'));

    final FittedFade roomy = fitMixFade(
      exactDurationMs: 180000,
      mixOutMs: 178000,
      wantedFadeMs: 18000,
      structuralMs: const <int>[135000],
    );
    expect(roomy.mixOutMs, 135000);
    expect(roomy.fadeMs, 18000);
    expect(roomy.shortened, isFalse);
    expect(roomy.mixOutMs, isNot(180000 - 4000));
  });

  test('el disparo no se adelanta 25 s ni usa una duración sin medir', () {
    const int exact = 283000;
    const int mixOut = 270000;
    expect(
      mixTriggerDue(posMs: exact - 25000, exactMs: exact, mixOutMs: mixOut),
      isFalse,
    );
    expect(
      mixTriggerDue(posMs: mixOut, exactMs: exact, mixOutMs: mixOut),
      isTrue,
    );
    expect(
      mixTriggerDue(posMs: mixOut, exactMs: 0, mixOutMs: mixOut),
      isFalse,
    );
  });

  test('el informe de TLEN distingue el audio pegado', () {
    final TlenReport hit = TlenReport.parse(
      'audio=283000,tlen=224209,mismatch=1,wrote=1',
    );
    expect(
      stuckAudioLine(
        name: 'Hurt So Good.mp3',
        tlenMs: hit.tlenMs,
        audioMs: hit.audioMs,
        mismatch: hit.mismatch,
      ),
      'Hurt So Good.mp3 — posible audio pegado / versión distinta '
      '(tlen=224209, audio=283000)',
    );
    final TlenReport ok = TlenReport.parse(
      'audio=222000,tlen=222000,mismatch=0,wrote=0',
    );
    expect(ok.mismatch, isFalse);
    expect(
      stuckAudioLine(
        name: 'ok.mp3',
        tlenMs: ok.tlenMs,
        audioMs: ok.audioMs,
        mismatch: ok.mismatch,
      ),
      isNull,
    );
  });

  test('el golpe espera al siguiente beat, menos 20 ms', () {
    expect(
      beatPhaseWaitMs(nowOutMs: 1000, beatMs: 0, bpm: 120, outRate: 1),
      480,
    );
    expect(
      beatPhaseWaitMs(nowOutMs: 1000, beatMs: 0, bpm: 120, outRate: 1.25),
      ((1500 - 1000) / 1.25).round() - 20,
    );
    expect(
      beatPhaseWaitMs(nowOutMs: 1000, beatMs: 0, bpm: 0, outRate: 1),
      0,
    );
  });
}
