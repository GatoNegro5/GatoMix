import 'dart:convert';
import 'dart:math' as math;

import 'track_name_clean.dart';

/// Tolerancia directa de duración contra LRCLIB, en segundos.
const int kLyricDurationTolSec = 2;

/// Hasta aquí solo si artista y título coinciden fuerte.
const int kLyricDurationWideSec = 10;

/// En la coincidencia directa, la última línea queda a esta distancia del final.
const int kLyricEndSlackMs = 20000;

/// Título: token-set mínimo para aceptar.
const double kLyricTitleMin = 0.85;

/// Título fuerte: abre la ventana de ±10 s.
const double kLyricTitleStrong = 0.92;

/// Reintentos ante 429 o 503. No es «sin letra».
const int kLyricHttpTries = 3;

const String kLyricNoneMark = '[gmx_sin_letra:1]';
const String kLyricDoubtMark = '[gmx_dudosa:1]';

enum LyricKind { none, synced, plain }

/// Qué se puede guardar. [body] de una plana no trae tiempos.
class LyricChoice {
  final LyricKind kind;
  final String body;

  /// El servidor no contestó y no hubo un candidato utilizable.
  final bool serverDown;

  const LyricChoice({
    required this.kind,
    this.body = '',
    this.serverDown = false,
  });

  const LyricChoice.none() : this(kind: LyricKind.none);

  const LyricChoice.down() : this(kind: LyricKind.none, serverDown: true);

  bool get hasText => kind != LyricKind.none && body.trim().isNotEmpty;

  /// Texto que se escribe en el `.lrc`. La plana lleva la marca y cero sellos.
  String get fileText {
    if (kind == LyricKind.plain) {
      final String bare = body.replaceAll(_lrcStamp, '').trim();
      return '[gmx_plain:1]\n$bare';
    }
    return body;
  }
}

/// Artista, título y álbum con los que se pide la letra, y la duración medida.
class LyricIdentity {
  final String artist;
  final String title;
  final String album;
  final int durationSec;
  final bool remixOrExtended;
  final bool medley;
  final bool fromFile;

  const LyricIdentity({
    required this.artist,
    required this.title,
    this.album = '',
    required this.durationSec,
    this.remixOrExtended = false,
    this.medley = false,
    this.fromFile = false,
  });
}

const Map<String, String> _accents = {
  'á': 'a',
  'é': 'e',
  'í': 'i',
  'ó': 'o',
  'ú': 'u',
  'ü': 'u',
  'ñ': 'n',
  'à': 'a',
  'è': 'e',
  'ì': 'i',
  'ò': 'o',
  'ù': 'u',
};

/// 429, 503 o cualquier 5xx: reintento, no «sin letra».
bool lyricHttpTransient(int status) =>
    status == 429 || status == 503 || status >= 500;

/// 1,5 s, 3 s y 6 s. [attempt] es 0 en el primer fallo.
int lyricRetryDelayMs(int attempt) => 1500 * (1 << attempt);

/// UTF-8 leído como Latin-1 (`AÃ±os` → `Años`) y la capitalización
/// partida (`mINUTO` → `Minuto`). La comparación igual pasa a minúsculas.
String repairLyricText(String raw) {
  var s = raw.replaceAll('\u0000', '').trim();
  s = s.replaceAll('n\u0303', 'ñ').replaceAll('N\u0303', 'Ñ');
  if (s.contains('Ã') || s.contains('Â')) {
    try {
      final String fixed = utf8.decode(latin1.encode(s));
      if (!fixed.contains('\uFFFD')) s = fixed;
    } catch (_) {}
  }
  return s
      .split(' ')
      .map((String w) {
        if (w.length < 2) return w;
        final String letters = w.replaceAll(
          RegExp(r'[^A-Za-zÁÉÍÓÚÜÑáéíóúüñ]'),
          '',
        );
        if (letters.length < 2) return w;
        final String first = letters[0];
        final String rest = letters.substring(1);
        final bool firstLower =
            first == first.toLowerCase() && first != first.toUpperCase();
        final bool restUpper =
            rest == rest.toUpperCase() && rest != rest.toLowerCase();
        if (firstLower && restUpper) {
          return w[0].toUpperCase() + w.substring(1).toLowerCase();
        }
        return w;
      })
      .join(' ');
}

String _fold(String s) {
  var t = repairLyricText(s).toLowerCase();
  _accents.forEach((String k, String v) => t = t.replaceAll(k, v));
  return t;
}

/// Minúsculas, sin acentos, sin paréntesis y sin el feat. del final.
String lyricNorm(String s) {
  var t = _fold(s);
  t = t.replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), ' ');
  t = t.replaceAll(RegExp(r'\b(feat|ft|featuring)\b.*$'), ' ');
  t = t.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  return t;
}

