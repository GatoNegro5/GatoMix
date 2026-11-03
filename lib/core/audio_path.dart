import 'dart:io';

/// Identidad de un audio en disco.
///
/// La clave es la ruta absoluta con separadores `/`, segmentos `.` y `..`
/// resueltos y Unicode NFC. En Windows, macOS e iOS no distingue mayúsculas
/// (el sistema de archivos tampoco). No incluye mtime ni tamaño: reescribir
/// tags o el `.lrc` actualiza la misma entrada, no agrega otra.
bool audioPathFoldsCase() =>
    Platform.isWindows || Platform.isMacOS || Platform.isIOS;

/// Pista `_K` de Karaoke (solo TV). No entra en colas de Automix ni Live DJ.
bool isKaraokeAudioPath(String path) =>
    RegExp(r'_k\.[a-z0-9]+$', caseSensitive: false).hasMatch(path);

/// Ruta canónica si el archivo existe (enlaces y junctions). Si no, tal cual.
String canonicalAudioPath(String path) {
  try {
    final File f = File(path);
    if (f.existsSync()) {
      final String resolved = f.resolveSymbolicLinksSync();
      if (resolved.isNotEmpty) return resolved;
    }
  } catch (_) {}
  return path;
}

/// Clave de comparación. [absolute] antepone el directorio de trabajo a las
/// rutas relativas. [foldCase] null usa [audioPathFoldsCase].
String audioPathKey(
  String path, {
  bool? foldCase,
  bool absolute = true,
  String? workingDirectory,
}) {
  var p = _stripFileUri(path).trim();
  p = p.replaceAll('\\', '/');
  p = _nfc(p);
  final bool abs = p.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(p);
  if (absolute && !abs && p.isNotEmpty) {
    final String base = (workingDirectory ?? Directory.current.path)
        .replaceAll('\\', '/');
    p = '$base/$p';
  }
  p = _collapse(p);
  if (p.length > 1 && p.endsWith('/') && !RegExp(r'^[A-Za-z]:/$').hasMatch(p)) {
    p = p.substring(0, p.length - 1);
  }
  if (foldCase ?? audioPathFoldsCase()) p = p.toLowerCase();
  return p;
}

/// Misma canción aunque cambien separadores, mayúsculas (Win/macOS/iOS) o NFC.
bool sameAudioPath(String? a, String? b, {bool? foldCase}) {
  if (a == null || b == null || a.isEmpty || b.isEmpty) return false;
  return audioPathKey(a, foldCase: foldCase) ==
      audioPathKey(b, foldCase: foldCase);
}

/// Primera aparición de cada clave. Mantiene el texto original de esa entrada.
List<String> dedupeAudioPaths(
  List<String> paths, {
  bool? foldCase,
  bool dropKaraoke = false,
}) {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final String p in paths) {
    if (dropKaraoke && isKaraokeAudioPath(p)) continue;
    if (seen.add(audioPathKey(p, foldCase: foldCase))) out.add(p);
  }
  return out;
}

/// Como [dedupeAudioPaths] pero guarda la ruta resuelta en disco.
List<File> dedupeAudioFiles(List<File> files, {bool dropKaraoke = true}) {
  final List<File> out = <File>[];
  final Set<String> seen = <String>{};
  for (final File f in files) {
    if (dropKaraoke && isKaraokeAudioPath(f.path)) continue;
    final String canon = canonicalAudioPath(f.path);
    if (seen.add(audioPathKey(canon))) out.add(File(canon));
  }
  return out;
}

/// Siguiente índice que no es la pista que suena. -1 si no hay otra.
/// Con una sola pista devuelve -1 (no se mezcla consigo misma).
int nextDifferentAudioIndex(
  List<String> paths,
  int currentIndex,
  String? currentPath, {
  bool? foldCase,
}) {
  if (paths.length <= 1) return -1;
  bool same(String p) =>
      currentPath != null && sameAudioPath(p, currentPath, foldCase: foldCase);
  final int start = currentIndex < 0 ? -1 : currentIndex;
  for (var step = 1; step <= paths.length; step++) {
    final int i = (start + step) % paths.length;
    if (!same(paths[i])) return i;
  }
  return -1;
}

