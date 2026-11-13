import 'dart:async';
import 'dart:io';

import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;

import 'analysis_window.dart';
import 'audio_path.dart';
import 'bpm_range.dart';
import 'gatomix_store.dart';
import '../services/track_tags.dart';

/// 3.1.14: BPM de las pistas sin medir de la cola, de una en una, mientras
/// suena la sesion. Se pausa solo durante el cruce entre los 2 decks; el
/// BPM entra a la cache al momento y el orden se rehace por lotes.

/// Pistas sin BPM desde [from] (index + 2 en adelante), sin `_K` ni repetidas.
List<String> backfillCandidates(
  List<String> queue,
  int from,
  double Function(String path) bpmOf,
) {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (var i = from < 0 ? 0 : from; i < queue.length; i++) {
    final String p = queue[i];
    if (p.isEmpty || isKaraokeAudioPath(p)) continue;
    if (bpmOf(p) > 0) continue;
    if (seen.add(audioPathKey(p))) out.add(p);
  }
  return out;
}

/// queueEpoch: la cola es una lista inmutable; cualquier agregar, mover o
/// quitar crea otra. Si no es la misma del ultimo orden, no se reordena.
bool sameQueueEpoch(Object? epoch, Object queue) =>
    epoch != null && identical(epoch, queue);

/// Rehace solo `queue[fixed..]` con [order]. Las primeras [fixed] (actual y
/// siguiente) no se tocan y ninguna pista se pierde ni se duplica.
/// Null si no hay al menos 2 pistas que mover.
List<String>? reorderQueueTail(
  List<String> queue,
  int fixed,
  List<String> Function(List<String> tail, String? continueFrom) order,
) {
  final int head = fixed < 0 ? 0 : fixed;
  if (queue.length - head < 2) return null;
  final List<String> tail = queue.sublist(head);
  final List<String> out = queue.sublist(0, head);
  final Map<String, int> left = <String, int>{};
  for (final String p in tail) {
    final String k = audioPathKey(p);
    left[k] = (left[k] ?? 0) + 1;
  }
  final List<String> built = order(tail, head == 0 ? null : queue[head - 1]);
  for (final String p in <String>[...built, ...tail]) {
    final String k = audioPathKey(p);
    final int n = left[k] ?? 0;
    if (n <= 0) continue;
    left[k] = n - 1;
    out.add(p);
  }
  return out;
}

class BpmBackfillWorker {
  BpmBackfillWorker({
    required this.measure,
    required this.isPaused,
    required this.onBatch,
    this.batchSize = 5,
    this.gap = const Duration(milliseconds: 250),
  });

  final Future<double> Function(String path) measure;
  final bool Function() isPaused;
  final void Function(int measured) onBatch;
  final int batchSize;
  final Duration gap;

  final List<String> _pending = <String>[];
  final Set<String> _queued = <String>{};
  // Medida o fallida: no se vuelve a intentar en esta sesion.
  final Set<String> _done = <String>{};
  int _gen = 0;
  int? _runningGen;
  int _unapplied = 0;

  bool get isRunning => _runningGen == _gen;
  int get pendingCount => _pending.length;

  void enqueue(Iterable<String> paths) {
    for (final String p in paths) {
      final String k = audioPathKey(p);
      if (_done.contains(k) || !_queued.add(k)) continue;
      _pending.add(p);
    }
    if (_runningGen != _gen && _pending.isNotEmpty) unawaited(_run(_gen));
  }

  void cancel() {
    _gen++;
    _pending.clear();
    _queued.clear();
    _unapplied = 0;
  }

  /// Medidas que aun no entraron al orden (para el cambio de cancion).
  int takeUnapplied() {
    final int n = _unapplied;
    _unapplied = 0;
    return n;
  }

  Future<void> _run(int gen) async {
    _runningGen = gen;
    try {
      while (gen == _gen && _pending.isNotEmpty) {
        while (gen == _gen && isPaused()) {
          await Future<void>.delayed(gap);
        }
        if (gen != _gen || _pending.isEmpty) break;
        final String path = _pending.removeAt(0);
        final String key = audioPathKey(path);
        _queued.remove(key);
        _done.add(key);
        double bpm = 0;
        try {
          bpm = TrackTags.musicalBpm(await measure(path));
        } catch (_) {
          bpm = 0;
        }
        if (gen != _gen) break;
        if (bpm > 0) {
          TrackTags.rememberBpm(path, bpm);
          _unapplied++;
        }
        if (_unapplied >= batchSize || (_pending.isEmpty && _unapplied > 0)) {
          final int n = _unapplied;
          _unapplied = 0;
          onBatch(n);
        }
        if (_pending.isNotEmpty) await Future<void>.delayed(gap);
      }
    } finally {
      if (_runningGen == gen) _runningGen = null;
    }
  }
}

/// Mide con Rust (escribe TBPM) y deja en el `.gatomix.json` de la carpeta
/// el BPM y el mtime posterior a la escritura (como dsp_provider 3.1.11),
/// para que el escaneo de la carpeta no la vuelva a medir.
Future<double> measureAndStampBpm(String path) async {
  int durMs = 0;
  try {
    durMs = (await rust_dsp.exactDurationMs(inputPath: path)).toInt();
  } catch (_) {}
  if (!canAnalyzeFull(durMs)) return 0;
  final double raw = await rust_dsp
      .autoDetectAndInjectBpm(inputPath: path)
      .timeout(analysisTimeout(durMs, const Duration(seconds: 45)));
  final double bpm = fixBpmRange(raw) ?? 0;
  stampBackfill(path, bpm);
  return bpm;
}

void stampBackfill(String path, double bpm) {
  final File file = File(path);
  final String dir = file.parent.path;
  if (!File('$dir${Platform.pathSeparator}$gatomixStoreName').existsSync()) {
    return;
  }
  final int mtime;
  try {
    mtime = file.lastModifiedSync().millisecondsSinceEpoch;
  } catch (_) {
    return;
  }
  final Map<String, dynamic> stamps =
      Map<String, dynamic>.from(readDjTimestamps(dir))..[path] = mtime;
  writeDjTimestamps(dir, stamps);
  if (bpm > 0) {
    writeDjMetadata(
      dir,
      bpmIndexPreservingKeys(readDjMetadata(dir), <String, double>{path: bpm}),
    );
  }
}
