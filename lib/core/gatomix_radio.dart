import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'audio_path.dart';
import 'gatomix_store.dart';
import 'livedj_order.dart';

/// Nombre del archivo viejo, junto a la sesión de Live DJ.
const String legacyRadioFileName = '_livedj_radio.json';

/// El archivo aparte que ya no se usa. Su historial se muda a la sección.
const String retiredRadioFileName = '.gatomix_radio.json';

const int radioWaveLength = 20;

/// Estado de la radio: historial, parejas, ola y BPM anterior.
/// Vive en la sección `radio` del `.gatomix.json` de la raíz de Música.
/// No guarda una lista de canciones por sonar.
class RadioMemory {
  final List<String> history;
  final List<String> pairs;
  final bool waveUp;
  final int inWave;
  final double previousBpm;
  final String lastArtist;
  final String? lastPath;

  const RadioMemory({
    this.history = const <String>[],
    this.pairs = const <String>[],
    this.waveUp = true,
    this.inWave = 0,
    this.previousBpm = 0,
    this.lastArtist = '',
    this.lastPath,
  });

  static const RadioMemory empty = RadioMemory();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'history': history,
    'pairs': pairs,
    'waveUp': waveUp,
    'inWave': inWave,
    'previousBpm': previousBpm,
    'lastArtist': lastArtist,
    'lastPath': lastPath,
  };

  static RadioMemory fromJson(dynamic raw) {
    if (raw is! Map) return RadioMemory.empty;
    final dynamic bpm = raw['previousBpm'];
    final dynamic wave = raw['inWave'];
    final String? last = raw['lastPath']?.toString();
    return RadioMemory(
      history: _strings(raw['history']),
      pairs: _strings(raw['pairs']),
      waveUp: raw['waveUp'] as bool? ?? true,
      inWave: wave is num ? wave.toInt() : 0,
      previousBpm: bpm is num ? bpm.toDouble() : 0,
      lastArtist: raw['lastArtist']?.toString() ?? '',
      lastPath: last == null || last.isEmpty ? null : last,
    );
  }

  RadioMemory copy({
    List<String>? history,
    List<String>? pairs,
    bool? waveUp,
    int? inWave,
    double? previousBpm,
    String? lastArtist,
    String? lastPath,
    bool clearLastPath = false,
  }) {
    return RadioMemory(
      history: history ?? this.history,
      pairs: pairs ?? this.pairs,
      waveUp: waveUp ?? this.waveUp,
      inWave: inWave ?? this.inWave,
      previousBpm: previousBpm ?? this.previousBpm,
      lastArtist: lastArtist ?? this.lastArtist,
      lastPath: clearLastPath ? null : (lastPath ?? this.lastPath),
    );
  }
}

List<String> _strings(dynamic raw) {
  if (raw is! List) return const <String>[];
  return <String>[for (final dynamic p in raw) p.toString()];
}

bool _has(Iterable<String> xs, String p) =>
    xs.any((String e) => sameAudioPath(e, p));

/// Carpetas de los géneros marcados, juntas, como una sola cola.
/// Sin géneros marcados entra todo. Si los marcados no existen, también todo.
List<String> radioPool({
  required Map<String, List<String>> byFolder,
  required Map<String, String> folderGenre,
  required Set<String> genres,
}) {
  List<String> take(bool Function(String folder) ok) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    for (final MapEntry<String, List<String>> e in byFolder.entries) {
      if (!ok(e.key)) continue;
      for (final String p in e.value) {
        if (p.isEmpty || isKaraokeAudioPath(p)) continue;
        if (seen.add(audioPathKey(p))) out.add(p);
      }
    }
    return out;
  }

  final List<String> filtered = take((String folder) {
    final String? g = folderGenre[folder];
    return genres.isEmpty || (g != null && genres.contains(g));
  });
  if (filtered.isNotEmpty || genres.isEmpty) return filtered;
  return take((String _) => true);
}

bool radioOutsideExplorer(String path, String? prefix, {bool foldCase = false}) {
  if (prefix == null || prefix.isEmpty) return true;
  final String p = foldCase ? path.toLowerCase() : path;
  final String pre = foldCase ? prefix.toLowerCase() : prefix;
  return !p.startsWith(pre);
}

class RadioChoice {
  final String? path;
  final RadioMemory memory;

  /// Cierto si el nivel 2 vació el historial para poder seguir.
  final bool historyReset;

