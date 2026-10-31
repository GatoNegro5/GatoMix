import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'mix_pause.dart';
import 'tempo_drift.dart';

/// Por debajo de esto el golpe ya está empatado: se vuelve al rate de la rampa.
const double phaseSettleMs = 5;

/// Tope del ajuste, pedido por Gabriel: 1 % sobre el rate de la rampa.
const double phaseMaxNudge = 0.01;

/// Un paso al tope cierra ~1 ms (`100 ms * 1 %`). No salta la banda de 5 ms.
const int phaseSampleMs = 100;

/// Segundos de una propiedad libmpv (`time-pos`, `audio-pts`, …).
double? parseMpvSeconds(dynamic raw) {
  if (raw == null) return null;
  if (raw is num) {
    final double v = raw.toDouble();
    if (v.isNaN || v.isInfinite) return null;
    return v;
  }
  final String s = raw.toString().trim();
  if (s.isEmpty || s == 'none' || s == 'nil' || s == 'null') return null;
  final double? v = double.tryParse(s);
  if (v == null || v.isNaN || v.isInfinite) return null;
  return v;
}

double _mod(double value, double period) {
  final double r = value % period;
  return r < 0 ? r + period : r;
}

/// Envuelve [delta] al arco más corto, en (-periodo/2, +periodo/2].
double wrapPhaseMs(double delta, double period) {
  if (period <= 0) {
    throw ArgumentError.value(period, 'period');
  }
  double x = delta % period;
  if (x <= -period / 2) x += period;
  if (x > period / 2) x -= period;
  return x;
}

/// Milisegundos reales hasta el próximo golpe. Cero si el deck está en el golpe.
double timeToNextBeatMs({
  required double posMs,
  required double beatMs,
  required double bpm,
  required double rate,
}) {
  if (bpm <= 0 || rate <= 0) {
    throw ArgumentError('bpm y rate tienen que ser positivos');
  }
  final double period = 60000.0 / bpm;
  final double phase = _mod(posMs - beatMs, period);
  if (phase == 0) return 0;
  return (period - phase) / rate;
}

/// Desfase de la entrante respecto de la saliente, en ms reales.
///
/// Positivo: el golpe de la entrante llega después (va tarde) → hay que
/// acelerarla. Negativo: va adelantada → hay que frenarla. Es el arco más
/// corto. El periodo de ese arco es el que se oye en la saliente
/// (`60000 / bpm / rate`), así que un rate distinto cambia el resultado.
double beatPhaseOffsetMs({
  required double outPosMs,
  required double outBeatMs,
  required double outBpm,
  required double outRate,
  required double inPosMs,
  required double inBeatMs,
  required double inBpm,
  required double inRate,
}) {
  final double tIn = timeToNextBeatMs(
    posMs: inPosMs,
    beatMs: inBeatMs,
    bpm: inBpm,
    rate: inRate,
  );
  final double tOut = timeToNextBeatMs(
    posMs: outPosMs,
    beatMs: outBeatMs,
    bpm: outBpm,
    rate: outRate,
  );
  final double periodReal = (60000.0 / outBpm) / outRate;
  return wrapPhaseMs(tIn - tOut, periodReal);
}

/// Espera para que, al dar al play, los golpes coincidan.
/// La entrante no tiene por qué estar seekeada a un golpe: se descuenta
/// lo que a ella le falta. El resultado queda en `[0, periodo)`.
int phaseAlignWaitMs({
  required double nowOutMs,
  required double outBeatMs,
  required double outBpm,
  required double outRate,
  required double inPosMs,
  required double inBeatMs,
  required double inBpm,
  required double inRate,
  required int startupMs,
}) {
  if (outBpm <= 0 || inBpm <= 0 || outRate <= 0 || inRate <= 0) return 0;
  final double tOut = timeToNextBeatMs(
    posMs: nowOutMs,
    beatMs: outBeatMs,
    bpm: outBpm,
    rate: outRate,
  );
  final double tIn = timeToNextBeatMs(
    posMs: inPosMs,
    beatMs: inBeatMs,
    bpm: inBpm,
    rate: inRate,
  );
  final double periodReal = (60000.0 / outBpm) / outRate;
  return _mod(tOut - tIn - startupMs, periodReal).round();
}

/// Ajuste temporal encima del rate de la rampa. No lo sustituye:
/// `aplicado = rampa + rampa * nudge`, con `|nudge| ≤ 1 %`.
class PhaseCorrection {
  final double offsetMs;
  final double rampRate;
  final double nudge;
  final double appliedRate;
  final bool settled;

  const PhaseCorrection({
    required this.offsetMs,
    required this.rampRate,
    required this.nudge,
    required this.appliedRate,
    required this.settled,
  });
}

