import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/services/adaptive_eq.dart';

/// 3.1.20 (Pendiente 6): rampa de sonoridad de AdaptiveEq.
double db(double lin) => 20 * log(lin) / ln10;

/// Linea de tiempo (dB efectivo) del deck entrante con cache fria: el nivel
/// del af empieza en 0 y onReady llega a mitad del cruce con [level].
List<double> timeline(double level, {required bool glide}) {
  double afLevel = 0;
  double trim = 1;
  final List<double> out = <double>[0];
  if (!glide) {
    afLevel = level;
    out.add(afLevel);
    return out;
  }
  for (final LevelGlideStep s in levelGlidePlan(level - afLevel)) {
    if (s.applyAf) afLevel = level;
    trim = s.trim;
    out.add(afLevel + db(trim));
  }
  return out;
}

double maxJump(List<double> t) {
  double m = 0;
  for (int i = 1; i < t.length; i++) {
    m = max(m, (t[i] - t[i - 1]).abs());
  }
  return m;
}

void main() {
  test('cache fria: antes el onReady tardio era un escalon entero', () {
    final List<double> old = timeline(-6.0, glide: false);
    final List<double> now = timeline(-6.0, glide: true);
    // ignore: avoid_print
    print('3120 escalon viejo=${maxJump(old).toStringAsFixed(2)} dB, '
        'rampa=${maxJump(now).toStringAsFixed(2)} dB, final=${now.last.toStringAsFixed(2)}');
    expect(maxJump(old), closeTo(6.0, 1e-9));
    expect(maxJump(now), lessThanOrEqualTo(6.0 / 5 + 1e-6));
    expect(now.last, closeTo(-6.0, 1e-6));
  });

  for (final double d in <double>[-12, -6, -1.5, 2.5, 9]) {
    test('plan $d dB: 50 ms, recorte <= 1, af una vez, monotono', () {
      final List<LevelGlideStep> p = levelGlidePlan(d);
      expect(p.last.atMs, 50);
      expect(p.last.trim, 1.0);
      expect(p.where((s) => s.applyAf).length, 1);
      expect(p.every((s) => s.trim <= 1.0 && s.trim > 0), isTrue);
      final List<double> t = timeline(d, glide: true);
      for (int i = 1; i < t.length; i++) {
        if (d < 0) {
          expect(t[i], lessThanOrEqualTo(t[i - 1] + 1e-9));
        } else {
          expect(t[i], greaterThanOrEqualTo(t[i - 1] - 1e-9));
        }
      }
      expect(maxJump(t), lessThanOrEqualTo(d.abs() / 5 + 1e-6));
      for (int i = 1; i < p.length; i++) {
        expect(p[i].atMs - p[i - 1].atMs, lessThanOrEqualTo(10));
      }
    });
  }

  test('sin cambio de nivel no hay rampa', () {
    expect(levelGlidePlan(0.0), isEmpty);
    expect(levelGlidePlan(0.04), isEmpty);
  });
}