/// Igual que [lyricNorm], pero las palabras del paréntesis se quedan:
/// el alias «Duncan Dhu» vive dentro de «MIKEL ERENTXUN (DUNCAN DHU)».
String lyricNormLoose(String s) {
  var t = _fold(s);
  t = t.replaceAll(RegExp(r'[\(\)\[\]\{\}]'), ' ');
  t = t.replaceAll(RegExp(r'\b(feat|ft|featuring)\b'), ' ');
  t = t.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  return t;
}

bool lyricNamesEqual(String a, String b) {
  final String na = lyricNorm(a);
  final String nb = lyricNorm(b);
  return na.isNotEmpty && na == nb;
}

List<String> _tokens(String norm) =>
    norm.split(' ').where((String t) => t.isNotEmpty).toList();

bool _tokenRun(String longer, String shorter) {
  if (shorter.length < 5) return false;
  final List<String> lt = _tokens(longer);
  final List<String> st = _tokens(shorter);
  if (st.isEmpty || lt.length < st.length) return false;
  var i = 0;
  for (final String tok in lt) {
    if (i < st.length && tok == st[i]) i++;
  }
  return i == st.length;
}

/// Igualdad, contención (`Medardo` dentro de `Don Medardo y Sus Players`)
/// o alias entre paréntesis.
bool lyricArtistsMatch(String a, String b) {
  final String na = lyricNorm(a);
  final String nb = lyricNorm(b);
  if (na.isEmpty || nb.isEmpty) return false;
  if (na == nb) return true;
  final String la = lyricNormLoose(a);
  final String lb = lyricNormLoose(b);
  return _tokenRun(la, lb) || _tokenRun(lb, la);
}

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (int i) => i);
  for (var i = 0; i < a.length; i++) {
    final List<int> cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final int cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
      final int del = prev[j + 1] + 1;
      final int ins = cur[j] + 1;
      final int sub = prev[j] + cost;
      var m = del < ins ? del : ins;
      if (sub < m) m = sub;
      cur[j + 1] = m;
    }
    prev = cur;
  }
  return prev[b.length];
}

double _ratio(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 1;
  final int m = a.length > b.length ? a.length : b.length;
  if (m == 0) return 0;
  return 1 - _lev(a, b) / m;
}

String _join(Iterable<String> xs) {
  final List<String> l = xs.toList()..sort();
  return l.join(' ');
}

/// Token-set de 0 a 1. Un token suelto no arrastra un título largo.
double lyricTitleScore(String a, String b) {
  final Set<String> ta = _tokens(lyricNorm(a)).toSet();
  final Set<String> tb = _tokens(lyricNorm(b)).toSet();
  if (ta.isEmpty || tb.isEmpty) return 0;
  final Set<String> inter = ta.intersection(tb);
  final int larger = ta.length > tb.length ? ta.length : tb.length;
  final double cover = inter.length / larger;
  if (inter.isEmpty || cover < 0.6) {
    return _ratio(_join(ta), _join(tb));
  }
  final String t0 = _join(inter);
  final String t1 = _join({...inter, ...ta.difference(tb)});
  final String t2 = _join({...inter, ...tb.difference(ta)});
  var score = _ratio(t0, t1);
  final double r2 = _ratio(t0, t2);
  final double r3 = _ratio(t1, t2);
  if (r2 > score) score = r2;
  if (r3 > score) score = r3;
  return score;
}

bool lyricTitlesMatch(String a, String b) =>
    lyricTitleScore(a, b) >= kLyricTitleMin;

bool _blankNorm(String norm) =>
    norm.isEmpty ||
    norm == 'unknown' ||
    norm == 'desconocido' ||
    norm == 'unknown artist' ||
    norm == 'artista desconocido' ||
    norm == 'n a' ||
    norm == 'na' ||
    norm == 'none' ||
    norm == 'null';

/// Unknown, Desconocido o vacío: no se envían. Entra el nombre de archivo.
bool lyricFieldBlank(String s) => _blankNorm(lyricNorm(s));

/// Álbum genérico (el sello ReGenial Master y los mismos vacíos).
bool lyricAlbumBlank(String s) {
  final String n = lyricNorm(s);
  if (_blankNorm(n)) return true;
  return n == 'regenial master' || n.startsWith('regenial master ');
}

final RegExp _remixMark = RegExp(
  r'remix|extended|extendid|versi[oó]n larga',
  caseSensitive: false,
);

final RegExp _medleyMark = RegExp(
  r'\b(medley|mosaico|mix|enganchado)\b',
  caseSensitive: false,
);

bool lyricLooksRemixOrExtended(String raw) => _remixMark.hasMatch(raw);

bool lyricLooksMedley(String raw) => _medleyMark.hasMatch(raw);

/// Cuánto baja una versión que el audio no pidió. Fuerte: no empata con la normal.
const double kLyricEditionPenalty = 80;

/// Marca interna: la fila salió de /api/get. No se envía a LRCLIB.
const String kLyricFromGetKey = '_gmxFromGet';

