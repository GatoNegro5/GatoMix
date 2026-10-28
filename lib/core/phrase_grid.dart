import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:io';

import 'audio_path.dart';
import 'gatomix_store.dart';

/// Sección de `.gatomix.json` con el perfil de Phrase 8.
/// No vive dentro de `djMetadata`: ese mapa solo guarda BPM y tonalidad.
const String phraseGridSection = 'phraseGrid';

/// Voz si la banda 300 Hz–3,4 kHz pesa al menos esto y el RMS no es silencio.
const double phraseVocalMinRatio = 0.35;
const double phraseVocalMinRms = 0.02;

/// Una frase es «baja» si su RMS no pasa de esta fracción del cuerpo.
const double phraseEnergyDrop = 0.55;

const int phraseFadeMinMs = 8000;
const int phraseFadeMaxMs = 18000;

/// Una frase de 8 compases (4/4) sobre el beatgrid.
class PhrasePhrase {
  final int startMs;
  final double rms;
  final double vocal;

  const PhrasePhrase({
    required this.startMs,
    required this.rms,
    required this.vocal,
  });

  bool get vocalOn => vocal >= phraseVocalMinRatio && rms >= phraseVocalMinRms;
}

/// Perfil de una pista. Se calcula una vez y se lee de memoria.
class PhraseTrack {
  final double bpm;
  final int beatMs;
  final int durationMs;
  final int outroMs;
  final int introEndMs;
  final double bodyRms;
  final List<PhrasePhrase> phrases;

  const PhraseTrack({
    required this.bpm,
    required this.beatMs,
    required this.durationMs,
    required this.outroMs,
    required this.introEndMs,
    required this.bodyRms,
    required this.phrases,
  });

  bool hitsDownbeat(int ms) {
    for (final PhrasePhrase p in phrases) {
      if ((p.startMs - ms).abs() <= 30) return true;
    }
    return false;
  }

  /// Frase que contiene [ms] (la última que ya empezó).
  PhrasePhrase? phraseAt(int ms) {
    PhrasePhrase? best;
    for (final PhrasePhrase p in phrases) {
      if (p.startMs <= ms) {
        best = p;
      } else {
        break;
      }
    }
    return best;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'bpm': bpm,
    'beat': beatMs,
    'dur': durationMs,
    'outro': outroMs,
    'intro': introEndMs,
    'body': bodyRms,
    'p': <List<num>>[
      for (final PhrasePhrase p in phrases)
        <num>[p.startMs, _round(p.rms), _round(p.vocal)],
    ],
  };

  static PhraseTrack? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final double bpm = (raw['bpm'] as num?)?.toDouble() ?? 0;
    final List<PhrasePhrase> phrases = <PhrasePhrase>[];
    final Object? rows = raw['p'];
    if (rows is List) {
      for (final Object? row in rows) {
        if (row is! List || row.length < 3) continue;
        final int? start = row[0] is num ? (row[0] as num).round() : null;
        final double? rms = row[1] is num ? (row[1] as num).toDouble() : null;
        final double? vocal = row[2] is num
            ? (row[2] as num).toDouble()
            : null;
        if (start == null || rms == null || vocal == null) continue;
        phrases.add(PhrasePhrase(startMs: start, rms: rms, vocal: vocal));
      }
    }
    if (bpm < 60 || phrases.isEmpty) return null;
    phrases.sort((PhrasePhrase a, PhrasePhrase b) => a.startMs - b.startMs);
    return PhraseTrack(
      bpm: bpm,
      beatMs: (raw['beat'] as num?)?.round() ?? 0,
      durationMs: (raw['dur'] as num?)?.round() ?? 0,
      outroMs: (raw['outro'] as num?)?.round() ?? -1,
      introEndMs: (raw['intro'] as num?)?.round() ?? -1,
      bodyRms: (raw['body'] as num?)?.toDouble() ?? 0,
      phrases: phrases,
    );
  }
}

double _round(double v) => (v * 10000).round() / 10000;

