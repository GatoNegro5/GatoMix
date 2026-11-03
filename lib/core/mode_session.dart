import 'dart:io';

import 'audio_path.dart';
import 'gatomix_store.dart';
import 'hal/platform_strategy.dart';
import 'livedj_order.dart';
import 'session_store.dart';

/// Un archivo por modo, en la carpeta donde ya vivía su sesión.
/// Automix y Live DJ: `Music/DjPlaylists` (la de `getSessionPath`).
/// La radio sigue en la raíz de Música (`LiveDj_Radio.json`).
const String automixStateName = 'automix.json';
const String liveDjStateName = 'liveDj.json';

const List<String> _automixMaps = <String>[
  '_player_session.json',
  'player_session.json',
  '_automix_sort.json',
];

const String _liveLegacyName = '_livedj_session.json';

final Map<String, int> _epoch = <String, int>{};
final Map<String, Future<void>> _locks = <String, Future<void>>{};

String _sep() => Platform.pathSeparator;

String sessionDir() {
  final String session = MixStrategyFactory.getStrategy().getSessionPath();
  return File(session).parent.path;
}

String automixStatePath() {
  final String dir = sessionDir();
  migrateAutomixDir(dir);
  return '$dir${_sep()}$automixStateName';
}

String liveDjStatePath() {
  final String dir = sessionDir();
  migrateLiveDjDir(dir);
  return '$dir${_sep()}$liveDjStateName';
}

Map<String, dynamic> readModeDoc(String path) {
  final Object? data = SessionStore.readJson(path);
  if (data is Map) return Map<String, dynamic>.from(data);
  return <String, dynamic>{};
}

/// Junta la sesión, la cola, lo ya sonado, el orden y la ruta de Automix.
/// Copia, verifica y solo entonces borra los viejos.
Map<String, dynamic> migrateAutomixDir(String dir) {
  if (dir.isEmpty) return <String, dynamic>{};
  final String destPath = '$dir${_sep()}$automixStateName';
  final Map<String, dynamic> dest = readModeDoc(destPath);
  var changed = false;

  void takeList(String name, String slot) {
    final Object? raw = SessionStore.readJson('$dir${_sep()}$name');
    if (raw is! List) return;
    if (dest.containsKey(slot)) return;
    dest[slot] = <String>[for (final Object? e in raw) e.toString()];
    changed = true;
  }

  takeList('_automix_session.json', 'queue');
  takeList('_played_tracks_session.json', 'played');

  void takeMap(String name) {
    final Object? raw = SessionStore.readJson('$dir${_sep()}$name');
    if (raw is! Map) return;
    for (final MapEntry<dynamic, dynamic> e in raw.entries) {
      final String key = e.key.toString();
      if (dest.containsKey(key)) continue;
      dest[key] = e.value;
      changed = true;
    }
  }

  for (final String name in _automixMaps) {
    takeMap(name);
  }

  final Object? routeDoc = SessionStore.readJson('$dir${_sep()}_ui_route.json');
  if (routeDoc is Map &&
      routeDoc['route'] is int &&
      !dest.containsKey('uiRoute')) {
    dest['uiRoute'] = routeDoc['route'];
    changed = true;
  }

  if (changed) {
    dest.putIfAbsent('schema', () => 1);
    try {
      SessionStore.writeJsonSync(destPath, dest);
    } catch (_) {
      return readModeDoc(destPath);
    }
  }

  final Map<String, dynamic> back = readModeDoc(destPath);
  if (changed && back.isEmpty && dest.isNotEmpty) return dest;

  takeListVerify(String name, String slot) {
    final String path = '$dir${_sep()}$name';
    final Object? raw = SessionStore.readJson(path);
    if (raw is! List) return;
    final List<String> want = <String>[
      for (final Object? e in raw) e.toString(),
    ];
    final Object? got = back[slot];
    if (got is! List) return;
    final List<String> have = <String>[for (final Object? e in got) e.toString()];
    if (!jsonEqual(have, want)) return;
    _deleteLegacy(path);
  }

  takeListVerify('_automix_session.json', 'queue');
  takeListVerify('_played_tracks_session.json', 'played');
  for (final String name in _automixMaps) {
    final String path = '$dir${_sep()}$name';
    final Object? raw = SessionStore.readJson(path);
    if (raw is! Map) continue;
    if (!_covers(back, raw)) continue;
    _deleteLegacy(path);
  }
  return readModeDoc(destPath);
}

