import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'audio_path.dart';
import 'gatomix_store.dart';
import 'livedj_order.dart';

/// Estado de la Radio, en un solo archivo en la raíz de Música.
/// No es una sección de `.gatomix.json`.
const String gatomixRadioName = '.gatomix_radio.json';

/// Tope de parejas iguales con la vuelta anterior. Por encima se rearma.
const double radioPairOverlapMax = 0.20;

const int radioRebuildAttempts = 5;

/// Clave de una opción: géneros marcados, ordenados, o `todo`.
String radioGenreKey(Iterable<String> genres) {
  final List<String> list = genres
      .map((String g) => g.trim())
      .where((String g) => g.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
  if (list.isEmpty) return 'todo';
  return list.join('+');
}

/// Lista ya armada de una opción y por dónde va.
class RadioPlan {
  final List<String> order;
  final int position;

  /// Parejas A→B de esta lista.
  final List<String> pairs;

  /// Parejas de la vuelta anterior, para no repetirlas al rearmar.
  final List<String> previousPairs;

  const RadioPlan({
    this.order = const <String>[],
    this.position = 0,
    this.pairs = const <String>[],
    this.previousPairs = const <String>[],
  });

  bool get finished => order.isEmpty || position >= order.length;

  RadioPlan copy({
    List<String>? order,
    int? position,
    List<String>? pairs,
    List<String>? previousPairs,
  }) {
    return RadioPlan(
      order: order ?? this.order,
      position: position ?? this.position,
      pairs: pairs ?? this.pairs,
      previousPairs: previousPairs ?? this.previousPairs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'order': order,
    'position': position,
    'pairs': pairs,
    'previousPairs': previousPairs,
  };

  static RadioPlan fromJson(dynamic raw) {
    if (raw is! Map) return const RadioPlan();
    final dynamic pos = raw['position'];
    return RadioPlan(
      order: <String>[
        for (final dynamic p in (raw['order'] as List?) ?? const <dynamic>[])
          p.toString(),
      ],
      position: pos is num ? pos.toInt() : 0,
      pairs: <String>[
        for (final dynamic p in (raw['pairs'] as List?) ?? const <dynamic>[])
          p.toString(),
      ],
      previousPairs: <String>[
        for (final dynamic p
            in (raw['previousPairs'] as List?) ?? const <dynamic>[])
          p.toString(),
      ],
    );
  }
}

class RadioMemory {
  final List<String> history;
  final Map<String, RadioPlan> plans;

  const RadioMemory({
    this.history = const <String>[],
    this.plans = const <String, RadioPlan>{},
  });

  static const RadioMemory empty = RadioMemory();

  RadioPlan? planOf(String key) => plans[key];

  RadioMemory putPlan(String key, RadioPlan plan) {
    return RadioMemory(
      history: history,
      plans: <String, RadioPlan>{...plans, key: plan},
    );
  }

  Map<String, dynamic> toJson({String? activeKey}) {
    final RadioPlan? active = activeKey == null ? null : plans[activeKey];
    return <String, dynamic>{
      'schema': 1,
      'history': history,
      'previousPairs': active?.previousPairs ?? const <String>[],
      'plans': <String, dynamic>{
        for (final MapEntry<String, RadioPlan> e in plans.entries)
          e.key: e.value.toJson(),
      },
    };
  }
}

class RadioSync {
  final RadioPlan plan;

  /// Cierto solo cuando la lista se armó ahora (no existía o se terminó).
  final bool rebuilt;

  const RadioSync(this.plan, {required this.rebuilt});
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

bool _has(Iterable<String> xs, String p) =>
    xs.any((String e) => sameAudioPath(e, p));

List<String> _cleanPool(List<String> pool) {
  final List<String> out = <String>[];
  for (final String p in pool) {
    if (p.isEmpty || isKaraokeAudioPath(p)) continue;
    if (_has(out, p)) continue;
    out.add(p);
  }
  return out;
}

List<String> radioPairsOf(List<String> order) {
  final List<String> out = <String>[];
  for (var i = 1; i < order.length; i++) {
    if (sameAudioPath(order[i - 1], order[i])) continue;
    out.add(shufflePairKey(order[i - 1], order[i]));
  }
  return out;
}

/// Fracción de parejas A→B de [order] que ya estaban en [previous].
double radioPairOverlap(List<String> order, Iterable<String> previous) {
  if (order.length < 2) return 0;
  final Set<String> prev = previous.toSet();
  var steps = 0;
  var hit = 0;
  for (var i = 1; i < order.length; i++) {
    if (sameAudioPath(order[i - 1], order[i])) continue;
    steps++;
    if (prev.contains(shufflePairKey(order[i - 1], order[i]))) hit++;
  }
  if (steps == 0) return 0;
  return hit / steps;
}

bool sameRadioOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!sameAudioPath(a[i], b[i])) return false;
  }
  return true;
}