/// BPM con el que suena la entrante: el suyo, o el común ya igualado.
double phraseSoundingBpm({
  required double incomingBpm,
  required double incomingRate,
}) {
  if (incomingBpm < 60 || incomingBpm > 200) return incomingBpm;
  if (incomingRate >= 0.88 && incomingRate <= 1.12) {
    final double sounded = incomingBpm * incomingRate;
    if (sounded >= 60 && sounded <= 200) return sounded;
  }
  return incomingBpm;
}

/// 16 compases si el cruce es instrumental; 8 si hay voz. Siempre 8–18 s.
int phraseGridFadeMs({
  required double bpm,
  required bool instrumental,
  required int durationMs,
}) {
  if (bpm >= 60 && bpm <= 200) {
    final int barMs = ((60000.0 / bpm) * 4).round();
    final int span = barMs * (instrumental ? 16 : 8);
    if (span > 0) return span.clamp(phraseFadeMinMs, phraseFadeMaxMs);
  }
  if (durationMs > 0) {
    return (durationMs * 0.06).round().clamp(phraseFadeMinMs, phraseFadeMaxMs);
  }
  return 12000;
}

/// Las dos frases del cruce son instrumentales (banda vocal baja).
bool phraseCrossIsInstrumental({
  required PhraseTrack? outgoing,
  required PhraseTrack? incoming,
  required int outMs,
  required int inMs,
}) {
  if (outgoing == null || incoming == null) return false;
  final PhrasePhrase? a = outgoing.phraseAt(outMs);
  final PhrasePhrase? b = incoming.phraseAt(inMs);
  if (a == null || b == null) return false;
  return !a.vocalOn && !b.vocalOn;
}

class PhrasePlan {
  final int mixOutMs;
  final int cueInMs;
  final int fadeMs;
  final bool energyExit;
  final bool phraseEntry;
  final bool instrumental;

  const PhrasePlan({
    required this.mixOutMs,
    required this.cueInMs,
    required this.fadeMs,
    required this.energyExit,
    required this.phraseEntry,
    required this.instrumental,
  });
}

/// Punto de salida, entrada y duración de Phrase 8.
///
/// Sin perfil, o con el outro fuera de 60 %..(fin−8 s), [mixOutMs] es
/// [fallbackMixOutMs] (el DNA ya ajustado a 8 compases). La entrada, si hay
/// perfil, es el primer downbeat de frase en o después de ~10 s o del fin
/// de la intro. [lockExit] deja la salida quieta (el cruce ya se disparó)
/// y solo mueve la entrada para no juntar dos frases vocales.
PhrasePlan planPhrase8({
  required int outDurationMs,
  required int inDurationMs,
  required int fallbackMixOutMs,
  required int fallbackCueMs,
  required double incomingBpm,
  required double incomingRate,
  PhraseTrack? outgoing,
  PhraseTrack? incoming,
  bool lockExit = false,
}) {
  final int mixLo = outDurationMs <= 0 ? 0 : (outDurationMs * 0.60).round();
  final int mixHi = outDurationMs - phraseFadeMinMs;
  var mixOut = fallbackMixOutMs;
  var energyExit = false;
  if (!lockExit &&
      outgoing != null &&
      outgoing.outroMs >= mixLo &&
      mixHi > mixLo &&
      outgoing.outroMs <= mixHi) {
    mixOut = outgoing.outroMs;
    energyExit = true;
  }

  final double inBpm = incomingBpm >= 60 && incomingBpm <= 200
      ? incomingBpm
      : (incoming?.bpm ?? 0);
  final int cueDur = inDurationMs > 0
      ? inDurationMs
      : (incoming?.durationMs ?? 0);
  var cue = fallbackCueMs;
  var phraseEntry = false;
  if (incoming != null && inBpm >= 60 && inBpm <= 200 && cueDur > 30000) {
    final int snapped = _entryDownbeat(
      track: incoming,
      bpm: inBpm,
      durationMs: cueDur,
      fallbackCueMs: fallbackCueMs,
    );
    if (snapped >= 0) {
      cue = snapped;
      phraseEntry = true;
    }
  }

  if (outgoing != null && incoming != null) {
    final PhrasePhrase? outPhrase = outgoing.phraseAt(mixOut);
    final PhrasePhrase? inPhrase = incoming.phraseAt(cue);
    if (outPhrase != null &&
        inPhrase != null &&
        outPhrase.vocalOn &&
        inPhrase.vocalOn) {
      if (!lockExit && mixHi > mixLo) {
        final int? moved = _nearestNonVocal(
          outgoing,
          mixOut,
          mixLo,
          mixHi,
        );
        if (moved != null && moved != mixOut) {
          mixOut = moved;
          energyExit = outgoing.outroMs == moved;
        }
      }
      final PhrasePhrase? after = outgoing.phraseAt(mixOut);
      if (after != null && after.vocalOn) {
        final int cueHi = cueDur > 0
            ? math.min((cueDur * 0.45).round(), cueDur - phraseFadeMinMs)
            : 90000;
        final int? movedIn = _nearestNonVocal(incoming, cue, 8000, cueHi);
        if (movedIn != null && movedIn != cue) {
          cue = movedIn;
          phraseEntry = true;
        }
      }
    }
  }

  final bool instrumental = phraseCrossIsInstrumental(
    outgoing: outgoing,
    incoming: incoming,
    outMs: mixOut,
    inMs: cue,
  );
  final double sounded = phraseSoundingBpm(
    incomingBpm: inBpm >= 60 ? inBpm : incomingBpm,
    incomingRate: incomingRate,
  );
  return PhrasePlan(
    mixOutMs: mixOut,
    cueInMs: cue,
    fadeMs: phraseGridFadeMs(
      bpm: sounded,
      instrumental: instrumental,
      durationMs: inDurationMs > 0 ? inDurationMs : cueDur,
    ),
    energyExit: energyExit,
    phraseEntry: phraseEntry,
    instrumental: instrumental,
  );
}