const Set<String> _editionTokens = <String>{
  'karaoke',
  'instrumental',
  'cover',
  'tribute',
  'remix',
  'live',
  'acustico',
  'acoustic',
};

const List<String> _editionPhrases = <String>[
  'in the style of',
  'made famous by',
  'en vivo',
];

/// Karaoke, Instrumental, Cover, Tribute, «in the style of», «made famous by»,
/// Remix, Live o Acústico. Live y «en vivo» son la misma marca; Acústico y
/// Acoustic también. Solo se mira el título, con los paréntesis puestos.
Set<String> lyricEditionMarks(String title) {
  final String loose = lyricNormLoose(title);
  final Set<String> marks = <String>{};
  if (loose.contains('en vivo') || _tokens(loose).contains('live')) {
    marks.add('live');
  }
  if (_tokens(loose).contains('acustico') ||
      _tokens(loose).contains('acoustic')) {
    marks.add('acoustic');
  }
  for (final String phrase in _editionPhrases) {
    if (phrase == 'en vivo') continue;
    if (loose.contains(phrase)) marks.add(phrase);
  }
  for (final String tok in _tokens(loose)) {
    if (tok == 'live' || tok == 'acustico' || tok == 'acoustic') continue;
    if (_editionTokens.contains(tok)) marks.add(tok);
  }
  return marks;
}

/// Penaliza el título del candidato. Si el audio trae la misma marca, no.
double lyricEditionPenalty(String audioTitle, String candidateTitle) {
  final Set<String> audio = lyricEditionMarks(audioTitle);
  for (final String mark in lyricEditionMarks(candidateTitle)) {
    if (!audio.contains(mark)) return kLyricEditionPenalty;
  }
  return 0;
}

/// Inicio de la voz, en ms. Energía por ventana y el primer tramo que
/// además es periódico en el rango de la voz (80–400 Hz) y se sostiene.
/// Null si no hay una subida clara: el desempate pasa a /api/get.
int? lyricVoiceOnsetMs(List<double> samples, int sampleRate) {
  if (sampleRate < 4000 || samples.length < sampleRate) return null;
  final int hop = math.max(1, (sampleRate * 0.02).round());
  final int win = math.max(hop + 1, (sampleRate * 0.032).round());
  final int lagMin = math.max(8, (sampleRate / 400).round());
  final int lagMax = math.max(lagMin + 2, (sampleRate / 80).round());
  const int need = 8;
  var run = 0;
  var runStart = 0;
  for (var pos = 0; pos + win < samples.length; pos += hop) {
    var energy = 0.0;
    var mean = 0.0;
    for (var i = 0; i < win; i++) {
      final double s = samples[pos + i];
      energy += s * s;
      mean += s;
    }
    energy /= win;
    mean /= win;
    var voiced = false;
    if (energy > 1e-4) {
      var r0 = 0.0;
      for (var i = 0; i < win; i++) {
        final double d = samples[pos + i] - mean;
        r0 += d * d;
      }
      if (r0 > 1e-8) {
        var best = 0.0;
        for (var lag = lagMin; lag <= lagMax; lag += 2) {
          var r = 0.0;
          final int n = win - lag;
          for (var i = 0; i < n; i++) {
            r += (samples[pos + i] - mean) * (samples[pos + i + lag] - mean);
          }
          final double ncc = r / r0;
          if (ncc > best) best = ncc;
        }
        voiced = best >= 0.55;
      }
    }
    if (voiced) {
      if (run == 0) runStart = pos;
      run++;
      if (run >= need) {
        return (runStart * 1000 / sampleRate).round();
      }
    } else {
      run = 0;
    }
  }
  return null;
}

final RegExp _audioExt = RegExp(
  r'\.(mp3|m4a|webm|flac|wav|ogg|aac)$',
  caseSensitive: false,
);

LyricIdentity _identity({
  required String artist,
  required String title,
  required String album,
  required int durationSec,
  required bool remix,
  required bool medley,
  required bool fromFile,
}) {
  return LyricIdentity(
    artist: artist,
    title: title,
    album: album,
    durationSec: durationSec,
    remixOrExtended: remix,
    medley: medley,
    fromFile: fromFile,
  );
}

