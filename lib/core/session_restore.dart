import 'audio_path.dart';
import 'session_store.dart';

/// Sesión de Automix ya sin duplicados ni pistas `_K`.
/// La posición se conserva si la pista actual sigue en la lista (aunque
/// hubiera entrado dos veces con otra grafía de la ruta).
class AutomixSessionRestore {
  final List<String> playlist;
  final int? index;
  final int? positionMs;
  final int mixStrategyIndex;
  final bool autoMixArmed;
  final bool wasPlaying;

  const AutomixSessionRestore({
    required this.playlist,
    required this.index,
    required this.positionMs,
    required this.mixStrategyIndex,
    required this.autoMixArmed,
    required this.wasPlaying,
  });
}

AutomixSessionRestore restoreAutomixSession(
  Map<dynamic, dynamic> data, {
  bool Function(String path)? exists,
  List<String> Function(String dir)? listDir,
  bool? foldCase,
  int strategyCount = 2,
}) {
  final List<String> raw =
      ((data['playlist'] as List?) ?? const <dynamic>[])
          .map((e) => e.toString())
          .toList();
  final int? rawIndex = data['currentIndex'] is int
      ? data['currentIndex'] as int
      : null;
  final List<String> playlist = <String>[];
  final Map<String, int> at = <String, int>{};
  int? index;
  for (var i = 0; i < raw.length; i++) {
    final List<String> hit = resolvePlayableSessionPaths(
      <String>[raw[i]],
      exists: exists,
      listDir: listDir,
      foldCase: foldCase,
    );
    if (hit.isEmpty) continue;
    final String p = hit.first;
    final String key = audioPathKey(p, foldCase: foldCase);
    final int? prev = at[key];
    if (prev != null) {
      if (i == rawIndex) index = prev;
      continue;
    }
    if (i == rawIndex) index = playlist.length;
    at[key] = playlist.length;
    playlist.add(p);
  }
  final bool sameTrack = index != null;
  if (index == null && playlist.isNotEmpty && rawIndex != null) {
    index = rawIndex.clamp(0, playlist.length - 1);
  }
  final int? positionMs = sameTrack && data['positionMs'] is int
      ? data['positionMs'] as int
      : null;
  final int maxS = strategyCount <= 1 ? 0 : strategyCount - 1;
  final int mix = ((data['mixStrategy'] as int?) ?? 0).clamp(0, maxS);
  return AutomixSessionRestore(
    playlist: playlist,
    index: index,
    positionMs: positionMs,
    mixStrategyIndex: mix,
    autoMixArmed: data['autoMixArmed'] as bool? ?? true,
    wasPlaying: data['wasPlaying'] as bool? ?? false,
  );
}

/// Sesión de Live DJ: cola, pista actual, modo y posición, sin duplicados
/// ni `_K`. Si no hay actual, la primera de la cola pasa a actual y sale
/// de la cola (no suena dos veces) y la posición no se hereda.
class LiveDjSessionRestore {
  final List<String> queue;
  final String? currentTrackPath;
  final int? positionMs;
  final bool currentFromQueue;
  final int mixStrategyIndex;
  final int mixModeIndex;
  final bool wasPlaying;

  const LiveDjSessionRestore({
    required this.queue,
    required this.currentTrackPath,
    required this.positionMs,
    required this.currentFromQueue,
    required this.mixStrategyIndex,
    required this.mixModeIndex,
    required this.wasPlaying,
  });
}

LiveDjSessionRestore restoreLiveDjSession(
  Map<dynamic, dynamic> data, {
  bool Function(String path)? exists,
  List<String> Function(String dir)? listDir,
  bool? foldCase,
  int strategyCount = 2,
  int modeCount = 2,
}) {
  final List<String> raw =
      ((data['queue'] as List?) ?? const <dynamic>[])
          .map((e) => e.toString())
          .toList();
  final List<String> queue = <String>[];
  final Set<String> seen = <String>{};
  for (final String p in resolvePlayableSessionPaths(
    raw,
    exists: exists,
    listDir: listDir,
    foldCase: foldCase,
  )) {
    if (seen.add(audioPathKey(p, foldCase: foldCase))) queue.add(p);
  }
  String? current = data['currentTrackPath'] as String?;
  if (current != null && isKaraokeAudioPath(current)) current = null;
  if (current != null) {
    final List<String> hit = resolvePlayableSessionPaths(
      <String>[current],
      exists: exists,
      listDir: listDir,
      foldCase: foldCase,
    );
    current = hit.isEmpty ? null : hit.first;
  }
  if (current != null) {
    final String ck = audioPathKey(current, foldCase: foldCase);
    queue.removeWhere((p) => audioPathKey(p, foldCase: foldCase) == ck);
  }
  var fromQueue = false;
  if (current == null && queue.isNotEmpty) {
    current = queue.removeAt(0);
    fromQueue = true;
  }
  final int? positionMs = fromQueue
      ? null
      : (data['positionMs'] is int ? data['positionMs'] as int : null);
  final int maxS = strategyCount <= 1 ? 0 : strategyCount - 1;
  final int maxM = modeCount <= 1 ? 0 : modeCount - 1;
  return LiveDjSessionRestore(
    queue: queue,
    currentTrackPath: current,
    positionMs: positionMs,
    currentFromQueue: fromQueue,
    mixStrategyIndex: ((data['mixStrategy'] as int?) ?? 0).clamp(0, maxS),
    mixModeIndex: ((data['mixMode'] as int?) ?? 0).clamp(0, maxM),
    wasPlaying: data['wasPlaying'] as bool? ?? false,
  );
}
