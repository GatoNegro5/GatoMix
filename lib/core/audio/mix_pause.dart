import 'dart:async';

/// Reloj de mezcla: solo cuenta el tiempo en que el audio está corriendo.
/// [pause] lo congela en el acto; la pausa no entra en [elapsedMilliseconds].
class MixRunClock {
  int _base;
  final Stopwatch _sw = Stopwatch();
  bool _running = false;

  MixRunClock([this._base = 0]) {
    _resume();
  }

  int get elapsedMilliseconds =>
      _base + (_running ? _sw.elapsedMilliseconds : 0);

  bool get running => _running;

  void pause() {
    if (!_running) return;
    _base += _sw.elapsedMilliseconds;
    _sw
      ..stop()
      ..reset();
    _running = false;
  }

  void resume() {
    if (_running) return;
    _resume();
  }

  void _resume() {
    _running = true;
    _sw
      ..reset()
      ..start();
  }
}

/// Línea de bitácora. [elapsedMs] y [fadeMs] son tiempo de mezcla, no de pared.
/// `fade` es el porcentaje del fundido (0–100, puede pasar de 100 si el reloj
/// se pasó). `rampa` es el BPM que manda la rampa en ese instante.
String mixPauseLine({
  required bool resume,
  required int elapsedMs,
  required int fadeMs,
  required double rampBpm,
}) {
  final double pct = fadeMs <= 0 ? 0 : (100.0 * elapsedMs / fadeMs);
  final String verb = resume ? 'REANUDA' : 'PAUSA';
  return '$verb en mezcla t=$elapsedMs fade=${pct.toStringAsFixed(1)} '
      'rampa=${rampBpm.toStringAsFixed(2)}';
}

/// Pausa compartida por el fundido, la rampa de BPM y el lazo de fase.
///
/// [pauseAll] congela cada reloj registrado en ese instante y despierta las
/// esperas. El tiempo de pared de la pausa no avanza esos relojes.
class MixPause {
  bool _paused = false;
  bool _armed = false;
  int _epoch = 0;
  int _fadeMs = 0;
  double _rampBpm = 0;
  MixRunClock? _fadeClock;
  Completer<void> _wake = Completer<void>();
  final List<MixRunClock> _clocks = <MixRunClock>[];
  String? lastLine;

  bool get paused => _paused;
  bool get armed => _armed;
  int get epoch => _epoch;
  int get fadeMs => _fadeMs;
  double get rampBpm => _rampBpm;
  MixRunClock? get fadeClock => _fadeClock;

  void arm() {
    _armed = true;
  }

  void setRampBpm(double bpm) {
    _rampBpm = bpm;
  }

  /// Reloj del fundido. [elapsedMs] solo lo usan las pruebas para clavar
  /// un punto; en la mezcla real arranca en cero.
  MixRunClock beginFade(int fadeMs, {int elapsedMs = 0}) {
    _armed = true;
    _fadeMs = fadeMs;
    final MixRunClock clock = _adopt(MixRunClock(elapsedMs));
    _fadeClock = clock;
    return clock;
  }

  MixRunClock clock() => _adopt(MixRunClock());

  MixRunClock _adopt(MixRunClock clock) {
    if (_paused) clock.pause();
    _clocks.add(clock);
    return clock;
  }

  /// Congela los relojes ya. La línea solo sale si hay una mezcla armada.
  String? pauseAll() {
    if (_paused) return null;
    _paused = true;
    for (final MixRunClock clock in _clocks) {
      clock.pause();
    }
    _signal();
    if (!_armed) return null;
    final String line = _line(false);
    lastLine = line;
    return line;
  }

  /// La línea se arma con los relojes todavía quietos, y después corren.
  String? resumeAll() {
    if (!_paused) return null;
    final String? line = _armed ? _line(true) : null;
    _paused = false;
    for (final MixRunClock clock in _clocks) {
      clock.resume();
    }
    _signal();
    if (line != null) lastLine = line;
    return line;
  }

  /// Suelta la mezcla. Despierta a quien esperaba; no deja el flag pegado
  /// para la rampa de la pista que sigue.
  void end() {
    _epoch++;
    _armed = false;
    _paused = false;
    _fadeMs = 0;
    _rampBpm = 0;
    _fadeClock = null;
    _clocks.clear();
    _signal();
  }

  String _line(bool resume) {
    final int t = _fadeClock?.elapsedMilliseconds ?? 0;
    return mixPauseLine(
      resume: resume,
      elapsedMs: t,
      fadeMs: _fadeMs,
      rampBpm: _rampBpm,
    );
  }

  void _signal() {
    final Completer<void> current = _wake;
    _wake = Completer<void>();
    if (!current.isCompleted) current.complete();
  }

  Future<void> untilRunning() async {
    while (_paused) {
      final Completer<void> gate = _wake;
      await gate.future;
    }
  }

  /// Espera [ms] de tiempo de este reloj. Una pausa lo interrumpe y no cuenta.
  Future<void> slice(int ms, MixRunClock clock) async {
    final int epoch = _epoch;
    if (ms <= 0) return;
    final int target = clock.elapsedMilliseconds + ms;
    while (clock.elapsedMilliseconds < target) {
      if (_epoch != epoch) return;
      if (_paused) {
        await untilRunning();
        if (_epoch != epoch) return;
        continue;
      }
      final int left = target - clock.elapsedMilliseconds;
      if (left <= 0) return;
      final Completer<void> gate = _wake;
      final int chunk = left > 20 ? 20 : left;
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(Duration(milliseconds: chunk)),
        gate.future,
      ]);
    }
  }

  /// Duerme [ms] de pared o hasta una pausa/fin, lo que ocurra antes.
  /// No mueve un reloj de mezcla: sirve para sondear libmpv.
  Future<void> nap(int ms) async {
    if (ms <= 0) return;
    final Completer<void> gate = _wake;
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(Duration(milliseconds: ms)),
      gate.future,
    ]);
  }
}
