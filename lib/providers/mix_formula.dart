import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audio_path.dart';
import '../core/phrase_grid.dart' show PhrasePhrase;

/// DNA 60–80 % · Phrase 8 · Stealth (entra 5–10 %, cruza ~60 % sin voz).
/// Prohibido: fade suelto, corte seco, cambio al final de la pista.
enum MixFormula { dnaEnergy, phraseGrid, stealthGap }

final mixFormulaProvider = StateProvider<MixFormula>(
  (ref) => MixFormula.dnaEnergy,
);

int snapPhraseGridMixOut({
  required int durationMs,
  required int dnaMixOutMs,
  required double bpm,
}) {
  if (durationMs <= 0 || dnaMixOutMs <= 0) return dnaMixOutMs;
  if (bpm < 60 || bpm > 200) return dnaMixOutMs;

  final int barMs = ((60000.0 / bpm) * 4).round();
  if (barMs <= 0) return dnaMixOutMs;
  final int phraseMs = barMs * 8;
  final int minMs = (durationMs * 0.60).round();
  final int maxMs = dnaMixOutMs < durationMs ? dnaMixOutMs : durationMs;
  if (maxMs <= minMs) {
    return dnaMixOutMs < durationMs ? dnaMixOutMs : minMs;
  }

  int snapped = (maxMs ~/ phraseMs) * phraseMs;
  if (snapped < minMs) {
    snapped = ((minMs + phraseMs - 1) ~/ phraseMs) * phraseMs;
  }
  if (snapped < minMs || snapped > maxMs || snapped >= durationMs) {
    return dnaMixOutMs < durationMs ? dnaMixOutMs : minMs;
  }
  return snapped;
}

int phraseFadeMs({
  required double incomingBpm,
  required int incomingDurationMs,
}) {
  if (incomingBpm >= 60 && incomingBpm <= 200) {
    final double barMs = (60000.0 / incomingBpm) * 4;
    for (final int bars in const [16, 8]) {
      final int span = (barMs * bars).round();
      if (span >= 8000 && span <= 18000) return span;
    }
  }
  if (incomingDurationMs > 0) {
    return (incomingDurationMs * 0.06).round().clamp(8000, 18000);
  }
  return 12000;
}

/// Entra entre el 5 % y el 10 % de la pista (cuerpo, no intro muerta).
int stealthCueInMs(int durationMs, List<int> lyricMs) {
  if (durationMs <= 0) return 0;
  final int minIn = (durationMs * 0.05).round();
  final int maxIn = (durationMs * 0.10).round();
  if (durationMs < 30000) return minIn.clamp(0, durationMs ~/ 5);
  for (final int t in lyricMs) {
    if (t >= minIn && t <= maxIn) return t;
  }
  return ((minIn + maxIn) ~/ 2).clamp(minIn, maxIn);
}

/// Desde el 60 % busca hacia adelante el hueco instrumental; no corta tajante al 60.
int stealthMixOutMs({
  required int durationMs,
  required List<int> lyricMs,
  required double bpm,
}) {
  if (durationMs <= 0) return 0;
  final int lo = (durationMs * 0.60).round();
  final int hi = (durationMs * 0.80).round();
  if (hi <= lo) return lo.clamp(0, durationMs);

  int bestAt = -1;
  int bestGap = 0;
  for (int i = 0; i < lyricMs.length - 1; i++) {
    final int gapStart = lyricMs[i];
    final int gapEnd = lyricMs[i + 1];
    if (gapEnd <= lo) continue;
    final int overlapLo = max(gapStart, lo);
    final int overlapHi = min(gapEnd, hi);
    final int gap = overlapHi - overlapLo;
    if (gap >= 2500 && gap > bestGap) {
      bestGap = gap;
      bestAt = overlapLo + (gap * 0.25).round();
    }
  }

  int mixOut;
  if (bestGap >= 2500 && bestAt >= lo) {
    mixOut = bestAt;
  } else if (bpm >= 60 && bpm <= 200) {
    final int barMs = ((60000.0 / bpm) * 4).round();
    final int phraseMs = barMs * 8;
    if (phraseMs > 0) {
      mixOut = ((lo + phraseMs - 1) ~/ phraseMs) * phraseMs;
      if (mixOut < lo) mixOut = lo;
    } else {
      mixOut = lo;
    }
  } else {
    mixOut = lo;
  }

  if (mixOut > hi) mixOut = hi;
  if (mixOut >= durationMs) mixOut = hi < durationMs ? hi : lo;
  if (hi < lo) return lo.clamp(0, durationMs);
  return mixOut.clamp(lo, hi);
}