PhaseCorrection phaseCorrectionPlan({
  required double offsetMs,
  required double rampRate,
}) {
  final bool settled = offsetMs.abs() < phaseSettleMs;
  // Positivo = entrante tarde → más rápido. Negativo → más lento.
  final double nudge = settled
      ? 0.0
      : (offsetMs > 0 ? phaseMaxNudge : -phaseMaxNudge);
  return PhaseCorrection(
    offsetMs: offsetMs,
    rampRate: rampRate,
    nudge: nudge,
    appliedRate: rampRate + rampRate * nudge,
    settled: settled,
  );
}

String phaseTraceLine({
  required double? initialMs,
  required double? finalMs,
  required double latencyMs,
  required int steps,
}) {
  String ms(double? v) {
    if (v == null || v.isNaN) return 'na';
    final String s = v.toStringAsFixed(1);
    return s == '-0.0' ? '0.0' : s;
  }

  final String latency = latencyMs.toStringAsFixed(1);
  return 'PHASE inicial=${ms(initialMs)} final=${ms(finalMs)} '
      'latencia=${latency == '-0.0' ? '0.0' : latency} pasos=$steps';
}

/// Promedio móvil de la latencia de arranque. Sin tope: un intento que no
/// llegó a medir no se guarda.
class LatencyAverage {
  LatencyAverage({this.window = 8});

  final int window;
  final List<double> _samples = <double>[];

  void add(double ms) {
    if (ms.isNaN || ms.isInfinite || ms < 0) return;
    _samples.add(ms);
    while (_samples.length > window) {
      _samples.removeAt(0);
    }
  }

  double? get ms {
    if (_samples.isEmpty) return null;
    double sum = 0;
    for (final double sample in _samples) {
      sum += sample;
    }
    return sum / _samples.length;
  }
}

/// Latencia de arranque por dispositivo de audio, viva mientras corre la app.
class DeckLatencyStore {
  DeckLatencyStore();

  static final DeckLatencyStore session = DeckLatencyStore();
  final Map<String, LatencyAverage> _byDevice = <String, LatencyAverage>{};

  void add(String device, double ms) {
    _byDevice.putIfAbsent(device, LatencyAverage.new).add(ms);
  }

  double? averageMs(String device) => _byDevice[device]?.ms;
}

class DeckClock {
  double? _ms;
  double _rate = 1;
  final Stopwatch _sw = Stopwatch();

  void note(double ms, double rate) {
    _ms = ms;
    _rate = rate > 0 ? rate : 1;
    _sw
      ..reset()
      ..start();
  }

  double? project() {
    final double? ms = _ms;
    if (ms == null || !_sw.isRunning) return null;
    return ms + _sw.elapsedMicroseconds * _rate / 1000.0;
  }
}

class HeardPosition {
  final double ms;
  final String source;

  const HeardPosition(this.ms, this.source);
}

Future<double?> mpvPropertyMs(dynamic platform, String key) async {
  try {
    final dynamic raw = await platform.getProperty(key);
    final double? sec = parseMpvSeconds(raw);
    if (sec == null || sec < 0) return null;
    return sec * 1000.0;
  } catch (_) {
    return null;
  }
}

Future<double?> _firstMs(dynamic platform, List<String> keys) async {
  for (final String key in keys) {
    final double? ms = await mpvPropertyMs(platform, key);
    if (ms != null) return ms;
  }
  return null;
}

const List<String> _audioKeys = <String>['audio-pts/full', 'audio-pts'];
const List<String> _timeKeys = <String>['time-pos/full', 'time-pos'];

double? _rateOf(Player player) {
  try {
    final double rate = player.state.rate;
    if (rate <= 0) return null;
    return rate;
  } catch (_) {
    return null;
  }
}

/// Posición que se está oyendo. `audio-pts` ya resta el retardo del ao.
/// Si libmpv no contesta, se proyecta la última lectura con un reloj.
Future<HeardPosition> heardPosition(Player player, DeckClock clock) async {
  final dynamic platform = player.platform;
  if (platform != null) {
    final double? audio = await _firstMs(platform, _audioKeys);
    if (audio != null) {
      clock.note(audio, _rateOf(player) ?? 1);
      return HeardPosition(audio, 'audio-pts');
    }
    final double? time = await _firstMs(platform, _timeKeys);
    if (time != null) {
      clock.note(time, _rateOf(player) ?? 1);
      return HeardPosition(time, 'time-pos');
    }
  }
  final double? projected = clock.project();
  if (projected != null) return HeardPosition(projected, 'clock');
  double stateMs = 0;
  try {
    stateMs = player.state.position.inMilliseconds.toDouble();
  } catch (_) {}
  clock.note(stateMs, _rateOf(player) ?? 1);
  return HeardPosition(stateMs, 'state');
}

