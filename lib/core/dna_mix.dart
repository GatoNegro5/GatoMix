import 'livedj_order.dart';
import 'phrase_grid.dart';

/// Cómo cruza DNA. El nombre en la UI no cambia.
enum DnaKind {
  /// Sin perfil: porcentajes por género, cue de 10 s, fundido de 18 s.
  legacy,
  longBlend,
  shortBlend,
  echoOut,
  filterSweep,
  /// (c) sin eco ni ecualizador en este libmpv: fundido de volumen, sin tempo.
  blendFallback,
}

class DnaDecision {
  final DnaKind kind;
  final int mixOutMs;
  final int cueInMs;
  final int fadeMs;
  final bool lockTempo;
  final bool bassSwap;

  /// Un golpe de la saliente. 0 si no hay eco.
  final int echoDelayMs;
  final double echoFeedback;

  /// De dónde salió el punto: outro, hueco o frase.
  final String mixSource;

  const DnaDecision({
    required this.kind,
    required this.mixOutMs,
    required this.cueInMs,
    required this.fadeMs,
    required this.lockTempo,
    required this.bassSwap,
    required this.echoDelayMs,
    required this.echoFeedback,
    this.mixSource = '',
  });

  bool get legacy => kind == DnaKind.legacy;
}

/// DNA de un par saliente → entrante. No toca Phrase 8 ni Stealth.
///
/// (a) BPM ±12 %, Camelot compatible (o tonalidad desconocida) y sin voz en
/// el outro y la intro: 16 compases, bass swap y corte de agudos.
/// (b) Compatible, con voz cerca: 8 compases y las frases vocales no coinciden.
/// (c) BPM fuera de ±12 % o tonalidades incompatibles: eco al beat o barrido
/// pasa-altos. El tempo igual se encuentra en el punto medio. Si el libmpv no
/// tiene esos filtros, [DnaKind.blendFallback].
DnaDecision decideDna({
  required int outDurationMs,
  required int inDurationMs,
  required int genreMixOutMs,
  required int fallbackCueMs,
  required double outBpm,
  required double inBpm,
  double outRate = 1,
  String? outKey,
  String? inKey,
  PhraseTrack? outgoing,
  PhraseTrack? incoming,
  required bool echoSupported,
  required bool eqSupported,
  bool exitLocked = false,
}) {
  if (outgoing == null && incoming == null) {
    final int lo = (outDurationMs * 0.60).round();
    final int hi = (outDurationMs * 0.80).round();
    var m = _clampWindow(genreMixOutMs, lo, hi);
    var f = 18000;
    if (outDurationMs > 0 && m + f > outDurationMs && outDurationMs - f >= lo) {
      final int pulled = outDurationMs - f;
      m = pulled > hi ? hi : pulled;
    }
    if (outDurationMs > 0 && m + f > outDurationMs) {
      f = outDurationMs - m;
      if (f < 0) f = 0;
    }
    return DnaDecision(
      kind: DnaKind.legacy,
      mixOutMs: m,
      cueInMs: fallbackCueMs,
      fadeMs: f,
      lockTempo: true,
      bassSwap: true,
      echoDelayMs: 0,
      echoFeedback: 0,
      mixSource: 'frase',
    );
  }

  final int winLo = (outDurationMs * 0.60).round();
  final int winHi = (outDurationMs * 0.80).round();
  var source = 'frase';
  var mixOut = _clampWindow(genreMixOutMs, winLo, winHi);
  if (!exitLocked && outgoing != null) {
    if (_outroFits(outgoing.outroMs, outDurationMs)) {
      mixOut = outgoing.outroMs;
      source = 'outro';
    } else {
      final int? quiet = _nearestQuiet(outgoing, mixOut, winLo, winHi);
      if (quiet != null) {
        mixOut = quiet;
        source = 'hueco';
      } else {
        final int? phrase = _nearestDownbeat(outgoing, mixOut, winLo, winHi);
        if (phrase != null) mixOut = phrase;
      }
    }
  }

  final double entryBpm = inBpm >= 60 && inBpm <= 200
      ? inBpm
      : (incoming?.bpm ?? 0);
  var cue = fallbackCueMs;
  if (incoming != null && inDurationMs > 30000 && entryBpm >= 60) {
    final int? snapped = _entryPoint(incoming, entryBpm, inDurationMs);
    if (snapped != null) cue = snapped;
  }

  final bool voice = _hasVoice(outgoing, mixOut) || _hasVoice(incoming, cue);
  if (outgoing != null && incoming != null) {
    if (_phraseVocal(outgoing, mixOut) && _phraseVocal(incoming, cue)) {
      final int? movedIn = _nearestQuiet(
        incoming,
        cue,
        0,
        (inDurationMs * 0.45).round(),
      );
      if (movedIn != null && movedIn != cue) cue = movedIn;
    }
  }

  final bool tempo = _bpmClose(outBpm, inBpm, outRate);
  final bool clash = _keysClash(outKey, inKey);
  final double sounded = tempo
      ? phraseSoundingBpm(
          incomingBpm: entryBpm >= 60 ? entryBpm : inBpm,
          incomingRate: _matchRate(outBpm, inBpm, outRate),
        )
      : (entryBpm >= 60 ? entryBpm : inBpm);

  DnaDecision seal({
    required DnaKind kind,
    required int cueIn,
    required int fade,
    required bool lock,
    required bool bass,
    required int echoDelay,
    required double echoFb,
  }) {
    var m = mixOut;
    var f = fade < 0 ? 0 : fade;
    if (!exitLocked && outDurationMs > 0 && winHi >= winLo) {
      if (m < winLo) m = winLo;
      if (m > winHi) m = winHi;
      if (m + f > outDurationMs && outDurationMs - f >= winLo) {
        final int pulled = outDurationMs - f;
        m = pulled > winHi ? winHi : pulled;
      }
    }
    if (outDurationMs > 0 && m + f > outDurationMs) {
      f = outDurationMs - m;
      if (f < 0) f = 0;
    }
    return DnaDecision(
      kind: kind,
      mixOutMs: m,
      cueInMs: cueIn,
      fadeMs: f,
      lockTempo: lock,
      bassSwap: bass,
      echoDelayMs: echoDelay,
      echoFeedback: echoFb,
      mixSource: source,
    );
  }

  if (!tempo || clash) {
    final int delay = _beatMs(outBpm >= 60 ? outBpm : inBpm);
    if (echoSupported) {
      return seal(
        kind: DnaKind.echoOut,
        cueIn: cue,
        fade: _bars(outBpm >= 60 ? outBpm : sounded, 8),
        lock: false,
        bass: false,
        echoDelay: delay,
        echoFb: 0.45,
      );
    }
    if (eqSupported) {
      return seal(
        kind: DnaKind.filterSweep,
        cueIn: cue,
        fade: _bars(outBpm >= 60 ? outBpm : sounded, 8),
        lock: false,
        bass: false,
        echoDelay: 0,
        echoFb: 0,
      );
    }
    return seal(
      kind: DnaKind.blendFallback,
      cueIn: cue,
      fade: _bars(sounded, voice ? 8 : 16),
      lock: false,
      bass: false,
      echoDelay: 0,
      echoFb: 0,
    );
  }

  if (!voice) {
    return seal(
      kind: DnaKind.longBlend,
      cueIn: cue,
      fade: _bars(sounded, 16),
      lock: true,
      bass: true,
      echoDelay: 0,
      echoFb: 0,
    );
  }
  return seal(
    kind: DnaKind.shortBlend,
    cueIn: cue,
    fade: _bars(sounded, 8),
    lock: true,
    bass: false,
    echoDelay: 0,
    echoFb: 0,
  );
}