  const RadioChoice(this.path, this.memory, {this.historyReset = false});
}

Map<String, int> _recentAge(List<String> history) {
  final Map<String, int> age = <String, int>{};
  final int n = history.length;
  final int start = n > 8 ? n - 8 : 0;
  for (var i = start; i < n; i++) {
    age[audioPathKey(history[i])] = n - i;
  }
  return age;
}

/// Siguiente pista del fondo único.
///
/// Nivel 0: fuera del Explorador, sin historial y sin repetir artista.
/// Nivel 1: el artista ya puede repetirse. Nivel 2: el historial se vacía.
/// Nivel 3: también vale la carpeta del Explorador.
/// Dentro del nivel, el Shuffle armónico (±4/8/12, Camelot, ola, top 3).
RadioChoice chooseRadioTrack({
  required List<String> pool,
  required RadioMemory memory,
  required double Function(String path) bpmOf,
  String? Function(String path)? keyOf,
  required String Function(String path) artistOf,
  String? anchorPath,
  double anchorBpm = 0,
  String? explorerPrefix,
  bool explorerFoldCase = false,
  String? playing,
  Random? rng,
}) {
  final Random random = rng ?? Random();
  final String? anchor = (anchorPath != null && anchorPath.isNotEmpty)
      ? anchorPath
      : memory.lastPath;
  final double bpm = anchorBpm > 0 ? anchorBpm : memory.previousBpm;
  RadioMemory mem = memory;
  var reset = false;
  for (var level = 0; level < 4; level++) {
    final bool relaxExplorer = level >= 3;
    if (level == 2 && mem.history.isNotEmpty) {
      mem = mem.copy(history: const <String>[]);
      reset = true;
    }
    final List<String> cands = <String>[
      for (final String p in pool)
        if (!_blocked(
          p,
          level: level,
          history: mem.history,
          lastArtist: mem.lastArtist,
          artistOf: artistOf,
          explorerPrefix: relaxExplorer ? null : explorerPrefix,
          explorerFoldCase: explorerFoldCase,
          playing: playing,
          anchor: anchor,
        ))
          p,
    ];
    if (cands.isEmpty) continue;
    final String? pick = pickHarmonicNext(
      cands,
      bpmOf,
      keyOf: keyOf,
      anchor: anchor,
      anchorBpm: bpm,
      waveUp: mem.waveUp,
      usedPairs: mem.pairs.toSet(),
      recentAge: _recentAge(mem.history),
      rng: random,
    );
    if (pick == null) continue;
    return RadioChoice(pick, mem, historyReset: reset);
  }
  return RadioChoice(null, mem, historyReset: reset);
}

bool _blocked(
  String path, {
  required int level,
  required List<String> history,
  required String lastArtist,
  required String Function(String path) artistOf,
  required String? explorerPrefix,
  required bool explorerFoldCase,
  required String? playing,
  required String? anchor,
}) {
  if (playing != null && sameAudioPath(path, playing)) return true;
  if (anchor != null && sameAudioPath(path, anchor)) return true;
  if (!radioOutsideExplorer(
    path,
    explorerPrefix,
    foldCase: explorerFoldCase,
  )) {
    return true;
  }
  if (level < 2 && _has(history, path)) return true;
  if (level < 1 && lastArtist.isNotEmpty) {
    final String artist = artistOf(path);
    if (artist.isNotEmpty && artist == lastArtist) return true;
  }
  return false;
}

/// Anota la pista que sonó: historial, pareja A→B, ola y BPM anterior.
RadioMemory noteRadioPlayed(
  RadioMemory memory,
  String path, {
  required double bpm,
  required String artist,
}) {
  final List<String> history = <String>[
    for (final String p in memory.history)
      if (!sameAudioPath(p, path)) p,
    path,
  ];
  final List<String> pairs = List<String>.from(memory.pairs);
  final String? prev = memory.lastPath;
  if (prev != null && !sameAudioPath(prev, path)) {
    final String pair = shufflePairKey(prev, path);
    if (!pairs.contains(pair)) pairs.add(pair);
  }
  final List<String> kept = pairs.length > shufflePairCap
      ? pairs.sublist(pairs.length - shufflePairCap)
      : pairs;
  var inWave = memory.inWave + 1;
  var up = memory.waveUp;
  if (inWave >= radioWaveLength) {
    up = !up;
    inWave = 0;
  }
  return RadioMemory(
    history: history,
    pairs: kept,
    waveUp: up,
    inWave: inWave,
    previousBpm: bpm > 0 ? bpm : memory.previousBpm,
    lastArtist: artist,
    lastPath: path,
  );
}

