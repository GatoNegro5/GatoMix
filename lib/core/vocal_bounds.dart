/// Cues automáticos desde la letra contra la duración exacta del audio (ms).
///
/// `null` = letra de otra versión (la última línea llega o pasa el final real):
/// no se escribe nada y decide el motor de audio. Con `exactMs <= 0` (sin
/// medición) se queda `lastMs + 1000`, igual que antes.
class VocalBounds {
  final int cueInMs;
  final int mixOutMs;
  const VocalBounds(this.cueInMs, this.mixOutMs);
}

VocalBounds? vocalBounds({
  required int firstMs,
  required int lastMs,
  required int exactMs,
}) {
  if (exactMs > 0 && lastMs >= exactMs) return null;
  int cueIn = firstMs - 5000;
  if (cueIn < 0) cueIn = 0;
  int mixOut = lastMs + 1000;
  if (exactMs > 0) {
    final int remaining = exactMs - mixOut;
    if (remaining > 15000) {
      mixOut = lastMs + 4000;
    } else if (remaining < 3000) {
      mixOut = exactMs - 4000;
    }
  }
  if (mixOut < 0) mixOut = 0;
  return VocalBounds(cueIn, mixOut);
}