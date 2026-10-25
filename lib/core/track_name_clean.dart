/// Limpieza del nombre de archivo hacia `Artista - Título`.
///
/// Quita prefijos de BPM (`85 Bpm -`, `120 -`), Camelot (`6a`, `11B`),
/// el sufijo `74bpm`, y colas de YouTube (`[extended]`, `(official video)`,
/// `(lyrics)`, …). Si el ID3 trae TPE1/TIT2 y el archivo está al revés
/// (`Título - Artista`), lo endereza. No pisa mayúsculas: quien llama
/// aplica el formato final.
class CleanTrackName {
  final String artist;
  final String title;

  /// BPM leído del nombre, si el número caía en 40–250.
  final double? bpmHint;

  /// Camelot encontrado (`6A`, `11B`), si había.
  final String? camelot;

  const CleanTrackName({
    this.artist = '',
    this.title = '',
    this.bpmHint,
    this.camelot,
  });

  String get stem {
    if (artist.isNotEmpty && title.isNotEmpty) return '$artist - $title';
    if (title.isNotEmpty) return title;
    return artist;
  }
}

final RegExp _ytJunk = RegExp(
  r'\s*[\[\(][^\]\)]*(?:official(?:\s+music)?\s+video|official\s+audio|video\s+oficial|audio\s+oficial|music\s+video|lyric\s+video|lyrics?|letras?|audio|video|hq|hd|4k|visuali[sz]er|topic|extended(?:\s+mix|\s+version)?|remaster(?:ed)?|oficial)[^\]\)]*[\]\)]',
  caseSensitive: false,
);

/// Sello o canal entre paréntesis o corchetes, sin importar mayúsculas.
/// (Infopesa), (infopesa), (Discos Fuentes), (Vevo). No toca (En Vivo) ni (Live).
/// Colas de YouTube SOLO al final del título (`... letra`, `- lyrics`,
/// `con letra`, `lyric video`, `video oficial`). `letra` en medio no se toca.
final RegExp _tailJunk = RegExp(
  r'(?:\s*[-–—|:]\s*|\s+)(?:con\s+letras?|letras?|lyrics?|lyric\s+video|video\s+lyrics?|video\s+oficial|official\s+(?:music\s+)?video|audio\s+oficial|official\s+audio)\s*$',
  caseSensitive: false,
);

/// Quita colas conservadoras al final; nunca deja el título vacío.
String stripTrailingYtJunk(String name) {
  var out = name.trim();
  while (true) {
    final Match? m = _tailJunk.firstMatch(out);
    if (m == null || m.start == 0) return out;
    final String next = out.substring(0, m.start).trim();
    if (next.isEmpty) return out;
    out = next;
  }
}

final RegExp _labelTag = RegExp(
  r'\s*[\[\(][^\]\)]*\b(?:infopesa|discos|codiscos|peerless|musart|fania|orfe[oó]n|sono\s*radio|ieesa|vevo|records?|recording|sello|canal|channel|productions?|entertainment)\b[^\]\)]*[\]\)]',
  caseSensitive: false,
);

final RegExp _bpmPrefix = RegExp(
  r'^(\d{2,3})(?!\d)\s*(?:bpm)?\s*-\s*',
  caseSensitive: false,
);

final RegExp _camelotPrefix = RegExp(r'^(\d{1,2})\s*([abAB])\s*-\s*');

final RegExp _bpmSuffix = RegExp(
  r'(?:\s*-\s*|\s+)(\d{2,3})(?!\d)\s*bpm\s*$',
  caseSensitive: false,
);

final RegExp _camelotSuffix = RegExp(
  r'(?:\s*-\s*|\s+)(\d{1,2})\s*([abAB])\s*$',
);

final RegExp _camelotToken = RegExp(r'^\d{1,2}\s*[abAB]$');

