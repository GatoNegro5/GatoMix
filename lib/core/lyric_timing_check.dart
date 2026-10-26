// Chequeo de tiempo de la letra contra el audio (Masterizar, 1.0.9+23).
// Lógica pura: sin I/O, igual en Windows, Android, macOS e iPhone.
import 'lrc_timeline.dart';

enum LyricTimingIssue {
  none,
  endsEarly,
  pastEnd,
  startsLate,
  startsBeforeVoice,
}

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
  static const double endsEarlyRatio =
      0.70; // último verso < 70 % de la canción
  static const int endsEarlyGapMs = 45000; // y faltan > 45 s
  static const int pastEndMs = 2000; // último verso > duración + 2 s
  static const double startsLateRatio =
      0.40; // primer verso > 40 % de la canción
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
      final String text = (m.group(4) ?? '')
          .replaceAll(RegExp(r'\[[^\]]*\]'), '')
          .trim();
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
    return const LyricTimingVerdict(
      LyricTimingIssue.none,
      null,
      null,
      'sin sellos',
    );
  }
  final int? first = firstVerseMs(lrc);
  final int? last = lastVerseMs(lrc);
  if (first == null || last == null) {
    return const LyricTimingVerdict(
      LyricTimingIssue.none,
      null,
      null,
      'sin sellos',
    );
  }
  String s(int ms) =>
      '${ms ~/ 60000}:${((ms % 60000) ~/ 1000).toString().padLeft(2, '0')}';
  if (last > durationMs + LyricTimingRules.pastEndMs) {
    return LyricTimingVerdict(
      LyricTimingIssue.pastEnd,
      first,
      last,
      'la letra sigue en ${s(last)} y la canción dura ${s(durationMs)}',
    );
  }
  if (last < durationMs * LyricTimingRules.endsEarlyRatio &&
      durationMs - last > LyricTimingRules.endsEarlyGapMs) {
    return LyricTimingVerdict(
      LyricTimingIssue.endsEarly,
      first,
      last,
      'la letra termina en ${s(last)} de ${s(durationMs)}',
    );
  }
  if (first > durationMs * LyricTimingRules.startsLateRatio &&
      first > LyricTimingRules.startsLateMinMs) {
    return LyricTimingVerdict(
      LyricTimingIssue.startsLate,
      first,
      last,
      'la letra empieza recién en ${s(first)}',
    );
  }
  if (voiceOnsetMs != null &&
      first < LyricTimingRules.earlyFirstMs &&
      voiceOnsetMs > LyricTimingRules.voiceIntroMs) {
    return LyricTimingVerdict(
      LyricTimingIssue.startsBeforeVoice,
      first,
      last,
      'la letra arranca en ${s(first)} pero la voz entra en ${s(voiceOnsetMs)}',
    );
  }
  return LyricTimingVerdict(LyricTimingIssue.none, first, last, 'ok');
}

/// Mínimo desfase (ms) que vale la pena corregir moviendo toda la letra.
const int kLyricRealignMinMs = 1000;

/// Mueve TODOS los sellos de la letra para que el primer verso caiga en
/// [voiceOnsetMs]. Solo si la letra queda bien según [checkLyricTiming];
/// si no, null. Nunca toca una letra manual. La marca `[gmx_shift:]` se
/// conserva tal cual (es el recorte del audio, no este ajuste).
String? realignLrcToVoice({
  required String lrc,
  required int durationMs,
  required int? voiceOnsetMs,
}) {
  if (voiceOnsetMs == null || voiceOnsetMs < 0) return null;
  if (lrcIsManual(lrc) || lrcIsPlain(lrc)) return null;
  final int? first = firstVerseMs(lrc);
  if (first == null) return null;
  final int delta = voiceOnsetMs - first;
  if (delta.abs() < kLyricRealignMinMs) return null;
  final RegExp stamp = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{2,3})\]');
  final String moved = lrc.replaceAllMapped(stamp, (Match m) {
    final String f = m.group(3)!;
    final int frac = f.length == 2 ? int.parse(f) * 10 : int.parse(f);
    int ms =
        (int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!)) * 1000 +
        frac +
        delta;
    if (ms < 0) ms = 0;
    final int cs = (ms % 1000) ~/ 10;
    return '[${(ms ~/ 60000).toString().padLeft(2, '0')}:'
        '${((ms % 60000) ~/ 1000).toString().padLeft(2, '0')}.'
        '${cs.toString().padLeft(2, '0')}]';
  });
  final LyricTimingVerdict v = checkLyricTiming(
    lrc: moved,
    durationMs: durationMs,
    voiceOnsetMs: voiceOnsetMs,
  );
  return v.ok ? moved : null;
}

/// Primer candidato (en orden) que, con el recorte [trimMs] aplicado, pasa
/// el chequeo y es distinto de [current]. Null si ninguno sirve.
String? firstPassingLyric({
  required List<String> candidates,
  required String current,
  required int trimMs,
  required int durationMs,
  int? voiceOnsetMs,
}) {
  for (final String raw in candidates) {
    if (raw.trim().isEmpty || lrcIsPlain(raw)) continue;
    final String fresh = trimMs > 0 ? shiftLrcText(raw, trimMs).text : raw;
    if (fresh.trim() == current.trim()) continue;
    final LyricTimingVerdict v = checkLyricTiming(
      lrc: fresh,
      durationMs: durationMs,
      voiceOnsetMs: voiceOnsetMs,
    );
    if (v.ok) return fresh;
  }
  return null;
}

/// Motivo de GMX_LYR_CHECK=SKIP, o null si el chequeo debe correr.
/// Megamix (GMX_LYR=NA), sin `.lrc` (NONE / RETRY sin archivo) o letra plana.
String? lyricCheckSkipReason({
  required bool mega,
  required bool lrcExists,
  required bool plain,
}) {
  if (mega) return 'megamix';
  if (!lrcExists) return 'sin_lrc';
  if (plain) return 'plain';
  return null;
}

/// Etapa 2 (1.0.12+26): motivo honesto cuando ningún rescate de letra sirvió.
/// Va en `GMX_RESCUE_LYR=FAIL:motivo`. No inventa tiempos: solo clasifica.
/// endsEarly / pastEnd / startsLate = la letra es de OTRA versión (radio edit
/// contra extended/remix DJ): mover la letra entera no lo arregla.
String lyricRescueFailReason(LyricTimingVerdict v, {required int durationMs}) {
  final int a = (durationMs / 1000).round();
  final int f = ((v.firstMs ?? 0) / 1000).round();
  final int l = ((v.lastMs ?? 0) / 1000).round();
  switch (v.issue) {
    case LyricTimingIssue.endsEarly:
    case LyricTimingIssue.pastEnd:
    case LyricTimingIssue.startsLate:
      return 'FAIL:lyric_version_mismatch,audio=${a}s,lrc=$f-${l}s';
    case LyricTimingIssue.startsBeforeVoice:
      return 'FAIL:lyric_before_voice,lrc_start=${f}s';
    case LyricTimingIssue.none:
      return '';
  }
}

/// 1.0.18: al recortar silencio inicial, toda letra sincronizada que no sea
/// manual se desplaza los mismos ms (con `.lrc.bak`).
bool shouldShiftLrcOnTrim(String lrc) =>
    RegExp(r'\[\d{1,3}:\d{2}\.\d{2,3}\]').hasMatch(lrc) &&
    !lrcIsManual(lrc) &&
    !lrcIsPlain(lrc);