/// ID3 primero. Unknown, Desconocido y el álbum genérico cuentan como vacíos
/// y entra el nombre de archivo. Si el ID3 contradice al archivo, van los dos.
List<LyricIdentity> lyricIdentities({
  required String path,
  String id3Artist = '',
  String id3Title = '',
  String id3Album = '',
  required int durationSec,
}) {
  final String stem = _stem(path);
  final CleanTrackName file = cleanTrackFileName(stem);
  final bool remix = lyricLooksRemixOrExtended('$stem $id3Title $id3Album');
  final bool medley = lyricLooksMedley('$stem $id3Title $id3Album');
  final String tagArtist = lyricFieldBlank(id3Artist)
      ? ''
      : repairLyricText(id3Artist.trim());
  final String tagTitle = lyricFieldBlank(id3Title)
      ? ''
      : repairLyricText(id3Title.trim());
  final String album = lyricAlbumBlank(id3Album)
      ? ''
      : repairLyricText(id3Album.trim());
  final String fileArtist = repairLyricText(file.artist);
  final String fileTitle = repairLyricText(file.title);
  final String artist = tagArtist.isNotEmpty ? tagArtist : fileArtist;
  final String title = tagTitle.isNotEmpty ? tagTitle : fileTitle;
  final LyricIdentity primary = _identity(
    artist: artist,
    title: title,
    album: album,
    durationSec: durationSec,
    remix: remix,
    medley: medley,
    fromFile: tagArtist.isEmpty && tagTitle.isEmpty,
  );
  final bool contradict =
      tagArtist.isNotEmpty &&
      tagTitle.isNotEmpty &&
      fileArtist.isNotEmpty &&
      fileTitle.isNotEmpty &&
      (!lyricArtistsMatch(tagArtist, fileArtist) ||
          lyricTitleScore(tagTitle, fileTitle) < kLyricTitleMin);
  if (!contradict) return <LyricIdentity>[primary];
  return <LyricIdentity>[
    primary,
    _identity(
      artist: fileArtist,
      title: fileTitle,
      album: '',
      durationSec: durationSec,
      remix: remix,
      medley: medley,
      fromFile: true,
    ),
  ];
}

/// ID3 primero. El nombre del archivo solo rellena lo que la etiqueta no trae.
LyricIdentity lyricIdentity({
  required String path,
  String id3Artist = '',
  String id3Title = '',
  String id3Album = '',
  required int durationSec,
}) {
  return lyricIdentities(
    path: path,
    id3Artist: id3Artist,
    id3Title: id3Title,
    id3Album: id3Album,
    durationSec: durationSec,
  ).first;
}

String _stem(String path) {
  var name = path.trim().replaceAll('\\', '/');
  final int slash = name.lastIndexOf('/');
  if (slash >= 0) name = name.substring(slash + 1);
  return name.replaceAll(_audioExt, '');
}

/// `GET /api/get`. El álbum vacío no se envía.
Uri lrclibGetUri(LyricIdentity id, {bool withAlbum = true}) {
  final Map<String, String> q = <String, String>{
    'artist_name': id.artist,
    'track_name': id.title,
    'duration': '${id.durationSec}',
  };
  if (withAlbum && id.album.isNotEmpty) q['album_name'] = id.album;
  return Uri.https('lrclib.net', '/api/get', q);
}

/// `GET /api/search` solo con artista y título. El filtro lo hace el matcher.
Uri lrclibSearchUri(LyricIdentity id) {
  return Uri.https('lrclib.net', '/api/search', {
    'artist_name': id.artist,
    'track_name': id.title,
  });
}

/// `GET /api/search?q=` con el nombre limpio. Lo usa la búsqueda manual.
Uri lrclibQueryUri(String query) {
  return Uri.https('lrclib.net', '/api/search', {'q': query.trim()});
}

/// Sin artista (nombre sin ` - `): búsqueda libre `q=` con el título
/// completo. Null si hay artista o no hay título.
Uri? lrclibTitleOnlyUri(LyricIdentity id) {
  if (id.artist.trim().isNotEmpty || id.title.trim().isEmpty) return null;
  return lrclibQueryUri(id.title);
}

/// Identidad sin artista: el título completo debe contener al artista de
/// LRCLIB y el resto coincidir fuerte con su título. 0 si no encaja.
double lyricTitleOnlyScore(
  String fullTitle,
  String apiArtist,
  String apiTitle,
) {
  final String full = lyricNormLoose(fullTitle);
  final String art = lyricNormLoose(apiArtist);
  if (full.isEmpty || art.isEmpty) return 0;
  final String padded = ' $full ';
  if (!padded.contains(' $art ')) return 0;
  final String rest = padded.replaceFirst(' $art ', ' ').trim();
  if (rest.isEmpty) return 0;
  final double ts = lyricTitleScore(rest, apiTitle);
  return ts >= kLyricTitleStrong ? ts : 0;
}

/// Las tres lecturas del botón Buscar letra, en paralelo.
List<Uri> lrclibManualUris({
  required String artist,
  required String title,
  required int durationSec,
  String query = '',
}) {
  final LyricIdentity id = LyricIdentity(
    artist: artist,
    title: title,
    durationSec: durationSec,
  );
  final String q = query.trim().isNotEmpty ? query.trim() : '$artist $title';
  return <Uri>[
    lrclibGetUri(id, withAlbum: false),
    lrclibSearchUri(id),
    lrclibQueryUri(q),
  ];
}

final RegExp _lrcStamp = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{2,3})\]');