int _clampWindow(int ms, int lo, int hi) {
  if (hi < lo) return ms;
  if (ms < lo) return lo;
  if (ms > hi) return hi;
  return ms;
}

bool _outroFits(int outroMs, int durationMs) {
  if (outroMs < 0 || durationMs <= 0) return false;
  final int lo = (durationMs * 0.60).round();
  final int hi = (durationMs * 0.80).round();
  return outroMs >= lo && outroMs <= hi;
}

bool _bpmClose(double outBpm, double inBpm, double outRate) {
  if (outBpm < 60 || inBpm < 60) return false;
  final double rate = outRate > 0 ? outRate : 1;
  final double ratio = (outBpm * rate) / inBpm;
  return ratio >= 0.88 && ratio <= 1.12;
}

double _matchRate(double outBpm, double inBpm, double outRate) {
  if (!_bpmClose(outBpm, inBpm, outRate)) return 1;
  final double rate = outRate > 0 ? outRate : 1;
  return (outBpm * rate) / inBpm;
}

/// Chocan solo si las dos tonalidades se conocen y no son compatibles.
bool _keysClash(String? a, String? b) {
  if (a == null || b == null) return false;
  final String aa = a.trim();
  final String bb = b.trim();
  if (aa.isEmpty || bb.isEmpty) return false;
  return !camelotCompatible(aa, bb);
}