/// La sesión de Live DJ, con el mismo contenido, pasa a `liveDj.json`.
Map<String, dynamic> migrateLiveDjDir(String dir) {
  if (dir.isEmpty) return <String, dynamic>{};
  final String legacy = '$dir${_sep()}$_liveLegacyName';
  final String destPath = '$dir${_sep()}$liveDjStateName';
  final Map<String, dynamic> dest = readModeDoc(destPath);
  final Object? raw = SessionStore.readJson(legacy);
  var changed = false;
  if (raw is Map) {
    for (final MapEntry<dynamic, dynamic> e in raw.entries) {
      final String key = e.key.toString();
      if (dest.containsKey(key)) continue;
      dest[key] = e.value;
      changed = true;
    }
  }
  if (changed) {
    try {
      SessionStore.writeJsonSync(destPath, dest);
    } catch (_) {
      return readModeDoc(destPath);
    }
  }
  final Map<String, dynamic> back = readModeDoc(destPath);
  if (raw is Map && _covers(back, raw)) _deleteLegacy(legacy);
  return readModeDoc(destPath);
}

bool _covers(Map<dynamic, dynamic> dest, Map<dynamic, dynamic> src) {
  for (final MapEntry<dynamic, dynamic> e in src.entries) {
    final String key = e.key.toString();
    if (!dest.containsKey(key) || !jsonEqual(dest[key], e.value)) return false;
  }
  return true;
}

bool _legacyName(String name) {
  final String n = name.toLowerCase();
  if (n.endsWith('.mp3') || n.endsWith('.lrc') || n.contains('_k')) {
    return false;
  }
  const Set<String> ok = <String>{
    'player_session.json',
    '_player_session.json',
    '_automix_session.json',
    '_played_tracks_session.json',
    '_automix_sort.json',
    '_livedj_session.json',
    '.gatomix_radio.json',
  };
  if (ok.contains(n)) return true;
  for (final String base in ok) {
    if (n == '$base.bak' || n == '$base.tmp') return true;
  }
  return false;
}

void _deleteLegacy(String path) {
  final String name = path.replaceAll('\\', '/').split('/').last;
  if (!_legacyName(name)) return;
  for (final String p in <String>[path, '$path.bak', '$path.tmp']) {
    final String leaf = p.replaceAll('\\', '/').split('/').last;
    if (!_legacyName(leaf)) continue;
    final File f = File(p);
    if (!f.existsSync()) continue;
    try {
      f.deleteSync();
    } catch (_) {}
  }
}

/// Borra el nombre viejo de la radio solo si [path] es ese archivo.
void deleteRadioLegacy(String path) => _deleteLegacy(path);

Future<void> patchModeDoc(String path, Map<String, dynamic> fields) {
  final int epoch = _epoch[path] ?? 0;
  final int gen = SessionStore.generationOf(path);
  final Future<void> prev = _locks[path] ?? Future<void>.value();
  final Future<void> next = prev.catchError((_) {}).then((_) async {
    if ((_epoch[path] ?? 0) != epoch) return;
    if (SessionStore.generationOf(path) != gen) return;
    final Map<String, dynamic> doc = readModeDoc(path);
    if ((_epoch[path] ?? 0) != epoch) return;
    if (SessionStore.generationOf(path) != gen) return;
    for (final MapEntry<String, dynamic> e in fields.entries) {
      if (e.value == null) {
        doc.remove(e.key);
      } else {
        doc[e.key] = e.value;
      }
    }
    await SessionStore.writeJson(path, doc, generation: gen);
  });
  _locks[path] = next;
  return next;
}

/// Vacía cola, posición, lo ya sonado, parejas y ola. El resto del
/// documento (modo, orden elegido, radio encendida) se queda.
void clearModeQueueSync(
  String path, {
  bool playbackList = false,
  bool keepRadioFreeze = false,
}) {
  _epoch[path] = (_epoch[path] ?? 0) + 1;
  SessionStore.invalidate(path);
  final Map<String, dynamic> doc = readModeDoc(path);
  doc['queue'] = <String>[];
  doc['positionMs'] = 0;
  doc['wasPlaying'] = false;
  doc['played'] = <String>[];
  doc['pairs'] = <String>[];
  doc['recent'] = <Object>[];
  doc['waveUp'] = true;
  doc['inWave'] = 0;
  doc['previousBpm'] = 0;
  doc.remove('currentTrackPath');
  if (!keepRadioFreeze) doc.remove('radioFreeze');
  if (playbackList || doc.containsKey('playlist')) {
    doc['playlist'] = <String>[];
    doc['currentIndex'] = -1;
  }
  if (!doc.containsKey('schema')) doc['schema'] = playbackList ? 1 : 2;
  SessionStore.writeJsonSync(path, doc);
}

bool modeQueueIsClear(Map<String, dynamic> doc) {
  bool empty(Object? v) => v is List && v.isEmpty;
  if (!empty(doc['queue'])) return false;
  if ((doc['positionMs'] ?? 0) != 0) return false;
  if (doc['wasPlaying'] == true) return false;
  if (doc.containsKey('played') && !empty(doc['played'])) return false;
  if (doc.containsKey('pairs') && !empty(doc['pairs'])) return false;
  if (doc.containsKey('recent') && !empty(doc['recent'])) return false;
  if (doc['inWave'] != null && doc['inWave'] != 0) return false;
  if (doc['waveUp'] == false) return false;
  if ((doc['previousBpm'] ?? 0) != 0) return false;
  if (doc.containsKey('currentTrackPath') && doc['currentTrackPath'] != null) {
    return false;
  }
  if (doc.containsKey('playlist') && !empty(doc['playlist'])) return false;
  if (doc.containsKey('radioFreeze')) return false;
  return true;
}

