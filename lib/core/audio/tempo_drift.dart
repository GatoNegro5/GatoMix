import 'dart:math';

import 'package:media_kit/media_kit.dart';

import 'mix_pause.dart';

/// Un paso de la rampa: [offsetMs] desde el punto de mezcla (negativo = antes)
/// y el BPM con el que la pista queda sonando al completar el paso.
class TempoMark {
  final int offsetMs;
  final double bpm;

  const TempoMark(this.offsetMs, this.bpm);
}

/// Rampa al punto medio. A (saliente) llega a [midpoint] en el cruce.
/// B (entrante) arranca en [midpoint] y vuelve a su BPM.
class MidpointTempoPlan {
  final double a;
  final double b;
  final double midpoint;
  final double span;
  final List<TempoMark> outgoing;
  final List<TempoMark> incoming;

  /// El rate `m/natural` de A o de B cae fuera de 0.88–1.12.
  final bool rateLimited;
  final double outgoingRate;
  final double incomingRate;
  final String note;

  const MidpointTempoPlan({
    required this.a,
    required this.b,
    required this.midpoint,
    required this.span,
    required this.outgoing,
    required this.incoming,
    required this.rateLimited,
    required this.outgoingRate,
    required this.incomingRate,
    required this.note,
  });
}

/// Pasos de A antes del cruce y de B después.
///
/// d ≤ 8: mitad en 2 pasos iguales (−10 s, −5 s y +5 s, +10 s).
/// 8 < d ≤ 12: 4 pasos antes (12/9/6/3 s, pesos 1-1-2-2) y 3 después
/// (+5/+10/+14). d > 12: los mismos pesos y el mismo espaciado, con más
/// pasos. Si B > A el signo se invierte. La fracción se reparte igual.
MidpointTempoPlan midpointTempoPlan(double a, double b) {
  final double m = (a + b) / 2;
  final double d = (a - b).abs();
  final double outRate = a.abs() < 1e-9 ? 1 : m / a;
  final double inRate = b.abs() < 1e-9 ? 1 : m / b;
  final bool limited = a > 0 &&
      b > 0 &&
      (outRate < TempoDrift.minRate ||
          outRate > TempoDrift.maxRate ||
          inRate < TempoDrift.minRate ||
          inRate > TempoDrift.maxRate);
  final String note =
      'a=${a.toStringAsFixed(3)} b=${b.toStringAsFixed(3)} '
      'm=${m.toStringAsFixed(3)} '
      'rateA=${outRate.toStringAsFixed(4)} rateB=${inRate.toStringAsFixed(4)}';
  if (d < 1e-9 || a <= 0 || b <= 0) {
    return MidpointTempoPlan(
      a: a,
      b: b,
      midpoint: m,
      span: d,
      outgoing: const <TempoMark>[],
      incoming: const <TempoMark>[],
      rateLimited: limited,
      outgoingRate: outRate,
      incomingRate: inRate,
      note: note,
    );
  }
  final double half = d / 2;
  final bool wide = d > 8;
  final int nOut = wide ? 2 + 2 * ((d - 8) / 4).ceil() : 2;
  final int nIn = (d / 4).ceil() < 2 ? 2 : (d / 4).ceil();
  final List<double> outPortions = _portions(nOut, half, weighted: wide);
  final List<double> inPortions = _portions(nIn, half, weighted: false);
  return MidpointTempoPlan(
    a: a,
    b: b,
    midpoint: m,
    span: d,
    outgoing: _walk(
      start: a,
      end: m,
      offsets: _outgoingOffsets(nOut),
      portions: outPortions,
    ),
    incoming: _walk(
      start: m,
      end: b,
      offsets: _incomingOffsets(nIn),
      portions: inPortions,
    ),
    rateLimited: limited,
    outgoingRate: outRate,
    incomingRate: inRate,
    note: note,
  );
}

/// Rate de B en el cruce. Si el punto medio no cabe en 0.88–1.12, [blocked]
/// y el rate queda en 1: no se recorta a la frontera.
class MidpointEntry {
  final double incomingRate;
  final bool blocked;
  final String note;

  const MidpointEntry({
    required this.incomingRate,
    required this.blocked,
    required this.note,
  });
}

bool _musicalBpm(double bpm) => bpm >= 40 && bpm <= 250;

MidpointEntry midpointEntry(double a, double b) {
  if (!_musicalBpm(a) || !_musicalBpm(b)) {
    return const MidpointEntry(incomingRate: 1, blocked: false, note: '');
  }
  final MidpointTempoPlan plan = midpointTempoPlan(a, b);
  if (plan.rateLimited) {
    return MidpointEntry(incomingRate: 1, blocked: true, note: plan.note);
  }
  return MidpointEntry(
    incomingRate: plan.incomingRate,
    blocked: false,
    note: plan.note,
  );
}