int _entryDownbeat({
  required PhraseTrack track,
  required double bpm,
  required int durationMs,
  required int fallbackCueMs,
}) {
  var anchor = fallbackCueMs;
  if (durationMs > 30000 && anchor < 10000) anchor = 10000;
  final int intro = track.introEndMs;
  if (intro >= 8000 && intro <= (durationMs * 0.40).round() && intro > anchor) {
    anchor = intro;
  }
  final int snapped = _snapUp(anchor, track.beatMs, bpm);
  final int cap = (durationMs * 0.45).round();
  if (snapped < 8000 || snapped > cap || snapped >= durationMs - phraseFadeMinMs) {
    return -1;
  }
  return snapped;
}

int _snapUp(int anchorMs, int beatMs, double bpm) {
  final int phraseMs = ((60000.0 / bpm) * 4).round() * 8;
  if (phraseMs <= 0) return anchorMs;
  if (anchorMs <= beatMs) return beatMs;
  final int k = ((anchorMs - beatMs) + phraseMs - 1) ~/ phraseMs;
  return beatMs + k * phraseMs;
}

int? _nearestNonVocal(PhraseTrack track, int fromMs, int lo, int hi) {
  if (hi < lo) return null;
  int? best;
  var bestDist = 1 << 62;
  for (final PhrasePhrase p in track.phrases) {
    if (p.startMs < lo || p.startMs > hi) continue;
    if (p.vocalOn) continue;
    final int d = (p.startMs - fromMs).abs();
    if (best == null || d < bestDist || (d == bestDist && p.startMs < best)) {
      bestDist = d;
      best = p.startMs;
    }
  }
  return best;
}