bool _phraseVocal(PhraseTrack? track, int ms) {
  final PhrasePhrase? p = track?.phraseAt(ms);
  if (p == null) return false;
  return p.vocalOn;
}

/// Sin perfil, o con una frase vocal: hay voz cerca (no se hace el blend largo).
bool _hasVoice(PhraseTrack? track, int ms) {
  if (track == null) return true;
  return _phraseVocal(track, ms);
}

int? _entryPoint(PhraseTrack track, double bpm, int durationMs) {
  var anchor = track.beatMs < 0 ? 0 : track.beatMs;
  final int intro = track.introEndMs;
  if (intro >= 0 && intro <= (durationMs * 0.45).round()) {
    anchor = intro;
  } else if (track.phrases.isNotEmpty && anchor <= track.phrases.first.startMs) {
    anchor = track.phrases.first.startMs;
  }
  final int phraseMs = ((60000.0 / bpm) * 4).round() * 8;
  if (phraseMs <= 0) return null;
  final int beat = track.beatMs;
  final int start = anchor <= beat
      ? beat
      : beat + ((anchor - beat + phraseMs - 1) ~/ phraseMs) * phraseMs;
  final int cap = (durationMs * 0.45).round();
  if (start < 0 || start > cap || start >= durationMs) return null;
  return start;
}

int? _nearestQuiet(PhraseTrack track, int fromMs, int lo, int hi) {
  if (hi < lo) return null;
  int? best;
  var bestDist = 1 << 62;
  for (final PhrasePhrase p in track.phrases) {
    if (p.startMs < lo || p.startMs > hi || p.vocalOn) continue;
    final int d = (p.startMs - fromMs).abs();
    if (best == null || d < bestDist || (d == bestDist && p.startMs < best)) {
      bestDist = d;
      best = p.startMs;
    }
  }
  return best;
}

int? _nearestDownbeat(PhraseTrack track, int fromMs, int lo, int hi) {
  if (hi < lo) return null;
  int? best;
  var bestDist = 1 << 62;
  for (final PhrasePhrase p in track.phrases) {
    if (p.startMs < lo || p.startMs > hi) continue;
    final int d = (p.startMs - fromMs).abs();
    if (best == null || d < bestDist || (d == bestDist && p.startMs < best)) {
      bestDist = d;
      best = p.startMs;
    }
  }
  return best;
}

/// Punto de género ya dentro del 60–80 % de la duración efectiva.
int dnaPercentPoint(int effectiveMs, double fraction) {
  if (effectiveMs <= 0) return 0;
  final int lo = (effectiveMs * 0.60).round();
  final int hi = (effectiveMs * 0.80).round();
  return _clampWindow((effectiveMs * fraction).round(), lo, hi);
}

int _bars(double bpm, int bars) {
  if (bpm >= 60 && bpm <= 200) {
    final int span = ((60000.0 / bpm) * 4).round() * bars;
    if (span > 0) return span.clamp(8000, 18000);
  }
  return bars >= 16 ? 18000 : 8000;
}

int _beatMs(double bpm) {
  if (bpm < 60 || bpm > 200) return 500;
  return (60000.0 / bpm).round().clamp(250, 1000);
}

/// Corte de agudos con `equalizer` (el filtro que sí trae el libmpv).
const String dnaHighShelfCut =
    'equalizer=f=6500:width_type=o:w=1.2:g=-12,equalizer=f=10000:width_type=o:w=1:g=-8';

/// Pasa-altos aproximado: dos pasos, no un `af` nuevo en cada tick.
const String dnaHighpassMild =
    'equalizer=f=90:width_type=o:w=2.2:g=-18,equalizer=f=220:width_type=o:w=1.6:g=-10';

const String dnaHighpassHard =
    'equalizer=f=90:width_type=o:w=2.2:g=-26,equalizer=f=240:width_type=o:w=1.8:g=-16,equalizer=f=480:width_type=o:w=1.2:g=-8';

String dnaEchoChain(int delayMs, double feedback) {
  final int delay = delayMs.clamp(20, 2000);
  final String fb = feedback.clamp(0.05, 0.85).toStringAsFixed(2);
  return 'aecho=0.8:0.88:$delay:$fb';
}
