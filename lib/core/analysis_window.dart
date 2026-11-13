/// 3.1.04: ventana de analisis completo por duracion exacta (Rust), no por
/// tamano. Debe coincidir con `MAX_ANALYZE_SECS` (rust/src/api/core_dsp.rs:56,
/// 900 s): si cambia alli, cambia aqui.
const int kMaxAnalyzeMs = 900000;

/// `true` si la pista se puede medir entera: duracion conocida y < 15 min.
bool fitsAnalysisWindow(int exactMs) => exactMs > 0 && exactMs < kMaxAnalyzeMs;
