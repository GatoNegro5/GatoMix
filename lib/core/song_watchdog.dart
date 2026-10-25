/// Vigilante del lote sin clics (1.0.14): si ninguna pista avanza en
/// [headlessStallLimit], el proceso sale para que el runner siga con la
/// carpeta siguiente. Rust ya corta cada canción a los 20 min; esto es la
/// red de seguridad por si algo se cuelga fuera de `cancel_now`.
const Duration headlessStallLimit = Duration(minutes: 30);

bool headlessStalled(
  DateTime lastProgress,
  DateTime now, {
  Duration limit = headlessStallLimit,
}) =>
    now.difference(lastProgress) >= limit;