List<int> _outgoingOffsets(int n) {
  if (n <= 2) return const <int>[-10000, -5000];
  return <int>[for (int i = 0; i < n; i++) -3000 * (n - i)];
}

List<int> _incomingOffsets(int n) {
  if (n <= 2) return const <int>[5000, 10000];
  return <int>[
    5000,
    10000,
    for (int i = 2; i < n; i++) 14000 + (i - 2) * 4000,
  ];
}

List<double> _portions(int n, double half, {required bool weighted}) {
  if (n <= 0) return const <double>[];
  if (!weighted) {
    final double s = half / n;
    return List<double>.filled(n, s);
  }
  final int h = n ~/ 2;
  final List<int> w = <int>[for (int i = 0; i < n; i++) i < h ? 1 : 2];
  final int sum = w.fold<int>(0, (int a, int b) => a + b);
  return <double>[for (final int x in w) half * x / sum];
}

List<TempoMark> _walk({
  required double start,
  required double end,
  required List<int> offsets,
  required List<double> portions,
}) {
  final List<TempoMark> out = <TempoMark>[];
  double cursor = start;
  final double dir = end >= start ? 1.0 : -1.0;
  for (int i = 0; i < offsets.length; i++) {
    if (i == offsets.length - 1) {
      cursor = end;
    } else {
      cursor += dir * portions[i].abs();
    }
    out.add(TempoMark(offsets[i], cursor));
  }
  return out;
}

/// Ganancia del cruce (curva `pow`). No recibe el rate: `setRate` no mueve el nivel.
double dawnCrossfadeGain(double progress) {
  final double x = (progress * 1.8).clamp(0.0, 1.0);
  return pow(x, 1.2).toDouble();
}

/// Rampa de tempo al punto medio (Live DJ, incluido Stealth, y Automix).
///
/// Antes del cruce A camina hacia el punto medio. B arranca ahí, en fase,
/// y después vuelve a su BPM. Los cambios van en rampa senoidal.
class TempoDrift {
  static const double minRate = 0.88;
  static const double maxRate = 1.12;

  double natural = 0.0;
  bool active = false;
  int rampMs = 5000;
  bool midpointBlocked = false;
  String midpointNote = '';

  int _gen = 0;
  int _rampGen = 0;
  bool _phaseIn = false;
  bool _originSet = false;
  int _originMs = 0;
  int _inStep = 0;
  int _outStep = 0;
  MidpointTempoPlan? _inPlan;
  MidpointTempoPlan? _outPlan;
  bool _reported = false;

  /// Pista que acaba de quedar sonando. [rate] es el tempo con el que entró
  /// (m/b si el cruce igualó en el punto medio).
  void begin(double naturalBpm, double rate) {
    _gen++;
    _rampGen++;
    natural = naturalBpm;
    _inStep = 0;
    _outStep = 0;
    _originSet = false;
    _outPlan = null;
    _reported = false;
    midpointBlocked = false;
    midpointNote = '';
    final bool musical = _musicalBpm(naturalBpm);
    final double entry = musical && rate > 0 ? naturalBpm * rate : 0;
    if (musical && (entry - naturalBpm).abs() >= 0.05) {
      _inPlan = midpointTempoPlan(entry * 2 - naturalBpm, naturalBpm);
      _phaseIn = true;
      active = _inPlan!.incoming.isNotEmpty && !_inPlan!.rateLimited;
      if (_inPlan!.rateLimited) {
        midpointBlocked = true;
        midpointNote = _inPlan!.note;
        active = false;
        _phaseIn = false;
        _inPlan = null;
      }
    } else {
      _inPlan = null;
      _phaseIn = false;
      active = false;
    }
  }

  void stop() {
    _gen++;
    _rampGen++;
    active = false;
    natural = 0.0;
    _phaseIn = false;
    _inPlan = null;
    _outPlan = null;
    _inStep = 99;
    _outStep = 99;
    midpointBlocked = false;
    midpointNote = '';
  }

  /// Nota de un punto medio fuera de rango, una sola vez.
  String? takeBlockedReport() {
    if (!midpointBlocked || _reported) return null;
    _reported = true;
    return midpointNote;
  }

  double _clamp(double r) => r.clamp(minRate, maxRate).toDouble();

  double? _arm(double rate, int ms) {
    _rampGen++;
    rampMs = ms < 400 ? 400 : (ms > 8000 ? 8000 : ms);
    return _clamp(rate);
  }

