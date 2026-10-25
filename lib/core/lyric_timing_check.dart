// Chequeo de tiempo de la letra contra el audio (Masterizar, 1.0.9+23).
// Lógica pura: sin I/O, igual en Windows, Android, macOS e iPhone.
import 'lrc_timeline.dart';

enum LyricTimingIssue { none, endsEarly, pastEnd, startsLate, startsBeforeVoice }

class LyricTimingVerdict {
  final LyricTimingIssue issue;
  final int? firstMs;
  final int? lastMs;
  final String reason;
  const LyricTimingVerdict(this.issue, this.firstMs, this.lastMs, this.reason);
  bool get ok => issue == LyricTimingIssue.none;
}

/// Umbrales (ms). Pensados para outros largos (bachata, salsa) sin falsos
/// avisos: "termina antes" exige las DOS condiciones.
class LyricTimingRules {
  static const double endsEarlyRatio = 0.70; // último verso < 70 % de la canción
  static const int endsEarlyGapMs = 45000; // y faltan > 45 s
  static const int pastEndMs = 2000; // último verso > duración + 2 s
  static const double startsLateRatio = 0.40; // primer verso > 40 % de la canción
  static const int startsLateMinMs = 45000; // y > 45 s
  static const int earlyFirstMs = 3000; // letra arranca en < 3 s
  static const int voiceIntroMs = 8000; // pero la voz aparece > 8 s
}

/// Último sello con texto real (ignora sellos vacíos y marcas gmx).
int? lastVerseMs(String content) {
  final RegExp lineRe = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{2,3})\](.*)');
  int? last;
  for (final String line in content.split('\n')) {
    if (line.contains('[gmx_')) continue;
    for (final Match m in lineRe.allMatches(line)) {
      final String text = (m.group(4) ?? '').replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
      if (text.length < 2) continue;
      final int min = int.parse(m.group(1)!);
      final int sec = int.parse(m.group(2)!);
      final String f = m.group(3)!;
      final int frac = f.length == 2 ? int.parse(f) * 10 : int.parse(f);
      final int ms = (min * 60 + sec) * 1000 + frac;
      if (last == null || ms > last) last = ms;
    }
  }
  return last;
}

/// [voiceOnsetMs]: inicio de voz medido en el audio (null si no se pudo).
LyricTimingVerdict checkLyricTiming({
  required String lrc,
  required int durationMs,
  int? voiceOnsetMs,
}) {
  if (lrcIsPlain(lrc) || durationMs <= 0) {
    return const LyricTimingVerdict(LyricTimingIssue.none, null, null, 'sin sellos');
  }
  final int? first = firstVerseMs(lrc);
  final int? last = lastVerseMs(lrc);
  if (first == null || last == null) {
    return const LyricTimingVerdict(LyricTimingIssue.none, null, null, 'sin sellos');
  }
  String s(int ms) => '${ms ~/ 60000}:${((ms % 60000) ~/ 1000).toString().padLeft(2, '0')}';
  if (last > durationMs + LyricTimingRules.pastEndMs) {
    return LyricTimingVerdict(LyricTimingIssue.pastEnd, first, last,
        'la letra sigue en ${s(last)} y la canción dura ${s(durationMs)}');
  }
  if (last < durationMs * LyricTimingRules.endsEarlyRatio &&
      durationMs - last > LyricTimingRules.endsEarlyGapMs) {
    return LyricTimingVerdict(LyricTimingIssue.endsEarly, first, last,
        'la letra termina en ${s(last)} de ${s(durationMs)}');
  }
  if (first > durationMs * LyricTimingRules.startsLateRatio &&
      first > LyricTimingRules.startsLateMinMs) {
    return LyricTimingVerdict(LyricTimingIssue.startsLate, first, last,
        'la letra empieza recién en ${s(first)}');
  }
  if (voiceOnsetMs != null &&
      first < LyricTimingRules.earlyFirstMs &&
      voiceOnsetMs > LyricTimingRules.voiceIntroMs) {
    return LyricTimingVerdict(LyricTimingIssue.startsBeforeVoice, first, last,
        'la letra arranca en ${s(first)} pero la voz entra en ${s(voiceOnsetMs)}');
  }
  return LyricTimingVerdict(LyricTimingIssue.none, first, last, 'ok');
}