void _displaceFirst(List<String> order, String? banned, Random rng) {
  if (banned == null || order.length < 2) return;
  if (!sameAudioPath(order.first, banned)) return;
  final List<int> rest = <int>[for (var i = 1; i < order.length; i++) i]
    ..shuffle(rng);
  final int i = rest.first;
  final String swap = order[i];
  order[i] = order[0];
  order[0] = swap;
}

/// Arma una vuelta completa. Si hay vuelta anterior, otra semilla, otra
/// primera canción y las menos parejas A→B posible (hasta 5 intentos).
List<String> buildDifferentRound({
  required List<String> pool,
  required double Function(String path) bpmOf,
  String? Function(String path)? keyOf,
  List<String> previousOrder = const <String>[],
  List<String> previousPairs = const <String>[],
  Random? rng,
  int maxAttempts = radioRebuildAttempts,
}) {
  final List<String> songs = _cleanPool(pool);
  if (songs.length <= 1) return songs;
  final Random random = rng ?? Random();
  final String? banned = previousOrder.isEmpty ? null : previousOrder.first;
  final Set<String> used = <String>{
    ...previousPairs,
    if (previousPairs.isEmpty) ...radioPairsOf(previousOrder),
  };
  final int tries = maxAttempts < 1 ? 1 : maxAttempts;
  List<String>? best;
  var bestScore = double.infinity;
  for (var n = 0; n < tries; n++) {
    final Random spin = Random(random.nextInt(1 << 31));
    final List<String> built = List<String>.from(
      buildHarmonicShuffle(
        songs,
        bpmOf,
        keyOf: keyOf,
        usedPairs: used,
        rng: spin,
      ).tracks,
    );
    _displaceFirst(built, banned, spin);
    final bool sameFirst =
        banned != null &&
        built.isNotEmpty &&
        sameAudioPath(built.first, banned);
    final bool sameList = previousOrder.isNotEmpty &&
        sameRadioOrder(built, previousOrder);
    final double overlap = radioPairOverlap(built, used);
    final double score = overlap + (sameFirst ? 1 : 0) + (sameList ? 1 : 0);
    if (score < bestScore) {
      best = built;
      bestScore = score;
    }
    if (!sameFirst && !sameList && overlap <= radioPairOverlapMax) {
      return built;
    }
  }
  final List<String> out = List<String>.from(best ?? songs);
  _displaceFirst(out, banned, random);
  return out;
}

RadioPlan _freshPlan(
  List<String> pool,
  double Function(String path) bpmOf,
  String? Function(String path)? keyOf,
  List<String> previousOrder,
  List<String> previousPairs,
  Random rng,
) {
  final List<String> order = buildDifferentRound(
    pool: pool,
    bpmOf: bpmOf,
    keyOf: keyOf,
    previousOrder: previousOrder,
    previousPairs: previousPairs,
    rng: rng,
  );
  return RadioPlan(
    order: order,
    position: 0,
    pairs: radioPairsOf(order),
    previousPairs: previousPairs.isNotEmpty
        ? previousPairs
        : radioPairsOf(previousOrder),
  );
}

