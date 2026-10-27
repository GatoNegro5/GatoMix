import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;

import '../core/audio_path.dart';

/// Lo que dejó el MASTERIZADO en las etiquetas de la pista (Rust/id3):
/// silencios de inicio/fin, BPM y ganancia ReplayGain. Se lee sin decodificar.
/// Caché en memoria con lectura síncrona (`peek`) para los motores de mezcla.
/// La clave es [audioPathKey]: separadores, `.`/`..` y mayúsculas (Windows,
/// macOS, iOS) no crean otra entrada.
class TrackTags {
  final bool analyzed;
  final int leadMs;
  final int tailMs;
  final double bpm;
  final double gainDb;

  /// Cierto si solo se anotó el BPM (metadata o TBPM) y aún no se leyeron
  /// silencios. [load] sigue yendo a las etiquetas en ese caso.
  final bool bpmOnly;
  const TrackTags({
    this.analyzed = false,
    this.leadMs = 0,
    this.tailMs = 0,
    this.bpm = 0.0,
    this.gainDb = 0.0,
    this.bpmOnly = false,
  });

  static const TrackTags empty = TrackTags();
  static final Map<String, TrackTags> _cache = {};

  static String _k(String path) => audioPathKey(path);

  /// Lectura inmediata (null si aún no se cargó con [load] ni [rememberBpm]).
  static TrackTags? peek(String? path) =>
      path == null || path.isEmpty ? null : _cache[_k(path)];

  /// Anota el BPM sin pisar silencios ya leídos. Misma clave que [peek].
  static void rememberBpm(String path, double bpm) {
    final double musical = musicalBpm(bpm);
    if (musical <= 0 || path.isEmpty) return;
    final String k = _k(path);
    final TrackTags? prev = _cache[k];
    if (prev != null && !prev.bpmOnly && prev.bpm > 0) return;
    if (prev != null && !prev.bpmOnly) {
      _cache[k] = TrackTags(
        analyzed: prev.analyzed,
        leadMs: prev.leadMs,
        tailMs: prev.tailMs,
        bpm: musical,
        gainDb: prev.gainDb,
      );
      return;
    }
    _cache[k] = TrackTags(
      analyzed: prev?.analyzed ?? false,
      leadMs: prev?.leadMs ?? 0,
      tailMs: prev?.tailMs ?? 0,
      bpm: musical,
      gainDb: prev?.gainDb ?? 0,
      bpmOnly: true,
    );
  }

  /// Carga (una sola vez por ruta normalizada) y devuelve las etiquetas.
  static Future<TrackTags> load(String path) async {
    final String k = _k(path);
    final TrackTags? hit = _cache[k];
    if (hit != null && !hit.bpmOnly) return hit;
    TrackTags t = empty;
    var failed = false;
    try {
      final m = await rust_dsp.readMasterTags(inputPath: path);
      t = TrackTags(
        analyzed: m.analyzed,
        leadMs: m.leadMs.toInt(),
        tailMs: m.tailMs.toInt(),
        bpm: TrackTags.musicalBpm(m.bpm),
        gainDb: m.gainDb,
      );
    } catch (_) {
      failed = true;
    }
    if (failed) {
      final TrackTags kept = hit ?? empty;
      final TrackTags stored = TrackTags(
        analyzed: kept.analyzed,
        leadMs: kept.leadMs,
        tailMs: kept.tailMs,
        bpm: kept.bpm,
        gainDb: kept.gainDb,
      );
      _cache[k] = stored;
      return stored;
    }
    if (t.bpm <= 0 && hit != null && hit.bpm > 0) {
      t = TrackTags(
        analyzed: t.analyzed,
        leadMs: t.leadMs,
        tailMs: t.tailMs,
        bpm: hit.bpm,
        gainDb: t.gainDb,
      );
    }
    _cache[k] = t;
    return t;
  }

  /// Olvida una ruta (p. ej. tras volver a masterizar).
  static void forget(String path) => _cache.remove(_k(path));

  /// Vacía la caché. Lo usan las pruebas del Shuffle.
  static void clear() => _cache.clear();

  /// BPM de una canción: entre 40 y 250. Si el archivo lo guardó × 100
  /// (14109 = 141.09), se divide. Un valor fuera de eso no es un BPM.
  static double musicalBpm(double v) {
    if (v >= 40 && v <= 250) return v;
    if (v >= 4000 && v <= 25000) {
      final double scaled = v / 100.0;
      if (scaled >= 40 && scaled <= 250) return scaled;
    }
    return 0.0;
  }
}
