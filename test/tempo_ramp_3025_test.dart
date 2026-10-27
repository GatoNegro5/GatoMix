import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio/tempo_drift.dart';
import 'package:gatomix/providers/mix_formula.dart';

/// 128 sonando, 134 la que entra. La misma rampa en Live DJ, Automix y Radio:
/// los tres llaman a [TempoDrift] (la radio mezcla por el motor de Live DJ).
void _expectMatchAndReturn(String mode) {
  const double outBpm = 128;
  const double inBpm = 134;
  final double entry = matchBpmRate(outBpm, inBpm);
  expect(entry, isNot(1.0), reason: '$mode iguala el BPM antes del cruce');
  expect(entry, closeTo(outBpm / inBpm, 1e-9));

  final TempoDrift before = TempoDrift();
  before.begin(outBpm, 1.0);
  final double? nudged = before.tick(
    posMs: 170000,
    durMs: 200000,
    mixOutMs: 180000,
    rate: 1.0,
    nextBpm: inBpm,
  );
  expect(nudged, isNotNull, reason: '$mode acerca el rate 10 s antes');
  expect(nudged!, greaterThan(1.0));
  expect(nudged, lessThan(inBpm / outBpm));
  final List<double> up = tempoRampSchedule(1.0, nudged);
  expect(up.length, greaterThanOrEqualTo(50));
  for (var i = 1; i < up.length; i++) {
    expect(up[i], greaterThanOrEqualTo(up[i - 1]));
  }
  expect(up.first, 1.0);
  expect(up.last, nudged);

  final TempoDrift after = TempoDrift();
  after.begin(inBpm, entry);
  expect(after.active, isTrue, reason: '$mode no suelta el rate de golpe');
  const int dur = 200000;
  final List<double> back = <double>[entry];
  for (final int step in <int>[1, 2, 3, 4, 5]) {
    final double? rate = after.tick(
      posMs: (dur * step / 10).round(),
      durMs: dur,
      mixOutMs: 180000,
      rate: back.last,
      nextBpm: 0,
    );
    expect(rate, isNotNull, reason: '$mode paso $step');
    back.add(rate!);
    final List<double> glide = tempoRampSchedule(back[back.length - 2], rate);
    expect(glide.length, greaterThanOrEqualTo(50));
    expect(glide.first, back[back.length - 2]);
    expect(glide.last, rate);
  }
  expect(back.last, closeTo(1.0, 1e-9), reason: '$mode vuelve a 1.0');
  for (var i = 1; i < back.length; i++) {
    expect(back[i], greaterThan(back[i - 1]));
  }
}

void main() {
  test('Live DJ: 128 hacia 134 antes del cruce y vuelve a 1.0', () {
    _expectMatchAndReturn('Live DJ');
  });

  test('Automix: 128 hacia 134 antes del cruce y vuelve a 1.0', () {
    _expectMatchAndReturn('Automix');
  });

  test('Radio: 128 hacia 134 antes del cruce y vuelve a 1.0', () {
    _expectMatchAndReturn('Radio');
  });

  test('el golpe espera al siguiente beat, menos 20 ms', () {
    // 120 BPM, golpe en 0, posición 1000 ms, rate 1: el siguiente es 1500.
    // 1500 - 1000 - 20 = 480.
    expect(
      beatPhaseWaitMs(nowOutMs: 1000, beatMs: 0, bpm: 120, outRate: 1),
      480,
    );
    // Con el rate ya subido, el mismo tramo de pista dura menos tiempo real.
    expect(
      beatPhaseWaitMs(nowOutMs: 1000, beatMs: 0, bpm: 120, outRate: 1.25),
      ((1500 - 1000) / 1.25).round() - 20,
    );
    expect(
      beatPhaseWaitMs(nowOutMs: 1000, beatMs: 0, bpm: 0, outRate: 1),
      0,
    );
  });

  test('el reloj de 250 ms no se salta los pasos de la vuelta', () {
    const double entry = 128 / 134;
    final TempoDrift drift = TempoDrift();
    drift.begin(134, entry);
    const int dur = 240000;
    final List<double> rates = <double>[];
    double rate = entry;
    for (int pos = 0; pos <= dur ~/ 2; pos += 250) {
      final double? next = drift.tick(
        posMs: pos,
        durMs: dur,
        mixOutMs: dur - 20000,
        rate: rate,
        nextBpm: 0,
      );
      if (next != null) {
        rates.add(next);
        rate = next;
      }
    }
    expect(rates, hasLength(5));
    expect(rates.last, closeTo(1.0, 1e-9));
    expect(tempoRampSchedule(entry, 1.0).length, greaterThanOrEqualTo(50));
  });
}
