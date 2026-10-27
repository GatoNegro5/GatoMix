import 'dart:convert';
import 'dart:io';

import 'audio_path.dart';

/// Un solo JSON por carpeta: `.gatomix.json`.
///
/// Sustituye a `.dj_master_checkpoint.json`, `.gatomix_master_index.json`,
/// `.gatomix_lyric_fail.json`, `_dj_metadata.json`, `_dj_timestamps.json`,
/// `_lyrics_auto.json` y a los bancos de shuffle. La migración lee los
/// viejos, escribe el nuevo, verifica y solo entonces los borra.
/// Nunca borra mp3, `.lrc` ni pistas `_K`.
const String gatomixStoreName = '.gatomix.json';
const String gatomixLogName = '.gatomix.log';

const int gatomixLogMaxBytes = 200 * 1024;
const int shufflePairCap = 1500;
const int shuffleRecentCap = 500;
const int shuffleAgeMax = 12;
const int shuffleSectionMaxBytes = 160 * 1024;

const Map<String, String> _legacySections = <String, String>{
  '.dj_master_checkpoint.json': 'checkpoint',
  '.gatomix_master_index.json': 'masterIndex',
  '.gatomix_lyric_fail.json': 'lyricFail',
  '_dj_metadata.json': 'djMetadata',
  '_dj_timestamps.json': 'djTimestamps',
  '_lyrics_auto.json': 'lyricsAuto',
};

const Set<String> _legacyLogs = <String>{
  '.pass1.log',
  'pass1.log',
  '.gatomix_master_headless.log',
};

const Set<String> _legacyTmp = <String>{
  '_dj_metadata.tmp',
  '_dj_timestamps.tmp',
};

bool isGatomixLegacyName(String name) =>
    _legacySections.containsKey(name) ||
    name == 'shuffle_banks.json' ||
    name == '_livedj_shuffle_banks.json' ||
    _legacyLogs.contains(name) ||
    _legacyTmp.contains(name);

bool _safeToDelete(String name) {
  final String n = name.toLowerCase();
  if (n.endsWith('.mp3') || n.endsWith('.lrc') || n.endsWith('.bak')) {
    return false;
  }
  if (n.contains('_k.')) return false;
  return isGatomixLegacyName(name);
}

class ShuffleMemory {
  final Set<String> pairs;
  final Map<String, int> age;
  const ShuffleMemory(this.pairs, this.age);
  static const ShuffleMemory empty = ShuffleMemory(<String>{}, <String, int>{});
}

class GatomixStore {
  static final String _sep = Platform.pathSeparator;

  static File fileOf(String dir) => File('$dir$_sep$gatomixStoreName');

