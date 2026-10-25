// Alineación de letra contra palabras con tiempo (1.0.13+27).
// Lógica pura, igual en las 4 plataformas. Las palabras vienen de un
// transcriptor offline (solo escritorio, ver tool/gmx_whisper_words.py) en un
// archivo `<canción>.gmx_words.json`. Si no hay palabras, no se hace nada.
// Regla honesta: nunca inventa tiempos. Cada verso movido queda anclado a
// palabras oídas en el audio o hereda el desfase de su bloque anclado.
import 'dart:convert';
import 'dart:math' as math;

import 'lrc_timeline.dart';
import 'lyric_timing_check.dart';

class TimedWord {
  final int startMs;
  final String text;
  const TimedWord(this.startMs, this.text);
}

/// Lee `{dur, words:[[start,end,word],...]}` (segundos).
List<TimedWord> parseTimedWordsJson(String json) {
  final dynamic d = jsonDecode(json);
  final List<dynamic> ws = (d is Map ? d['words'] : d) as List<dynamic>;
  return <TimedWord>[
    for (final dynamic w in ws)
      TimedWord(((w[0] as num) * 1000).round(), '${w[2]}'),
  ];
}

class _Line {
  final int ms;
  final String text;
  _Line(this.ms, this.text);
}

final RegExp _stampRe = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{2,3})\]');

List<_Line> _lines(String lrc) {
  final List<_Line> out = <_Line>[];
  for (final String line in lrc.split('\n')) {
    if (line.contains('[gmx_')) continue;
    final String txt = line.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
    if (txt.length < 2) continue;
    for (final Match m in _stampRe.allMatches(line)) {
      out.add(_Line(_ms(m), txt));
    }
  }
  out.sort((a, b) => a.ms.compareTo(b.ms));
  return out;
}

int _ms(Match m) {
  final String f = m.group(3)!;
  final int frac = f.length == 2 ? int.parse(f) * 10 : int.parse(f);
  return (int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!)) * 1000 + frac;
}

String _stamp(int ms) {
  if (ms < 0) ms = 0;
  return '[${(ms ~/ 60000).toString().padLeft(2, '0')}:'
      '${((ms % 60000) ~/ 1000).toString().padLeft(2, '0')}.'
      '${((ms % 1000) ~/ 10).toString().padLeft(2, '0')}]';
}

List<String> _norm(String s) => s
    .toLowerCase()
    .replaceAll("'", '')
    .replaceAll(RegExp(r"[^a-z0-9áéíóúñü ]"), ' ')
    .split(' ')
    .where((String w) => w.isNotEmpty)
    .toList();

double _sim(String a, String b) {
  if (a == b) return 1.0;
  if (a.length < 3 || b.length < 3) return 0.0;
  // Levenshtein normalizado.
  final List<int> prev = List<int>.generate(b.length + 1, (i) => i);
  for (int i = 1; i <= a.length; i++) {
    int diag = prev[0];
    prev[0] = i;
    for (int j = 1; j <= b.length; j++) {
      final int tmp = prev[j];
      prev[j] = math.min(
        math.min(prev[j] + 1, prev[j - 1] + 1),
        diag + (a[i - 1] == b[j - 1] ? 0 : 1),
      );
      diag = tmp;
    }
  }
  final double r = 1 - prev[b.length] / math.max(a.length, b.length);
  return r >= 0.75 ? r : 0.0;
}

/// Umbrales. Validados contra 26 casos REVIEW reales (ver CHANGELOG 1.0.13).
class LyricAiRules {
  static const int minWords = 60; // transcripción mínima para opinar
  static const double wrongSongCov = 0.25; // menos = otra canción
  static const double minCov = 0.45; // para mover algo
  static const double minAnchoredRatio = 0.5;
  static const int constSpreadMs = 3000; // desfase constante
  static const int blockTolMs = 2500; // versos del mismo bloque
  static const int minBlockAnchors = 2;
  static const int minShiftMs = 300;
}

enum LyricAiKind { none, constantShift, segments, wrongSong, unsure }

class LyricAiResult {
  final LyricAiKind kind;
  final String? lrc; // letra nueva si constantShift / segments
  final double coverage;
  final int anchored;
  final int lines;
  final int medianOffsetMs;
  final int spreadMs;
  final String reason;
  const LyricAiResult(
    this.kind,
    this.lrc,
    this.coverage,
    this.anchored,
    this.lines,
    this.medianOffsetMs,
    this.spreadMs,
    this.reason,
  );
  String get failReason => switch (kind) {
    LyricAiKind.wrongSong =>
      'FAIL:lyric_wrong_song,cov=${coverage.toStringAsFixed(2)}',
    LyricAiKind.unsure => 'FAIL:lyric_ai_unsure,$reason',
    _ => '',
  };
}

