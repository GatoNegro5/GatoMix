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
bool lanIsKaraokeMp3(String name) => lanBaseName(name).toLowerCase().endsWith('_k.mp3');

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
