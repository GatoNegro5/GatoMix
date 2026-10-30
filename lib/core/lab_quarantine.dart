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

import 'gatomix_store.dart';

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

/// Anota (o quita, si [reason] es null/vacío) el FAIL de letra de [mp3].
void recordLyricFailSync(String mp3, String? reason) {
  try {
    final String dir = _dirOf(mp3);
    final Map<String, dynamic> m = readLyricFailMap(dir);
    final String k = _nameOf(mp3);
    if (reason == null || reason.isEmpty || !reason.startsWith('FAIL:')) {
      if (m.remove(k) == null) return;
    } else {
      m[k] = reason;
    }
    writeLyricFailMap(dir, m);
  } catch (_) {}
}

Map<String, String> readLyricFails(String dir) =>
    readLyricFailMap(dir)
        .map((String k, dynamic v) => MapEntry<String, String>(k, '$v'));

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
    final Map<String, dynamic> m = readLyricFailMap(dir);
    for (final LabMove mv in out) {
      m.remove(mv.fileName);
    }
    writeLyricFailMap(dir, m);
    // El FAIL viaja al LAB para que el modo rescate sepa qué intentar.
    final Map<String, dynamic> lj = readLyricFailMap(labDir);
    for (final LabMove mv in out) {
      lj[mv.fileName] = mv.reason;
    }
    writeLyricFailMap(labDir, lj);
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

const String labManualOriginLabel =
    'Origen Desconocido (Inyección Manual OS)';

const List<String> labAudioExtensions = <String>[
  '.mp3',
  '.m4a',
  '.webm',
  '.wav',
  '.flac',
];

/// Segundo envío al LAB mientras otro espera la mezcla: entra a la cola,
/// sin repetir la pista que ya va ni una que ya esté encolada.
List<String> enqueueLabSend(
  List<String> queue,
  String track, {
  String? inFlight,
}) {
  if (track.isEmpty) return List<String>.from(queue);
  if (inFlight != null && inFlight == track) return List<String>.from(queue);
  if (queue.contains(track)) return List<String>.from(queue);
  return List<String>.from(queue)..add(track);
}

bool _sameFile(String a, String b) =>
    File(a).absolute.path == File(b).absolute.path;

String lrcBesideAudio(String audio) {
  final RegExp ext = RegExp(
    r'\.(mp3|m4a|wav|flac|webm|ogg|aac)$',
    caseSensitive: false,
  );
  if (ext.hasMatch(audio)) return audio.replaceAll(ext, '.lrc');
  return '$audio.lrc';
}

/// `<base>_K.mp3`, el mismo corte de [KaraokeEngine.karaokePathFor].
String karaokeMp3Beside(String audio) {
  final int dot = audio.lastIndexOf('.');
  if (dot <= 0) return '${audio}_K.mp3';
  return '${audio.substring(0, dot)}_K.mp3';
}

String karaokeLrcBeside(String audio) =>
    karaokeMp3Beside(audio).replaceAll(RegExp(r'\.mp3$'), '.lrc');

/// Mueve [src] a [dest]. No pisa. Si `rename` cruza de volumen, copia y borra.
void moveOneNoOverwriteSync(String src, String dest) {
  if (File(dest).existsSync() || Directory(dest).existsSync()) {
    throw FileSystemException('destino ocupado', dest);
  }
  final File s = File(src);
  try {
    s.renameSync(dest);
  } on FileSystemException {
    final int len = s.lengthSync();
    final File copy = s.copySync(dest);
    if (copy.lengthSync() != len) {
      try {
        copy.deleteSync();
      } catch (_) {}
      throw FileSystemException('Copia incompleta', src);
    }
    s.deleteSync();
  }
}

/// Ida al LAB. Si cualquier compañero ya está en [destDir], no mueve nada.
bool moveCompanionsToSync(String audioPath, String destDir) {
  final List<String> files = companionsOf(audioPath);
  if (files.isEmpty) return false;
  if (files.any(
    (String p) => File('$destDir$_sep${_nameOf(p)}').existsSync(),
  )) {
    return false;
  }
  Directory(destDir).createSync(recursive: true);
  for (final String p in files) {
    moveOneNoOverwriteSync(p, '$destDir$_sep${_nameOf(p)}');
  }
  return true;
}

class LabReturn {
  final bool blocked;
  final bool lrcKeptAtOrigin;
  const LabReturn({required this.blocked, this.lrcKeptAtOrigin = false});
}