/// Desfase (ms, audio − letra) por verso anclado (≥ 50 % de sus palabras).
({double cov, Map<int, int> offs}) _align(
  List<_Line> lines,
  List<TimedWord> words,
) {
  final List<String> lt = <String>[];
  final List<int> own = <int>[];
  for (int i = 0; i < lines.length; i++) {
    for (final String w in _norm(lines[i].text)) {
      lt.add(w);
      own.add(i);
    }
  }
  final List<String> wt = <String>[
    for (final TimedWord w in words)
      (_norm(w.text).isEmpty ? '' : _norm(w.text).first),
  ];
  final int n = lt.length, m = wt.length;
  const double gapL = -0.3, gapW = -0.05;
  final List<Float64List2> s = List<Float64List2>.generate(
    n + 1,
    (_) => Float64List2(m + 1),
  );
  final List<List<int>> bk = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
  );
  for (int i = 1; i <= n; i++) {
    s[i].v[0] = i * gapL;
    bk[i][0] = 1;
  }
  for (int j = 1; j <= m; j++) {
    bk[0][j] = 2;
  }
  for (int i = 1; i <= n; i++) {
    for (int j = 1; j <= m; j++) {
      final double q = _sim(lt[i - 1], wt[j - 1]);
      final double d = s[i - 1].v[j - 1] + (q > 0 ? 2 * q - 0.5 : -1.0);
      final double u = s[i - 1].v[j] + gapL;
      final double l = s[i].v[j - 1] + gapW;
      if (d >= u && d >= l) {
        s[i].v[j] = d;
      } else if (u >= l) {
        s[i].v[j] = u;
        bk[i][j] = 1;
      } else {
        s[i].v[j] = l;
        bk[i][j] = 2;
      }
    }
  }
  final Map<int, int> match = <int, int>{};
  int i = n, j = m;
  while (i > 0 || j > 0) {
    final int b = bk[i][j];
    if (i > 0 && j > 0 && b == 0) {
      if (_sim(lt[i - 1], wt[j - 1]) > 0) match[i - 1] = j - 1;
      i--;
      j--;
    } else if (i > 0 && (j == 0 || b == 1)) {
      i--;
    } else {
      j--;
    }
  }
  final List<int> cnt = List<int>.filled(lines.length, 0);
  final List<int> tot = List<int>.filled(lines.length, 0);
  final Map<int, int> first = <int, int>{};
  for (int k = 0; k < n; k++) {
    tot[own[k]]++;
    if (match.containsKey(k)) {
      cnt[own[k]]++;
      first.putIfAbsent(own[k], () => words[match[k]!].startMs);
    }
  }
  final Map<int, int> offs = <int, int>{};
  for (int l = 0; l < lines.length; l++) {
    if (tot[l] > 0 && cnt[l] / tot[l] >= 0.5 && first.containsKey(l)) {
      offs[l] = first[l]! - lines[l].ms;
    }
  }
  return (cov: n == 0 ? 0.0 : match.length / n, offs: offs);
}

class Float64List2 {
  final List<double> v;
  Float64List2(int n) : v = List<double>.filled(n, 0);
}

int _median(List<int> xs) {
  final List<int> s = List<int>.from(xs)..sort();
  return s.isEmpty ? 0 : s[s.length ~/ 2];
}

int _spread(List<int> xs) {
  if (xs.length < 2) return 0;
  final double mu = xs.reduce((a, b) => a + b) / xs.length;
  final double v =
      xs.map((x) => (x - mu) * (x - mu)).reduce((a, b) => a + b) / xs.length;
  return math.sqrt(v).round();
}

/// Reescribe cada sello con el desfase de su verso. [lineOffset] por índice
/// de verso ordenado.
String _apply(String lrc, List<_Line> lines, List<int> lineOffset) {
  // Mapa sello original+texto → nuevo. Recorre en el mismo orden que _lines.
  final Map<String, List<int>> queue = <String, List<int>>{};
  for (int i = 0; i < lines.length; i++) {
    queue
        .putIfAbsent('${lines[i].ms}|${lines[i].text}', () => <int>[])
        .add(lines[i].ms + lineOffset[i]);
  }
  final StringBuffer out = StringBuffer();
  final List<String> rows = lrc.split('\n');
  for (int r = 0; r < rows.length; r++) {
    final String line = rows[r];
    final String txt = line.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
    String next = line;
    if (!line.contains('[gmx_') && txt.length >= 2) {
      next = line.replaceAllMapped(_stampRe, (Match m) {
        final List<int>? q = queue['${_ms(m)}|$txt'];
        if (q == null || q.isEmpty) return m.group(0)!;
        return _stamp(q.removeAt(0));
      });
    }
    out.write(next);
    if (r < rows.length - 1) out.write('\n');
  }
  return out.toString();
}