/// RMS y banda vocal por frase. Puro: sirve en un isolate y en los tests.
PhraseTrack? analyzePhraseSamples({
  required Float32List samples,
  required int sampleRate,
  required double bpm,
  int beatMs = 0,
}) {
  if (sampleRate < 8000 || bpm < 60 || bpm > 200 || samples.isEmpty) {
    return null;
  }
  final int durationMs = (samples.length * 1000 / sampleRate).round();
  final int phraseMs = ((60000.0 / bpm) * 4).round() * 8;
  if (phraseMs < 1000 || durationMs < phraseMs) return null;

  final List<PhrasePhrase> phrases = <PhrasePhrase>[];
  for (var start = beatMs; start < durationMs; start += phraseMs) {
    if (start < 0) continue;
    final int end = math.min(start + phraseMs, durationMs);
    if (end - start < phraseMs ~/ 2) break;
    final int i0 = (start * sampleRate / 1000).round().clamp(0, samples.length);
    final int i1 = (end * sampleRate / 1000).round().clamp(i0, samples.length);
    if (i1 <= i0) break;
    final _Rms band = _phraseRms(samples, i0, i1, sampleRate);
    phrases.add(
      PhrasePhrase(startMs: start, rms: band.rms, vocal: band.vocal),
    );
  }
  if (phrases.isEmpty) return null;

  final List<double> body = <double>[
    for (final PhrasePhrase p in phrases)
      if (p.startMs >= durationMs * 0.15 && p.startMs < durationMs * 0.60) p.rms,
  ];
  final double bodyRms = _median(body.isEmpty ? phrases.map((p) => p.rms).toList() : body);
  final double lowLine = bodyRms * phraseEnergyDrop;

  var outro = -1;
  if (bodyRms > 0) {
    for (var i = 0; i < phrases.length; i++) {
      if (phrases[i].startMs < durationMs / 2) continue;
      if (phrases[i].rms > lowLine) continue;
      final bool sustained =
          i + 1 >= phrases.length || phrases[i + 1].rms <= lowLine;
      if (!sustained) continue;
      outro = phrases[i].startMs;
      break;
    }
  }

  var intro = -1;
  if (bodyRms > 0) {
    var sawLow = false;
    for (final PhrasePhrase p in phrases) {
      if (p.rms <= lowLine) {
        sawLow = true;
        continue;
      }
      if (sawLow && p.startMs <= (durationMs * 0.40).round()) intro = p.startMs;
      break;
    }
  }

  return PhraseTrack(
    bpm: bpm,
    beatMs: beatMs,
    durationMs: durationMs,
    outroMs: outro,
    introEndMs: intro,
    bodyRms: bodyRms,
    phrases: phrases,
  );
}

/// PCM s16le (lo que devuelve `decode_mono_pcm`) → perfil.
PhraseTrack? analyzePhrasePcm({
  required Uint8List pcm,
  required int sampleRate,
  required double bpm,
  int beatMs = 0,
}) {
  final int n = pcm.length ~/ 2;
  if (n <= 0) return null;
  final Float32List samples = Float32List(n);
  final ByteData data = ByteData.sublistView(pcm);
  for (var i = 0; i < n; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return analyzePhraseSamples(
    samples: samples,
    sampleRate: sampleRate,
    bpm: bpm,
    beatMs: beatMs,
  );
}

class _Rms {
  final double rms;
  final double vocal;
  const _Rms(this.rms, this.vocal);
}

_Rms _phraseRms(Float32List samples, int i0, int i1, int rate) {
  final _Biquad hp = _Biquad.highpass(300, rate.toDouble());
  final _Biquad lp = _Biquad.lowpass(3400, rate.toDouble());
  var sum = 0.0;
  var sumF = 0.0;
  final int n = i1 - i0;
  for (var i = i0; i < i1; i++) {
    final double x = samples[i];
    sum += x * x;
    final double y = lp.tick(hp.tick(x));
    sumF += y * y;
  }
  if (n <= 0 || sum < 1e-12) return const _Rms(0, 0);
  final double rms = math.sqrt(sum / n);
  final double rmsF = math.sqrt(sumF / n);
  return _Rms(rms, rms <= 1e-8 ? 0 : rmsF / rms);
}

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  final List<double> xs = List<double>.of(values)..sort();
  final int n = xs.length;
  if (n.isOdd) return xs[n ~/ 2];
  return (xs[n ~/ 2 - 1] + xs[n ~/ 2]) / 2;
}

/// Biquad RBJ. Pasa-altos y pasa-bajos de Butterworth (Q = 1/√2).
class _Biquad {
  final double b0;
  final double b1;
  final double b2;
  final double a1;
  final double a2;
  double x1 = 0;
  double x2 = 0;
  double y1 = 0;
  double y2 = 0;

