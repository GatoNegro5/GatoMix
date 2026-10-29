/// Duración del deck cuando el conteo de frames y el reproductor no coinciden.
///
/// Un MP3 con basura o un segundo stream al final infla el conteo de frames
/// (Rust) por encima de lo que el reproductor llega a sonar. La estimación
/// inversa también existe: libmpv alarga por bitrate y el conteo es el corto.
/// Si discrepan más de 1,5 s manda la más corta, salvo que el reproductor sea
/// claramente falso (0, o menos de la mitad del conteo: estimación de arranque).
const int kDurationDisagreeMs = 1500;

/// Fundido más corto que sigue siendo una mezcla (DNA / Phrase 8 / Stealth).
/// El disparo nunca queda a menos de esto del final real.
const int kMinMixLengthMs = 8000;

/// Elige la duración que manda el deck.
///
/// [frameMs] es el conteo de frames. [playerMs] es la duración del reproductor.
/// [heldMs] es la ya publicada para esta pista (0 si todavía no hay). Una corta
/// creíble ya publicada no se vuelve a estirar con un conteo más largo, y una
/// corta posterior creíble sí sustituye a la publicada.
int resolveDeckDurationMs({
  required int frameMs,
  required int playerMs,
  int heldMs = 0,
}) {
  final int frame = frameMs < 0 ? 0 : frameMs;
  final int player = playerMs < 0 ? 0 : playerMs;
  final int held = heldMs < 0 ? 0 : heldMs;

  final int picked = _pickDeckDurationMs(frame, player);
  if (held <= 0 || picked <= 0) return picked;

  // Corta posterior creíble: el reproductor acaba de medir el final real.
  // Una estimación de arranque (0 o < 50 % del conteo) no achica.
  if (picked + kDurationDisagreeMs < held) {
    if (frame > 0 && !_credibleAgainstFrame(picked, frame)) return held;
    return picked;
  }

  // No estirar una corta ya creíble con un conteo o un reporte más largo.
  if (held + kDurationDisagreeMs < picked &&
      _credibleAgainstFrame(held, frame)) {
    return held;
  }
  return picked;
}

int _pickDeckDurationMs(int frame, int player) {
  if (frame <= 0) return player;
  if (player <= 0 || player * 2 < frame) return frame;
  if ((frame - player).abs() > kDurationDisagreeMs) {
    return player < frame ? player : frame;
  }
  return player;
}

bool _credibleAgainstFrame(int ms, int frame) {
  if (ms <= 0) return false;
  if (frame <= 0) return true;
  return ms * 2 >= frame;
}

/// Final real si el reproductor es más corto y creíble, o si el deck ya
/// terminó / la posición se quedó quieta antes del final calculado.
/// Devuelve null cuando el cálculo sigue valiendo.
int? earlyPlaybackEndMs({
  required int computedEndMs,
  required int positionMs,
  required int playerDurationMs,
  required bool deckCompleted,
  required bool positionStalled,
  int minPositionMs = 20000,
}) {
  if (computedEndMs <= 0) return null;

  int? end;
  if (playerDurationMs > 0 &&
      _credibleAgainstFrame(playerDurationMs, computedEndMs) &&
      playerDurationMs + kDurationDisagreeMs < computedEndMs) {
    end = playerDurationMs;
  }

  final bool stopped =
      (deckCompleted || positionStalled) &&
      positionMs >= minPositionMs &&
      positionMs + kDurationDisagreeMs < computedEndMs;
  if (stopped && (end == null || positionMs < end)) {
    end = positionMs;
  }
  return end;
}

/// El disparo de la mezcla queda como máximo en
/// `duración real − mezcla mínima`, para que siempre arranque antes del final.
///
/// Un disparo que ya está antes se conserva (65 / 80 / 75, DNA, Phrase, Stealth).
/// En una pista tan corta que ese tope bajaría de los 10 s con los que el deck
/// arma, se conserva el disparo si todavía cae antes del final.
int clampMixTriggerMs({
  required int triggerMs,
  required int realDurationMs,
  int minMixMs = kMinMixLengthMs,
}) {
  if (triggerMs <= 0 || realDurationMs <= 0) return triggerMs;
  final int room = minMixMs > 0 ? minMixMs : 0;
  final int latest = realDurationMs - room;
  if (triggerMs <= latest) return triggerMs;
  if (latest > 10000) return latest;
  if (triggerMs < realDurationMs) return triggerMs;
  if (latest > 0) return latest;
  final int beforeEnd = realDurationMs - 1;
  return beforeEnd > 0 ? beforeEnd : triggerMs;
}

/// La posición no avanza con el deck en play (no en pausa ni en buffer).
class PlaybackStallWatch {
  int _anchorMs = -1;
  int _sinceMs = 0;

  void reset() {
    _anchorMs = -1;
    _sinceMs = 0;
  }

  bool stalled({
    required int positionMs,
    required bool playing,
    required bool buffering,
    required int nowMs,
    int needMs = kDurationDisagreeMs,
    int jitterMs = 250,
  }) {
    if (!playing || buffering) {
      reset();
      return false;
    }
    if (_anchorMs < 0 || (positionMs - _anchorMs).abs() > jitterMs) {
      _anchorMs = positionMs;
      _sinceMs = nowMs;
      return false;
    }
    return nowMs - _sinceMs >= needMs;
  }
}
