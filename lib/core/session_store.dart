import 'dart:convert';
import 'dart:io';

import 'audio_path.dart';

/// Guardado de sesión a prueba de cortes y de actualizaciones.
///
/// - Escribe en `<archivo>.tmp` y renombra: el archivo nunca queda a medias
///   aunque la app se cierre (o se mate para instalar otra versión) en medio.
/// - Las escrituras de un mismo archivo van en fila: dos guardados seguidos
///   ya no se pisan (antes podían dejar JSON con basura al final → la cola
///   se perdía y el modo volvía a Secuencial).
/// - Guarda copia `<archivo>.bak` del último JSON válido; si el principal está
///   dañado, se lee la copia.
class SessionStore {
  static final Map<String, Future<void>> _chains = <String, Future<void>>{};
  static final Map<String, int> _generation = <String, int>{};

  static int generationOf(String path) => _generation[path] ?? 0;

  /// El siguiente guardado de [path] queda inválido. Un clear lo usa para
  /// que una escritura ya en fila no vuelva a poner la cola vieja.
  static void invalidate(String path) {
    _generation[path] = (_generation[path] ?? 0) + 1;
  }

  static Future<void> writeJson(String path, Object data, {int? generation}) {
    final int stamp = generation ?? (_generation[path] ?? 0);
    final String text = jsonEncode(data);
    final Future<void> prev = _chains[path] ?? Future<void>.value();
    final Future<void> next = prev.catchError((_) {}).then((_) async {
      if ((_generation[path] ?? 0) != stamp) return;
      await _writeAtomic(path, text);
    });
    _chains[path] = next;
    return next;
  }

  static void writeJsonSync(String path, Object data) {
    _writeAtomicSync(path, jsonEncode(data));
  }

  static Future<void> _writeAtomic(String path, String text) async {
    try {
      _writeAtomicSync(path, text);
    } catch (_) {}
  }

  static void _writeAtomicSync(String path, String text) {
    final File target = File(path);
    target.parent.createSync(recursive: true);
    // Copia del último guardado válido antes de reemplazarlo.
    if (target.existsSync()) {
      try {
        final String old = target.readAsStringSync();
        jsonDecode(old);
        File('$path.bak').writeAsStringSync(old, flush: true);
      } catch (_) {}
    }
    final File tmp = File('$path.tmp');
    tmp.writeAsStringSync(text, flush: true);
    try {
      tmp.renameSync(path);
    } catch (_) {
      // Windows con el destino bloqueado: copia directa como último recurso.
      target.writeAsStringSync(text, flush: true);
      try {
        tmp.deleteSync();
      } catch (_) {}
    }
  }

  /// JSON del archivo principal o, si falta o está dañado, de la copia.
  static dynamic readJson(String path) {
    for (final String p in <String>[path, '$path.tmp', '$path.bak']) {
      try {
        final File f = File(p);
        if (!f.existsSync()) continue;
        final String text = f.readAsStringSync();
        if (text.trim().isEmpty) continue;
        return jsonDecode(text);
      } catch (_) {}
    }
    return null;
  }
}

/// ¿Hace falta volver a escribir la sesión por este movimiento del reloj?
///
/// Un avance de más de 15 s, o un seek real hacia atrás. Un glitch a 0
/// (el reloj de media_kit a veces intercala `Duration.zero`) no cuenta:
/// si contara, cada tick reescribiría el JSON con fsync y el procesador
/// se queda caliente.
bool sessionPositionShouldSave(int posMs, int lastSavedMs) {
  final int delta = posMs - lastSavedMs;
  if (delta > 15000) return true;
  if (delta < -2000 && posMs > 500) return true;
  return false;
}

/// Clave de nombre para reencontrar una pista que Masterizar renombró
/// (limpieza de nombre): minúsculas, solo letras/dígitos, sin "bpm" ni
/// sufijos de versión.
String trackNameKey(String path) {
  String name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  final int dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  name = name
      .replaceAll(RegExp(r'\d{2,3}(?:\.\d+)?\s*bpm'), ' ')
      .replaceAll(
        RegExp(r'\((?:official|lyrics?|video|audio|hq|hd)[^)]*\)'),
        ' ',
      )
      .replaceAll(RegExp(r'[^a-z0-9]+'), '');
  return name;
}

/// Devuelve las rutas que siguen existiendo. Si una ya no existe, la busca
/// en su misma carpeta por [trackNameKey] (renombrada por Masterizar).
/// Nunca descarta en silencio una pista que se puede reencontrar.
List<String> resolveSessionPaths(
  List<String> paths, {
  bool Function(String path)? exists,
  List<String> Function(String dir)? listDir,
  bool? foldCase,
}) {
  final bool Function(String) ex = exists ?? (p) => File(p).existsSync();
  final List<String> Function(String) ls =
      listDir ??
      (String dir) {
        try {
          return Directory(
            dir,
          ).listSync().whereType<File>().map((f) => f.path).toList();
        } catch (_) {
          return const <String>[];
        }
      };
  final Map<String, Map<String, String>> dirIndex =
      <String, Map<String, String>>{};
  final Set<String> used = <String>{};
  final List<String> out = <String>[];
  String keyOf(String p) => audioPathKey(p, foldCase: foldCase);
  for (final String p in paths) {
    if (ex(p)) {
      if (used.add(keyOf(p))) out.add(p);
      continue;
    }
    final int cut = p.replaceAll('\\', '/').lastIndexOf('/');
    if (cut <= 0) continue;
    final String dir = p.substring(0, cut);
    final Map<String, String> idx = dirIndex.putIfAbsent(dir, () {
      final Map<String, String> m = <String, String>{};
      for (final String f in ls(dir)) {
        final String low = f.toLowerCase();
        if (!(low.endsWith('.mp3') ||
            low.endsWith('.m4a') ||
            low.endsWith('.flac') ||
            low.endsWith('.wav') ||
            low.endsWith('.ogg'))) {
          continue;
        }
        m.putIfAbsent(trackNameKey(f), () => f);
      }
      return m;
    });
    final String? hit = idx[trackNameKey(p)];
    if (hit != null && used.add(keyOf(hit))) out.add(hit);
  }
  return out;
}

/// Pista _K de Karaoke (solo TV): nunca se restaura en Automix ni Live DJ.
bool isKaraokeSessionPath(String path) => isKaraokeAudioPath(path);

/// Como [resolveSessionPaths] pero sin pistas _K (cola, actual y Shuffle).
List<String> resolvePlayableSessionPaths(
  List<String> paths, {
  bool Function(String path)? exists,
  List<String> Function(String dir)? listDir,
  bool? foldCase,
}) => resolveSessionPaths(
  paths.where((p) => !isKaraokeSessionPath(p)).toList(),
  exists: exists,
  listDir: listDir,
  foldCase: foldCase,
).where((p) => !isKaraokeSessionPath(p)).toList();