class ModeWave {
  final Set<String> pairs;
  final Map<String, int> age;
  final bool waveUp;
  final int inWave;
  final double previousBpm;

  const ModeWave({
    required this.pairs,
    required this.age,
    required this.waveUp,
    required this.inWave,
    required this.previousBpm,
  });
}

List<String> _strings(Object? raw) {
  if (raw is! List) return <String>[];
  return <String>[for (final Object? e in raw) e.toString()];
}

Map<String, int> _ages(Object? raw) {
  final Map<String, int> age = <String, int>{};
  if (raw is! List) return age;
  for (final Object? row in raw) {
    if (row is List && row.length >= 2 && row[1] is num) {
      age[row[0].toString()] = (row[1] as num).toInt();
    }
  }
  return age;
}

/// Parejas y ola de esta cola. Si el archivo aún no las tiene, se copian
/// una vez desde el `.gatomix.json` de las carpetas y a partir de ahí
/// manda el archivo del modo.
ModeWave loadModeWave(String path, Iterable<String> tracks) {
  final Map<String, dynamic> doc = readModeDoc(path);
  if (!doc.containsKey('pairs')) {
    final ShuffleMemory mem = GatomixStore.loadShuffleMemory(tracks);
    final Map<String, dynamic> again = readModeDoc(path);
    if (again.containsKey('pairs')) return _waveFrom(again);
    again['pairs'] = mem.pairs.toList();
    again['recent'] = <List<Object>>[
      for (final MapEntry<String, int> e in mem.age.entries)
        <Object>[e.key, e.value],
    ];
    again['waveUp'] = true;
    again['inWave'] = 0;
    again['previousBpm'] = 0;
    try {
      SessionStore.writeJsonSync(path, again);
    } catch (_) {}
    final Map<String, dynamic> wrote = readModeDoc(path);
    if (wrote.containsKey('pairs')) return _waveFrom(wrote);
    return ModeWave(
      pairs: mem.pairs,
      age: mem.age,
      waveUp: true,
      inWave: 0,
      previousBpm: 0,
    );
  }
  return _waveFrom(doc);
}

ModeWave _waveFrom(Map<String, dynamic> doc) {
  final Object? wave = doc['inWave'];
  final Object? bpm = doc['previousBpm'];
  return ModeWave(
    pairs: _strings(doc['pairs']).toSet(),
    age: _ages(doc['recent']),
    waveUp: doc['waveUp'] as bool? ?? true,
    inWave: wave is num ? wave.toInt() : 0,
    previousBpm: bpm is num ? bpm.toDouble() : 0,
  );
}

Map<String, dynamic> queueWavePatch({
  required Map<String, dynamic> doc,
  required List<String> order,
  String? anchor,
  required bool waveUp,
  required int inWave,
  required double previousBpm,
}) {
  final List<String> fresh = <String>[];
  final List<String> seq = <String>[
    if (anchor != null && anchor.isNotEmpty) anchor,
    ...order,
  ];
  for (var i = 1; i < seq.length; i++) {
    if (sameAudioPath(seq[i - 1], seq[i])) continue;
    fresh.add(shufflePairKey(seq[i - 1], seq[i]));
  }
  final List<String> prev = _strings(doc['pairs']);
  final List<String> pairs = <String>[];
  final Set<String> seen = <String>{};
  for (final String p in <String>[...prev, ...fresh].reversed) {
    if (seen.add(p)) pairs.add(p);
  }
  final List<String> kept = pairs.reversed.toList();
  final List<String> capped = kept.length > shufflePairCap
      ? kept.sublist(kept.length - shufflePairCap)
      : kept;
  return <String, dynamic>{
    'pairs': capped,
    'waveUp': waveUp,
    'inWave': inWave,
    'previousBpm': previousBpm,
  };
}

/// El mismo hueco de BPM que Live DJ (`insertHarmonicTracks`).
List<String> automixInsertAtGap({
  required List<String> queue,
  required List<String> incoming,
  required double Function(String path) bpmOf,
  String? Function(String path)? keyOf,
  int lockedPrefix = 0,
  String? playing,
  String? pinned,
  bool? foldCase,
  int waveLength = 20,
}) {
  return insertHarmonicTracks(
    queue: queue,
    incoming: incoming,
    bpmOf: bpmOf,
    keyOf: keyOf,
    lockedPrefix: lockedPrefix,
    playing: playing,
    pinned: pinned,
    foldCase: foldCase,
    waveLength: waveLength,
  );
}
