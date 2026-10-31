import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audio_path.dart';

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
