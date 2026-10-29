import 'dart:io';

import 'audio_path.dart';
import 'gatomix_store.dart';
import '../services/track_tags.dart';

/// BPM de la cola antes del Shuffle. Lee `_dj_metadata` (o `.gatomix.json`)
/// y la etiqueta TBPM. La caché de [TrackTags] queda indexada por
/// [audioPathKey], así una ruta con otra forma no cae en 0.
Future<void> preloadQueueBpm(List<String> paths) async {
  preloadQueueBpmSync(paths);
  final List<Future<void>> pending = <Future<void>>[];
  for (final String path in paths) {
    if (path.isEmpty || isKaraokeAudioPath(path)) continue;
    if ((TrackTags.peek(path)?.bpm ?? 0) > 0) continue;
    if (_bpmFromName(path) > 0) continue;
    pending.add(TrackTags.load(path));
  }
  if (pending.isNotEmpty) await Future.wait(pending);
}

void preloadQueueBpmSync(List<String> paths) {
  _preloadQueueBpm(paths, readTags: true);
}

/// Nombre y `.gatomix.json`. No abre cada MP3: el armado de Radio con toda
/// la biblioteca no se queda esperando el TBPM de miles de archivos.
void preloadQueueBpmFromStore(List<String> paths) {
  _preloadQueueBpm(paths, readTags: false);
}

void _preloadQueueBpm(List<String> paths, {required bool readTags}) {
  final Map<String, List<Map<String, dynamic>>> meta =
      <String, List<Map<String, dynamic>>>{};
  for (final String path in paths) {
    if (path.isEmpty || isKaraokeAudioPath(path)) continue;
    if ((TrackTags.peek(path)?.bpm ?? 0) > 0) continue;
    final double named = _bpmFromName(path);
    if (named > 0) {
      TrackTags.rememberBpm(path, named);
      continue;
    }
    final double fromMeta = _fromMetadata(path, meta);
    if (fromMeta > 0) {
      TrackTags.rememberBpm(path, fromMeta);
      continue;
    }
    if (!readTags) continue;
    final double fromTag = readTbpmSync(path);
    if (fromTag > 0) TrackTags.rememberBpm(path, fromTag);
  }
}

double _bpmFromName(String path) {
  final String fileName = path.replaceAll('\\', '/').split('/').last;
  final RegExpMatch? match = RegExp(
    r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
    caseSensitive: false,
  ).firstMatch(fileName);
  if (match == null) return 0;
  return TrackTags.musicalBpm(double.tryParse(match.group(1)!) ?? 0);
}

double _fromMetadata(
  String path,
  Map<String, List<Map<String, dynamic>>> cache,
) {
  final String key = audioPathKey(path);
  final String name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  final List<Map<String, dynamic>> maps = _metaChain(path, cache);
  for (final Map<String, dynamic> m in maps) {
    for (final MapEntry<String, dynamic> e in m.entries) {
      if (audioPathKey(e.key) != key) continue;
      final double bpm = _bpmValue(e.value);
      if (bpm > 0) return bpm;
    }
  }
  for (final Map<String, dynamic> m in maps) {
    for (final MapEntry<String, dynamic> e in m.entries) {
      final String base = e.key
          .replaceAll('\\', '/')
          .split('/')
          .last
          .toLowerCase();
      if (base != name) continue;
      final double bpm = _bpmValue(e.value);
      if (bpm > 0) return bpm;
    }
  }
  return 0;
}

int _metaGen = -1;
final Map<String, List<Map<String, dynamic>>> _metaMem =
    <String, List<Map<String, dynamic>>>{};

List<Map<String, dynamic>> _metaChain(
  String path,
  Map<String, List<Map<String, dynamic>>> cache,
) {
  if (_metaGen != GatomixStore.generation) {
    _metaGen = GatomixStore.generation;
    _metaMem.clear();
  }
  final String dir = File(path).parent.path;
  final List<Map<String, dynamic>>? stable = _metaMem[dir];
  if (stable != null) return stable;
  final List<Map<String, dynamic>>? hit = cache[dir];
  if (hit != null) return hit;
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  Directory cursor = Directory(dir);
  var ownLoaded = false;
  for (var depth = 0; depth < 6; depth++) {
    final Map<String, dynamic> m = readDjMetadata(cursor.path);
    if (depth == 0) ownLoaded = GatomixStore.holdsDocument(cursor.path);
    if (m.isNotEmpty) out.add(m);
    final Directory parent = cursor.parent;
    if (parent.path == cursor.path) break;
    cursor = parent;
  }
  cache[dir] = out;
  // Un archivo que todavía no está no se memoriza: si no, el BPM queda en 0
  // para siempre y la rampa cree que las dos pistas van igual. Un documento
  // ya leído sí se memoriza, aunque no tenga BPM, para no reabrir el JSON
  // en cada tick.
  if (ownLoaded || out.isNotEmpty) _metaMem[dir] = out;
  return out;
}

double _bpmValue(dynamic value) {
  if (value is num) return TrackTags.musicalBpm(value.toDouble());
  if (value is Map && value['bpm'] is num) {
    return TrackTags.musicalBpm((value['bpm'] as num).toDouble());
  }
  return 0;
}

/// BPM en memoria o en el nombre. No abre el archivo ni el `.gatomix.json`.
double memoryBpm(String? path) {
  if (path == null || path.isEmpty) return 0;
  final double named = _bpmFromName(path);
  if (named > 0) return named;
  return TrackTags.peek(path)?.bpm ?? 0;
}