/// Decide qué hacer con una letra en REVIEW teniendo palabras con tiempo.
LyricAiResult alignLyricToWords({
  required String lrc,
  required List<TimedWord> words,
  required int durationMs,
}) {
  LyricAiResult r(
    LyricAiKind k,
    String why, {
    String? out,
    double cov = 0,
    int a = 0,
    int n = 0,
    int med = 0,
    int sp = 0,
  }) => LyricAiResult(k, out, cov, a, n, med, sp, why);
  if (lrcIsManual(lrc) || lrcIsPlain(lrc)) {
    return r(LyricAiKind.none, 'manual_o_plana');
  }
  final List<_Line> lines = _lines(lrc);
  if (lines.length < 4) return r(LyricAiKind.none, 'pocos_versos');
  if (words.length < LyricAiRules.minWords) {
    return r(LyricAiKind.unsure, 'pocas_palabras=${words.length}');
  }
  final a = _align(lines, words);
  final List<int> idx = a.offs.keys.toList()..sort();
  final List<int> offs = [for (final int i in idx) a.offs[i]!];
  final int med = _median(offs);
  final int sp = _spread(offs);
  final int n = lines.length;
  LyricAiResult rr(LyricAiKind k, String why, [String? out]) =>
      r(k, why, out: out, cov: a.cov, a: idx.length, n: n, med: med, sp: sp);
  if (a.cov < LyricAiRules.wrongSongCov) {
    return rr(LyricAiKind.wrongSong, 'cov=${a.cov.toStringAsFixed(2)}');
  }
  if (a.cov < LyricAiRules.minCov ||
      idx.length < n * LyricAiRules.minAnchoredRatio) {
    return rr(
      LyricAiKind.unsure,
      'cov=${a.cov.toStringAsFixed(2)},anclados=${idx.length}/$n',
    );
  }
  // "Termina antes" no es error si la IA confirma los versos que SÍ hay
  // (outro instrumental o coros repetidos que la letra no trae). Lo demás
  // (pasa del final, empieza tarde) sigue bloqueando.
  String? passes(String moved) {
    final LyricTimingVerdict v = checkLyricTiming(
      lrc: moved,
      durationMs: durationMs,
    );
    return v.ok || v.issue == LyricTimingIssue.endsEarly ? moved : null;
  }

  // A) Desfase constante confirmado por la IA.
  if (sp <= LyricAiRules.constSpreadMs) {
    if (med.abs() < LyricAiRules.minShiftMs) {
      return rr(LyricAiKind.none, 'ya_alineada');
    }
    final String? out = passes(_apply(lrc, lines, List<int>.filled(n, med)));
    return out == null
        ? rr(LyricAiKind.unsure, 'shift_no_pasa_chequeo')
        : rr(LyricAiKind.constantShift, 'shift=${med}ms', out);
  }
  // B) Bloques: versos anclados consecutivos con desfase parecido.
  final List<List<int>> blocks = <List<int>>[];
  for (final int i in idx) {
    if (blocks.isNotEmpty) {
      final List<int> b = blocks.last;
      final int bm = _median([for (final int k in b) a.offs[k]!]);
      if ((a.offs[i]! - bm).abs() <= LyricAiRules.blockTolMs) {
        b.add(i);
        continue;
      }
    }
    blocks.add(<int>[i]);
  }
  // Anclas sueltas (bloque de 1) se descartan como ruido; si son muchas, no.
  final List<List<int>> good = blocks
      .where((b) => b.length >= LyricAiRules.minBlockAnchors)
      .toList();
  final int kept = good.fold(0, (s, b) => s + b.length);
  if (good.isEmpty || kept < n * LyricAiRules.minAnchoredRatio) {
    return rr(LyricAiKind.unsure, 'bloques_inconsistentes,anclados=$kept/$n');
  }
  // Cada verso hereda el desfase del bloque bueno más cercano ANTES (o el
  // primero, si está antes de todos). Los versos entre bloques quedan con el
  // bloque anterior: cubren la misma sección que ya estaba anclada.
  final List<int> blockOff = [
    for (final b in good) _median([for (final int k in b) a.offs[k]!]),
  ];
  final List<int> lineOff = List<int>.filled(n, blockOff.first);
  for (int i = 0; i < n; i++) {
    for (int g = 0; g < good.length; g++) {
      if (good[g].first <= i) lineOff[i] = blockOff[g];
    }
  }
  // Monótono: ningún verso puede quedar antes del anterior.
  for (int i = 1; i < n; i++) {
    if (lines[i].ms + lineOff[i] < lines[i - 1].ms + lineOff[i - 1]) {
      return rr(LyricAiKind.unsure, 'orden_roto_verso_$i');
    }
  }
  final String? out = passes(_apply(lrc, lines, lineOff));
  return out == null
      ? rr(LyricAiKind.unsure, 'segmentos_no_pasan_chequeo')
      : rr(LyricAiKind.segments, 'bloques=${good.length}', out);
}
