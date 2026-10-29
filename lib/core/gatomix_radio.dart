import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'audio_path.dart';
import 'gatomix_store.dart';
import 'livedj_order.dart';
import 'mode_session.dart';
import 'queue_bpm.dart';

/// Estado de la Radio, en un solo archivo en la raíz de Música.
/// No es una sección de `.gatomix.json`.
const String gatomixRadioName = 'LiveDj_Radio.json';
const String gatomixRadioLegacyName = '.gatomix_radio.json';

/// Tope de parejas iguales con la vuelta anterior. Por encima se rearma.
const double radioPairOverlapMax = 0.20;

const int radioRebuildAttempts = 5;

/// Clave de una opción: géneros marcados, ordenados, o `todo`.
String radioGenreKey(Iterable<String> genres) {
  final List<String> list =
      genres
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

  /// Parejas que venían en la sección `radio` antes de mudarla.
  final List<String> carriedPairs;
  final bool waveUp;
  final int inWave;
  final double previousBpm;
  final String lastArtist;
  final String? lastPath;

  const RadioMemory({
    this.history = const <String>[],
    this.plans = const <String, RadioPlan>{},
    this.carriedPairs = const <String>[],
    this.waveUp = true,
    this.inWave = 0,
    this.previousBpm = 0,
    this.lastArtist = '',
    this.lastPath,
  });

  static const RadioMemory empty = RadioMemory();

  RadioPlan? planOf(String key) => plans[key];

  RadioMemory putPlan(String key, RadioPlan plan) {
    return RadioMemory(
      history: history,
      plans: <String, RadioPlan>{...plans, key: plan},
      carriedPairs: carriedPairs,
      waveUp: waveUp,
      inWave: inWave,
      previousBpm: previousBpm,
      lastArtist: lastArtist,
      lastPath: lastPath,
    );
  }

  /// La mezcla de [played] ya entró. Avanza la posición de [key] y la anota
  /// al final del historial para que no vuelva enseguida (A→B→A).
  RadioMemory rememberMix({required String key, required String played}) {
    final RadioPlan? plan = plans[key];
    final Map<String, RadioPlan> nextPlans = <String, RadioPlan>{...plans};
    if (plan != null) {
      nextPlans[key] = advanceRadioPlan(plan, played);
    }
    final List<String> nextHistory = <String>[
      for (final String p in history)
        if (!sameAudioPath(p, played)) p,
      played,
    ];
    final List<String> capped = nextHistory.length > 48
        ? nextHistory.sublist(nextHistory.length - 48)
        : nextHistory;
    return RadioMemory(
      history: capped,
      plans: nextPlans,
      carriedPairs: carriedPairs,
      waveUp: waveUp,
      inWave: inWave,
      previousBpm: previousBpm,
      lastArtist: lastArtist,
      lastPath: played,
    );
  }

  Map<String, dynamic> toJson({String? activeKey}) {
    final RadioPlan? active = activeKey == null ? null : plans[activeKey];
    final List<String> prev = active != null && active.previousPairs.isNotEmpty
        ? active.previousPairs
        : carriedPairs;
    return <String, dynamic>{
      'schema': 1,
      'history': history,
      'pairs': carriedPairs,
      'previousPairs': prev,
      'waveUp': waveUp,
      'inWave': inWave,
      'previousBpm': previousBpm,
      'lastArtist': lastArtist,
      'lastPath': lastPath,
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

List<String> _cleanPool(List<String> pool) {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final String p in pool) {
    if (p.isEmpty || isKaraokeAudioPath(p)) continue;
    if (!seen.add(audioPathKey(p))) continue;
    out.add(p);
  }
  return out;
}

/// La lista guardada todavía tiene pistas por sonar y el fondo no cambió.
/// Entonces no hace falta rearmar (ni leer BPM de toda la biblioteca).
bool radioPlanIsOpen(RadioPlan? saved, List<String> pool) {
  if (saved == null || saved.order.isEmpty || saved.finished) return false;
  final Set<String> have = <String>{
    for (final String p in pool) audioPathKey(p),
  };
  final Set<String> orderKeys = <String>{};
  var removedBefore = 0;
  var kept = 0;
  for (var i = 0; i < saved.order.length; i++) {
    final String key = audioPathKey(saved.order[i]);
    orderKeys.add(key);
    if (have.contains(key)) {
      kept++;
    } else if (i < saved.position) {
      removedBefore++;
    }
  }
  for (final String p in pool) {
    if (!orderKeys.contains(audioPathKey(p))) return false;
  }
  final int position = saved.position - removedBefore;
  return position >= 0 && position < kept;
}

/// La vuelta completa (BPM de todo el universo + Shuffle) no se relanza
/// en cada tick. Mientras hay una en curso, o la lista guardada sigue
/// abierta, no arranca otra. Una lista ya terminada sí pide la vuelta
/// siguiente: una sola, no una por tick.
bool radioAssembleShouldStart({
  required bool inFlight,
  required bool planOpen,
}) {
  if (planOpen || inFlight) return false;
  return true;
}

/// La que suena, la anterior y el historial reciente no pueden volver a salir.
bool radioRepeatsRecent(
  String path, {
  String? playing,
  String? previous,
  Iterable<String> recent = const <String>[],
}) {
  if (path.isEmpty) return true;
  if (playing != null && playing.isNotEmpty && sameAudioPath(path, playing)) {
    return true;
  }
  if (previous != null &&
      previous.isNotEmpty &&
      sameAudioPath(path, previous)) {
    return true;
  }
  for (final String r in recent) {
    if (sameAudioPath(path, r)) return true;
  }
  return false;
}

/// Las últimas [limit] del historial (lo más nuevo al final).
List<String> radioRecent(List<String> history, {int limit = 8}) {
  if (history.length <= limit) return List<String>.from(history);
  return List<String>.from(history.sublist(history.length - limit));
}

/// Siguiente de una lista que todavía no se terminó.
/// Salta la que suena, la anterior y el historial. No rearma.
String? radioPlanNext({
  required RadioPlan plan,
  String? playing,
  String? previous,
  List<String> recent = const <String>[],
}) {
  if (plan.order.isEmpty || plan.finished) return null;
  final int start = plan.position < 0 ? 0 : plan.position;
  for (var i = start; i < plan.order.length; i++) {
    final String p = plan.order[i];
    if (radioRepeatsRecent(
      p,
      playing: playing,
      previous: previous,
      recent: recent,
    )) {
      continue;
    }
    return p;
  }
  return null;
}

/// Lo que elige la radio para la próxima mezcla, sin tocar un deck.
class RadioResolve {
  final String? next;
  final RadioMemory memory;

  /// Cierto si esta llamada armó una vuelta nueva.
  final bool rebuilt;

  /// Cierto si [next] sale de la lista ya abierta, en su orden.
  final bool followedPlan;

  /// No hay lista abierta: hay que armarla fuera del hilo que suena.
  final bool needsAssemble;

  const RadioResolve({
    required this.next,
    required this.memory,
    required this.rebuilt,
    required this.followedPlan,
    required this.needsAssemble,
  });
}

/// Sigue la lista de [key]. Si queda cola, no la rearma y no elige por BPM.
/// Si no queda, y [allowRebuild] es falso, devuelve una pista suelta que no
/// sea la actual ni la anterior; la vuelta completa la arma el isolate.
RadioResolve radioResolveNext({
  required RadioMemory memory,
  required String key,
  required List<String> pool,
  String? playing,
  String? previous,
  required double Function(String path) bpmOf,
  String? Function(String path)? keyOf,
  Random? rng,
  bool allowRebuild = true,
}) {
  final List<String> recent = radioRecent(memory.history);
  final RadioPlan? saved = memory.planOf(key);
  // Un plan que no cubre este pool no se fusiona aquí: con «Todo» eso
  // recorría toda la biblioteca en el hilo que suena y el armado no llegaba.
  if (saved != null && !saved.finished && radioPlanIsOpen(saved, pool)) {
    final RadioSync synced = syncRadioPlan(
      saved: saved,
      pool: pool,
      bpmOf: bpmOf,
      keyOf: keyOf,
      rng: rng,
      playing: playing,
      previous: previous,
    );
    final String? next = radioPlanNext(
      plan: synced.plan,
      playing: playing,
      previous: previous,
      recent: recent,
    );
    if (next != null) {
      // Si el puesto apuntaba a la que suena, la lista visible empieza en la
      // que va a entrar. La mezcla, al completarse, avanza uno más.
      return RadioResolve(
        next: next,
        memory: memory.putPlan(key, _alignPlan(synced.plan, next)),
        rebuilt: synced.rebuilt,
        followedPlan: !synced.rebuilt,
        needsAssemble: false,
      );
    }
    memory = memory.putPlan(key, synced.plan.copy(position: synced.plan.order.length));
  }
  if (!allowRebuild) {
    return RadioResolve(
      next: radioQuickNext(
        pool: pool,
        anchor: playing,
        previous: previous,
        recent: recent,
        bpmOf: bpmOf,
        keyOf: keyOf,
        rng: rng,
      ),
      memory: memory,
      rebuilt: false,
      followedPlan: false,
      needsAssemble: true,
    );
  }
  final List<String> roundPool = <String>[
    for (final String p in pool)
      if (!radioRepeatsRecent(p, playing: playing, previous: previous)) p,
  ];
  if (roundPool.isEmpty) {
    return RadioResolve(
      next: null,
      memory: memory,
      rebuilt: false,
      followedPlan: false,
      needsAssemble: false,
    );
  }
  final RadioPlan? done = memory.planOf(key);
  final RadioSync fresh = syncRadioPlan(
    saved: done != null && done.finished ? done : null,
    pool: roundPool,
    bpmOf: bpmOf,
    keyOf: keyOf,
    rng: rng,
    playing: playing,
    previous: previous,
  );
  final String? next = radioPlanNext(
    plan: fresh.plan,
    playing: playing,
    previous: previous,
    recent: recent,
  );
  return RadioResolve(
    next: next,
    memory: next == null ? memory : memory.putPlan(key, _alignPlan(fresh.plan, next)),
    rebuilt: true,
    followedPlan: false,
    needsAssemble: false,
  );
}

RadioPlan _alignPlan(RadioPlan plan, String next) {
  final int start = plan.position < 0 ? 0 : plan.position;
  for (var i = start; i < plan.order.length; i++) {
    if (!sameAudioPath(plan.order[i], next)) continue;
    if (i == plan.position) return plan;
    return plan.copy(position: i);
  }
  return plan;
}

/// Una pista para mezclar ya, sin armar la vuelta entera.
/// Nunca devuelve [anchor] (la que suena), [previous] ni [recent].
String? radioQuickNext({
  required List<String> pool,
  String? anchor,
  String? previous,
  Iterable<String> recent = const <String>[],
  double Function(String path)? bpmOf,
  String? Function(String path)? keyOf,
  Random? rng,
}) {
  final List<String> cands = <String>[];
  final bool wide = pool.length > 800;
  final int step = wide ? (pool.length / 400).ceil() : 1;
  final int cap = wide ? 400 : pool.length;
  for (var i = 0; i < pool.length && cands.length < cap; i += step) {
    final String p = pool[i];
    if (p.isEmpty || isKaraokeAudioPath(p)) continue;
    if (radioRepeatsRecent(
      p,
      playing: anchor,
      previous: previous,
      recent: recent,
    )) {
      continue;
    }
    cands.add(p);
  }
  if (cands.isEmpty) return null;
  final double Function(String path) bpm = bpmOf ?? memoryBpm;
  return pickHarmonicNext(
    cands,
    bpm,
    keyOf: keyOf ?? camelotFromPath,
    anchor: anchor,
    anchorBpm: anchor == null ? 0 : bpm(anchor),
    rng: rng,
  );
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
  String? fixedFirst,
  String? playing,
  Map<String, int> recentAge = const <String, int>{},
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
        recentAge: recentAge,
        playing: playing,
        fixedFirst: fixedFirst,
        rng: spin,
      ).tracks,
    );
    if (fixedFirst == null) _displaceFirst(built, banned, spin);
    final bool sameFirst =
        banned != null &&
        fixedFirst == null &&
        built.isNotEmpty &&
        sameAudioPath(built.first, banned);
    final bool sameList =
        previousOrder.isNotEmpty && sameRadioOrder(built, previousOrder);
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
  if (fixedFirst == null) _displaceFirst(out, banned, random);
  return out;
}