/// Conserva la lista guardada. La rearma solo si no existe o ya se terminó.
/// Lo nuevo entra en lo que falta por sonar; lo que ya no está se quita.
RadioSync syncRadioPlan({
  required RadioPlan? saved,
  required List<String> pool,
  required double Function(String path) bpmOf,
  String? Function(String path)? keyOf,
  String? pinned,
  Random? rng,
}) {
  final Random random = rng ?? Random();
  final List<String> songs = _cleanPool(pool);
  if (songs.isEmpty) {
    return RadioSync(
      const RadioPlan(),
      rebuilt: saved == null,
    );
  }
  if (saved == null || saved.order.isEmpty) {
    return RadioSync(
      _freshPlan(songs, bpmOf, keyOf, const <String>[], const <String>[], random),
      rebuilt: true,
    );
  }
  final List<String> kept = <String>[];
  var removedBefore = 0;
  for (var i = 0; i < saved.order.length; i++) {
    if (_has(songs, saved.order[i])) {
      kept.add(saved.order[i]);
    } else if (i < saved.position) {
      removedBefore++;
    }
  }
  var position = saved.position - removedBefore;
  if (position < 0) position = 0;
  if (position > kept.length) position = kept.length;
  if (position >= kept.length) {
    final List<String> prevPairs = saved.pairs.isNotEmpty
        ? saved.pairs
        : radioPairsOf(saved.order);
    return RadioSync(
      _freshPlan(songs, bpmOf, keyOf, saved.order, prevPairs, random),
      rebuilt: true,
    );
  }
  final List<String> prefix = kept.sublist(0, position);
  List<String> tail = kept.sublist(position);
  final List<String> fresh = <String>[
    for (final String p in songs)
      if (!_has(kept, p)) p,
  ];
  if (fresh.isNotEmpty) {
    var lock = 0;
    if (pinned != null &&
        tail.isNotEmpty &&
        sameAudioPath(tail.first, pinned)) {
      lock = 1;
    }
    tail = insertHarmonicTracks(
      queue: tail,
      incoming: fresh,
      bpmOf: bpmOf,
      keyOf: keyOf,
      lockedPrefix: lock,
      playing: prefix.isEmpty ? null : prefix.last,
    );
  }
  final List<String> order = <String>[...prefix, ...tail];
  return RadioSync(
    RadioPlan(
      order: order,
      position: position,
      pairs: radioPairsOf(order),
      previousPairs: saved.previousPairs,
    ),
    rebuilt: false,
  );
}

/// Avanza la posición al consumir [path]. No rearma.
RadioPlan advanceRadioPlan(RadioPlan plan, String path) {
  if (plan.order.isEmpty) return plan;
  if (plan.position < plan.order.length &&
      sameAudioPath(plan.order[plan.position], path)) {
    return plan.copy(position: plan.position + 1);
  }
  for (var i = 0; i < plan.order.length; i++) {
    if (sameAudioPath(plan.order[i], path)) {
      return plan.copy(position: i + 1);
    }
  }
  return plan;
}

class GatomixRadio {
  static File fileIn(String musicRoot) =>
      File('$musicRoot${Platform.pathSeparator}$gatomixRadioName');

  static RadioMemory load(
    String musicRoot, {
    List<String> legacyPaths = const <String>[],
  }) {
    final File f = fileIn(musicRoot);
    if (f.existsSync()) {
      final RadioMemory? parsed = _read(f);
      if (parsed != null) return parsed;
    }
    final List<String> history = <String>[];
    final List<File> migrated = <File>[];
    for (final String path in legacyPaths) {
      final File old = File(path);
      if (!old.existsSync()) continue;
      history.addAll(_legacyHistory(old));
      migrated.add(old);
    }
    final RadioMemory mem = RadioMemory(history: history);
    if (migrated.isNotEmpty) {
      save(musicRoot, mem);
      for (final File old in migrated) {
        try {
          if (old.existsSync()) old.deleteSync();
        } catch (_) {}
      }
    }
    return mem;
  }

  static void save(String musicRoot, RadioMemory mem, {String? activeKey}) {
    if (musicRoot.isEmpty) return;
    try {
      final Directory dir = Directory(musicRoot);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final File dest = fileIn(musicRoot);
      final String text = jsonEncode(mem.toJson(activeKey: activeKey));
      final File tmp = File('${dest.path}.tmp');
      tmp.writeAsStringSync(text, flush: true);
      if (jsonDecode(tmp.readAsStringSync()) is! Map) {
        try {
          tmp.deleteSync();
        } catch (_) {}
        return;
      }
      if (dest.existsSync()) dest.deleteSync();
      tmp.renameSync(dest.path);
      hideOnWindows(dest.path);
    } catch (_) {}
  }

  static RadioMemory? _read(File f) {
    try {
      final Object? data = jsonDecode(f.readAsStringSync());
      if (data is! Map) return null;
      final Map<String, RadioPlan> plans = <String, RadioPlan>{};
      final dynamic raw = data['plans'];
      if (raw is Map) {
        for (final MapEntry<dynamic, dynamic> e in raw.entries) {
          plans[e.key.toString()] = RadioPlan.fromJson(e.value);
        }
      }
      return RadioMemory(
        history: <String>[
          for (final dynamic p in (data['history'] as List?) ?? const <dynamic>[])
            p.toString(),
        ],
        plans: plans,
      );
    } catch (_) {
      return null;
    }
  }

  static List<String> _legacyHistory(File f) {
    try {
      final Object? data = jsonDecode(f.readAsStringSync());
      if (data is! Map) return const <String>[];
      final dynamic list = data['history'];
      if (list is! List) return const <String>[];
      return <String>[for (final dynamic p in list) p.toString()];
    } catch (_) {
      return const <String>[];
    }
  }
}