class GatomixRadio {
  /// Lee la sección `radio`. Si no está, muda el historial viejo, verifica
  /// y solo entonces borra esos json.
  static RadioMemory load(
    String musicRoot, {
    List<String> legacyPaths = const <String>[],
  }) {
    if (musicRoot.isEmpty) return RadioMemory.empty;
    final RadioMemory? section = _section(musicRoot);
    final List<File> old = <File>[
      for (final String p in legacyPaths) File(p),
      File('$musicRoot${Platform.pathSeparator}$retiredRadioFileName'),
    ];
    final List<File> present = <File>[
      for (final File f in old)
        if (f.existsSync()) f,
    ];
    if (section != null && present.isEmpty) return section;
    final RadioMemory merged = _merge(section ?? RadioMemory.empty, present);
    if (present.isEmpty) return merged;
    save(musicRoot, merged);
    final RadioMemory? back = _section(musicRoot);
    if (back == null || !_sameHistory(back.history, merged.history)) {
      return section ?? merged;
    }
    for (final File f in present) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    return back;
  }

  static void save(String musicRoot, RadioMemory mem) {
    if (musicRoot.isEmpty) return;
    try {
      final Directory dir = Directory(musicRoot);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      GatomixStore.putSection(musicRoot, 'radio', mem.toJson());
    } catch (_) {}
  }

  static RadioMemory? _section(String musicRoot) {
    final dynamic raw = GatomixStore.section(musicRoot, 'radio');
    if (raw is! Map) return null;
    return RadioMemory.fromJson(raw);
  }

  static RadioMemory _merge(RadioMemory base, List<File> files) {
    final List<String> history = List<String>.from(base.history);
    final List<String> pairs = List<String>.from(base.pairs);
    for (final File f in files) {
      final Object? data = _decode(f);
      if (data is! Map) continue;
      for (final String p in _strings(data['history'])) {
        if (!_has(history, p)) history.add(p);
      }
      for (final String p in _strings(data['pairs'])) {
        if (!pairs.contains(p)) pairs.add(p);
      }
      for (final String p in _strings(data['previousPairs'])) {
        if (!pairs.contains(p)) pairs.add(p);
      }
      final dynamic plans = data['plans'];
      if (plans is Map) {
        for (final dynamic plan in plans.values) {
          if (plan is! Map) continue;
          for (final String p in _strings(plan['pairs'])) {
            if (!pairs.contains(p)) pairs.add(p);
          }
          for (final String p in _strings(plan['previousPairs'])) {
            if (!pairs.contains(p)) pairs.add(p);
          }
        }
      }
    }
    return base.copy(history: history, pairs: pairs);
  }

  static Object? _decode(File f) {
    try {
      return jsonDecode(f.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  static bool _sameHistory(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Cola de Live DJ congelada al encender la radio.
class LiveQueueFreeze {
  final List<String> queue;
  final String? current;
  final int positionMs;
  final bool wasPlaying;

  const LiveQueueFreeze({
    required this.queue,
    this.current,
    this.positionMs = 0,
    this.wasPlaying = false,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'queue': queue,
    'current': current,
    'positionMs': positionMs,
    'wasPlaying': wasPlaying,
  };

  static LiveQueueFreeze? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final dynamic pos = raw['positionMs'];
    return LiveQueueFreeze(
      queue: <String>[
        for (final dynamic p in (raw['queue'] as List?) ?? const <dynamic>[])
          p.toString(),
      ],
      current: raw['current']?.toString(),
      positionMs: pos is num ? pos.toInt() : 0,
      wasPlaying: raw['wasPlaying'] as bool? ?? false,
    );
  }
}

/// La cola vuelve a ser la congelada. Lo que sonó la radio y no estaba
/// en esa cola no se mezcla.
LiveQueueFreeze resumeLiveQueue(LiveQueueFreeze freeze) {
  final List<String> queue = <String>[];
  final Set<String> seen = <String>{};
  for (final String p in freeze.queue) {
    if (isKaraokeAudioPath(p)) continue;
    if (seen.add(audioPathKey(p))) queue.add(p);
  }
  return LiveQueueFreeze(
    queue: queue,
    current: freeze.current,
    positionMs: freeze.positionMs,
    wasPlaying: freeze.wasPlaying,
  );
}
