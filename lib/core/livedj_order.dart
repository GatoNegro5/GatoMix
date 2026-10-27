import 'dart:math';

import 'audio_path.dart';

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

/// Shuffle por grupos de [groupSize]:
/// - Las pistas con BPM se ordenan por BPM y se reparten en grupos de 20
///   vecinos en BPM, con composición distinta en cada semilla (ventanas de
///   2 grupos barajadas).
/// - Grupo 1 sube de BPM, grupo 2 baja, grupo 3 sube… (se mezcla de arriba
///   hacia abajo).
/// - Las pistas sin BPM van al final, barajadas.
List<List<String>> buildShuffleGroups(
  List<String> paths,
  double Function(String path) bpmOf,
  int seed, {
  int groupSize = 20,
  bool? foldCase,
}) {
  final Random rng = Random(seed);
  final List<String> uniq = <String>[];
  final Set<String> seen = <String>{};
  for (final String p in paths) {
    if (isKaraokeAudioPath(p)) continue;
    if (seen.add(audioPathKey(p, foldCase: foldCase))) uniq.add(p);
  }
  final List<String> known = uniq.where((p) => bpmOf(p) > 0).toList();
  final List<String> unknown = uniq.where((p) => bpmOf(p) <= 0).toList();
  known.shuffle(rng); // desempate aleatorio entre BPM iguales
  known.sort((a, b) => bpmOf(a).compareTo(bpmOf(b)));

  // Ventanas de 2 grupos (vecinos en BPM) barajadas: cambia qué canciones
  // comparten grupo sin juntar BPM lejanos.
  final int window = groupSize * 2;
  final List<String> mixed = <String>[];
  // El primer corte de ventana se desplaza al azar: así tampoco el último
  // grupo sale siempre igual.
  int i = 0;
  final int firstCut = known.length > groupSize
      ? groupSize + rng.nextInt(groupSize + 1)
      : known.length;
  while (i < known.length) {
    final int end = min(i == 0 ? firstCut : i + window, known.length);
    mixed.addAll(known.sublist(i, end)..shuffle(rng));
    i = end;
  }
  final List<List<String>> groups = <List<String>>[];
  for (int pos = 0; pos < mixed.length; pos += groupSize) {
    groups.add(mixed.sublist(pos, min(pos + groupSize, mixed.length)));
  }
  // Un grupo final muy chico se une al anterior.
  if (groups.length > 1 && groups.last.length < groupSize ~/ 4) {
    final List<String> tail = groups.removeLast();
    groups.last.addAll(tail);
  }
  for (int g = 0; g < groups.length; g++) {
    final bool up = g.isEven;
    groups[g].sort((a, b) {
      final int c = up
          ? bpmOf(a).compareTo(bpmOf(b))
          : bpmOf(b).compareTo(bpmOf(a));
      return c != 0 ? c : a.compareTo(b);
    });
  }
  if (unknown.isNotEmpty) {
    unknown.shuffle(rng);
    groups.add(unknown);
  }
  return groups;
}

/// Elige la semilla cuyo armado repite menos grupos de [history] (firmas de
/// los grupos ya usados). Con 0 repetidos se queda con ese.
({List<List<String>> groups, int seed}) pickFreshShuffle(
  List<String> paths,
  double Function(String path) bpmOf,
  Set<String> history,
  Random rng, {
  int tries = 60,
  int groupSize = 20,
  bool? foldCase,
}) {
  List<List<String>>? best;
  int bestSeed = 0;
  int bestRep = 1 << 30;
  for (int t = 0; t < tries; t++) {
    final int seed = rng.nextInt(1 << 31);
    final List<List<String>> g = buildShuffleGroups(
      paths,
      bpmOf,
      seed,
      groupSize: groupSize,
      foldCase: foldCase,
    );
    // Si toda la cola cabe en un grupo, la composición no puede cambiar.
    final int rep = g.length <= 1
        ? 0
        : g.where((x) => history.contains(groupSignature(x))).length;
    if (rep < bestRep) {
      best = g;
      bestSeed = seed;
      bestRep = rep;
      if (rep == 0) break;
    }
  }
  return (
    groups: best ?? <List<String>>[List<String>.from(paths)],
    seed: bestSeed,
  );
}
