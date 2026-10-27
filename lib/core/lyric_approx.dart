// Letra aproximada (1.0.20+37): versiones DJ (Intro/Clean/Edit/Mashup) cuya
// duración no calza ±2 s con ninguna letra de LRCLIB. Se guarda la letra de
// estudio más cercana, alineada a la entrada de voz, con la marca
// [gmx_approx] y GMX_LYR=APPROX. Automix la muestra con un aviso y, al
// guardar el ajuste del usuario, pasa a MANUAL.
import 'lyric_match.dart';

const String kLyricApproxMark = '[gmx_approx]';
const String kLyrApprox = 'APPROX';

bool lrcIsApprox(String content) =>
    content.trimLeft().toLowerCase().startsWith(kLyricApproxMark);

final RegExp _stamp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]');

int _ms(Match m) {
  final String f = m.group(3) ?? '0';
  final int frac = f.length == 1
      ? int.parse(f) * 100
      : f.length == 2
      ? int.parse(f) * 10
      : int.parse(f);
  return int.parse(m.group(1)!) * 60000 + int.parse(m.group(2)!) * 1000 + frac;
}

String _fmt(int ms) {
  final int t = ms < 0 ? 0 : ms;
  final String mm = (t ~/ 60000).toString().padLeft(2, '0');
  final String ss = ((t % 60000) ~/ 1000).toString().padLeft(2, '0');
  final String cc = ((t % 1000) ~/ 10).toString().padLeft(2, '0');
  return '[$mm:$ss.$cc]';
}

/// Primer verso con texto, en ms. Null si no hay sellos.
int? approxFirstVerseMs(String synced) {
  for (final String line in synced.split('\n')) {
    final Match? m = _stamp.firstMatch(line);
    if (m == null) continue;
    if (line.substring(m.end).trim().isEmpty) continue;
    return _ms(m);
  }
  return null;
}

/// Letra de estudio desplazada para que el primer verso caiga en la entrada
/// de voz ([voiceOnsetMs]); sin onset no se mueve. Lleva la marca arriba.
String buildApproxLrc(String synced, {int? voiceOnsetMs}) {
  final String body = synced.replaceAll('\r\n', '\n').trim();
  final int? first = approxFirstVerseMs(body);
  final int delta = (voiceOnsetMs == null || first == null)
      ? 0
      : voiceOnsetMs - first;
  final String moved = delta == 0
      ? body
      : body.replaceAllMapped(_stamp, (Match m) => _fmt(_ms(m) + delta));
  return '$kLyricApproxMark\n$moved\n';
}

/// Título y artista limpios para buscar la letra de estudio. En un mashup
/// sin artista («X Vs. Y» en el nombre) el artista es el primero.
({String artist, String title}) approxQuery({
  required String artist,
  required String title,
  required String fileStem,
}) {
  var a = artist.trim();
  if (a.isEmpty) {
    final List<String> p = fileStem.split(RegExp(r'\s+-\s+'));
    a = p.length > 1 ? p.first : fileStem;
  }
  a = lyricPrimaryArtist(lyricStripYearSuffix(a));
  final String t = lyricCleanTitle(lyricStripYearSuffix(title));
  return (artist: a, title: t);
}

bool _titleFits(String want, String got) {
  final String w = lyricNormLoose(want);
  final String g = lyricNormLoose(lyricCleanTitle(got));
  if (w.isEmpty || g.isEmpty) return false;
  if (lyricTitleScore(want, got) >= kLyricTitleStrong) return true;
  // «Should Be Dancing» ⊂ «You Should Be Dancing».
  return w.length >= 8 && (' $g ').contains(' $w ');
}

/// La letra sincronizada de estudio más cercana en duración: mismo artista,
/// título que encaja, sin Karaoke/Live/Cover que el audio no pidió. Null si
/// nada es razonable.
Map<String, dynamic>? pickApproxRow(
  List<Map<String, dynamic>> rows, {
  required String artist,
  required String title,
  required int durationSec,
}) {
  Map<String, dynamic>? best;
  var bestGap = 1 << 30;
  for (final Map<String, dynamic> r in rows) {
    final String synced = (r['syncedLyrics'] ?? '').toString();
    if (synced.trim().isEmpty || r['instrumental'] == true) continue;
    final String ra = (r['artistName'] ?? '').toString();
    final String rt = (r['trackName'] ?? '').toString();
    if (artist.isNotEmpty && !lyricArtistsMatch(artist, ra)) continue;
    if (!_titleFits(title, rt)) continue;
    if (lyricEditionPenalty(title, rt) > 0) continue;
    final num d = (r['duration'] is num) ? r['duration'] as num : 0;
    final int gap = (d.round() - durationSec).abs();
    if (gap < bestGap) {
      bestGap = gap;
      best = r;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// 1.0.20+38: la marca viaja con el `.lrc` (laptop, celular, copia manual).

final RegExp _kTwin = RegExp(r'_K(\.[A-Za-z0-9]+)$', caseSensitive: false);

/// Audio dueño de la letra: el `_K` comparte la de la canción normal.
String approxOwnerAudio(String audioPath) =>
    audioPath.replaceFirstMapped(_kTwin, (Match m) => m.group(1)!);

/// `.lrc` que corresponde a [audioPath] (también para `_K`).
String approxLrcPath(String audioPath) {
  final String owner = approxOwnerAudio(audioPath);
  final int dot = owner.lastIndexOf('.');
  final int sep = owner.lastIndexOf(RegExp(r'[\\/]'));
  return (dot > sep ? owner.substring(0, dot) : owner) + '.lrc';
}

/// Texto confirmado: sin la línea de marca, el resto intacto.
String stripApproxMark(String content) {
  if (!lrcIsApprox(content)) return content;
  final String t = content.trimLeft();
  final int nl = t.indexOf('\n');
  return nl < 0 ? '' : t.substring(nl + 1);
}

/// ¿Debe [incoming] reemplazar a [existing] en la sincronización?
/// - Un confirmado nunca vuelve a aproximado.
/// - Un confirmado siempre reemplaza a un aproximado.
/// - En los demás casos decide [overwrite] (la opción del usuario).
bool lrcSyncShouldReplace({
  required String? existing,
  required String incoming,
  required bool overwrite,
}) {
  if (existing == null) return true;
  final bool inApprox = lrcIsApprox(incoming);
  final bool exApprox = lrcIsApprox(existing);
  if (inApprox && !exApprox) return false;
  if (!inApprox && exApprox) return true;
  return overwrite;
}
