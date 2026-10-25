// GatoMix 1.0.13 — Laboratorio automático (Dart puro, las 4 plataformas).
//
// - El Masterizar anota cada letra que queda en FAIL en
//   `<carpeta>/.gatomix_lyric_fail.json` (y la borra si luego se arregla).
// - `moveFailsToLab` mueve esas pistas (mp3 + compañeros) a GatoMix_LAB y
//   apunta el origen en `quarantine_registry.json` (mismo formato que el
//   botón «Enviar al LAB»), así siempre se puede devolver.
// - `restoreFixedFromLab` devuelve a su carpeta las que ya no fallan.
// Nunca pisa un archivo existente ni borra nada.
import 'dart:convert';
import 'dart:io';

const String lyricFailJournalName = '.gatomix_lyric_fail.json';
const String labRegistryName = 'quarantine_registry.json';

String _sep = Platform.pathSeparator;
String _dirOf(String p) => File(p).parent.path;
String _nameOf(String p) => File(p).uri.pathSegments.last;
String _stem(String name) =>
    name.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '');

Map<String, dynamic> _readJson(File f) {
  if (!f.existsSync()) return <String, dynamic>{};
  try {
    final Object? v = jsonDecode(f.readAsStringSync());
    return v is Map<String, dynamic> ? v : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

void _writeJson(File f, Map<String, dynamic> m) {
  final File tmp = File('${f.path}.tmp');
  tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(m));
  if (f.existsSync()) f.deleteSync();
  tmp.renameSync(f.path);
}

File _journal(String dir) => File('$dir$_sep$lyricFailJournalName');

/// Anota (o quita, si [reason] es null/vacío) el FAIL de letra de [mp3].
void recordLyricFailSync(String mp3, String? reason) {
  try {
    final File j = _journal(_dirOf(mp3));
    final Map<String, dynamic> m = _readJson(j);
    final String k = _nameOf(mp3);
    if (reason == null || reason.isEmpty || !reason.startsWith('FAIL:')) {
      if (m.remove(k) == null) return;
    } else {
      m[k] = reason;
    }
    _writeJson(j, m);
  } catch (_) {}
}

Map<String, String> readLyricFails(String dir) => _readJson(
  _journal(dir),
).map((String k, dynamic v) => MapEntry<String, String>(k, '$v'));

/// Archivos que viajan con la pista.
List<String> companionsOf(String mp3) {
  final String d = _dirOf(mp3);
  final String s = _stem(_nameOf(mp3));
  return <String>[
    mp3,
    '$d$_sep$s.lrc',
    '$d$_sep$s.lrc.bak',
    '$d$_sep$s.gmx_words.json',
    '$d$_sep${s}_K.mp3',
    '$d$_sep${s}_K.lrc',
  ].where((String p) => File(p).existsSync()).toList();
}

class LabMove {
  final String fileName;
  final String from;
  final String reason;
  const LabMove(this.fileName, this.from, this.reason);
}

/// Mueve al Laboratorio las pistas con FAIL de letra de [dir].
/// Opcional: [only] filtra por motivo (p. ej. solo `FAIL:lyric_wrong_song`).
List<LabMove> moveFailsToLab(
  String dir,
  String labDir, {
  bool Function(String reason)? only,
}) {
  final Map<String, String> fails = readLyricFails(dir);
  if (fails.isEmpty) return const <LabMove>[];
  Directory(labDir).createSync(recursive: true);
  final File regF = File('$labDir$_sep$labRegistryName');
  final Map<String, dynamic> reg = _readJson(regF);
  final List<LabMove> out = <LabMove>[];
  for (final MapEntry<String, String> e in fails.entries) {
    if (only != null && !only(e.value)) continue;
    final String mp3 = '$dir$_sep${e.key}';
    if (!File(mp3).existsSync()) continue;
    final List<String> files = companionsOf(mp3);
    // Nunca pisar: si algo ya existe en el LAB, se deja quieta.
    if (files.any(
      (String p) => File('$labDir$_sep${_nameOf(p)}').existsSync(),
    )) {
      continue;
    }
    for (final String p in files) {
      File(p).renameSync('$labDir$_sep${_nameOf(p)}');
    }
    reg[e.key] = mp3;
    out.add(LabMove(e.key, mp3, e.value));
  }
  if (out.isNotEmpty) {
    _writeJson(regF, reg);
    final Map<String, dynamic> m = _readJson(_journal(dir));
    for (final LabMove mv in out) {
      m.remove(mv.fileName);
    }
    _writeJson(_journal(dir), m);
    // El FAIL viaja al LAB para que el modo rescate sepa qué intentar.
    final Map<String, dynamic> lj = _readJson(_journal(labDir));
    for (final LabMove mv in out) {
      lj[mv.fileName] = mv.reason;
    }
    _writeJson(_journal(labDir), lj);
  }
  return out;
}

/// Devuelve a su carpeta original las pistas del LAB que ya no fallan
/// (tras pasar el Masterizar en el LAB). Solo las que vinieron por registro.
List<String> restoreFixedFromLab(String labDir) {
  final File regF = File('$labDir$_sep$labRegistryName');
  final Map<String, dynamic> reg = _readJson(regF);
  final Map<String, String> fails = readLyricFails(labDir);
  final List<String> back = <String>[];
  for (final String name in reg.keys.toList()) {
    if (fails.containsKey(name)) continue;
    final String mp3 = '$labDir$_sep$name';
    final String origin = '${reg[name]}';
    if (!File(mp3).existsSync() || origin.isEmpty) continue;
    final String toDir = _dirOf(origin);
    if (!Directory(toDir).existsSync()) continue;
    final List<String> files = companionsOf(mp3);
    if (files.any(
      (String p) => File('$toDir$_sep${_nameOf(p)}').existsSync(),
    )) {
      continue;
    }
    for (final String p in files) {
      File(p).renameSync('$toDir$_sep${_nameOf(p)}');
    }
    reg.remove(name);
    back.add(origin);
  }
  if (back.isNotEmpty) _writeJson(regF, reg);
  return back;
}