/// Retardo de salida: `time-pos` va por delante de `audio-pts` en lo que
/// el ao todavía no ha soltado. Null si libmpv no publica las dos.
Future<double?> outputDelayMs(Player player) async {
  final dynamic platform = player.platform;
  if (platform == null) return null;
  final double? audio = await _firstMs(platform, _audioKeys);
  final double? time = await _firstMs(platform, _timeKeys);
  if (audio == null || time == null) return null;
  final double delay = time - audio;
  if (delay < 0) return null;
  return delay;
}

Future<String> audioDeviceKey(Player player) async {
  final dynamic platform = player.platform;
  if (platform == null) return 'default';
  for (final String key in const <String>['audio-device', 'current-ao']) {
    try {
      final dynamic raw = await platform.getProperty(key);
      final String name = (raw ?? '').toString().trim();
      if (name.isNotEmpty &&
          name != 'none' &&
          name != 'nil' &&
          name != 'null') {
        return name;
      }
    } catch (_) {}
  }
  return 'default';
}

/// Desde `play()` hasta que la posición oída avanza. Null si no llegó a moverse:
/// eso no se guarda como si fuera una latencia.
Future<double?> measurePlayAdvanceMs({
  required Player player,
  required MixRunClock clock,
  required MixPause hold,
  required double? audioBeforeMs,
  required double? timeBeforeMs,
  int timeoutMs = 1000,
}) async {
  final int epoch = hold.epoch;
  bool sawAudio = audioBeforeMs != null;
  while (clock.elapsedMilliseconds < timeoutMs) {
    if (hold.epoch != epoch) return null;
    if (hold.paused) {
      await hold.untilRunning();
      continue;
    }
    final dynamic platform = player.platform;
    if (platform != null) {
      final double? audio = await _firstMs(platform, _audioKeys);
      if (audio != null) {
        sawAudio = true;
        final double base = audioBeforeMs ?? timeBeforeMs ?? audio;
        if (audio > base + 1.0) {
          return clock.elapsedMilliseconds.toDouble();
        }
      } else if (!sawAudio) {
        final double? time = await _firstMs(platform, _timeKeys);
        final double base = timeBeforeMs ?? 0;
        if (time != null && time > base + 1.0) {
          return clock.elapsedMilliseconds.toDouble();
        }
      }
    }
    await hold.nap(5);
  }
  return null;
}

/// Lazo de fase. El nudge va encima de [rampRate]; al asentarse o al cerrar
/// se devuelve ese rate, no un 1.0.
class PhaseLockSession {
  PhaseLockSession({
    required this.outgoing,
    required this.incoming,
    required this.outBeatMs,
    required this.outBpm,
    required this.inBeatMs,
    required this.inBpm,
    required this.rampRate,
    required this.hold,
    required this.latencyUsedMs,
    required this.measuredMs,
  });

  final Player outgoing;
  final Player incoming;
  final double outBeatMs;
  final double outBpm;
  final double inBeatMs;
  final double inBpm;
  final double rampRate;
  final MixPause hold;
  final double latencyUsedMs;
  final Future<double?> measuredMs;

  double? initialMs;
  double? finalMs;
  int steps = 0;

  final DeckClock _outClock = DeckClock();
  final DeckClock _inClock = DeckClock();
  MixRunClock? _clock;
  Future<void>? _running;
  bool _stop = false;
  bool _closed = false;
  int _epoch = 0;

  void start() {
    _epoch = hold.epoch;
    _clock = hold.clock();
    _running ??= _loop();
  }

  Future<void> finish() async {
    if (_closed) return;
    _closed = true;
    _stop = true;
    try {
      await _running;
    } catch (_) {}
  }

  void logLater(void Function(String line) write) {
    unawaited(() async {
      final double latency = await latencyForLog();
      write(line(latency));
    }());
  }

  Future<double> latencyForLog() async {
    try {
      final double? measured = await measuredMs;
      if (measured != null && measured >= 0) return measured;
    } catch (_) {}
    return latencyUsedMs;
  }

  String line(double latencyMs) => phaseTraceLine(
    initialMs: initialMs,
    finalMs: finalMs,
    latencyMs: latencyMs,
    steps: steps,
  );

  Future<void> _loop() async {
    final MixRunClock clock = _clock ?? hold.clock();
    try {
      while (!_stop && hold.epoch == _epoch) {
        await _sample(apply: true);
        if (_stop || hold.epoch != _epoch) break;
        await hold.slice(phaseSampleMs, clock);
      }
      if (hold.epoch == _epoch) await _sample(apply: false);
    } finally {
      try {
        await incoming.setRate(rampRate);
      } catch (_) {}
    }
  }