  int _gap(List<TempoMark> steps, int index, int rel, {required bool untilMix}) {
    if (index + 1 < steps.length) {
      return steps[index + 1].offsetMs - rel;
    }
    if (untilMix) return -rel;
    final int prev = index > 0
        ? steps[index].offsetMs - steps[index - 1].offsetMs
        : 5000;
    return prev;
  }

  /// El último paso ya vencido, o null si todavía no toca.
  int? _due(List<TempoMark> steps, int from, int rel) {
    int last = -1;
    for (int i = from; i < steps.length; i++) {
      if (rel >= steps[i].offsetMs) {
        last = i;
      } else {
        break;
      }
    }
    return last < 0 ? null : last;
  }

  /// Nuevo rate, o null si no toca. [mixOutMs] es el punto de mezcla de la
  /// pista que suena. [nextBpm] es el BPM real de la que entra.
  double? tick({
    required int posMs,
    required int durMs,
    required int mixOutMs,
    required double rate,
    required double nextBpm,
  }) {
    if (!_musicalBpm(natural) || durMs <= 0) return null;
    if (_phaseIn && _inPlan != null && !_inPlan!.rateLimited) {
      if (!_originSet) {
        _originMs = posMs;
        _originSet = true;
      }
      final int rel = posMs - _originMs;
      final int? due = _due(_inPlan!.incoming, _inStep, rel);
      if (due != null) {
        _inStep = due + 1;
        if (_inStep >= _inPlan!.incoming.length) {
          active = false;
          _phaseIn = false;
        }
        final double target = _inPlan!.incoming[due].bpm / natural;
        final int gap = _gap(
          _inPlan!.incoming,
          due,
          rel,
          untilMix: false,
        );
        if ((target - rate).abs() >= 0.002 &&
            target >= minRate &&
            target <= maxRate) {
          return _arm(target, gap);
        }
      }
      if (_phaseIn) return null;
    }

    if (!_musicalBpm(nextBpm) || mixOutMs <= 0) return null;
    if (_outPlan == null || (_outPlan!.b - nextBpm).abs() > 0.05) {
      _outPlan = midpointTempoPlan(natural, nextBpm);
      _outStep = 0;
      if (_outPlan!.rateLimited) {
        midpointBlocked = true;
        midpointNote = _outPlan!.note;
      }
    }
    if (_outPlan!.rateLimited) return null;
    final int rel = posMs - mixOutMs;
    final int? due = _due(_outPlan!.outgoing, _outStep, rel);
    if (due == null) return null;
    _outStep = due + 1;
    final double target = _outPlan!.outgoing[due].bpm / natural;
    if (target < minRate || target > maxRate) return null;
    if ((target - rate).abs() < 0.002) return null;
    return _arm(
      target,
      _gap(_outPlan!.outgoing, due, rel, untilMix: true),
    );
  }

  /// Rampa lenta (senoidal) del rate. El temporizador es propio: no depende
  /// del reloj de la UI (250 ms) ni de los rebuilds de la carátula.
  /// [hold] congela ese reloj si el usuario pausa; la curva no cambia.
  Future<void> ramp(
    Player p,
    double from,
    double to, {
    int? ms,
    MixPause? hold,
  }) async {
    final int g = _gen;
    final int r = _rampGen;
    final int dur = ms ?? rampMs;
    final int epoch = hold?.epoch ?? 0;
    final MixRunClock clock = hold?.clock() ?? MixRunClock();
    try {
      while (clock.elapsedMilliseconds < dur) {
        if (g != _gen || r != _rampGen) return;
        if (hold != null && hold.epoch != epoch) return;
        if (hold != null && hold.paused) {
          await hold.untilRunning();
          continue;
        }
        final double t = clock.elapsedMilliseconds / dur;
        await p.setRate(tempoRampValue(from, to, t));
        if (hold != null) {
          await hold.slice(100, clock);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      if (g == _gen && r == _rampGen) await p.setRate(to);
    } catch (_) {}
  }
}

/// Curva de la rampa: seno de cuarto de ciclo, de [from] a [to].
/// Espera hasta el próximo golpe del saliente, menos la latencia de arranque
/// medida ([startupMs]). El saliente avanza [outRate] ms de pista por cada ms
/// real. Cero si no hay que esperar. El llamador solo demora si queda entre
/// 0 y 1500.
int beatPhaseWaitMs({
  required double nowOutMs,
  required double beatMs,
  required double bpm,
  required double outRate,
  required int startupMs,
}) {
  if (bpm <= 0 || outRate <= 0) return 0;
  final double period = 60000.0 / bpm;
  final double k = ((nowOutMs + 60 - beatMs) / period).ceilToDouble();
  final double nextBeat = beatMs + k * period;
  return ((nextBeat - nowOutMs) / outRate).round() - startupMs;
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
