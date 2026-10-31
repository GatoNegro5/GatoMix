import 'dart:math';

import 'audio_path.dart';
import 'queue_bpm.dart';
import 'track_name_clean.dart';

/// Orden de la cola de Live DJ en modo Secuencial.
enum LiveDjSortMode { manual, alphabetical, bpmAsc, bpmDesc }

const Map<LiveDjSortMode, String> kLiveDjSortLabels = {
  LiveDjSortMode.manual: 'Como se cargó',
  LiveDjSortMode.alphabetical: 'Alfabético (A-Z)',
  LiveDjSortMode.bpmAsc: 'BPM (Menor a Mayor)',
  LiveDjSortMode.bpmDesc: 'BPM (Mayor a Menor)',
};

String _nameOf(String p) =>
    p.replaceAll('\\', '/').split('/').last.toLowerCase();

/// Ordena [paths] según [mode]. Sin BPM (0) van al final en los modos BPM.
List<String> sortLiveDjPaths(
  List<String> paths,
  LiveDjSortMode mode,
  double Function(String path) bpmOf,
) {
  final List<String> out = List<String>.from(paths);
  switch (mode) {
    case LiveDjSortMode.manual:
      return out;
    case LiveDjSortMode.alphabetical:
      out.sort((a, b) => _nameOf(a).compareTo(_nameOf(b)));
      return out;
    case LiveDjSortMode.bpmAsc:
    case LiveDjSortMode.bpmDesc:
      final bool up = mode == LiveDjSortMode.bpmAsc;
      out.sort((a, b) {
        final double x = bpmOf(a), y = bpmOf(b);
        final bool xa = x > 0, ya = y > 0;
        if (xa != ya) return xa ? -1 : 1;
        final int c = up ? x.compareTo(y) : y.compareTo(x);
        return c != 0 ? c : _nameOf(a).compareTo(_nameOf(b));
      });
      return out;
  }
}

/// Firma de un grupo (sin importar el orden interno).
String groupSignature(List<String> group) {
  final List<String> s = List<String>.from(group)..sort();
  return s.join('\u0001');
}

/// Camelot del nombre (`8A`, `11B`), si el archivo lo trae.
String? camelotFromPath(String path) => cleanTrackFileName(path).camelot;

/// Misma casilla, ±1 en la rueda (con vuelta 12↔1) o el cambio A/B.
bool camelotCompatible(String a, String b) {
  final (int, String)? pa = _camelot(a);
  final (int, String)? pb = _camelot(b);
  if (pa == null || pb == null) return false;
  if (pa.$1 == pb.$1 && pa.$2 == pb.$2) return true;
  if (pa.$1 == pb.$1) return true;
  if (pa.$2 == pb.$2) {
    final int d = (pa.$1 - pb.$1).abs();
    if (d == 1 || d == 11) return true;
  }
  return false;
}

(int, String)? _camelot(String raw) {
  final RegExpMatch? m = RegExp(
    r'^(\d{1,2})\s*([abAB])$',
  ).firstMatch(raw.trim());
  if (m == null) return null;
  final int n = int.parse(m.group(1)!);
  if (n < 1 || n > 12) return null;
  return (n, m.group(2)!.toUpperCase());
}

String shufflePairKey(String a, String b, {bool? foldCase}) =>
    '${audioPathKey(a, foldCase: foldCase)}\u0001${audioPathKey(b, foldCase: foldCase)}';

/// Orden armónico (djay / Harmonize):
/// primera al azar; la siguiente entre las no usadas con |BPM−actual| ≤ 4
/// (si no hay, 8, luego 12, luego la más cercana). Con tonalidad, se prefiere
/// Camelot compatible. Se puntúa y se elige al azar entre los 3 mejores.
/// Unas [waveLength] pistas suben y otras tantas bajan. Sin BPM al final.
/// Sin `_K`, sin duplicados, y nunca [playing].
class HarmonicOrder {
  final List<String> tracks;
  final bool waveUp;
  final int inWave;
  const HarmonicOrder(this.tracks, {this.waveUp = true, this.inWave = 0});
}