int? _stampMs(Match m) {
  final int min = int.parse(m.group(1)!);
  final int sec = int.parse(m.group(2)!);
  int ms = int.parse(m.group(3)!);
  if (m.group(3)!.length == 2) ms *= 10;
  return (min * 60000) + (sec * 1000) + ms;
}

int? lastLrcStampMs(String lrc) {
  int? last;
  for (final Match m in _lrcStamp.allMatches(lrc)) {
    last = _stampMs(m);
  }
  return last;
}

int? firstLrcStampMs(String lrc) {
  final Match? m = _lrcStamp.firstMatch(lrc);
  if (m == null) return null;
  return _stampMs(m);
}

class LyricStampLine {
  final int ms;
  final String text;
  const LyricStampLine(this.ms, this.text);
}

/// Sellos de un LRC, en orden. La vista karaoke los pinta como [LyricLine].
List<LyricStampLine> parseLyricStampLines(String lrc) {
  final List<LyricStampLine> out = <LyricStampLine>[];
  for (final Match m in _lrcStamp.allMatches(lrc)) {
    final int? ms = _stampMs(m);
    if (ms == null) continue;
    final int end = m.end;
    final int nl = lrc.indexOf('\n', end);
    final String text = lrc.substring(end, nl < 0 ? lrc.length : nl).trim();
    if (text.isEmpty) continue;
    out.add(LyricStampLine(ms, text));
  }
  return out;
}

/// La última línea es ≤ la duración y queda a ≤ ~20 s del final.
bool lrcEndsWithAudio(String lrc, int durationSec) {
  final int? last = lastLrcStampMs(lrc);
  if (last == null || durationSec <= 0) return false;
  final int durMs = durationSec * 1000;
  if (last > durMs) return false;
  return durMs - last <= kLyricEndSlackMs;
}

/// La última línea cae dentro del audio, sin exigir los ~20 s del final.
bool lrcInsideAudio(String lrc, int durationSec) {
  final int? last = lastLrcStampMs(lrc);
  if (last == null || durationSec <= 0) return false;
  return last <= durationSec * 1000;
}

bool lyricDurationClose(int apiSec, int localSec) {
  if (apiSec <= 0 || localSec <= 0) return false;
  return (apiSec - localSec).abs() <= kLyricDurationTolSec;
}

/// Un `.lrc` que ya existe no se vuelve a bajar, salvo la revisión del Laboratorio.
bool lyricMayDownload({required bool lrcExists}) => !lrcExists;

bool lrcIsNoRetry(String content) =>
    content.toLowerCase().contains('[gmx_sin_letra:');

bool lrcIsDoubtful(String content) =>
    content.toLowerCase().contains('[gmx_dudosa:');

String markLrcDoubtful(String content) {
  if (lrcIsDoubtful(content)) return content;
  return '$kLyricDoubtMark\n$content';
}

String _msToStamp(int totalMs) {
  if (totalMs < 0) totalMs = 0;
  final String min = (totalMs ~/ 60000).toString().padLeft(2, '0');
  final String sec = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
  final String cs = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
  return '[$min:$sec.$cs]';
}

/// Mueve cada sello. El editor manual lo usa; no escribe `[gmx_shift:]`.
String shiftLyricStamps(String content, int deltaMs) {
  if (deltaMs == 0) return content;
  return content.replaceAllMapped(_lrcStamp, (Match m) {
    return _msToStamp(_stampMs(m)! + deltaMs);
  });
}

/// La primera línea pasa a [targetMs] y el resto se desplaza igual.
String alignFirstLyricLine(String content, int targetMs) {
  final int? first = firstLrcStampMs(content);
  if (first == null) return content;
  return shiftLyricStamps(content, targetMs - first);
}

bool _syncedFits(String lrc, int durationSec, {required bool wide}) {
  if (wide) return lrcInsideAudio(lrc, durationSec);
  return lrcEndsWithAudio(lrc, durationSec);
}

class _Ranked {
  final double rank;
  final LyricKind kind;
  final String body;
  const _Ranked(this.rank, this.kind, this.body);
}

