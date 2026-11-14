/// 3.1.05: reglas puras de LAN Sync (sin I/O), iguales en las 4 plataformas.
/// Nombres sin distinguir mayusculas: Android e iPhone si las distinguen;
/// Windows y macOS no.
library;

/// Sufijo del archivo temporal mientras llega una pista.
const String lanPartSuffix = '.part';

/// Nombre del archivo (acepta `/` y `\`).
String lanBaseName(String path) {
  final int cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

/// Temporal de un envio cortado: nunca se lista ni viaja.
bool lanIsPart(String name) => name.toLowerCase().endsWith(lanPartSuffix);

/// 3.1.15: pista karaoke `<base>_K.mp3` (sus `.lrc`/`.txt` viajan siempre).
bool lanIsKaraokeMp3(String name) =>
    lanBaseName(name).toLowerCase().endsWith('_k.mp3');

/// Lo que LAN Sync lista y envia: `.mp3`, `.lrc`, `.txt`; nunca `.part`.
bool lanSyncable(String name) {
  final String n = name.toLowerCase();
  if (lanIsPart(n)) return false;
  return n.endsWith('.mp3') || n.endsWith('.lrc') || n.endsWith('.txt');
}

/// Interfaz Wi-Fi: `wlan0` (Android), `Wi-Fi` (Windows), `en0` (macOS/iPhone).
bool lanIsWlanName(String name) {
  final String n = name.toLowerCase();
  return n.contains('wlan') ||
      n.contains('wi-fi') ||
      n.contains('wifi') ||
      n == 'en0';
}

/// Hermanos de [mp3Name] en [siblings] (misma carpeta): `.lrc`, `.txt`,
/// `_K.mp3`, `_K.lrc`, `_K.txt` y, si se eligio el `_K`, la pista normal.
/// Sin distinguir mayusculas; nunca `.part`; devuelve el nombre real en disco.
/// 3.1.15: con [withKaraoke] en false no agrega el `_K.mp3` hermano.
List<String> lanCompanions(
  String mp3Name,
  Iterable<String> siblings, {
  bool withKaraoke = true,
}) {
  final String lower = mp3Name.toLowerCase();
  if (!lower.endsWith('.mp3') || lanIsPart(lower)) return const <String>[];
  String base = lower.substring(0, lower.length - 4);
  if (base.endsWith('_k')) base = base.substring(0, base.length - 2);
  final Set<String> want = <String>{
    '$base.mp3',
    '$base.lrc',
    '$base.txt',
    '${base}_k.mp3',
    '${base}_k.lrc',
    '${base}_k.txt',
  };
  final List<String> out = <String>[];
  for (final String s in siblings) {
    final String sl = s.toLowerCase();
    if (sl == lower || lanIsPart(sl)) continue;
    if (!withKaraoke && lanIsKaraokeMp3(sl)) continue;
    if (want.contains(sl)) out.add(s);
  }
  return out;
}

/// Nombre a usar en destino: si ya existe con otras mayusculas, ese.
String lanResolveName(Iterable<String> existing, String incoming) {
  final String want = incoming.toLowerCase();
  for (final String e in existing) {
    if (!lanIsPart(e) && e.toLowerCase() == want) return e;
  }
  return incoming;
}

Map<dynamic, dynamic>? _remoteEntry(Iterable<dynamic> remote, String name) {
  final String want = name.toLowerCase();
  for (final dynamic r in remote) {
    if (r is Map && '${r['name']}'.toLowerCase() == want) return r;
  }
  return null;
}

/// El remoto tiene un archivo con ese nombre (sin distinguir mayusculas).
bool lanRemoteHas(Iterable<dynamic> remote, String name) =>
    _remoteEntry(remote, name) != null;

/// Ya esta completo en el remoto: mismo nombre y mismo tamano. Un parcial de
/// otro tamano se reenvia. Sin `size_bytes` (receptor viejo) vale el nombre.
bool lanAlreadyThere(Iterable<dynamic> remote, String name, int sizeBytes) {
  final Map<dynamic, dynamic>? r = _remoteEntry(remote, name);
  if (r == null) return false;
  final dynamic size = r['size_bytes'];
  if (size is! int) return true;
  return size == sizeBytes;
}

/// 3.1.17: BPM que viaja por LAN Sync (numero o texto), en rango musical
/// 40-250; fuera de rango, NaN o vacio da 0.
double lanBpm(Object? value) {
  final double bpm = value is num
      ? value.toDouble()
      : double.tryParse('${value ?? ''}'.trim()) ?? 0;
  return (bpm >= 40 && bpm <= 250) ? bpm : 0;
}

/// 3.1.17: BPM recibido que el receptor guarda; 0 si no se guarda. Gana el
/// destino: si ya conoce un BPM ([localBpm], de nombre, etiquetas o su
/// `.gatomix.json`) no se pisa. Nunca viaja una ruta, solo el numero.
double lanBpmToSave({required double localBpm, required Object? incoming}) {
  if (lanBpm(localBpm) > 0) return 0;
  return lanBpm(incoming);
}

/// 3.1.17: parametro `&bpm=` para la URL de `/api/upload` ('' sin BPM
/// valido). Un receptor viejo ignora el parametro.
String lanBpmQuery(double bpm) {
  final double v = lanBpm(bpm);
  return v > 0 ? '&bpm=${v.toStringAsFixed(2)}' : '';
}

/// 3.1.36: carpetas auxiliares que nunca son DESTINO (ni sus subcarpetas):
/// Descargas, DjPlaylists, GatoMix_LAB y el LAB de la marca anterior.
const Set<String> lanHiddenDestFolders = <String>{
  'descargas',
  'djplaylists',
  'gatomix_lab',
  'dj'
      'studio_lab',
};

List<String> _lanSegs(String rel) => rel
    .replaceAll('\\', '/')
    .split('/')
    .where((String s) => s.isNotEmpty)
    .toList();

/// 3.1.36: quita el prefijo `ROOT` / `ROOT/` del destino remoto.
String lanStripRoot(String rel) {
  final String r = rel.replaceAll('\\', '/');
  if (r == 'ROOT') return '';
  if (r.startsWith('ROOT/')) return r.substring(5);
  return r;
}

/// 3.1.36: carpeta auxiliar (o dentro de una), sin distinguir mayusculas.
bool lanIsHiddenDest(String rel) {
  final List<String> s = _lanSegs(lanStripRoot(rel));
  return s.isNotEmpty && lanHiddenDestFolders.contains(s.first.toLowerCase());
}

/// 3.1.36: ruta remota insegura: `..`, absoluta (`/x`, `\\x`) o con unidad (`C:`).
bool lanUnsafeRel(String rel) {
  final String r = rel.replaceAll('\\', '/');
  if (r.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(r)) return true;
  return _lanSegs(r).any((String s) => s == '..' || s.contains(':'));
}

/// 3.1.36: dentro de `Musica/ReGenial` (biblioteca de produccion de la laptop).
bool lanUnderReGenial(String rel) {
  final List<String> s = _lanSegs(lanStripRoot(rel));
  return s.isNotEmpty && s.first.toLowerCase() == 'regenial';
}

/// 3.1.36: DESTINO de LAN Sync en las 4 plataformas: la carpeta referencia de
/// musica ([rootToken]) primero y luego el resto alfabetico, sin auxiliares.
List<String> lanDestFolders(Iterable<String> folders, String rootToken) {
  final List<String> rest =
      folders
          .where(
            (String f) => f.isNotEmpty && f != rootToken && !lanIsHiddenDest(f),
          )
          .toList()
        ..sort(
          (String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()),
        );
  return <String>[rootToken, ...rest];
}

/// 3.1.36: ruta relativa (con `/`) de [path] dentro de [base]; null si fuera.
String? lanRelUnder(String base, String path) {
  final String b = base.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final String p = path.replaceAll('\\', '/');
  if (b.isEmpty) return null;
  final String bl = b.toLowerCase();
  final String pl = p.toLowerCase();
  if (pl == bl) return '';
  if (!pl.startsWith('$bl/')) return null;
  return p.substring(b.length + 1);
}

/// 3.1.36: carpeta destino (con `/`) de [filePath] al clonar [selectedPath].
/// Estructura espejo: si la seleccion esta dentro de la raiz de Musica local
/// ([musicBase]) se conserva desde ahi (`ReGenial/Salsa`); si no, desde el
/// nombre de la carpeta elegida (comportamiento anterior).
String lanMirrorFolder({
  required String musicBase,
  required String selectedPath,
  required String filePath,
}) {
  final String f = filePath.replaceAll('\\', '/');
  final int cut = f.lastIndexOf('/');
  final String parent = cut < 0 ? '' : f.substring(0, cut);
  final String? underMusic = lanRelUnder(musicBase, selectedPath);
  if (underMusic != null && underMusic.isNotEmpty) {
    return lanRelUnder(musicBase, parent) ?? underMusic;
  }
  final List<String> sel = _lanSegs(selectedPath);
  final String name = sel.isEmpty ? '' : sel.last;
  final String sub = lanRelUnder(selectedPath, parent) ?? '';
  return sub.isEmpty ? name : '$name/$sub';
}

/// 3.1.36: carpeta que borra WIPE en un receptor movil (`Musica/<clonada>`);
/// null = no se borra nada (vacia, insegura, auxiliar u oculta).
String? lanWipeTarget(String? rel) {
  if (rel == null) return null;
  final String r = lanStripRoot(rel);
  final List<String> s = _lanSegs(r);
  if (s.isEmpty || lanUnsafeRel(r) || lanIsHiddenDest(r)) return null;
  if (s.any((String x) => x.startsWith('.'))) return null;
  return s.join('/');
}
