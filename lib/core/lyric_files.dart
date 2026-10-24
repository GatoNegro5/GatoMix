import 'dart:async';
import 'dart:io';

/// Escribe [text] en el `.lrc`. El `.lrc.bak` guarda SIEMPRE el original
/// previo al LAB: se crea solo la primera vez y nunca se pisa, así aplicar
/// o guardar varias veces no pierde la letra original.
///
/// Deshacer ([undoAppliedLrc]) vuelve a ese original (o borra el `.lrc` si
/// antes no había ninguno). No es un historial paso a paso.
Future<void> writeLrcKeepingBak(String lrcPath, String text) async {
  final File f = File(lrcPath);
  keepOriginalLrcBakSync(lrcPath);
  await f.writeAsString(text);
}

/// Copia el `.lrc` a `.lrc.bak` solo si aún no existe un `.bak`.
/// True si creó la copia.
/// Si antes no había `.lrc`, el `.bak` queda con [kLrcNoOriginalMark] para
/// que Deshacer sepa que debe borrar (y no volver a una versión del LAB).
bool keepOriginalLrcBakSync(String lrcPath) {
  final File f = File(lrcPath);
  final File bak = File('$lrcPath.bak');
  if (bak.existsSync()) return false;
  if (f.existsSync()) {
    f.copySync(bak.path);
  } else {
    bak.writeAsStringSync('$kLrcNoOriginalMark\n');
  }
  return true;
}

/// Contenido del `.lrc.bak` cuando no existía `.lrc` antes del LAB.
const String kLrcNoOriginalMark = '[gmx_no_original:1]';

bool _bakIsNoOriginal(File bak) {
  try {
    return bak.readAsStringSync().trim() == kLrcNoOriginalMark;
  } catch (_) {
    return false;
  }
}

/// Extensiones de audio que maneja el LAB.
const List<String> kLabAudioExts = <String>[
  'mp3',
  'm4a',
  'wav',
  'flac',
  'webm',
  'ogg',
  'aac',
];

final RegExp _labAudioExt = RegExp(
  r'\.(mp3|m4a|wav|flac|webm|ogg|aac)$',
  caseSensitive: false,
);

/// `canción.<audio>` -> `canción.lrc` (cualquier extensión de audio).
String lrcPathForAudio(String audioPath) {
  if (_labAudioExt.hasMatch(audioPath)) {
    return audioPath.replaceAll(_labAudioExt, '.lrc');
  }
  return '$audioPath.lrc';
}

/// Borra el `.lrc` y el `.lrc.bak` de un audio. Devuelve los borrados.
List<String> deleteLrcSidecarsSync(String audioPath) {
  final String lrc = lrcPathForAudio(audioPath);
  final List<String> gone = <String>[];
  for (final String p in <String>[lrc, '$lrc.bak']) {
    final File f = File(p);
    if (f.existsSync()) {
      f.deleteSync();
      gone.add(p);
    }
  }
  return gone;
}

enum LabMove { moved, destExists, missing }

/// Mueve [src] a [dest] sin pisar nunca un archivo existente. Si `rename`
/// falla (p. ej. entre volúmenes/SD), copia, verifica el tamaño y recién
/// entonces borra el origen; si la verificación falla, deja el origen.
Future<LabMove> moveFileNoOverwrite(String src, String dest) async {
  final File s = File(src);
  if (!s.existsSync()) return LabMove.missing;
  if (File(dest).existsSync() || Directory(dest).existsSync()) {
    return LabMove.destExists;
  }
  try {
    await s.rename(dest);
    return LabMove.moved;
  } on FileSystemException {
    final int len = await s.length();
    final File copy = await s.copy(dest);
    if (await copy.length() != len) {
      try {
        await copy.delete();
      } catch (_) {}
      throw FileSystemException('Copia incompleta, el original queda', src);
    }
    await s.delete();
    return LabMove.moved;
  }
}

/// Restaura `.lrc.bak` sobre el `.lrc`. False si no hay copia.
Future<bool> restoreLrcBak(String lrcPath) async {
  final File bak = File('$lrcPath.bak');
  if (!bak.existsSync()) return false;
  if (_bakIsNoOriginal(bak)) {
    final File f = File(lrcPath);
    if (f.existsSync()) await f.delete();
    return true;
  }
  await bak.copy(lrcPath);
  return true;
}

/// Deshace un Aplicar. Si había `.lrc`, vuelve el `.bak`. Si no había, borra el nuevo.
Future<bool> undoAppliedLrc(String lrcPath) async {
  final File bak = File('$lrcPath.bak');
  final File f = File(lrcPath);
  if (bak.existsSync()) {
    if (_bakIsNoOriginal(bak)) {
      if (f.existsSync()) await f.delete();
      await bak.delete();
      return true;
    }
    await bak.copy(lrcPath);
    return true;
  }
  if (f.existsSync()) {
    await f.delete();
    return true;
  }
  return false;
}

/// True si hay un `.lrc.bak` con una letra original (no la marca sin-original).
bool lrcBakExists(String lrcPath) {
  final File bak = File('$lrcPath.bak');
  return bak.existsSync() && !_bakIsNoOriginal(bak);
}

final StreamController<String> _lrcChanges =
    StreamController<String>.broadcast();

/// Audios cuyo `.lrc` cambió (Buscar letra, Deshacer, Restaurar). Automix y
/// Karaoke lo escuchan para releer la letra si es el tema que tienen abierto.
Stream<String> get lrcChanges => _lrcChanges.stream;

void notifyLrcChanged(String audioPath) {
  if (audioPath.isNotEmpty) _lrcChanges.add(audioPath);
}

/// Misma ruta de audio con `\` o `/`; sin distinguir mayúsculas en Windows.
bool sameAudioPath(String? a, String? b) {
  if (a == null || b == null || a.isEmpty || b.isEmpty) return false;
  String n(String p) {
    final String x = p.replaceAll('\\', '/');
    return Platform.isWindows ? x.toLowerCase() : x;
  }

  return n(a) == n(b);
}

enum LabLrcRestore { none, moved, keptOrigin }

/// Restaurar al Origen: mueve el `.lrc` del LAB junto al audio y borra solo
/// `<lrc del LAB>.bak`. Si en origen ya hay `.lrc`, no se sobrescribe: la
/// letra del LAB y su `.bak` se quedan en el LAB.
Future<LabLrcRestore> moveLabLrcToOrigin({
  required String labLrcPath,
  required String originLrcPath,
}) async {
  final File lab = File(labLrcPath);
  final File bak = File('$labLrcPath.bak');
  if (!lab.existsSync()) {
    if (bak.existsSync()) await bak.delete();
    return LabLrcRestore.none;
  }
  final LabMove m = await moveFileNoOverwrite(labLrcPath, originLrcPath);
  if (m == LabMove.destExists) return LabLrcRestore.keptOrigin;
  if (bak.existsSync()) await bak.delete();
  return LabLrcRestore.moved;
}