  Future<void> _sample({required bool apply}) async {
    if (hold.paused || hold.epoch != _epoch) return;
    final double? outRate = _rateOf(outgoing);
    final double? inRate = _rateOf(incoming);
    if (outRate == null || inRate == null) return;
    final HeardPosition outHeard = await heardPosition(outgoing, _outClock);
    final HeardPosition inHeard = await heardPosition(incoming, _inClock);
    if (hold.paused || hold.epoch != _epoch) return;
    final double offset = beatPhaseOffsetMs(
      outPosMs: outHeard.ms,
      outBeatMs: outBeatMs,
      outBpm: outBpm,
      outRate: outRate,
      inPosMs: inHeard.ms,
      inBeatMs: inBeatMs,
      inBpm: inBpm,
      inRate: inRate,
    );
    initialMs ??= offset;
    finalMs = offset;
    final PhaseCorrection plan = phaseCorrectionPlan(
      offsetMs: offset,
      rampRate: rampRate,
    );
    if (!plan.settled) steps++;
    if (!apply || hold.paused) return;
    if ((inRate - plan.appliedRate).abs() < 0.0005) return;
    try {
      await incoming.setRate(plan.appliedRate);
    } catch (_) {}
  }
}

/// Espera al golpe con la posición oída y la latencia medida, da al play
/// y arranca el lazo. La pausa de [hold] congela la espera y el lazo.
Future<PhaseLockSession?> engageBeatLock({
  required Player outgoing,
  required Player incoming,
  required double outBeatMs,
  required double outBpm,
  required double outRate,
  required double inBeatMs,
  required double inBpm,
  required double cueMs,
  required double inRate,
  required double rampRate,
  required bool incomingOnBeat,
  required MixPause hold,
  DeckLatencyStore? store,
}) async {
  if (outBpm <= 0 || inBpm <= 0 || rampRate <= 0) {
    await incoming.play();
    return null;
  }
  final int epoch = hold.epoch;
  final DeckLatencyStore memory = store ?? DeckLatencyStore.session;
  final String device = await audioDeviceKey(outgoing);
  final double? average = memory.averageMs(device);
  double latency = average ?? 0;
  if (average == null) {
    final double? ao = await outputDelayMs(outgoing);
    if (ao != null && ao > 0) latency = ao;
  }
  final int startup = latency.round();
  final dynamic inPlatform = incoming.platform;
  final double? audioBefore = inPlatform == null
      ? null
      : await _firstMs(inPlatform, _audioKeys);
  final double? timeBefore = inPlatform == null
      ? null
      : await _firstMs(inPlatform, _timeKeys);
  final HeardPosition heard = await heardPosition(outgoing, DeckClock());
  final MixRunClock gate = hold.clock();
  final double liveOut = outRate > 0 ? outRate : (_rateOf(outgoing) ?? 1);
  final int waitMs;
  if (incomingOnBeat) {
    waitMs = beatPhaseWaitMs(
      nowOutMs: heard.ms,
      beatMs: outBeatMs,
      bpm: outBpm,
      outRate: liveOut,
      startupMs: startup,
    );
  } else {
    final double inPos = audioBefore ?? timeBefore ?? cueMs;
    waitMs = phaseAlignWaitMs(
      nowOutMs: heard.ms,
      outBeatMs: outBeatMs,
      outBpm: outBpm,
      outRate: liveOut,
      inPosMs: inPos,
      inBeatMs: inBeatMs,
      inBpm: inBpm,
      inRate: inRate > 0 ? inRate : rampRate,
      startupMs: startup,
    );
  }
  final int left = waitMs - gate.elapsedMilliseconds;
  if (left > 0 && left < 1500) {
    await hold.slice(left, gate);
  }
  if (hold.epoch != epoch) return null;
  if (hold.paused) await hold.untilRunning();
  if (hold.epoch != epoch) return null;
  final MixRunClock playClock = hold.clock();
  await incoming.play();
  final Future<double?> measured = measurePlayAdvanceMs(
    player: incoming,
    clock: playClock,
    hold: hold,
    audioBeforeMs: audioBefore,
    timeBeforeMs: timeBefore,
  ).then((double? ms) {
    if (ms != null) memory.add(device, ms);
    return ms;
  });
  final PhaseLockSession session = PhaseLockSession(
    outgoing: outgoing,
    incoming: incoming,
    outBeatMs: outBeatMs,
    outBpm: outBpm,
    inBeatMs: inBeatMs,
    inBpm: inBpm,
    rampRate: rampRate,
    hold: hold,
    latencyUsedMs: latency,
    measuredMs: measured,
  );
  session.start();
  return session;
}