String _stripFileUri(String path) {
  final String t = path.trim();
  if (!t.toLowerCase().startsWith('file:')) return t;
  try {
    final bool win = RegExp(r'^[a-zA-Z]:').hasMatch(t) || t.contains(':');
    return Uri.parse(t).toFilePath(windows: win && t.contains(':'));
  } catch (_) {
    return t;
  }
}

String _collapse(String slash) {
  final bool rooted = slash.startsWith('/');
  final List<String> parts = slash.split('/');
  final List<String> out = <String>[];
  for (var i = 0; i < parts.length; i++) {
    final String s = parts[i];
    if (s.isEmpty || s == '.') {
      if (i == 0 && s.isEmpty) out.add('');
      if (rooted &&
          i == 1 &&
          s.isEmpty &&
          out.length == 1 &&
          out.first.isEmpty) {
        out.add('');
      }
      continue;
    }
    if (s == '..') {
      if (out.isNotEmpty && out.last.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else if (!rooted) {
        out.add('..');
      }
      continue;
    }
    out.add(s);
  }
  return out.join('/');
}

/// NFC de las marcas latinas que aparecen en nombres de canciones
/// (á, é, ñ, ü…). Una marca combinante se funde con la letra anterior.
String _nfc(String input) {
  final List<int> out = <int>[];
  for (final int c in input.codeUnits) {
    if (out.isNotEmpty) {
      final int? composed = _compose(out.last, c);
      if (composed != null) {
        out[out.length - 1] = composed;
        continue;
      }
    }
    out.add(c);
  }
  return String.fromCharCodes(out);
}

int? _compose(int base, int mark) {
  const Map<int, Map<int, int>> table = <int, Map<int, int>>{
    // grave, acute, circumflex, tilde, diaeresis, ring, cedilla, caron, stroke
    0x41: {0x300: 0xC0, 0x301: 0xC1, 0x302: 0xC2, 0x303: 0xC3, 0x308: 0xC4, 0x30A: 0xC5},
    0x61: {0x300: 0xE0, 0x301: 0xE1, 0x302: 0xE2, 0x303: 0xE3, 0x308: 0xE4, 0x30A: 0xE5},
    0x45: {0x300: 0xC8, 0x301: 0xC9, 0x302: 0xCA, 0x308: 0xCB},
    0x65: {0x300: 0xE8, 0x301: 0xE9, 0x302: 0xEA, 0x308: 0xEB},
    0x49: {0x300: 0xCC, 0x301: 0xCD, 0x302: 0xCE, 0x308: 0xCF},
    0x69: {0x300: 0xEC, 0x301: 0xED, 0x302: 0xEE, 0x308: 0xEF},
    0x4F: {0x300: 0xD2, 0x301: 0xD3, 0x302: 0xD4, 0x303: 0xD5, 0x308: 0xD6},
    0x6F: {0x300: 0xF2, 0x301: 0xF3, 0x302: 0xF4, 0x303: 0xF5, 0x308: 0xF6},
    0x55: {0x300: 0xD9, 0x301: 0xDA, 0x302: 0xDB, 0x308: 0xDC},
    0x75: {0x300: 0xF9, 0x301: 0xFA, 0x302: 0xFB, 0x308: 0xFC},
    0x4E: {0x303: 0xD1},
    0x6E: {0x303: 0xF1},
    0x43: {0x327: 0xC7},
    0x63: {0x327: 0xE7},
    0x59: {0x301: 0xDD, 0x308: 0x178},
    0x79: {0x301: 0xFD, 0x308: 0xFF},
  };
  return table[base]?[mark];
}