RadioPlan _freshPlan(
  List<String> pool,
  double Function(String path) bpmOf,
  String? Function(String path)? keyOf,
  List<String> previousOrder,
  List<String> previousPairs,
  Random rng, {
  String? fixedFirst,
  String? playing,
  Map<String, int> recentAge = const <String, int>{},
}) {
  final List<String> order = buildDifferentRound(
    pool: pool,
    bpmOf: bpmOf,
    keyOf: keyOf,
    previousOrder: previousOrder,
    previousPairs: previousPairs,
    fixedFirst: fixedFirst,
    playing: playing,
    recentAge: recentAge,
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
  String? playing,
  String? previous,
  Random? rng,
}) {
  final Random random = rng ?? Random();
  String? lock = pinned;
  if (lock != null &&
      radioRepeatsRecent(lock, playing: playing, previous: previous)) {
    lock = null;
  }
  final List<String> songs = _cleanPool(pool);
  if (songs.isEmpty) {
    return RadioSync(const RadioPlan(), rebuilt: saved == null);
  }
  final Set<String> songKeys = <String>{
    for (final String p in songs) audioPathKey(p),
  };
  bool inSongs(String p) => songKeys.contains(audioPathKey(p));
  if (saved == null || saved.order.isEmpty) {
    return RadioSync(
      _freshPlan(
        songs,
        bpmOf,
        keyOf,
        const <String>[],
        const <String>[],
        random,
        fixedFirst: lock,
        playing: playing,
      ),
      rebuilt: true,
    );
  }
  final List<String> kept = <String>[];
  var removedBefore = 0;
  for (var i = 0; i < saved.order.length; i++) {
    if (inSongs(saved.order[i])) {
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
      _freshPlan(
        songs,
        bpmOf,
        keyOf,
        saved.order,
        prevPairs,
        random,
        fixedFirst: lock,
        playing: playing,
      ),
      rebuilt: true,
    );
  }
  final List<String> prefix = kept.sublist(0, position);
  List<String> tail = kept.sublist(position);
  final Set<String> keptKeys = <String>{
    for (final String p in kept) audioPathKey(p),
  };
  final List<String> fresh = <String>[
    for (final String p in songs)
      if (!keptKeys.contains(audioPathKey(p))) p,
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

/// La pista ya elegida para mezclar queda en el puesto visible.
RadioPlan _pinFirst(RadioPlan plan, String? pinned) {
  if (pinned == null || pinned.isEmpty || plan.order.isEmpty) return plan;
  final int pos = plan.position < 0
      ? 0
      : (plan.position > plan.order.length ? plan.order.length : plan.position);
  if (pos < plan.order.length && sameAudioPath(plan.order[pos], pinned)) {
    return plan;
  }
  final int i = plan.order.indexWhere((String p) => sameAudioPath(p, pinned));
  if (i < 0) return plan;
  final List<String> order = List<String>.from(plan.order);
  final String head = order.removeAt(i);
  final int at = pos > order.length ? order.length : pos;
  order.insert(at, head);
  return RadioPlan(
    order: order,
    position: at,
    pairs: radioPairsOf(order),
    previousPairs: plan.previousPairs,
  );
}

/// Arma la vuelta fuera del hilo de UI. Solo datos enviables.
Future<Map<String, Object?>> assembleRadioOffUi(
  Map<String, Object?> raw,
) async {
  try {
    final List<String> pool = <String>[
      for (final Object? p in (raw['pool'] as List?) ?? const <Object>[])
        p.toString(),
    ];
    final bool hasSaved = raw['hasSaved'] == true;
    final RadioPlan? saved = hasSaved
        ? RadioPlan(
            order: _strings(raw['order']),
            position: raw['position'] is int ? raw['position'] as int : 0,
            pairs: _strings(raw['pairs']),
            previousPairs: _strings(raw['previousPairs']),
          )
        : null;
    final int seed = raw['seed'] is int ? raw['seed'] as int : 1;
    final String? pinned = raw['pinned'] as String?;
    final String? playing = raw['playing'] as String?;
    if (raw['readTags'] == true) {
      preloadQueueBpmSync(pool);
    } else {
      preloadQueueBpmFromStore(pool);
    }
    final RadioSync synced = syncRadioPlan(
      saved: saved,
      pool: pool,
      bpmOf: knownBpm,
      keyOf: harmonicKeyOf,
      pinned: pinned,
      playing: playing,
      rng: Random(seed),
    );
    final RadioPlan plan = _pinFirst(synced.plan, pinned);
    final List<String> untagged = <String>[
      for (final String p in pool)
        if (p.isNotEmpty && knownBpm(p) <= 0) p,
    ];
    return <String, Object?>{
      'ok': true,
      'rebuilt': synced.rebuilt,
      'order': plan.order,
      'position': plan.position,
      'pairs': plan.pairs,
      'previousPairs': plan.previousPairs,
      'untagged': untagged,
    };
  } catch (e) {
    return <String, Object?>{'ok': false, 'error': e.toString()};
  }
}

List<String> _strings(Object? raw) {
  if (raw is! List) return const <String>[];
  return <String>[for (final Object? p in raw) p.toString()];
}

class GatomixRadio {
  static File fileIn(String musicRoot) =>
      File('$musicRoot${Platform.pathSeparator}$gatomixRadioName');

  /// Copia `.gatomix_radio.json` a `LiveDj_Radio.json`, verifica y solo
  /// entonces borra el viejo.
  static void _adoptLegacyName(String musicRoot) {
    final String sep = Platform.pathSeparator;
    final File neu = fileIn(musicRoot);
    final File old = File('$musicRoot$sep$gatomixRadioLegacyName');
    if (!old.existsSync() && !File('${old.path}.bak').existsSync()) return;
    final Object? raw = _decodeAny(old);
    if (raw is! Map) return;
    final Map<String, dynamic> incoming = Map<String, dynamic>.from(raw);
    Map<String, dynamic> dest = <String, dynamic>{};
    if (neu.existsSync()) {
      final Object? have = _decodeAny(neu);
      if (have is Map) dest = Map<String, dynamic>.from(have);
    }
    var changed = dest.isEmpty;
    for (final MapEntry<String, dynamic> e in incoming.entries) {
      if (e.key == 'plans' && e.value is Map) {
        final Map<String, dynamic> plans = dest['plans'] is Map
            ? Map<String, dynamic>.from(dest['plans'] as Map)
            : <String, dynamic>{};
        final Map<dynamic, dynamic> oldPlans = e.value as Map;
        for (final MapEntry<dynamic, dynamic> p in oldPlans.entries) {
          plans.putIfAbsent(p.key.toString(), () => p.value);
        }
        if (!jsonEqual(dest['plans'], plans)) changed = true;
        dest['plans'] = plans;
        continue;
      }
      if (!dest.containsKey(e.key)) {
        dest[e.key] = e.value;
        changed = true;
      }
    }
    if (!neu.existsSync() || changed) {
      try {
        final Directory dir = Directory(musicRoot);
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final String text = jsonEncode(dest);
        final File tmp = File('${neu.path}.tmp');
        tmp.writeAsStringSync(text, flush: true);
        if (!jsonEqual(jsonDecode(tmp.readAsStringSync()), dest)) {
          try {
            tmp.deleteSync();
          } catch (_) {}
          return;
        }
        if (neu.existsSync()) neu.deleteSync();
        tmp.renameSync(neu.path);
        hideOnWindows(neu.path);
      } catch (_) {
        return;
      }
    }
    final Object? back = _decodeAny(neu);
    if (back is! Map) return;
    final Map<String, dynamic> got = Map<String, dynamic>.from(back);
    if (incoming['plans'] is Map) {
      final Map<dynamic, dynamic> want = incoming['plans'] as Map;
      final Map<dynamic, dynamic> have = got['plans'] is Map
          ? got['plans'] as Map
          : const <dynamic, dynamic>{};
      for (final dynamic k in want.keys) {
        if (!have.containsKey(k) || !jsonEqual(have[k], want[k])) return;
      }
    }
    for (final MapEntry<String, dynamic> e in incoming.entries) {
      if (e.key == 'plans') continue;
      if (!got.containsKey(e.key) || !jsonEqual(got[e.key], e.value)) return;
    }
    deleteRadioLegacy(old.path);
  }

  static Object? _decodeAny(File f) {
    for (final String p in <String>[f.path, '${f.path}.bak', '${f.path}.tmp']) {
      final File file = File(p);
      if (!file.existsSync()) continue;
      try {
        return jsonDecode(file.readAsStringSync());
      } catch (_) {}
    }
    return null;
  }

  static RadioMemory load(
    String musicRoot, {
    List<String> legacyPaths = const <String>[],
  }) {
    if (musicRoot.isEmpty) return RadioMemory.empty;
    _adoptLegacyName(musicRoot);
    final File f = fileIn(musicRoot);
    RadioMemory mem = RadioMemory.empty;
    if (f.existsSync()) {
      mem = _read(f) ?? RadioMemory.empty;
    }
    final List<String> history = List<String>.from(mem.history);
    final List<String> pairs = List<String>.from(mem.carriedPairs);
    bool waveUp = mem.waveUp;
    var inWave = mem.inWave;
    var previousBpm = mem.previousBpm;
    var lastArtist = mem.lastArtist;
    String? lastPath = mem.lastPath;
    final dynamic section = GatomixStore.section(musicRoot, 'radio');
    final bool hasSection = section is Map;
    if (hasSection) {
      for (final String p in _stringList(section['history'])) {
        if (!_listed(history, p)) history.add(p);
      }
      for (final String p in _stringList(section['pairs'])) {
        if (!pairs.contains(p)) pairs.add(p);
      }
      if (section['waveUp'] is bool) waveUp = section['waveUp'] as bool;
      if (section['inWave'] is num) inWave = (section['inWave'] as num).toInt();
      if (section['previousBpm'] is num) {
        previousBpm = (section['previousBpm'] as num).toDouble();
      }
      final String artist = section['lastArtist']?.toString() ?? '';
      if (artist.isNotEmpty) lastArtist = artist;
      final String? last = section['lastPath']?.toString();
      if (last != null && last.isNotEmpty) lastPath = last;
    }
    final List<File> legacy = <File>[];
    for (final String path in legacyPaths) {
      final File old = File(path);
      if (!old.existsSync()) continue;
      for (final String p in _legacyHistory(old)) {
        if (!_listed(history, p)) history.add(p);
      }
      legacy.add(old);
    }
    mem = RadioMemory(
      history: history,
      plans: mem.plans,
      carriedPairs: pairs,
      waveUp: waveUp,
      inWave: inWave,
      previousBpm: previousBpm,
      lastArtist: lastArtist,
      lastPath: lastPath,
    );
    if (!hasSection && legacy.isEmpty) {
      return f.existsSync() ? mem : RadioMemory.empty;
    }
    save(musicRoot, mem);
    final RadioMemory? back = _read(fileIn(musicRoot));
    if (back == null || !_listedSame(back.history, mem.history)) return mem;
    if (!_listedSame(back.carriedPairs, mem.carriedPairs)) return mem;
    if (back.plans.length != mem.plans.length) return mem;
    if (hasSection) {
      GatomixStore.putSection(musicRoot, 'radio', null);
      final dynamic left = GatomixStore.section(musicRoot, 'radio');
      if (left != null) return back;
    }
    for (final File old in legacy) {
      try {
        if (old.existsSync()) old.deleteSync();
      } catch (_) {}
    }
    return back;
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

  /// Escritura fuera del hilo que está sonando. No usa `writeAsStringSync`.
  static Future<void> saveAsync(String musicRoot, Map<String, dynamic> doc) async {
    if (musicRoot.isEmpty) return;
    try {
      final Directory dir = Directory(musicRoot);
      if (!await dir.exists()) await dir.create(recursive: true);
      final String text = jsonEncode(doc);
      final File dest = fileIn(musicRoot);
      final File tmp = File('${dest.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      if (await dest.exists()) await dest.delete();
      await tmp.rename(dest.path);
      if (Platform.isWindows) {
        try {
          await Process.run('attrib', <String>['+h', dest.path]);
        } catch (_) {}
      }
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
      final dynamic bpm = data['previousBpm'];
      final dynamic wave = data['inWave'];
      final String? last = data['lastPath']?.toString();
      final List<String> pairs = _stringList(data['pairs']);
      return RadioMemory(
        history: _stringList(data['history']),
        plans: plans,
        carriedPairs: pairs.isNotEmpty
            ? pairs
            : _stringList(data['previousPairs']),
        waveUp: data['waveUp'] as bool? ?? true,
        inWave: wave is num ? wave.toInt() : 0,
        previousBpm: bpm is num ? bpm.toDouble() : 0,
        lastArtist: data['lastArtist']?.toString() ?? '',
        lastPath: last == null || last.isEmpty ? null : last,
      );
    } catch (_) {
      return null;
    }
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const <String>[];
    return <String>[for (final dynamic p in raw) p.toString()];
  }

  static bool _listed(List<String> xs, String p) =>
      xs.any((String e) => e == p || sameAudioPath(e, p));

  static bool _listedSame(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
