import 'dart:io';

/// Nombre de la carpeta anterior a 1.0.0. Va partido a propósito: el nombre
/// viejo completo está solo en CHANGELOG.md.
const legacyBrand =
    'DJ'
    'Studio';

/// `%LOCALAPPDATA%\GatoMix` (y el equivalente en macOS/Linux). Si todavía
/// existe la carpeta anterior y la nueva no, la renombra en silencio.
Directory ensureBrandDataDir(String base) {
  final sep = Platform.pathSeparator;
  final next = Directory('$base${sep}GatoMix');
  final prev = Directory('$base$sep$legacyBrand');
  if (!next.existsSync() && prev.existsSync()) {
    try {
      prev.renameSync(next.path);
    } catch (_) {}
  }
  if (!next.existsSync()) next.createSync(recursive: true);
  return next;
}

/// True si [path] está dentro de la carpeta de laboratorio.
bool pathIsLab(String path) {
  final String legacy = '${legacyBrand}_LAB';
  for (final String part in path.replaceAll('\\', '/').split('/')) {
    if (part == 'GatoMix_LAB' || part == legacy) return true;
  }
  return false;
}

/// Carpeta de laboratorio junto a [base]. Migra el directorio anterior.
String labFolder(String base) {
  final sep = Platform.pathSeparator;
  final next = Directory('$base${sep}GatoMix_LAB');
  final prev = Directory('$base$sep${legacyBrand}_LAB');
  if (!next.existsSync() && prev.existsSync()) {
    try {
      prev.renameSync(next.path);
    } catch (_) {}
  }
  return next.path;
}

/// Cuarentena junto al archivo dañado. Migra la carpeta anterior.
Directory quarantineDir(String parent) {
  final sep = Platform.pathSeparator;
  final next = Directory('$parent${sep}Cuarentena_GatoMix');
  final prev = Directory(
    '$parent$sep'
    'Cuarentena_$legacyBrand',
  );
  if (!next.existsSync() && prev.existsSync()) {
    try {
      prev.renameSync(next.path);
    } catch (_) {}
  }
  if (!next.existsSync()) next.createSync();
  return next;
}
