/// 3.1.04: ventana de analisis completo por duracion exacta (Rust), no por
/// tamano. Debe coincidir con `MAX_ANALYZE_SECS` (rust/src/api/core_dsp.rs:56,
/// 900 s): si cambia alli, cambia aqui.
const int kMaxAnalyzeMs = 900000;

/// `true` si la pista se puede medir entera: duracion conocida y < 15 min.
bool fitsAnalysisWindow(int exactMs) => exactMs > 0 && exactMs < kMaxAnalyzeMs;

/// 3.1.09: el analisis completo corre en streaming (Rust, RAM fija): se mide
/// toda pista con duracion conocida, megamixes >= 15 min incluidos.
bool canAnalyzeFull(int exactMs) => exactMs > 0;

/// 3.1.09: timeout proporcional. Hasta 15 min, `base` (el de siempre); por
/// encima, `base` por cada bloque de 15 min (62 min = 5 x base).
Duration analysisTimeout(int exactMs, Duration base) {
  if (exactMs <= kMaxAnalyzeMs) return base;
  final int blocks = (exactMs + kMaxAnalyzeMs - 1) ~/ kMaxAnalyzeMs;
  return base * blocks;
}

/// 3.1.09: el cache de BPM vuelve a escanear si el archivo cambio o si no
/// tiene BPM guardado (los megamixes que 3.1.04 marco sin medir).
bool needsBpmScan({
  required int? storedTimestamp,
  required int modified,
  required bool hasCachedBpm,
}) =>
    storedTimestamp == null || storedTimestamp != modified || !hasCachedBpm;