HarmonicOrder buildHarmonicShuffle(
  List<String> paths,
  double Function(String path) bpmOf, {
  String? Function(String path)? keyOf,
  Set<String> usedPairs = const <String>{},
  Map<String, int> recentAge = const <String, int>{},
  String? playing,
  String? continueFrom,
  String? fixedFirst,
  Random? rng,
  bool? foldCase,
  int waveLength = 20,
  bool startWaveUp = true,
  int startInWave = 0,
}) {
  final Random random = rng ?? Random();
  final List<String> uniq = <String>[];
  final Set<String> seen = <String>{};
  for (final String p in paths) {
    if (isKaraokeAudioPath(p)) continue;
    if (playing != null && sameAudioPath(p, playing, foldCase: foldCase)) {
      continue;
    }
    if (continueFrom != null &&
        sameAudioPath(p, continueFrom, foldCase: foldCase)) {
      continue;
    }
    if (seen.add(audioPathKey(p, foldCase: foldCase))) uniq.add(p);
  }
  final List<String> known = <String>[];
  final List<String> unknown = <String>[];
  for (final String p in uniq) {
    if (bpmOf(p) > 0) {
      known.add(p);
    } else {
      unknown.add(p);
    }
  }
  final List<String> order = <String>[];
  String? current = continueFrom;
  var up = startWaveUp;
  var inWave = startInWave < 0 ? 0 : startInWave;
  final int wave = waveLength < 1 ? 20 : waveLength;

  void placed() {
    inWave++;
    if (inWave >= wave) {
      up = !up;
      inWave = 0;
    }
  }

  if (current == null || bpmOf(current) <= 0) {
    current = null;
    if (known.isNotEmpty) {
      String first = known[random.nextInt(known.length)];
      if (fixedFirst != null) {
        for (final String p in known) {
          if (sameAudioPath(p, fixedFirst, foldCase: foldCase)) {
            first = p;
            break;
          }
        }
      }
      known.remove(first);
      order.add(first);
      current = first;
      placed();
    }
  }

  // Por debajo de esto el bucle de siempre (las pruebas chicas). Por
  // encima, índice por BPM: el bucle viejo es O(n²) con `audioPathKey` en
  // cada candidato y en una radio de miles de pistas congela la ventana.
  if (known.length >= 240 && current != null) {
    return _harmonicRest(
      known: known,
      unknown: unknown,
      currentPath: current,
      order: order,
      random: random,
      bpmOf: bpmOf,
      keyOf: keyOf,
      usedPairs: usedPairs,
      recentAge: recentAge,
      foldCase: foldCase,
      wave: wave,
      up: up,
      inWave: inWave,
    );
  }

  while (known.isNotEmpty && current != null) {
    final double cur = bpmOf(current);
    bool along(String p) {
      final double b = bpmOf(p);
      if ((b - cur).abs() <= 0.05) return true;
      return up ? b > cur : b < cur;
    }

    List<String> window(double delta) => known
        .where((String p) => (bpmOf(p) - cur).abs() <= delta + 1e-6)
        .toList();
    // La ola manda dentro de la ventana. Si en esa dirección no hay nadie
    // a ≤4, se amplía a 8 y a 12; si tampoco, la más cercana en la ola y,
    // en último caso, la más cercana de todas.
    List<String> cands = window(4).where(along).toList();
    if (cands.isEmpty) cands = window(8).where(along).toList();
    if (cands.isEmpty) cands = window(12).where(along).toList();
    if (cands.isEmpty) {
      final List<String> side = known.where(along).toList();
      cands = <String>[_closest(side.isEmpty ? known : side, bpmOf, cur)];
    }
    final String pick = _pickTop3(
      cands,
      current,
      cur,
      up,
      bpmOf,
      keyOf,
      usedPairs,
      recentAge,
      random,
      foldCase,
    );
    known.remove(pick);
    order.add(pick);
    current = pick;
    placed();
  }
  unknown.shuffle(random);
  order.addAll(unknown);
  return HarmonicOrder(order, waveUp: up, inWave: inWave);
}