/// Elige como mucho un resultado. Artista por contención o alias, título
/// por token-set ≥ 0,85. ±2 s es directo; hasta ±10 s solo si el título es
/// fuerte y la última línea cae dentro del audio. Un medley no lleva
/// sincronizada. Un remix sin esa duración se queda, como mucho, en plana.
LyricChoice chooseLrclibLyric(
  LyricIdentity id, {
  List<LyricIdentity> also = const [],
  Map<String, dynamic>? direct,
  List<dynamic> searched = const [],
}) {
  final List<LyricIdentity> ids = <LyricIdentity>[id, ...also];
  final bool medley = ids.any((LyricIdentity e) => e.medley);
  final bool remix = ids.any((LyricIdentity e) => e.remixOrExtended);
  final bool preferFile = also.isNotEmpty;
  final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
  if (direct != null) rows.add(direct);
  for (final dynamic raw in searched) {
    if (raw is Map) rows.add(Map<String, dynamic>.from(raw));
  }

  _Ranked? best;
  for (final Map<String, dynamic> raw in rows) {
    final String apiArtist = raw['artistName']?.toString() ?? '';
    final String apiTitle = raw['trackName']?.toString() ?? '';
    LyricIdentity? fit;
    var titleScore = 0.0;
    for (final LyricIdentity ident in ids) {
      if (ident.artist.trim().isEmpty) {
        final double t0 = lyricTitleOnlyScore(ident.title, apiArtist, apiTitle);
        if (t0 > 0 && (fit == null || t0 > titleScore)) {
          fit = ident;
          titleScore = t0;
        }
        continue;
      }
      if (!lyricArtistsMatch(ident.artist, apiArtist)) continue;
      final double ts = lyricTitleScore(ident.title, apiTitle);
      if (ts < kLyricTitleMin) continue;
      if (fit == null || ts > titleScore) {
        fit = ident;
        titleScore = ts;
      }
    }
    if (fit == null) continue;
    final int apiDur = (raw['duration'] as num?)?.round() ?? 0;
    final int delta = apiDur <= 0 ? 999 : (apiDur - id.durationSec).abs();
    final bool strong = titleScore >= kLyricTitleStrong;
    final bool directDur = apiDur > 0 && delta <= kLyricDurationTolSec;
    final bool wideDur = apiDur > 0 && strong && delta <= kLyricDurationWideSec;
    final bool durOk = directDur || wideDur;
    final String syncedText = raw['syncedLyrics']?.toString() ?? '';
    final String plainText = raw['plainLyrics']?.toString() ?? '';
    final double boost = (preferFile && fit.fromFile) ? 0.05 : 0;
    final double base =
        (20 - (delta > 20 ? 20 : delta)) + titleScore * 10 + boost;

    void offer(double rank, LyricKind kind, String body) {
      if (best == null || rank > best!.rank) {
        best = _Ranked(rank, kind, body);
      }
    }

    if (durOk &&
        !medley &&
        syncedText.trim().isNotEmpty &&
        _syncedFits(syncedText, id.durationSec, wide: !directDur)) {
      offer(200 + base, LyricKind.synced, syncedText);
    }
    if (durOk && plainText.trim().isNotEmpty) {
      offer(80 + base, LyricKind.plain, plainText);
    } else if (durOk && medley && syncedText.trim().isNotEmpty) {
      offer(70 + base, LyricKind.plain, syncedText);
    } else if (remix && !medley && !durOk && plainText.trim().isNotEmpty) {
      offer(40 + titleScore * 10, LyricKind.plain, plainText);
    }
  }

  if (best == null) return const LyricChoice.none();
  return LyricChoice(kind: best!.kind, body: best!.body);
}

/// Candidato de la búsqueda manual. Las dudosas se listan, con aviso.
class LyricCandidate {
  final String artist;
  final String title;
  final String album;
  final int durationSec;
  final int deltaSec;
  final double score;
  final bool synced;
  final bool doubtful;
  final String warning;
  final String body;
  final int? lrclibId;
  final int? firstStampMs;
  final bool fromGet;

  const LyricCandidate({
    required this.artist,
    required this.title,
    this.album = '',
    required this.durationSec,
    required this.deltaSec,
    required this.score,
    required this.synced,
    required this.doubtful,
    this.warning = '',
    required this.body,
    this.lrclibId,
    this.firstStampMs,
    this.fromGet = false,
  });

  LyricCandidate asFromGet() {
    if (fromGet) return this;
    return LyricCandidate(
      artist: artist,
      title: title,
      album: album,
      durationSec: durationSec,
      deltaSec: deltaSec,
      score: score,
      synced: synced,
      doubtful: doubtful,
      warning: warning,
      body: body,
      lrclibId: lrclibId,
      firstStampMs: firstStampMs,
      fromGet: true,
    );
  }

  String get fileText {
    if (!synced) {
      final String bare = body.replaceAll(_lrcStamp, '').trim();
      return '[gmx_plain:1]\n$bare';
    }
    return body;
  }
}

/// Verde ±3 s, ámbar ±10 s, lejos el resto. Es la marca de la lista manual.
String lyricDeltaBand(int deltaSec) {
  final int d = deltaSec.abs();
  if (d <= 3) return 'green';
  if (d <= 10) return 'amber';
  return 'far';
}

bool _closeContender(LyricCandidate c) =>
    c.synced && c.firstStampMs != null && c.deltaSec <= 3 && !c.doubtful;