/// Empata BPM si el ratio cabe en ±12 % (mezcla casi imperceptible).
double matchBpmRate(double fadingBpm, double incomingBpm) {
  if (fadingBpm < 60 || incomingBpm < 60) return 1.0;
  final double ratio = fadingBpm / incomingBpm;
  if (ratio >= 0.88 && ratio <= 1.12) return ratio;
  return 1.0;
}

/// Siguiente de la cola por BPM más cercano. No baraja ni sigue el orden.
/// [remaining] = pistas aún no sonadas. -1 si no hay candidata.
int pickStealthNextIndex({
  required List<String> remaining,
  required String? currentPath,
  required double Function(String path) bpmOf,
}) {
  if (remaining.isEmpty) return -1;
  final double currentBpm = currentPath == null ? 0.0 : bpmOf(currentPath);
  int best = -1;
  double bestDiff = double.infinity;
  for (int i = 0; i < remaining.length; i++) {
    if (currentPath != null && sameAudioPath(remaining[i], currentPath)) {
      continue;
    }
    final double b = bpmOf(remaining[i]);
    final double diff = (currentBpm >= 60 && b >= 60)
        ? (currentBpm - b).abs()
        : 10000 + i.toDouble();
    if (diff < bestDiff) {
      bestDiff = diff;
      best = i;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// 3.1.31: ventana activa 60-80 %, entrada adelantada y costuras de seda.
// ---------------------------------------------------------------------------

/// Golpe en ms desde el BPM; 0 si el BPM no es fiable (60-200).
int activeBeatMs(double bpm) {
  if (!bpm.isFinite || bpm < 60 || bpm > 200) return 0;
  return (60000.0 / bpm).round();
}

/// Suelo de la entrada: max(lead, 10 % de D, 8 s si D >= 60 s).
int activeCueMinMs({required int durationMs, int leadMs = 0}) {
  if (durationMs <= 0) return 0;
  final int tenth = (durationMs * 0.10).round();
  final int floor = durationMs >= 60000 ? 8000 : 0;
  final int lead = leadMs < 0 ? 0 : leadMs;
  return max(lead, max(tenth, floor));
}

int _gridUp(int ms, int g0, int step) {
  if (step <= 0) return ms;
  if (ms <= g0) return g0;
  return g0 + ((ms - g0 + step - 1) ~/ step) * step;
}

int _gridDown(int ms, int g0, int step) {
  if (step <= 0) return ms;
  if (ms <= g0) return g0;
  return g0 + ((ms - g0) ~/ step) * step;
}

/// Punto elegido: posicion, origen ('hueco' sin voz, 'frase' con voz del
/// perfil, 'golpe' por rejilla) y voz maxima del tramo (-1 sin perfil).
class ActivePick {
  final int ms;
  final String origin;
  final double voice;

  const ActivePick({required this.ms, required this.origin, this.voice = -1});
}

int _q2(double v) => (v * 100).round();

/// 3.1.32: entre las frases del perfil que empiezan en [lo, hi] elige la de
/// tramo [inicio, inicio + fadeMs] 1) sin voz (ninguna frase vocalOn), 2) con
/// menor voz maxima (`vocal`, a 2 decimales) y 3) mas cercana a [preferMs].
/// Las frases ya son downbeats de frase. null si ninguna cae en la ventana.
ActivePick? activeVocalPick({
  required List<PhrasePhrase> phrases,
  required int lo,
  required int hi,
  required int fadeMs,
  required int preferMs,
}) {
  if (phrases.isEmpty || hi < lo) return null;
  ActivePick? best;
  var bestQuiet = false;
  var bestVoice = 0;
  var bestDist = 0;
  final int span = fadeMs < 0 ? 0 : fadeMs;
  for (var i = 0; i < phrases.length; i++) {
    final int start = phrases[i].startMs;
    if (start < lo || start > hi) continue;
    var quiet = true;
    var voice = 0.0;
    for (var j = i; j < phrases.length; j++) {
      final PhrasePhrase q = phrases[j];
      if (j > i && q.startMs >= start + span) break;
      if (q.vocalOn) quiet = false;
      if (q.vocal > voice) voice = q.vocal;
    }
    final int v = _q2(voice);
    final int dist = (start - preferMs).abs();
    final bool better = best == null ||
        (quiet && !bestQuiet) ||
        (quiet == bestQuiet &&
            (v < bestVoice || (v == bestVoice && dist < bestDist)));
    if (better) {
      best = ActivePick(
        ms: start,
        origin: quiet ? 'hueco' : 'frase',
        voice: voice,
      );
      bestQuiet = quiet;
      bestVoice = v;
      bestDist = dist;
    }
  }
  return best;
}

/// Entrada adelantada: nunca antes de [activeCueMinMs] ni despues del 20 %
/// (salvo un lead mayor). 3.1.32: con perfil de frases ([phrases]) elige la
/// frase con menos voz en [cueMin, cueMax] (tramo de [fadeMs]); sin perfil,
/// [preferMs] (la entrada de la formula) manda si cae dentro y si no se
/// cuantiza hacia arriba a frase, compas o golpe sobre [gridMs] + k * golpe.
/// [bypass] (Mix largo) y D <= 0 devuelven 0; D < 20 s devuelve el lead.
ActivePick activeCuePick({
  required int durationMs,
  int leadMs = 0,
  double bpm = 0,
  int gridMs = 0,
  int? preferMs,
  bool bypass = false,
  List<PhrasePhrase>? phrases,
  int fadeMs = 0,
}) {
  if (bypass || durationMs <= 0) return const ActivePick(ms: 0, origin: 'golpe');
  if (durationMs < 20000) {
    return ActivePick(
      ms: leadMs > 0 && leadMs < durationMs ~/ 3 ? leadMs : 0,
      origin: 'golpe',
    );
  }
  final int cueMin = activeCueMinMs(durationMs: durationMs, leadMs: leadMs);
  final int cueMax = max(cueMin, (durationMs * 0.20).round());
  final int? prefer = preferMs;
  if (phrases != null && phrases.isNotEmpty) {
    final ActivePick? pick = activeVocalPick(
      phrases: phrases,
      lo: cueMin,
      hi: cueMax,
      fadeMs: fadeMs,
      preferMs: prefer ?? cueMin,
    );
    if (pick != null) return pick;
  }
  if (prefer != null && prefer >= cueMin && prefer <= cueMax) {
    return ActivePick(ms: prefer, origin: 'frase');
  }
  final int beat = activeBeatMs(bpm);
  if (beat <= 0) return ActivePick(ms: cueMin, origin: 'golpe');
  final int g0 = gridMs < 0 ? 0 : gridMs;
  for (final int step in <int>[beat * 32, beat * 4, beat]) {
    final int c = _gridUp(cueMin, g0, step);
    if (c >= cueMin && c <= cueMax) {
      return ActivePick(ms: c, origin: step == beat * 32 ? 'frase' : 'golpe');
    }
  }
  return ActivePick(ms: cueMin, origin: 'golpe');
}

/// Atajo: solo la posicion de [activeCuePick].
int activeCueInMs({
  required int durationMs,
  int leadMs = 0,
  double bpm = 0,
  int gridMs = 0,
  int? preferMs,
  bool bypass = false,
  List<PhrasePhrase>? phrases,
  int fadeMs = 0,
}) =>
    activeCuePick(
      durationMs: durationMs,
      leadMs: leadMs,
      bpm: bpm,
      gridMs: gridMs,
      preferMs: preferMs,
      bypass: bypass,
      phrases: phrases,
      fadeMs: fadeMs,
    ).ms;

/// Entrada, salida y fundido de la ventana activa.
class ActiveWindow {
  final int cueInMs;
  final int mixOutMs;
  final int fadeMs;

  /// 'hueco' | 'frase' | 'golpe' (ver [ActivePick]).
  final String origin;

  /// Voz maxima del tramo de salida; -1 sin perfil.
  final double voice;

  const ActiveWindow({
    required this.cueInMs,
    required this.mixOutMs,
    required this.fadeMs,
    this.origin = 'golpe',
    this.voice = -1,
  });
}

/// Tramo minimo reproducido antes de salir (40 % de D).
const double activeMinPlayFraction = 0.40;

/// 3.1.32 (opcion b): salida por POSICION entre el 60 % y el 80 % de D:
/// lo = max(0,60 D, cueIn + 0,40 D), hi = min(0,80 D, D - fade). Con perfil
/// ([phrases]) se elige la frase con menos voz en [lo, hi] (tramo del
/// fundido); sin perfil, el candidato de la formula se recorta a [lo, hi] y
/// se cuantiza hacia abajo a frase, compas o golpe. Si el fundido no cabe se
/// acorta hasta D - lo. [bypass] (Mix largo) y D <= 0 dejan el candidato.
ActiveWindow activeWindow({
  required int durationMs,
  required int cueInMs,
  required int fadeMs,
  required int candidateMs,
  double bpm = 0,
  int gridMs = 0,
  int cueMinMs = 0,
  bool bypass = false,
  List<PhrasePhrase>? phrases,
}) {
  final int wanted = fadeMs < 0 ? 0 : fadeMs;
  if (bypass || durationMs <= 0) {
    return ActiveWindow(
      cueInMs: cueInMs,
      mixOutMs: candidateMs,
      fadeMs: wanted,
    );
  }
  final int d = durationMs;
  final int lo60 = (d * 0.60).round();
  final int hi80 = (d * 0.80).round();
  final int minPlay = (d * activeMinPlayFraction).round();
  var cue = cueInMs < 0 ? 0 : cueInMs;
  if (cue + minPlay > hi80) {
    // Lead enorme: la entrada baja hasta dejar el tramo minimo.
    final int floor = cueMinMs < 0 ? 0 : min(cueMinMs, cue);
    cue = max(floor, hi80 - minPlay);
  }
  final int lo = min(hi80, max(lo60, cue + minPlay));
  var fade = wanted;
  if (d - fade < lo) fade = max(0, d - lo);
  var hi = min(hi80, d - fade);
  if (hi < lo) hi = lo;
  final int cand = candidateMs.clamp(lo, hi);
  var mixOut = cand;
  var origin = 'golpe';
  var voice = -1.0;
  ActivePick? pick;
  if (phrases != null && phrases.isNotEmpty) {
    pick = activeVocalPick(
      phrases: phrases,
      lo: lo,
      hi: hi,
      fadeMs: fade,
      preferMs: cand,
    );
  }
  if (pick != null) {
    mixOut = pick.ms;
    origin = pick.origin;
    voice = pick.voice;
  } else {
    final int beat = activeBeatMs(bpm);
    final int g0 = gridMs < 0 ? 0 : gridMs;
    if (beat > 0) {
      var found = false;
      for (final int step in <int>[beat * 32, beat * 4, beat]) {
        var s = _gridDown(cand, g0, step);
        if (s < lo) s = _gridUp(lo, g0, step);
        if (s >= lo && s <= hi) {
          mixOut = s;
          origin = step == beat * 32 ? 'frase' : 'golpe';
          found = true;
          break;
        }
      }
      if (!found) {
        // Ventana mas angosta que un golpe: primer golpe desde lo; el
        // fundido se acorta para no pasar del final.
        final int s = _gridUp(lo, g0, beat);
        if (s <= hi80 && s + min(wanted, 2000) <= d) mixOut = s;
      }
    }
  }
  if (mixOut + fade > d) fade = max(0, d - mixOut);
  return ActiveWindow(
    cueInMs: cue,
    mixOutMs: mixOut,
    fadeMs: fade,
    origin: origin,
    voice: voice,
  );
}

/// Atajo: solo el punto de salida de [activeWindow].
int activeMixOutMs({
  required int durationMs,
  required int cueInMs,
  required int fadeMs,
  required int candidateMs,
  double bpm = 0,
  int gridMs = 0,
  int cueMinMs = 0,
  bool bypass = false,
  List<PhrasePhrase>? phrases,
}) =>
    activeWindow(
      durationMs: durationMs,
      cueInMs: cueInMs,
      fadeMs: fadeMs,
      candidateMs: candidateMs,
      bpm: bpm,
      gridMs: gridMs,
      cueMinMs: cueMinMs,
      bypass: bypass,
      phrases: phrases,
    ).mixOutMs;

/// 3.1.32 (Automix): lleva la entrada al golpe de la rejilla de la entrante
/// (primer golpe [beatMs], tempo [bpm]). Set In manual: golpe mas cercano
/// (nunca mas de medio golpe). Automatica: golpe siguiente (ceil). Sin BPM
/// fiable devuelve [cueMs] tal cual.
int snapCueToBeat({
  required int cueMs,
  required double beatMs,
  required double bpm,
  required bool manual,
}) {
  if (!bpm.isFinite || bpm <= 0 || !beatMs.isFinite) return cueMs;
  final double p = 60000.0 / bpm;
  final double k = (cueMs - beatMs) / p;
  final double kk = manual ? k.roundToDouble() : k.ceilToDouble();
  var s = (beatMs + kk * p).round();
  while (s < 0) {
    s = (s + p).round();
  }
  return s;
}

/// Avance del cruce 0..1 con pendiente 0 en los dos extremos.
/// [edge] 0: smoothstep 3p^2 - 2p^3. 0 < [edge] < 0,5: rampas coseno de ancho
/// [edge] y meseta 1/(1-edge) (con edge 0,25 el centro es mas tendido que
/// smoothstep: pendiente 1,33 frente a 1,5). Simetrica: s(1-p) = 1 - s(p).
double seamProgress(double p, {double edge = 0}) {
  final double x = p.isNaN ? 0.0 : p.clamp(0.0, 1.0).toDouble();
  if (edge <= 0 || edge >= 0.5) return x * x * (3 - 2 * x);
  final double c = 1 / (1 - edge);
  if (x > 1 - edge) return 1 - seamProgress(1 - x, edge: edge);
  if (x < edge) return c * (x / 2 - edge / (2 * pi) * sin(pi * x / edge));
  return c * (x - edge / 2);
}

/// Ganancia (amplitud) de potencia constante: entrante seamGain(p), saliente
/// seamGain(1 - p) = cos(pi/2 * s). gIn^2 + gOut^2 = 1: sin bulto al centro.
double seamGain(double p, {double edge = 0}) =>
    sin(pi / 2 * seamProgress(p, edge: edge));

/// Volumen de mpv (0-100) para la amplitud [g]: mpv aplica (vol/100)^3, asi
/// que vol = 100 * g^(1/3). 0 exacto con g <= 0 y 100 con g >= 1.
double seamVolume(double g) {
  if (g.isNaN || g <= 0) return 0.0;
  if (g >= 1) return 100.0;
  return 100.0 * pow(g, 1 / 3).toDouble();
}

/// Caracter de cada tipo de mezcla de Live DJ.
class MixPersonality {
  final MixFormula formula;
  final int beats;
  final int fadeMs;

  /// Fraccion del cruce donde se hace el unico swap de graves/EQ.
  final double swapAt;

  /// Cuantizacion del swap: 1 golpe (Corta) o 4 (compas).
  final int swapQuantumBeats;

  /// Forma de la curva ([seamProgress]).
  final double edge;
  final String label;

  const MixPersonality({
    required this.formula,
    required this.beats,
    required this.fadeMs,
    required this.swapAt,
    required this.swapQuantumBeats,
    required this.edge,
    required this.label,
  });

  /// Punto del swap (ms desde el inicio del cruce), al golpe o compas mas
  /// cercano a [swapAt], sin tocar el primer ni el ultimo cuanto.
  int swapMs({required int fadeMs, double bpm = 0}) {
    if (fadeMs <= 0) return 0;
    final int target = (fadeMs * swapAt).round();
    final int q = activeBeatMs(bpm) * swapQuantumBeats;
    if (q <= 0 || fadeMs <= 2 * q) return target;
    final int s = ((target + q ~/ 2) ~/ q) * q;
    return s.clamp(q, fadeMs - q);
  }
}

/// Corta/Punch (stealthGap): 8 golpes, swap en el golpe 5.
/// Clasica/Club (dnaEnergy): 16 golpes con voz, 32 sin voz, swap al 50 %.
/// Larga/Blend (phraseGrid): 32 con voz, 64 sin voz (tope 40 s), curva mas
/// tendida y swap al 62,5 % (5/8). Sin BPM fiable: 4 / 8-16 / 16-32 s.
MixPersonality mixPersonality(
  MixFormula formula,
  double bpm, {
  required bool vocal,
}) {
  final int beat = activeBeatMs(bpm);
  switch (formula) {
    case MixFormula.stealthGap:
      return MixPersonality(
        formula: formula,
        beats: 8,
        fadeMs: beat > 0 ? max(2000, beat * 8) : 4000,
        swapAt: 0.5,
        swapQuantumBeats: 1,
        edge: 0,
        label: 'Corta',
      );
    case MixFormula.dnaEnergy:
      final int beats = vocal ? 16 : 32;
      return MixPersonality(
        formula: formula,
        beats: beats,
        fadeMs: beat > 0 ? beat * beats : (vocal ? 8000 : 16000),
        swapAt: 0.5,
        swapQuantumBeats: 4,
        edge: 0,
        label: 'Clasica',
      );
    case MixFormula.phraseGrid:
      final int beats = vocal ? 32 : 64;
      return MixPersonality(
        formula: formula,
        beats: beats,
        fadeMs: beat > 0 ? min(40000, beat * beats) : (vocal ? 16000 : 32000),
        swapAt: 0.625,
        swapQuantumBeats: 4,
        edge: 0.25,
        label: 'Larga',
      );
  }
}