String _fold(String s) {
  var t = s.toLowerCase();
  const Map<String, String> accents = {
    'á': 'a',
    'é': 'e',
    'í': 'i',
    'ó': 'o',
    'ú': 'u',
    'ü': 'u',
    'ñ': 'n',
  };
  accents.forEach((String k, String v) => t = t.replaceAll(k, v));
  return t.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

bool _same(String a, String b) {
  final String na = _fold(a);
  final String nb = _fold(b);
  return na.isNotEmpty && na == nb;
}

CleanTrackName cleanTrackFileName(
  String filename, {
  String id3Artist = '',
  String id3Title = '',
}) {
  var name = filename.trim().replaceAll('\\', '/');
  final int slash = name.lastIndexOf('/');
  if (slash >= 0) name = name.substring(slash + 1);
  if (name.toLowerCase().endsWith('.mp3')) {
    name = name.substring(0, name.length - 4);
  }
  if (name.endsWith('_R') || name.endsWith(' R')) {
    name = name.substring(0, name.length - 2).trim();
  }

  name = name.replaceAll(_ytJunk, ' ');
  name = name.replaceAll(_labelTag, ' ');
  name = name.replaceAll(RegExp(r'\s*-\s*-+\s*'), ' - ');
  name = name.replaceAll('_', ' ');
  name = name.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

  double? bpm;
  String? camelot;

  final Match? pre = _bpmPrefix.firstMatch(name);
  if (pre != null) {
    bpm = double.tryParse(pre.group(1)!);
    name = name.substring(pre.end).trim();
  }
  final Match? camPre = _camelotPrefix.firstMatch(name);
  if (camPre != null) {
    camelot = '${camPre.group(1)}${camPre.group(2)!.toUpperCase()}';
    name = name.substring(camPre.end).trim();
  }
  final Match? suf = _bpmSuffix.firstMatch(name);
  if (suf != null) {
    bpm ??= double.tryParse(suf.group(1)!);
    name = name.substring(0, suf.start).trim();
  }
  final Match? camSuf = _camelotSuffix.firstMatch(name);
  if (camSuf != null) {
    camelot ??= '${camSuf.group(1)}${camSuf.group(2)!.toUpperCase()}';
    name = name.substring(0, camSuf.start).trim();
  }

  name = name.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  name = stripTrailingYtJunk(name);
  name = name.replaceAll(RegExp(r'^[-\s]+|[-\s]+$'), '').trim();

  final List<String> parts = name
      .split(' - ')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .where((String s) {
        if (_camelotToken.hasMatch(s)) {
          camelot ??= s.replaceAll(RegExp(r'\s+'), '').toUpperCase();
          return false;
        }
        return true;
      })
      .toList();

  String artist = '';
  String title = '';
  if (parts.length >= 2) {
    artist = parts.first;
    title = parts.sublist(1).join(' - ');
  } else if (parts.isNotEmpty) {
    title = parts.first;
  }

  final String tagArtist = id3Artist.trim();
  final String tagTitle = id3Title.trim();
  if (artist.isNotEmpty &&
      title.isNotEmpty &&
      tagArtist.isNotEmpty &&
      tagTitle.isNotEmpty &&
      _same(artist, tagTitle) &&
      _same(title, tagArtist) &&
      !_same(artist, tagArtist)) {
    final String swap = artist;
    artist = title;
    title = swap;
  }

  double? hint;
  if (bpm != null && bpm >= 40 && bpm <= 250) hint = bpm;

  return CleanTrackName(
    artist: artist,
    title: title,
    bpmHint: hint,
    camelot: camelot,
  );
}

/// `Artista - Título.mp3`, con `(2)` si [taken] ya existe.
String uniqueMp3Name(String stem, bool Function(String fileName) taken) {
  final String base = stem.trim().isEmpty ? 'Pista' : stem.trim();
  String candidate = '$base.mp3';
  if (!taken(candidate)) return candidate;
  for (int n = 2; n < 100; n++) {
    candidate = '$base ($n).mp3';
    if (!taken(candidate)) return candidate;
  }
  return '$base (${DateTime.now().millisecondsSinceEpoch}).mp3';
}


final RegExp _fsForbidden = RegExp(r'[\\/:*?"<>|]');

/// Título de YouTube → nombre de archivo. Primero convierte ` / ` y ` | `
/// en separador ` - ` (antes de quitar caracteres prohibidos), luego limpia.
/// `AC/DC` (sin espacios) no es separador.
String ytTitleToStem(String rawTitle) {
  final String sep = rawTitle.replaceAll(RegExp(r'\s+[/|]\s+'), ' - ');
  final String safe = sep.replaceAll(_fsForbidden, '').trim();
  final CleanTrackName cleaned = cleanTrackFileName(safe);
  final String stem = cleaned.stem.trim().isEmpty ? safe : cleaned.stem.trim();
  final String out = stem.replaceAll(_fsForbidden, '').trim();
  return out.isEmpty ? 'Pista' : out;
}