  static bool migrate(String dir) {
    if (dir.isEmpty) return false;
    final Directory folder = Directory(dir);
    if (!folder.existsSync()) return false;
    final List<File> pending = <File>[];
    for (final String name in <String>[
      ..._legacySections.keys,
      'shuffle_banks.json',
      '_livedj_shuffle_banks.json',
      ..._legacyLogs,
      ..._legacyTmp,
    ]) {
      final File f = File('$dir$_sep$name');
      if (f.existsSync()) pending.add(f);
    }
    if (pending.isEmpty) return false;

    final Map<String, dynamic>? existing = _read(dir);
    if (existing == null) return false;
    final Map<String, dynamic> doc = existing;
    final Map<String, dynamic> imported = _map(doc['imported']);
    final List<File> ready = <File>[];

    for (final File f in pending) {
      final String name = f.uri.pathSegments.last;
      if (_legacyTmp.contains(name)) {
        ready.add(f);
        continue;
      }
      if (_legacyLogs.contains(name)) {
        GatomixLog.fold(dir, f);
        ready.add(f);
        continue;
      }
      final Object? old = _decodeFile(f);
      if (old == null) continue;
      imported[name] = old;
      if (name == 'shuffle_banks.json') {
        final Map<String, dynamic> sh = _map(doc['shuffle']);
        sh['legacyAutomix'] = old;
        doc['shuffle'] = sh;
      } else if (name == '_livedj_shuffle_banks.json') {
        final Map<String, dynamic> sh = _map(doc['shuffle']);
        sh['legacyLive'] = old;
        doc['shuffle'] = sh;
      } else {
        final String? section = _legacySections[name];
        if (section != null) {
          doc[section] = mergeJson(doc[section], old);
        }
      }
      ready.add(f);
    }
    if (ready.isEmpty) return false;
    doc['imported'] = imported;
    if (!_write(dir, doc)) return false;
    final Map<String, dynamic>? check = _read(dir);
    if (check == null) return false;
    final Map<String, dynamic> got = _map(check['imported']);
    for (final File f in ready) {
      final String name = f.uri.pathSegments.last;
      if (!_safeToDelete(name)) continue;
      if (!_legacyLogs.contains(name) && !_legacyTmp.contains(name)) {
        final Object? old = imported[name];
        if (old == null || !jsonEqual(got[name], old)) continue;
      }
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    return true;
  }

  /// Carpetas que todavía tienen un JSON o log viejo.
  static void migrateTree(String root) {
    migrate(root);
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return;
    final Set<String> parents = <String>{};
    try {
      for (final FileSystemEntity e in dir.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (e is! File) continue;
        final String name = e.uri.pathSegments.last;
        if (!isGatomixLegacyName(name)) continue;
        parents.add(e.parent.path);
      }
    } catch (_) {}
    for (final String p in parents) {
      migrate(p);
    }
  }

  static dynamic section(String dir, String key) {
    migrate(dir);
    final Map<String, dynamic>? doc = _read(dir);
    if (doc != null && doc.containsKey(key)) return doc[key];
    return _legacySection(dir, key);
  }

  static void putSection(String dir, String key, Object? value) {
    migrate(dir);
    final Map<String, dynamic>? doc = _read(dir);
    if (doc == null) return;
    if (value == null) {
      doc.remove(key);
    } else {
      doc[key] = value;
    }
    _write(dir, doc);
  }

  static Map<String, dynamic>? readCheckpoint(String dir) {
    final dynamic v = section(dir, 'checkpoint');
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  static void writeCheckpoint(String dir, Map<String, dynamic> data) {
    putSection(dir, 'checkpoint', data);
  }

  static void clearCheckpoint(String dir) =>
      putSection(dir, 'checkpoint', null);

  static Map<String, dynamic> readMap(String dir, String key) {
    final dynamic v = section(dir, key);
    if (v is Map) return Map<String, dynamic>.from(v);
    return <String, dynamic>{};
  }

  static void writeMap(String dir, String key, Map<String, dynamic> data) {
    putSection(dir, key, data.isEmpty ? null : data);
  }

  static ShuffleMemory loadShuffleMemory(Iterable<String> paths) {
    final Set<String> pairs = <String>{};
    final Map<String, int> age = <String, int>{};
    final Set<String> dirs = <String>{
      for (final String p in paths)
        if (p.isNotEmpty) File(p).parent.path,
    };
    for (final String dir in dirs) {
      final dynamic raw = section(dir, 'shuffle');
      if (raw is! Map) continue;
      final dynamic list = raw['pairs'];
      if (list is List) {
        for (final dynamic p in list) {
          pairs.add(p.toString());
        }
      }
      final dynamic recent = raw['recent'];
      if (recent is List) {
        for (final dynamic row in recent) {
          final ({String k, int a})? parsed = _recentRow(row);
          if (parsed == null) continue;
          final int? prev = age[parsed.k];
          if (prev == null || parsed.a < prev) age[parsed.k] = parsed.a;
        }
      }
    }
    return ShuffleMemory(pairs, age);
  }

  static void commitShuffleMemory(List<String> order, {String? anchor}) {
    if (order.isEmpty && (anchor == null || anchor.isEmpty)) return;
    final List<String> seq = <String>[
      if (anchor != null && anchor.isNotEmpty) anchor,
      ...order,
    ];
    final List<String> freshPairs = <String>[];
    for (var i = 1; i < seq.length; i++) {
      if (sameAudioPath(seq[i - 1], seq[i])) continue;
      freshPairs.add(_pair(seq[i - 1], seq[i]));
    }
    final Set<String> played = <String>{
      for (final String p in seq) audioPathKey(p),
    };
    final Set<String> dirs = <String>{
      for (final String p in seq)
        if (p.isNotEmpty) File(p).parent.path,
    };
    for (final String dir in dirs) {
      final Map<String, dynamic> sh = _map(section(dir, 'shuffle'));
      final List<String> pairs = <String>[
        for (final dynamic p in (sh['pairs'] as List?) ?? const <dynamic>[])
          p.toString(),
        ...freshPairs,
      ];
      final Set<String> seen = <String>{};
      final List<String> newestFirst = <String>[];
      for (final String p in pairs.reversed) {
        if (seen.add(p)) newestFirst.add(p);
      }
      final List<String> kept = newestFirst.reversed.toList();
      final Map<String, int> ages = <String, int>{};
      final dynamic recent = sh['recent'];
      if (recent is List) {
        for (final dynamic row in recent) {
          final ({String k, int a})? parsed = _recentRow(row);
          if (parsed == null) continue;
          final int next = parsed.a + 1;
          if (next <= shuffleAgeMax) ages[parsed.k] = next;
        }
      }
      for (final String k in played) {
        ages[k] = 1;
      }
      final List<MapEntry<String, int>> ranked = ages.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final List<MapEntry<String, int>> capped =
          ranked.length > shuffleRecentCap
          ? ranked.sublist(0, shuffleRecentCap)
          : ranked;
      sh['pairs'] = kept.length > shufflePairCap
          ? kept.sublist(kept.length - shufflePairCap)
          : kept;
      sh['recent'] = <List<Object>>[
        for (final MapEntry<String, int> e in capped) <Object>[e.key, e.value],
      ];
      _trimShuffle(sh);
      putSection(dir, 'shuffle', sh);
    }
  }

  static void _trimShuffle(Map<String, dynamic> sh) {
    List<String> pairs = <String>[
      for (final dynamic p in (sh['pairs'] as List?) ?? const <dynamic>[])
        p.toString(),
    ];
    while (pairs.length > 40 &&
        utf8.encode(jsonEncode(sh)).length > shuffleSectionMaxBytes) {
      pairs.removeAt(0);
      sh['pairs'] = pairs;
    }
  }

  static ({String k, int a})? _recentRow(dynamic row) {
    if (row is List && row.length >= 2) {
      final int? a = row[1] is num
          ? (row[1] as num).toInt()
          : int.tryParse('${row[1]}');
      if (a == null) return null;
      return (k: row[0].toString(), a: a);
    }
    if (row is Map && row['k'] != null) {
      final dynamic raw = row['a'];
      final int? a = raw is num ? raw.toInt() : int.tryParse('$raw');
      if (a == null) return null;
      return (k: '${row['k']}', a: a);
    }
    return null;
  }

  static String _pair(String a, String b) =>
      '${audioPathKey(a)}\u0001${audioPathKey(b)}';

  static dynamic _legacySection(String dir, String key) {
    for (final MapEntry<String, String> e in _legacySections.entries) {
      if (e.value != key) continue;
      final Object? old = _decodeFile(File('$dir$_sep${e.key}'));
      return old;
    }
    return null;
  }

  static Object? _decodeFile(File f) {
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _read(String dir) {
    final File f = fileOf(dir);
    if (!f.existsSync()) return <String, dynamic>{'schema': 1};
    try {
      final Object? d = jsonDecode(f.readAsStringSync());
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return null;
  }

  static bool _write(String dir, Map<String, dynamic> doc) {
    try {
      doc['schema'] = 1;
      final String text = jsonEncode(doc);
      final Object? parsed = jsonDecode(text);
      if (parsed is! Map) return false;
      final File dest = fileOf(dir);
      final File tmp = File('${dest.path}.tmp');
      tmp.writeAsStringSync(text, flush: true);
      final Object? back = jsonDecode(tmp.readAsStringSync());
      if (!jsonEqual(back, parsed)) {
        try {
          tmp.deleteSync();
        } catch (_) {}
        return false;
      }
      if (dest.existsSync()) dest.deleteSync();
      tmp.renameSync(dest.path);
      hideOnWindows(dest.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic> _map(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    return <String, dynamic>{};
  }
}

Map<String, dynamic> readDjMetadata(String dir) =>
    GatomixStore.readMap(dir, 'djMetadata');

void writeDjMetadata(String dir, Map<String, dynamic> data) =>
    GatomixStore.writeMap(dir, 'djMetadata', data);

/// BPM y tonalidad de una pista, ya, en el `.gatomix.json` de su carpeta.
/// No toca el audio. Un BPM 0 no pisa uno que ya estaba.
void saveTrackMusic(String path, {required double bpm, String? camelot}) {
  if (path.isEmpty) return;
  final String? key = camelot?.trim();
  final bool hasKey = key != null && key.isNotEmpty;
  if (bpm <= 0 && !hasKey) return;
  final String dir = File(path).parent.path;
  final Map<String, dynamic> map = readDjMetadata(dir);
  String? slot;
  dynamic prev;
  final String want = audioPathKey(path);
  for (final MapEntry<String, dynamic> e in map.entries) {
    if (audioPathKey(e.key) != want) continue;
    slot = e.key;
    prev = e.value;
    break;
  }
  var stored = bpm;
  if (stored <= 0 && prev is num) stored = prev.toDouble();
  if (stored <= 0 && prev is Map && prev['bpm'] is num) {
    stored = (prev['bpm'] as num).toDouble();
  }
  String? storedKey = hasKey ? key : null;
  if ((storedKey == null || storedKey.isEmpty) &&
      prev is Map &&
      prev['key'] is String) {
    storedKey = (prev['key'] as String).trim();
  }
  if (stored <= 0 && (storedKey == null || storedKey.isEmpty)) return;
  final Object value = (storedKey == null || storedKey.isEmpty)
      ? stored
      : <String, dynamic>{
          if (stored > 0) 'bpm': stored,
          'key': storedKey,
        };
  if (slot != null && slot != path) map.remove(slot);
  map[path] = value;
  writeDjMetadata(dir, map);
}

/// Lo que escribe el índice de BPM. No borra una tonalidad `{bpm, key}`
/// ni pisa un BPM ya guardado con 0. Lo que no se volvió a medir se queda.
Map<String, dynamic> bpmIndexPreservingKeys(
  Map<String, dynamic> existing,
  Map<String, double> measured,
) {
  final Map<String, dynamic> out = <String, dynamic>{
    for (final MapEntry<String, dynamic> e in existing.entries) e.key: e.value,
  };
  String? slotFor(String key) {
    if (out.containsKey(key)) return key;
    final String want = audioPathKey(key);
    for (final String k in out.keys) {
      if (audioPathKey(k) == want) return k;
    }
    return null;
  }

  for (final MapEntry<String, double> e in measured.entries) {
    final String? slot = slotFor(e.key);
    final dynamic prev = slot == null ? null : out[slot];
    String? camelot;
    var prevBpm = 0.0;
    if (prev is Map) {
      if (prev['key'] is String && (prev['key'] as String).trim().isNotEmpty) {
        camelot = (prev['key'] as String).trim();
      }
      if (prev['bpm'] is num) prevBpm = (prev['bpm'] as num).toDouble();
    } else if (prev is num) {
      prevBpm = prev.toDouble();
    }
    final double bpm = e.value > 0 ? e.value : prevBpm;
    final Object value;
    if (camelot != null) {
      value = <String, dynamic>{
        if (bpm > 0) 'bpm': bpm,
        'key': camelot,
      };
    } else if (bpm > 0) {
      value = bpm;
    } else if (prev != null) {
      continue;
    } else {
      value = 0.0;
    }
    if (slot != null && slot != e.key) out.remove(slot);
    out[e.key] = value;
  }
  return out;
}

Map<String, dynamic> readDjTimestamps(String dir) =>
    GatomixStore.readMap(dir, 'djTimestamps');

void writeDjTimestamps(String dir, Map<String, dynamic> data) =>
    GatomixStore.writeMap(dir, 'djTimestamps', data);

Map<String, dynamic> readLyricsAuto(String dir) =>
    GatomixStore.readMap(dir, 'lyricsAuto');

void writeLyricsAuto(String dir, Map<String, dynamic> data) =>
    GatomixStore.writeMap(dir, 'lyricsAuto', data);

Map<String, dynamic> readLyricFailMap(String dir) =>
    GatomixStore.readMap(dir, 'lyricFail');

void writeLyricFailMap(String dir, Map<String, dynamic> data) =>
    GatomixStore.writeMap(dir, 'lyricFail', data);

dynamic mergeJson(dynamic fresh, dynamic old) {
  if (old == null) return fresh;
  if (fresh == null) return old;
  if (fresh is Map && old is Map) {
    final Map<String, dynamic> out = <String, dynamic>{};
    final Set<String> keys = <String>{
      for (final dynamic k in old.keys) k.toString(),
      for (final dynamic k in fresh.keys) k.toString(),
    };
    for (final String k in keys) {
      out[k] = mergeJson(fresh[k], old[k]);
    }
    return out;
  }
  if (fresh is List && old is List) {
    final List<dynamic> out = <dynamic>[];
    final Set<String> seen = <String>{};
    for (final dynamic item in <dynamic>[...old, ...fresh]) {
      if (seen.add(jsonEncode(item))) out.add(item);
    }
    return out;
  }
  return fresh;
}

bool jsonEqual(dynamic a, dynamic b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final dynamic k in a.keys) {
      if (!b.containsKey(k) || !jsonEqual(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

void hideOnWindows(String path) {
  if (!Platform.isWindows) return;
  try {
    Process.runSync('attrib', <String>['+h', path]);
  } catch (_) {}
}

/// Un solo `.gatomix.log` por carpeta. Al pasar ~200 KB se queda con la cola.
class GatomixLog {
  static void append(String dir, String line) {
    try {
      final File f = File('$dir${Platform.pathSeparator}$gatomixLogName');
      final String prev = f.existsSync() ? f.readAsStringSync() : '';
      _write(f, '$prev${DateTime.now().toIso8601String()} $line\n');
    } catch (_) {}
  }

  static void fold(String dir, File old) {
    try {
      if (!old.existsSync()) return;
      final String text = old.readAsStringSync();
      if (text.isEmpty) return;
      final File f = File('$dir${Platform.pathSeparator}$gatomixLogName');
      final String prev = f.existsSync() ? f.readAsStringSync() : '';
      final String name = old.uri.pathSegments.last;
      _write(f, '$prev--- $name ---\n$text');
    } catch (_) {}
  }

  static void _write(File f, String text) {
    var out = text;
    final List<int> bytes = utf8.encode(out);
    if (bytes.length > gatomixLogMaxBytes) {
      final List<int> tail = bytes.sublist(
        bytes.length - (gatomixLogMaxBytes ~/ 2),
      );
      out = utf8.decode(tail, allowMalformed: true);
      final int nl = out.indexOf('\n');
      if (nl >= 0 && nl < out.length - 1) out = out.substring(nl + 1);
    }
    f.writeAsStringSync(out, flush: true);
    hideOnWindows(f.path);
  }
}
