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

  const DnaDecision({
    required this.kind,
    required this.mixOutMs,
    required this.cueInMs,
    required this.fadeMs,
    required this.lockTempo,
    required this.bassSwap,
    required this.echoDelayMs,
    required this.echoFeedback,
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
    return DnaDecision(
      kind: DnaKind.legacy,
      mixOutMs: genreMixOutMs,
      cueInMs: fallbackCueMs,
      fadeMs: 18000,
      lockTempo: true,
      bassSwap: true,
      echoDelayMs: 0,
      echoFeedback: 0,
    );
  }

  var mixOut = genreMixOutMs;
  if (!exitLocked &&
      outgoing != null &&
      _outroFits(outgoing.outroMs, outDurationMs)) {
    mixOut = outgoing.outroMs;
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
    if (!exitLocked && _phraseVocal(outgoing, mixOut) && _phraseVocal(incoming, cue)) {
      final int? moved = _nearestQuiet(
        outgoing,
        mixOut,
        (outDurationMs * 0.50).round(),
        outDurationMs,
      );
      if (moved != null && moved != mixOut) mixOut = moved;
    }
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

  if (!tempo || clash) {
    final int delay = _beatMs(outBpm >= 60 ? outBpm : inBpm);
    if (echoSupported) {
      return DnaDecision(
        kind: DnaKind.echoOut,
        mixOutMs: mixOut,
        cueInMs: cue,
        fadeMs: _bars(outBpm >= 60 ? outBpm : sounded, 8),
        lockTempo: false,
        bassSwap: false,
        echoDelayMs: delay,
        echoFeedback: 0.45,
      );
    }
    if (eqSupported) {
      return DnaDecision(
        kind: DnaKind.filterSweep,
        mixOutMs: mixOut,
        cueInMs: cue,
        fadeMs: _bars(outBpm >= 60 ? outBpm : sounded, 8),
        lockTempo: false,
        bassSwap: false,
        echoDelayMs: 0,
        echoFeedback: 0,
      );
    }
    return DnaDecision(
      kind: DnaKind.blendFallback,
      mixOutMs: mixOut,
      cueInMs: cue,
      fadeMs: _bars(sounded, voice ? 8 : 16),
      lockTempo: false,
      bassSwap: false,
      echoDelayMs: 0,
      echoFeedback: 0,
    );
  }

  if (!voice) {
    return DnaDecision(
      kind: DnaKind.longBlend,
      mixOutMs: mixOut,
      cueInMs: cue,
      fadeMs: _bars(sounded, 16),
      lockTempo: true,
      bassSwap: true,
      echoDelayMs: 0,
      echoFeedback: 0,
    );
  }
  return DnaDecision(
    kind: DnaKind.shortBlend,
    mixOutMs: mixOut,
    cueInMs: cue,
    fadeMs: _bars(sounded, 8),
    lockTempo: true,
    bassSwap: false,
    echoDelayMs: 0,
    echoFeedback: 0,
  );
}

bool _outroFits(int outroMs, int durationMs) {
  if (outroMs < 0 || durationMs <= 0) return false;
  final int floor = (durationMs * 0.50).round();
  return outroMs >= floor && outroMs < durationMs;
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