String _closest(
  List<String> pool,
  double Function(String path) bpmOf,
  double cur,
) {
  String best = pool.first;
  double bestD = double.infinity;
  for (final String p in pool) {
    final double d = (bpmOf(p) - cur).abs();
    if (d < bestD) {
      bestD = d;
      best = p;
    }
  }
  return best;
}

String _pickTop3(
  List<String> cands,
  String current,
  double cur,
  bool up,
  double Function(String path) bpmOf,
  String? Function(String path)? keyOf,
  Set<String> usedPairs,
  Map<String, int> recentAge,
  Random rng,
  bool? foldCase,
) {
  final String? ka = keyOf?.call(current);
  final List<(String, double)> scored = <(String, double)>[];
  for (final String p in cands) {
    final double bpm = bpmOf(p);
    final double dist = (bpm - cur).abs();
    double score = (12 - dist) * 8;
    final bool higher = bpm > cur + 0.05;
    final bool lower = bpm < cur - 0.05;
    if (up && higher) score += 36;
    if (!up && lower) score += 36;
    if ((up && lower) || (!up && higher)) score -= 12;
    final String? kb = keyOf?.call(p);
    if (ka != null && ka.isNotEmpty && kb != null && kb.isNotEmpty) {
      score += camelotCompatible(ka, kb) ? 28 : -18;
    }
    if (usedPairs.contains(shufflePairKey(current, p, foldCase: foldCase))) {
      score -= 400;
    }
    final int? age = recentAge[audioPathKey(p, foldCase: foldCase)];
    if (age != null && age >= 1 && age <= 8) score -= (9 - age) * 22;
    scored.add((p, score));
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  final List<(String, double)> top = scored.take(3).toList();
  if (top.length == 1) return top.first.$1;
  final double minS = top.map((e) => e.$2).reduce(min);
  final List<double> weights = <double>[
    for (final (String, double) e in top) e.$2 - minS + 1,
  ];
  final double sum = weights.reduce((double a, double b) => a + b);
  var ticket = rng.nextDouble() * sum;
  for (var i = 0; i < top.length; i++) {
    ticket -= weights[i];
    if (ticket <= 0) return top[i].$1;
  }
  return top.last.$1;
}

class _Tr {
  final String path;
  final double bpm;
  final String? key;
  final String id;
  final int ord;
  const _Tr(this.path, this.bpm, this.key, this.id, this.ord);
}

Map<String, Set<String>> _usedNextOf(Set<String> pairs) {
  final Map<String, Set<String>> out = <String, Set<String>>{};
  for (final String p in pairs) {
    final int i = p.indexOf('\u0001');
    if (i <= 0) continue;
    out
        .putIfAbsent(p.substring(0, i), () => <String>{})
        .add(p.substring(i + 1));
  }
  return out;
}

int _lowerBpm(List<int> ids, List<_Tr> pool, double x) {
  var lo = 0;
  var hi = ids.length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (pool[ids[mid]].bpm < x) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int _upperBpm(List<int> ids, List<_Tr> pool, double x) {
  var lo = 0;
  var hi = ids.length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (pool[ids[mid]].bpm <= x) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Los 3 no penalizados más cercanos de este lado, dentro de [delta].
/// Misma puntuación que [_pickTop3]: a igual BPM y tonalidad manda el
/// orden original, así que la lista va ordenada por BPM y luego por `ord`.
List<int> _takeSide(
  List<int> ids,
  List<_Tr> pool,
  List<bool> alive,
  double cur,
  double delta,
  int side,
  Set<String>? ban,
) {
  final int from;
  final int until;
  final bool forward;
  if (side == 1) {
    final double minB = cur + 0.05;
    final double maxB = cur + delta + 1e-6;
    if (minB > maxB) return const <int>[];
    from = _lowerBpm(ids, pool, minB);
    until = _upperBpm(ids, pool, maxB);
    forward = true;
  } else if (side == 2) {
    final double maxB = cur - 0.05;
    final double minB = cur - delta - 1e-6;
    if (minB > maxB) return const <int>[];
    from = _lowerBpm(ids, pool, minB);
    until = _upperBpm(ids, pool, maxB);
    forward = false;
  } else {
    from = _lowerBpm(ids, pool, cur - 0.05 - 1e-9);
    until = _upperBpm(ids, pool, cur + 0.05 + 1e-9);
    forward = true;
  }
  if (from >= until) return const <int>[];
  final List<int> out = <int>[];
  var good = 0;
  var i = forward ? from : until - 1;
  while (forward ? i < until : i >= from) {
    final int id = ids[i];
    i += forward ? 1 : -1;
    if (!alive[id]) continue;
    final bool banned = ban != null && ban.contains(pool[id].id);
    if (!banned) {
      out.add(id);
      good++;
      if (good >= 3) break;
    } else if (out.length < 6) {
      out.add(id);
    }
    if (out.length >= 8) break;
  }
  return out;
}

HarmonicOrder _harmonicRest({
  required List<String> known,
  required List<String> unknown,
  required String currentPath,
  required List<String> order,
  required Random random,
  required double Function(String path) bpmOf,
  required String? Function(String path)? keyOf,
  required Set<String> usedPairs,
  required Map<String, int> recentAge,
  required bool? foldCase,
  required int wave,
  required bool up,
  required int inWave,
}) {
  final List<_Tr> pool = <_Tr>[
    for (var i = 0; i < known.length; i++)
      _Tr(
        known[i],
        bpmOf(known[i]),
        keyOf?.call(known[i]),
        audioPathKey(known[i], foldCase: foldCase),
        i,
      ),
  ];
  final String curId = audioPathKey(currentPath, foldCase: foldCase);
  final _Tr anchor = _Tr(
    currentPath,
    bpmOf(currentPath),
    keyOf?.call(currentPath),
    curId,
    -1,
  );
  final Map<String, List<int>> byKey = <String, List<int>>{};
  for (var i = 0; i < pool.length; i++) {
    final String k = pool[i].key ?? '';
    byKey.putIfAbsent(k.isEmpty ? '' : k, () => <int>[]).add(i);
  }
  for (final List<int> list in byKey.values) {
    list.sort((int a, int b) {
      final int c = pool[a].bpm.compareTo(pool[b].bpm);
      return c != 0 ? c : pool[a].ord.compareTo(pool[b].ord);
    });
  }
  final List<bool> alive = List<bool>.filled(pool.length, true);
  var aliveCount = pool.length;
  var dead = 0;
  final Map<String, Set<String>> usedNext = _usedNextOf(usedPairs);
  final bool ageMatters = recentAge.isNotEmpty;
  _Tr current = anchor;

  void placed() {
    inWave++;
    if (inWave >= wave) {
      up = !up;
      inWave = 0;
    }
  }

  void compact() {
    for (final List<int> list in byKey.values) {
      list.removeWhere((int id) => !alive[id]);
    }
    dead = 0;
  }

  double scoreOf(_Tr t, _Tr cur) {
    final double dist = (t.bpm - cur.bpm).abs();
    double score = (12 - dist) * 8;
    final bool higher = t.bpm > cur.bpm + 0.05;
    final bool lower = t.bpm < cur.bpm - 0.05;
    if (up && higher) score += 36;
    if (!up && lower) score += 36;
    if ((up && lower) || (!up && higher)) score -= 12;
    final String? ka = cur.key;
    final String? kb = t.key;
    if (ka != null && ka.isNotEmpty && kb != null && kb.isNotEmpty) {
      score += camelotCompatible(ka, kb) ? 28 : -18;
    }
    final Set<String>? ban = usedNext[cur.id];
    if (ban != null && ban.contains(t.id)) score -= 400;
    final int? age = recentAge[t.id];
    if (age != null && age >= 1 && age <= 8) score -= (9 - age) * 22;
    return score;
  }

  List<int> scanWindow(double delta) {
    final double lo = current.bpm - delta - 1e-6;
    final double hi = current.bpm + delta + 1e-6;
    final List<int> ids = <int>[];
    for (var i = 0; i < pool.length; i++) {
      if (!alive[i]) continue;
      final _Tr t = pool[i];
      if (t.bpm < lo || t.bpm > hi) continue;
      final bool higher = t.bpm > current.bpm + 0.05;
      final bool lower = t.bpm < current.bpm - 0.05;
      final bool along = (!higher && !lower) || (up ? higher : lower);
      if (along) ids.add(i);
    }
    return ids;
  }

  List<int> indexedWindow(double delta) {
    final int dirSide = up ? 1 : 2;
    final Set<String>? ban = usedNext[current.id];
    final List<int> ids = <int>[];
    for (final List<int> list in byKey.values) {
      ids.addAll(_takeSide(list, pool, alive, current.bpm, delta, 0, ban));
      ids.addAll(
        _takeSide(list, pool, alive, current.bpm, delta, dirSide, ban),
      );
    }
    return ids;
  }

  int? closestWhere(bool Function(_Tr t) ok) {
    int? best;
    var bestD = double.infinity;
    var bestOrd = 1 << 30;
    for (final List<int> list in byKey.values) {
      if (list.isEmpty) continue;
      final int at = _lowerBpm(list, pool, current.bpm);
      var l = at - 1;
      var r = at;
      while (l >= 0 || r < list.length) {
        final bool useR =
            l < 0 ||
            (r < list.length &&
                (pool[list[r]].bpm - current.bpm).abs() <=
                    (pool[list[l]].bpm - current.bpm).abs());
        final int id = list[useR ? r++ : l--];
        if (!alive[id]) continue;
        final _Tr t = pool[id];
        if (!ok(t)) continue;
        final double d = (t.bpm - current.bpm).abs();
        if (d < bestD - 1e-9 || (d <= bestD + 1e-9 && t.ord < bestOrd)) {
          bestD = d;
          bestOrd = t.ord;
          best = id;
        }
        break;
      }
    }
    return best;
  }

  String choose(List<int> ids) {
    if (ids.length == 1) return pool[ids.first].path;
    final List<int> uniq = <int>[];
    final Set<int> seen = <int>{};
    for (final int id in ids) {
      if (seen.add(id)) uniq.add(id);
    }
    uniq.sort((int a, int b) {
      final double sa = scoreOf(pool[a], current);
      final double sb = scoreOf(pool[b], current);
      final int c = sb.compareTo(sa);
      return c != 0 ? c : pool[a].ord.compareTo(pool[b].ord);
    });
    final List<int> top = uniq.take(3).toList()
      ..sort((int a, int b) => pool[a].ord.compareTo(pool[b].ord));
    return _pickTop3(
      <String>[for (final int id in top) pool[id].path],
      current.path,
      current.bpm,
      up,
      bpmOf,
      keyOf,
      usedPairs,
      recentAge,
      random,
      foldCase,
    );
  }

  while (aliveCount > 0) {
    List<int> ids = ageMatters ? scanWindow(4) : indexedWindow(4);
    if (ids.isEmpty) ids = ageMatters ? scanWindow(8) : indexedWindow(8);
    if (ids.isEmpty) ids = ageMatters ? scanWindow(12) : indexedWindow(12);
    int? pick;
    if (ids.isEmpty) {
      bool along(_Tr t) {
        final bool higher = t.bpm > current.bpm + 0.05;
        final bool lower = t.bpm < current.bpm - 0.05;
        if (!higher && !lower) return true;
        return up ? higher : lower;
      }

      pick = closestWhere(along) ?? closestWhere((_) => true);
    } else {
      final String path = choose(ids);
      for (final int id in ids) {
        if (pool[id].path == path) {
          pick = id;
          break;
        }
      }
      pick ??= ids.first;
    }
    if (pick == null) break;
    alive[pick] = false;
    aliveCount--;
    dead++;
    if (dead > 512 && dead > aliveCount) compact();
    order.add(pool[pick].path);
    current = pool[pick];
    placed();
  }
  unknown.shuffle(random);
  order.addAll(unknown);
  return HarmonicOrder(order, waveUp: up, inWave: inWave);
}

/// Tonalidad del nombre o, si no viene, la guardada en `.gatomix.json`.
String? harmonicKeyOf(String path) {
  final String? named = camelotFromPath(path);
  if (named != null && named.isNotEmpty) return named;
  final String? stored = readStoredCamelot(path);
  if (stored == null) return null;
  final (int, String)? parsed = _camelot(stored);
  if (parsed == null) return null;
  return '${parsed.$1}${parsed.$2}';
}

/// Siguiente pista entre [candidates] con los criterios del Shuffle armónico.
/// Sin ancla de BPM elige al azar entre las que tienen BPM (si no hay, entre
/// todas). Sin candidatos devuelve null.
String? pickHarmonicNext(
  List<String> candidates,
  double Function(String path) bpmOf, {
  String? Function(String path)? keyOf,
  String? anchor,
  double anchorBpm = 0,
  bool waveUp = true,
  Set<String> usedPairs = const <String>{},
  Map<String, int> recentAge = const <String, int>{},
  Random? rng,
  bool? foldCase,
}) {
  final Random random = rng ?? Random();
  final List<String> known = <String>[];
  final List<String> unknown = <String>[];
  final Set<String> seen = <String>{};
  for (final String p in candidates) {
    if (isKaraokeAudioPath(p)) continue;
    if (!seen.add(audioPathKey(p, foldCase: foldCase))) continue;
    if (bpmOf(p) > 0) {
      known.add(p);
    } else {
      unknown.add(p);
    }
  }
  final double cur = anchor != null && bpmOf(anchor) > 0
      ? bpmOf(anchor)
      : anchorBpm;
  final String anchorPath = anchor ?? '';
  if (cur <= 0 || known.isEmpty) {
    final List<String> bag = known.isNotEmpty ? known : unknown;
    if (bag.isEmpty) return null;
    return bag[random.nextInt(bag.length)];
  }
  bool along(String p) {
    final double b = bpmOf(p);
    if ((b - cur).abs() <= 0.05) return true;
    return waveUp ? b > cur : b < cur;
  }

  List<String> window(double delta) => known
      .where((String p) => (bpmOf(p) - cur).abs() <= delta + 1e-6)
      .toList();
  List<String> cands = window(4).where(along).toList();
  if (cands.isEmpty) cands = window(8).where(along).toList();
  if (cands.isEmpty) cands = window(12).where(along).toList();
  if (cands.isEmpty) {
    final List<String> side = known.where(along).toList();
    cands = <String>[_closest(side.isEmpty ? known : side, bpmOf, cur)];
  }
  return _pickTop3(
    cands,
    anchorPath,
    cur,
    waveUp,
    bpmOf,
    keyOf,
    usedPairs,
    recentAge,
    random,
    foldCase,
  );
}

/// Mete [incoming] en el hueco armónico de la parte que aún no suena.
/// [lockedPrefix] y [playing] / [pinned] no se reordenan. Sin BPM, al final.
/// No duplica rutas ni mete pistas `_K`.
List<String> insertHarmonicTracks({
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
  final List<String> base = List<String>.from(queue);
  final Set<String> seen = <String>{
    for (final String p in base) audioPathKey(p, foldCase: foldCase),
  };
  if (playing != null && playing.isNotEmpty) {
    seen.add(audioPathKey(playing, foldCase: foldCase));
  }
  final List<String> fresh = <String>[];
  final List<String> noBpm = <String>[];
  for (final String p in incoming) {
    if (isKaraokeAudioPath(p)) continue;
    if (!seen.add(audioPathKey(p, foldCase: foldCase))) continue;
    if (bpmOf(p) > 0) {
      fresh.add(p);
    } else {
      noBpm.add(p);
    }
  }
  final int wave = waveLength < 1 ? 20 : waveLength;

  int pinOf(String? path) {
    if (path == null || path.isEmpty) return 0;
    for (var i = 0; i < base.length; i++) {
      if (sameAudioPath(base[i], path, foldCase: foldCase)) return i + 1;
    }
    return 0;
  }

  var lock = lockedPrefix;
  if (lock < 0) lock = 0;
  final int playLock = pinOf(playing);
  final int pinLock = pinOf(pinned);
  if (playLock > lock) lock = playLock;
  if (pinLock > lock) lock = pinLock;
  if (lock > base.length) lock = base.length;

  String? prevKnown(int i) {
    for (var j = i - 1; j >= 0; j--) {
      if (bpmOf(base[j]) > 0) return base[j];
    }
    if (playing != null &&
        playing.isNotEmpty &&
        bpmOf(playing) > 0 &&
        !base.any(
          (String p) => sameAudioPath(p, playing, foldCase: foldCase),
        )) {
      return playing;
    }
    return null;
  }

  String? nextKnown(int i, int tail) {
    for (var j = i; j < tail; j++) {
      if (bpmOf(base[j]) > 0) return base[j];
    }
    return null;
  }

  int tierOf(double dist) {
    if (dist <= 4) return 0;
    if (dist <= 8) return 1;
    if (dist <= 12) return 2;
    return 3;
  }

  for (final String p in fresh) {
    var tail = base.length;
    while (tail > lock && bpmOf(base[tail - 1]) <= 0) {
      tail--;
    }
    var bestI = tail;
    var bestTier = 1 << 20;
    var bestKey = -100;
    var bestWave = -2;
    var bestDist = double.infinity;
    final double b = bpmOf(p);
    final String? kb = keyOf?.call(p);
    for (var i = lock; i <= tail; i++) {
      final String? prev = prevKnown(i);
      final String? next = i < tail ? nextKnown(i, tail) : null;
      final double? dp = prev == null ? null : (b - bpmOf(prev)).abs();
      final double? dn = next == null ? null : (b - bpmOf(next)).abs();
      var tier = 4;
      if (dp != null && dn != null) {
        tier = max(tierOf(dp), tierOf(dn));
      } else if (dp != null) {
        tier = tierOf(dp);
      } else if (dn != null) {
        tier = tierOf(dn);
      }
      var keys = 0;
      if (kb != null && kb.isNotEmpty) {
        final String? kp = prev == null ? null : keyOf?.call(prev);
        final String? kn = next == null ? null : keyOf?.call(next);
        if (kp != null && kp.isNotEmpty) {
          keys += camelotCompatible(kp, kb) ? 1 : -1;
        }
        if (kn != null && kn.isNotEmpty) {
          keys += camelotCompatible(kn, kb) ? 1 : -1;
        }
      }
      var placed = 0;
      for (var j = 0; j < i; j++) {
        if (bpmOf(base[j]) <= 0) continue;
        if (playing != null &&
            sameAudioPath(base[j], playing, foldCase: foldCase)) {
          continue;
        }
        placed++;
      }
      final bool up = (placed ~/ wave) % 2 == 0;
      var waveScore = 0;
      if (prev != null) {
        final double pb = bpmOf(prev);
        final bool higher = b > pb + 0.05;
        final bool lower = b < pb - 0.05;
        final bool flat = (b - pb).abs() <= 0.05;
        if (flat || (up && higher) || (!up && lower)) {
          waveScore = 1;
        } else {
          waveScore = -1;
        }
      }
      final double dist = (dp ?? 0) + (dn ?? 0);
      final bool better =
          tier < bestTier ||
          (tier == bestTier && keys > bestKey) ||
          (tier == bestTier && keys == bestKey && waveScore > bestWave) ||
          (tier == bestTier &&
              keys == bestKey &&
              waveScore == bestWave &&
              dist < bestDist);
      if (better) {
        bestI = i;
        bestTier = tier;
        bestKey = keys;
        bestWave = waveScore;
        bestDist = dist;
      }
    }
    base.insert(bestI, p);
    if (bestI < lock) lock = bestI;
  }
  base.addAll(noBpm);
  return base;
}