/// Regreso a la carpeta original. Si el audio de destino ya existe, no mueve
/// nada. El resto de compañeros se mueve solo si su destino está libre.
LabReturn restoreCompanionsToSync({
  required String labAudio,
  required String originAudio,
}) {
  final List<String> files = companionsOf(labAudio);
  if (File(originAudio).existsSync() && !_sameFile(labAudio, originAudio)) {
    return const LabReturn(blocked: true);
  }
  final String originDir = _dirOf(originAudio);
  final String labLrc = lrcBesideAudio(labAudio);
  final String originLrc = lrcBesideAudio(originAudio);
  if (File(labAudio).existsSync() && !_sameFile(labAudio, originAudio)) {
    moveOneNoOverwriteSync(labAudio, originAudio);
  }
  var lrcKept = false;
  for (final String p in files) {
    if (_sameFile(p, labAudio)) continue;
    if (!File(p).existsSync()) continue;
    final bool isMainLrc = _sameFile(p, labLrc);
    final String dest = isMainLrc
        ? originLrc
        : '$originDir$_sep${_nameOf(p)}';
    if (_sameFile(p, dest)) continue;
    if (File(dest).existsSync()) {
      if (isMainLrc) lrcKept = true;
      continue;
    }
    moveOneNoOverwriteSync(p, dest);
  }
  return LabReturn(blocked: false, lrcKeptAtOrigin: lrcKept);
}

/// Borra el karaoke viejo (`<base>_K.mp3` y `<base>_K.lrc`). No toca el audio.
List<String> deleteStaleKaraokeSync(String audioPath) {
  final List<String> gone = <String>[];
  for (final String p in <String>[
    karaokeMp3Beside(audioPath),
    karaokeLrcBeside(audioPath),
  ]) {
    final File f = File(p);
    if (!f.existsSync()) continue;
    f.deleteSync();
    gone.add(p);
  }
  return gone;
}

/// Tras el rescate: mp3, .lrc, .lrc.bak, .gmx_words.json y, si
/// [includeKaraoke], el `_K` (mp3 y .lrc) del mismo base.
/// Si el audio de destino es otro archivo, no mueve nada.
/// Tras una entrega buena, quita la pista de [labRegistryName].
void deliverRescuedTrackSync(
  String audioPath,
  String originDir, {
  required bool includeKaraoke,
}) {
  final String audioName = _nameOf(audioPath);
  final String audioDest = '$originDir$_sep$audioName';
  if (File(audioDest).existsSync() && !_sameFile(audioPath, audioDest)) {
    return;
  }
  final String kMp3 = karaokeMp3Beside(audioPath);
  final String kLrc = karaokeLrcBeside(audioPath);
  final List<String> srcs = companionsOf(audioPath).where((String p) {
    if (includeKaraoke) return true;
    return !_sameFile(p, kMp3) && !_sameFile(p, kLrc);
  }).toList();
  for (final String p in srcs) {
    if (!File(p).existsSync()) continue;
    final String dest = '$originDir$_sep${_nameOf(p)}';
    if (_sameFile(p, dest)) continue;
    if (File(dest).existsSync()) continue;
    moveOneNoOverwriteSync(p, dest);
  }
  if (!File(audioDest).existsSync()) return;
  final File regF = File('${_dirOf(audioPath)}$_sep$labRegistryName');
  if (!regF.existsSync()) return;
  final Map<String, dynamic> reg = _readJson(regF);
  if (reg.remove(audioName) == null) return;
  _writeJson(regF, reg);
}

/// Vuelve a armar el mapa del LAB con lo que hay ahora en la carpeta.
Map<String, dynamic> rescanLabRegistry(
  String labDir,
  Map<String, dynamic> registry,
) {
  final List<String> physicalFiles = Directory(labDir)
      .listSync()
      .whereType<File>()
      .map((File e) => _nameOf(e.path))
      .toList();
  final Map<String, dynamic> next = Map<String, dynamic>.from(registry);
  next.removeWhere((String key, dynamic _) => !physicalFiles.contains(key));
  for (final String fileName in physicalFiles) {
    final bool isAudio = labAudioExtensions.any(
      (String ext) => fileName.toLowerCase().endsWith(ext),
    );
    if (isAudio && !next.containsKey(fileName)) {
      next[fileName] = labManualOriginLabel;
    }
  }
  return next;
}