  _Biquad._(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory _Biquad.highpass(double fc, double fs) {
    final _Coef c = _Coef(fc, fs);
    final double b0 = (1 + c.cosw) / 2 / c.a0;
    final double b1 = -(1 + c.cosw) / c.a0;
    final double b2 = (1 + c.cosw) / 2 / c.a0;
    return _Biquad._(b0, b1, b2, c.a1, c.a2);
  }

  factory _Biquad.lowpass(double fc, double fs) {
    final _Coef c = _Coef(fc, fs);
    final double b0 = (1 - c.cosw) / 2 / c.a0;
    final double b1 = (1 - c.cosw) / c.a0;
    final double b2 = (1 - c.cosw) / 2 / c.a0;
    return _Biquad._(b0, b1, b2, c.a1, c.a2);
  }

  double tick(double x0) {
    final double y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = x0;
    y2 = y1;
    y1 = y0;
    return y0;
  }
}

class _Coef {
  final double cosw;
  final double a0;
  final double a1;
  final double a2;

  _Coef(double fc, double fs)
    : cosw = math.cos(2 * math.pi * fc / fs),
      a0 = 1 + math.sin(2 * math.pi * fc / fs) / (2 * math.sqrt1_2),
      a1 =
          -2 *
          math.cos(2 * math.pi * fc / fs) /
          (1 + math.sin(2 * math.pi * fc / fs) / (2 * math.sqrt1_2)),
      a2 =
          (1 - math.sin(2 * math.pi * fc / fs) / (2 * math.sqrt1_2)) /
          (1 + math.sin(2 * math.pi * fc / fs) / (2 * math.sqrt1_2));
}

/// Perfiles en memoria. [peek] no abre el JSON: el tick solo lee esto.
class PhraseGridMemory {
  static final Map<String, PhraseTrack> _tracks = <String, PhraseTrack>{};
  static final Set<String> _gaveUp = <String>{};
  static final Set<String> _absorbed = <String>{};

  static PhraseTrack? peek(String? path) {
    if (path == null || path.isEmpty) return null;
    return _tracks[audioPathKey(path)];
  }

  static int stamp(String? path) {
    final PhraseTrack? t = peek(path);
    if (t == null) return 0;
    var h = t.outroMs ^ (t.introEndMs << 1) ^ t.phrases.length;
    for (final PhrasePhrase p in t.phrases) {
      h = (h * 33) ^ p.startMs ^ (p.vocal * 1000).round();
    }
    return h;
  }

  static bool gaveUp(String? path) =>
      path != null && path.isNotEmpty && _gaveUp.contains(audioPathKey(path));

  static void giveUp(String path) {
    if (path.isEmpty) return;
    _gaveUp.add(audioPathKey(path));
  }

  /// Lee la sección una vez (el documento queda en la caché del store).
  static void absorbDir(String dir) {
    if (dir.isEmpty || !_absorbed.add(dir)) return;
    final Map<String, dynamic> map = GatomixStore.readMap(dir, phraseGridSection);
    for (final MapEntry<String, dynamic> e in map.entries) {
      final PhraseTrack? t = PhraseTrack.fromJson(e.value);
      if (t == null) continue;
      _tracks[audioPathKey(e.key)] = t;
      _gaveUp.remove(audioPathKey(e.key));
    }
  }

  static void save(String path, PhraseTrack track) {
    if (path.isEmpty) return;
    final String dir = File(path).parent.path;
    final Map<String, dynamic> map = GatomixStore.readMap(dir, phraseGridSection);
    final String want = audioPathKey(path);
    String? previous;
    for (final String k in map.keys) {
      if (audioPathKey(k) == want) {
        previous = k;
        break;
      }
    }
    if (previous != null && previous != path) map.remove(previous);
    map[path] = track.toJson();
    GatomixStore.writeMap(dir, phraseGridSection, map);
    _tracks[want] = track;
    _gaveUp.remove(want);
    _absorbed.add(dir);
  }

  static void debugReset() {
    _tracks.clear();
    _gaveUp.clear();
    _absorbed.clear();
  }
}
