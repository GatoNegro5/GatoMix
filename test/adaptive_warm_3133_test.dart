import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/services/adaptive_eq.dart';

/// 3.1.33: precarga de AdaptiveEq y aire real en 16 kHz.
const List<double> target = [-1, 4, 6, 3, 1, 0, -3, -6, -11, -18];

/// Copia de la regla anterior a 3.1.33 (16 kHz sin realce).
List<double> oldCorrection(List<double> lv) {
  double m = 0;
  for (int i = 2; i <= 7; i++) {
    m += lv[i] - target[i];
  }
  m /= 6;
  final out = List<double>.filled(10, 0);
  for (int i = 0; i < 10; i++) {
    final d = lv[i] - target[i] - m;
    double c = -0.5 * d;
    if ((i >= 8 || i == 0) && d < -12) c = 0;
    double hiLim = 3.0;
    if (i == 0) hiLim = 1.0;
    if (i == 8) hiLim = 2.0;
    if (i == 9) hiLim = 0.0;
    c = c.clamp(-3.0, hiLim).toDouble();
    out[i] = (c * 10).round() / 10;
  }
  return out;
}

List<double> withBand(int band, double delta) {
  final lv = List<double>.from(target);
  lv[band] += delta;
  return lv;
}

void main() {
  test('aire real (> -20 dB) y 16 kHz caido: realza hasta +1,5 dB', () {
    final lv = withBand(9, -6);
    expect(AdaptiveEq.bandCorrection(lv, airDb: -10)[9], 1.5);
    expect(AdaptiveEq.bandCorrection(withBand(9, -2), airDb: -10)[9], 1.0);
    // Banda vacia (desvio < -12): no se realza aunque haya aire.
    expect(AdaptiveEq.bandCorrection(withBand(9, -14), airDb: -10)[9], 0.0);
  });

  test('paso bajo (<= -20 dB): 16 kHz queda en 0,0 dB', () {
    final lv = withBand(9, -6);
    expect(AdaptiveEq.bandCorrection(lv, airDb: -20)[9], 0.0);
    expect(AdaptiveEq.bandCorrection(lv, airDb: -35)[9], 0.0);
    expect(AdaptiveEq.bandCorrection(lv)[9], 0.0);
    // El corte en 16 kHz sigue igual.
    expect(AdaptiveEq.bandCorrection(withBand(9, 8), airDb: -10)[9], -3.0);
  });

  test('31 Hz tope +1 y bandas 0-8 identicas a la regla anterior', () {
    expect(AdaptiveEq.bandCorrection(withBand(0, -10))[0], 1.0);
    expect(AdaptiveEq.bandCorrection(withBand(0, -13))[0], 0.0);
    final rnd = Random(3133);
    for (int k = 0; k < 300; k++) {
      final lv = List<double>.generate(
        10,
        (i) => target[i] + (rnd.nextDouble() * 30 - 15),
      );
      final old = oldCorrection(lv);
      final noAir = AdaptiveEq.bandCorrection(lv);
      final air = AdaptiveEq.bandCorrection(lv, airDb: -5);
      expect(noAir, old);
      for (int i = 0; i <= 8; i++) {
        expect(air[i], old[i]);
      }
      expect(air[9], lessThanOrEqualTo(1.5));
      expect(air[9], greaterThanOrEqualTo(old[9]));
    }
    expect(AdaptiveEq.bandCorrection(const [1, 2, 3]), List<double>.filled(10, 0));
  });

  test('debugSeed: awaitProfile y prefetch resuelven < 50 ms sin decodificar',
      () async {
    final dir = await Directory.systemTemp.createTemp('gmx3133_');
    final f = File('${dir.path}${Platform.pathSeparator}seed.mp3');
    await f.writeAsBytes(List<int>.filled(64, 0));
    try {
      final p = AdaptiveProfile(List<double>.filled(10, 0.5), -2.5);
      AdaptiveEq.debugSeed(f.path, p);
      final sw = Stopwatch()..start();
      await AdaptiveEq.awaitProfile(f.path);
      await AdaptiveEq.prefetch(f.path);
      final got = await AdaptiveEq.profile(f.path);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(50));
      expect(got?.levelDb, -2.5);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('levelGlidePlan intacto', () {
    double lin(double db) => pow(10.0, db / 20.0).toDouble();
    expect(levelGlidePlan(0.04), isEmpty);
    final down = levelGlidePlan(-6);
    expect(down.length, 6);
    expect(down.first.atMs, 0);
    expect(down.first.trim, closeTo(lin(-1.2), 1e-9));
    expect(down.first.applyAf, isFalse);
    expect(down.last.atMs, 50);
    expect(down.last.trim, 1.0);
    expect(down.last.applyAf, isTrue);
    final up = levelGlidePlan(6);
    expect(up.length, 6);
    expect(up.first.applyAf, isTrue);
    expect(up.first.trim, closeTo(lin(-6), 1e-9));
    expect(up.last.atMs, 50);
    expect(up.last.trim, 1.0);
    for (final s in [...down, ...up]) {
      expect(s.trim, lessThanOrEqualTo(1.0));
    }
  });
}