int _knownBpmGen = -1;
final Map<String, double> _knownBpmMem = <String, double>{};

void _syncKnownBpmGen() {
  if (_knownBpmGen == GatomixStore.generation) return;
  _knownBpmGen = GatomixStore.generation;
  _knownBpmMem.clear();
}

/// BPM ya conocido. No decodifica.
///
/// Nombre, caché de etiquetas y `.gatomix.json`. La caché y el metadata se
/// buscan por [audioPathKey]: otra forma de la misma ruta no cae en 0.
/// Un acierto positivo se recuerda: el tick de posición no vuelve a abrir
/// el JSON. Un 0 no se recuerda (Masterizar puede escribir el BPM después).
double knownBpm(String? path) {
  if (path == null || path.isEmpty) return 0;
  _syncKnownBpmGen();
  final String memKey = audioPathKey(path);
  final double? mem = _knownBpmMem[memKey];
  if (mem != null && mem > 0) return mem;
  final double found = _knownBpmRead(path);
  if (found > 0) _knownBpmMem[memKey] = found;
  return found;
}

double _knownBpmRead(String path) {
  final String fileName = path.replaceAll('\\', '/').split('/').last;
  final RegExpMatch? match = RegExp(
    r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
    caseSensitive: false,
  ).firstMatch(fileName);
  if (match != null) {
    final double named = double.tryParse(match.group(1)!) ?? 0;
    if (named > 0) return named;
  }
  final double peeked = TrackTags.peek(path)?.bpm ?? 0;
  if (peeked > 0) return peeked;
  final double stored = _fromMetadata(
    path,
    <String, List<Map<String, dynamic>>>{},
  );
  if (stored > 0) {
    TrackTags.rememberBpm(path, stored);
    return stored;
  }
  return 0;
}

/// Igual que [knownBpm]. Lo usan la cola y el Shuffle.
double cachedBpm(String? path) => knownBpm(path);

/// Tonalidad Camelot guardada en el `.gatomix.json` de la carpeta.
String? readStoredCamelot(String path) {
  if (path.isEmpty) return null;
  final String key = audioPathKey(path);
  final String name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  final List<Map<String, dynamic>> maps = _metaChain(
    path,
    <String, List<Map<String, dynamic>>>{},
  );
  String? from(dynamic value) {
    if (value is Map && value['key'] is String) {
      final String s = (value['key'] as String).trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  for (final Map<String, dynamic> m in maps) {
    for (final MapEntry<String, dynamic> e in m.entries) {
      if (audioPathKey(e.key) != key) continue;
      final String? k = from(e.value);
      if (k != null) return k;
    }
  }
  for (final Map<String, dynamic> m in maps) {
    for (final MapEntry<String, dynamic> e in m.entries) {
      final String base = e.key
          .replaceAll('\\', '/')
          .split('/')
          .last
          .toLowerCase();
      if (base != name) continue;
      final String? k = from(e.value);
      if (k != null) return k;
    }
  }
  return null;
}

int _syncsafe(List<int> b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

/// TBPM del ID3v2, sin decodificar el audio.
double readTbpmSync(String path) {
  RandomAccessFile? raf;
  try {
    final File f = File(path);
    if (!f.existsSync()) return 0;
    raf = f.openSync();
    final List<int> head = raf.readSync(10);
    if (head.length < 10 ||
        head[0] != 0x49 ||
        head[1] != 0x44 ||
        head[2] != 0x33) {
      return 0;
    }
    final int ver = head[3];
    if (ver < 2 || ver > 4) return 0;
    final int tagEnd = 10 + _syncsafe(head, 6);
    var pos = 10;
    if (ver >= 3 && (head[5] & 0x40) != 0) {
      raf.setPositionSync(pos);
      final List<int> ext = raf.readSync(4);
      if (ext.length < 4) return 0;
      pos += ver == 4
          ? _syncsafe(ext, 0)
          : 4 + ((ext[0] << 24) | (ext[1] << 16) | (ext[2] << 8) | ext[3]);
    }
    final int hdrLen = ver == 2 ? 6 : 10;
    while (pos + hdrLen <= tagEnd) {
      raf.setPositionSync(pos);
      final List<int> h = raf.readSync(hdrLen);
      if (h.length < hdrLen || h[0] == 0) break;
      final String id = String.fromCharCodes(h.sublist(0, ver == 2 ? 3 : 4));
      final int size = ver == 2
          ? ((h[3] << 16) | (h[4] << 8) | h[5])
          : (ver == 4
                ? _syncsafe(h, 4)
                : ((h[4] << 24) | (h[5] << 16) | (h[6] << 8) | h[7]));
      if (size <= 0 || pos + hdrLen + size > tagEnd) break;
      if (id == 'TBPM' || id == 'TBP') {
        final List<int> body = raf.readSync(size);
        if (body.length <= 1) return 0;
        return _parseBpmText(body.sublist(1));
      }
      pos += hdrLen + size;
    }
  } catch (_) {
    return 0;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
  return 0;
}

double _parseBpmText(List<int> bytes) {
  final String text = String.fromCharCodes(
    bytes.where((int b) => b == 0x2C || b == 0x2E || (b >= 0x30 && b <= 0x39)),
  );
  return TrackTags.decodeTbpm(text);
}

void forgetKnownBpm(String? path) {
  if (path == null || path.isEmpty) return;
  _syncKnownBpmGen();
  _knownBpmMem.remove(audioPathKey(path));
}
