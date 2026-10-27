import 'dart:math';

import 'package:media_kit/media_kit.dart';

/// Regulación del tempo de la pista que suena (Live DJ, incluido Stealth, y Automix).
///
/// Tras la mezcla se mide la diferencia entre el BPM con el que entró y su BPM
/// real. Esa diferencia se divide en 5 y se aplica al 10 %, 20 %, 30 %, 40 % y
/// 50 %. A la mitad la canción ya va en su BPM normal.
/// 10 s antes de la mezcla siguiente se acerca 1-2 BPM al BPM de la que entra.
/// Los cambios van en rampa lenta.
class TempoDrift {
  static const double minRate = 0.88;
  static const double maxRate = 1.12;

  double natural = 0.0;
  bool active = false;
  int _lastStep = 0;
  bool _dEnd = false;
  int _gen = 0;
  int _rampGen = 0;
  double _entryBpm = 0.0;

  /// Nueva pista sonando: `natural` = su BPM real, `rate` = tempo con el que entró.
  void begin(double naturalBpm, double rate) {
    _gen++;
    _rampGen++;
    natural = naturalBpm;
    _entryBpm = naturalBpm > 60 ? naturalBpm * rate : 0.0;
    final double diff = naturalBpm - _entryBpm;
    active = naturalBpm > 60 && diff.abs() >= 0.05;
    _lastStep = 0;
    _dEnd = false;
  }

  void stop() {
    _gen++;
    _rampGen++;
    active = false;
    natural = 0.0;
    _entryBpm = 0.0;
    _lastStep = 99;
    _dEnd = true;
  }

  /// 1 BPM (2 si falta mucho) hacia el objetivo, nunca pasándose.
  static double _step(double deltaBpm) {
    final double a = deltaBpm.abs();
    if (a <= 1.0) return deltaBpm;
    final double s = a >= 6.0 ? 2.0 : 1.0;
    return deltaBpm.sign * min(s, a);
  }

  double _clamp(double r) => r.clamp(minRate, maxRate).toDouble();

  double? _arm(double rate) {
    _rampGen++;
    return rate;
  }

  /// Devuelve el nuevo rate objetivo, o null si no toca ajustar.
  double? tick({
    required int posMs,
    required int durMs,
    required int mixOutMs,
    required double rate,
    required double nextBpm,
  }) {
    if (natural <= 60 || durMs <= 0) return null;
    final double eff = natural * rate;
    final double f = posMs / durMs;

    // 5 pasos iguales: al 10 % va 1/5 del camino, al 50 % está en su BPM.
    final int stepNo = (f * 10).floor();
    if (active && stepNo >= 1 && stepNo <= 5 && stepNo > _lastStep) {
      _lastStep = stepNo;
      final double targetBpm = stepNo >= 5
          ? natural
          : _entryBpm + (natural - _entryBpm) * stepNo / 5.0;
      if (stepNo >= 5) active = false;
      if ((targetBpm - eff).abs() < 0.05) return null;
      return _arm(_clamp(targetBpm / natural));
    }
    if (!_dEnd && mixOutMs > 0 && posMs >= mixOutMs - 10000 && nextBpm > 60) {
      _dEnd = true;
      _lastStep = 99;
      final double d = nextBpm - eff;
      if (d.abs() < 0.3) return null;
      return _arm(_clamp((eff + _step(d)) / natural));
    }
    return null;
  }

  /// Rampa lenta (senoidal) del rate. El temporizador es propio: no depende
  /// del reloj de la UI (250 ms) ni de los rebuilds de la carátula.
  Future<void> ramp(Player p, double from, double to, {int ms = 5000}) async {
    final int g = _gen;
    final int r = _rampGen;
    final Stopwatch sw = Stopwatch()..start();
    try {
      while (sw.elapsedMilliseconds < ms) {
        if (g != _gen || r != _rampGen) return;
        final double t = sw.elapsedMilliseconds / ms;
        await p.setRate(tempoRampValue(from, to, t));
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (g == _gen && r == _rampGen) await p.setRate(to);
    } catch (_) {}
  }
}

/// Curva de la rampa: seno de cuarto de ciclo, de [from] a [to].
/// Espera hasta el próximo golpe del saliente, menos 20 ms de arranque.
/// El saliente avanza [outRate] ms de pista por cada ms real.
/// Cero si no hay que esperar. El llamador solo demora si queda entre 0 y 1500.
int beatPhaseWaitMs({
  required double nowOutMs,
  required double beatMs,
  required double bpm,
  required double outRate,
}) {
  if (bpm <= 0 || outRate <= 0) return 0;
  final double period = 60000.0 / bpm;
  final double k = ((nowOutMs + 60 - beatMs) / period).ceilToDouble();
  final double nextBeat = beatMs + k * period;
  return ((nextBeat - nowOutMs) / outRate).round() - 20;
}

double tempoRampValue(double from, double to, double t) {
  final double u = t.clamp(0.0, 1.0);
  return from + (to - from) * sin(u * pi / 2);
}

/// Pasos de la rampa con su propio reloj. 5 s / 100 ms: el mismo recorrido
/// aunque la UI publique la posición solo cada 250 ms.
List<double> tempoRampSchedule(
  double from,
  double to, {
  int ms = 5000,
  int stepMs = 100,
}) {
  if (ms <= 0 || stepMs <= 0) return <double>[to];
  final List<double> out = <double>[];
  for (int elapsed = 0; elapsed < ms; elapsed += stepMs) {
    out.add(tempoRampValue(from, to, elapsed / ms));
  }
  out.add(to);
  return out;
}