/// Empate: menor diferencia de duración, luego la primera línea contra el
/// inicio de la voz. Si no se midió, manda /api/get.
/// Varias candidatas en ±3 s y onset medido: manda la primera línea, así
/// una duración exacta no gana si arranca lejos de la voz.
int _candidateOrder(LyricCandidate a, LyricCandidate b, int? onset) {
  final bool band = onset != null && _closeContender(a) && _closeContender(b);
  if (band) {
    final int ae = (a.firstStampMs! - onset).abs();
    final int be = (b.firstStampMs! - onset).abs();
    if (ae != be) return ae.compareTo(be);
    if (a.deltaSec != b.deltaSec) return a.deltaSec.compareTo(b.deltaSec);
    if (a.fromGet != b.fromGet) return a.fromGet ? -1 : 1;
    return b.score.compareTo(a.score);
  }
  final int byScore = b.score.compareTo(a.score);
  if (byScore != 0) return byScore;
  if (a.deltaSec != b.deltaSec) return a.deltaSec.compareTo(b.deltaSec);
  if (onset != null && a.firstStampMs != null && b.firstStampMs != null) {
    final int ae = (a.firstStampMs! - onset).abs();
    final int be = (b.firstStampMs! - onset).abs();
    if (ae != be) return ae.compareTo(be);
  } else if (onset == null && a.fromGet != b.fromGet) {
    return a.fromGet ? -1 : 1;
  }
  return 0;
}

/// Puntaje de la búsqueda manual. El mismo matcher, y las dudosas no se ocultan.
List<LyricCandidate> rankLyricCandidates({
  required LyricIdentity id,
  required List<Map<String, dynamic>> rows,
  int? voiceOnsetMs,
}) {
  final Map<int, LyricCandidate> unique = <int, LyricCandidate>{};
  final List<LyricCandidate> rest = <LyricCandidate>[];
  for (final Map<String, dynamic> raw in rows) {
    final String artist = raw['artistName']?.toString() ?? '';
    final String title = raw['trackName']?.toString() ?? '';
    final int apiDur = (raw['duration'] as num?)?.round() ?? 0;
    final int delta = apiDur <= 0 || id.durationSec <= 0
        ? 999
        : (apiDur - id.durationSec).abs();
    final bool artistOk = lyricArtistsMatch(id.artist, artist);
    final double titleScore = lyricTitleScore(id.title, title);
    final String syncedText = raw['syncedLyrics']?.toString() ?? '';
    final String plainText = raw['plainLyrics']?.toString() ?? '';
    final bool hasSynced = syncedText.trim().isNotEmpty && !id.medley;
    final bool hasPlain =
        plainText.trim().isNotEmpty ||
        (id.medley && syncedText.trim().isNotEmpty);
    if (!hasSynced && !hasPlain) continue;
    final bool inside = hasSynced && lrcInsideAudio(syncedText, id.durationSec);
    final bool strong = artistOk && titleScore >= kLyricTitleStrong;
    final double edition = lyricEditionPenalty(id.title, title);
    final List<String> warnings = <String>[];
    if (edition > 0) {
      warnings.add(
        'Versión karaoke, instrumental, cover, tribute, remix, live o acústico',
      );
    }
    if (!artistOk || titleScore < kLyricTitleMin) {
      warnings.add('Artista o título no coinciden');
    }
    if (delta > kLyricDurationWideSec) {
      warnings.add('Duración lejos del audio');
    }
    if (hasSynced && !inside) {
      warnings.add('La última línea no cae dentro del audio');
    }
    if (id.medley) warnings.add('Medley: solo plana');
    final bool doubtful = warnings.isNotEmpty;
    var score = titleScore * 50;
    if (artistOk) score += 30;
    if (delta <= kLyricDurationTolSec) {
      score += 20;
    } else if (delta <= 3) {
      score += 12;
    } else if (delta <= kLyricDurationWideSec) {
      score += 8;
    } else if (delta > 30) {
      score -= 10;
    }
    if (hasSynced && inside && (delta <= 2 || strong)) score += 5;
    score -= edition;
    final String body = hasSynced
        ? syncedText
        : (plainText.isNotEmpty ? plainText : syncedText);
    final int? lid = (raw['id'] as num?)?.toInt();
    final bool fromGet = raw[kLyricFromGetKey] == true;
    final LyricCandidate hit = LyricCandidate(
      artist: artist,
      title: title,
      album: raw['albumName']?.toString() ?? '',
      durationSec: apiDur,
      deltaSec: delta == 999 ? apiDur : delta,
      score: score,
      synced: hasSynced,
      doubtful: doubtful,
      warning: warnings.join(' · '),
      body: body,
      lrclibId: lid,
      firstStampMs: hasSynced ? firstLrcStampMs(syncedText) : null,
      fromGet: fromGet,
    );
    if (lid != null) {
      final LyricCandidate? prev = unique[lid];
      if (prev == null || hit.score > prev.score) {
        unique[lid] = (prev?.fromGet ?? false) ? hit.asFromGet() : hit;
      } else if (hit.fromGet && !prev.fromGet) {
        unique[lid] = prev.asFromGet();
      }
    } else {
      rest.add(hit);
    }
  }
  final List<LyricCandidate> all = <LyricCandidate>[...unique.values, ...rest];
  all.sort(
    (LyricCandidate a, LyricCandidate b) => _candidateOrder(a, b, voiceOnsetMs),
  );
  return all;
}

enum LyricGap {
  none,
  duplicate,
  pastEnd,
  short,
  artist,
  title,
  duration,
  unsigned,
}

class LyricFileVerdict {
  final bool fits;
  final LyricGap gap;
  const LyricFileVerdict(this.fits, this.gap);
  const LyricFileVerdict.ok() : this(true, LyricGap.none);
  const LyricFileVerdict.bad(LyricGap gap) : this(false, gap);
}

String? lrcMeta(String lrc, String key) {
  final RegExp re = RegExp('\\[$key:(.*)\\]', caseSensitive: false);
  final Match? m = re.firstMatch(lrc);
  final String? v = m?.group(1)?.trim();
  if (v == null || v.isEmpty) return null;
  return v;
}

int? lrcLengthSec(String lrc) {
  final String? raw = lrcMeta(lrc, 'length');
  if (raw == null) return null;
  final List<String> parts = raw.split(':');
  if (parts.length != 2) return null;
  final int? m = int.tryParse(parts[0].trim());
  final double? s = double.tryParse(parts[1].trim());
  if (m == null || s == null) return null;
  return m * 60 + s.round();
}

/// Texto comparable: sin sellos ni marcas, normalizado.
String lyricComparable(String lrc) {
  final String bare = lrc
      .replaceAll(_lrcStamp, ' ')
      .replaceAll(RegExp(r'\[[a-zA-Z0-9_]+:[^\]]*\]'), ' ');
  return lyricNorm(bare);
}

bool lyricTextsMatch(String a, String b) {
  final String na = lyricComparable(a);
  final String nb = lyricComparable(b);
  return na.isNotEmpty && na == nb;
}

bool lyricDuplicates(String lrc, Iterable<String> others) {
  for (final String other in others) {
    if (lyricTextsMatch(lrc, other)) return true;
  }
  return false;
}

/// ¿Esta letra es de esta canción, cubre el audio y no está repetida?
LyricFileVerdict assessLabLyric({
  required String lrc,
  required String artist,
  required String title,
  required int durationSec,
  required Iterable<String> siblingLrcs,
}) {
  if (lyricDuplicates(lrc, siblingLrcs)) {
    return const LyricFileVerdict.bad(LyricGap.duplicate);
  }
  final bool stamped = _lrcStamp.hasMatch(lrc);
  if (stamped) {
    final int? last = lastLrcStampMs(lrc);
    if (last != null && durationSec > 0 && last > durationSec * 1000) {
      return const LyricFileVerdict.bad(LyricGap.pastEnd);
    }
    if (!lrcEndsWithAudio(lrc, durationSec)) {
      return const LyricFileVerdict.bad(LyricGap.short);
    }
  }
  final String? ar = lrcMeta(lrc, 'ar');
  final String? ti = lrcMeta(lrc, 'ti');
  if (ar != null && artist.isNotEmpty && !lyricArtistsMatch(artist, ar)) {
    return const LyricFileVerdict.bad(LyricGap.artist);
  }
  if (ti != null &&
      title.isNotEmpty &&
      lyricTitleScore(title, ti) < kLyricTitleMin) {
    return const LyricFileVerdict.bad(LyricGap.title);
  }
  final int? len = lrcLengthSec(lrc);
  if (len != null &&
      durationSec > 0 &&
      (len - durationSec).abs() > kLyricDurationWideSec) {
    return const LyricFileVerdict.bad(LyricGap.duration);
  }
  if (ar == null && ti == null) {
    return const LyricFileVerdict.bad(LyricGap.unsigned);
  }
  if (!stamped && !lrc.toLowerCase().contains('[gmx_plain:')) {
    return const LyricFileVerdict.bad(LyricGap.short);
  }
  return const LyricFileVerdict.ok();
}

enum LabLyricAction { keep, replace, doubt, retry }

/// Si no cuadra y hay una mejor, se reemplaza. Si el servidor cayó, se
/// reintenta. Si no hay mejor, se marca dudosa. La misma letra confirmada
/// por la búsqueda se queda.
LabLyricAction decideLabLyric({
  required LyricFileVerdict verdict,
  required bool serverDown,
  required bool hasBetter,
  bool sameText = false,
}) {
  if (verdict.fits) return LabLyricAction.keep;
  if (serverDown) return LabLyricAction.retry;
  if (verdict.gap == LyricGap.unsigned && sameText) return LabLyricAction.keep;
  if (hasBetter) return LabLyricAction.replace;
  return LabLyricAction.doubt;
}

/// 503 sin candidato no es «sin letra»: se puede intentar más tarde.
bool lyricFailureIsRetry({required bool serverDown, required bool hasText}) =>
    serverDown && !hasText;
