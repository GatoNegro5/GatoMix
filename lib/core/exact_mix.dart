/// El disparo usa la duración decodificada y el punto de mezcla ya calculado.
/// Sin medición no hay ventana. No hay red de 25 s ni otro adelanto fijo.
bool mixTriggerDue({
  required int posMs,
  required int exactMs,
  required int mixOutMs,
}) {
  if (exactMs <= 0 || mixOutMs <= 10000) return false;
  return posMs >= mixOutMs;
}

/// Línea del resumen cuando el TLEN y el audio difieren más de 10 s.
String? stuckAudioLine({
  required String name,
  required int? tlenMs,
  required int audioMs,
  required bool mismatch,
}) {
  if (!mismatch || tlenMs == null) return null;
  return '$name — posible audio pegado / versión distinta '
      '(tlen=$tlenMs, audio=$audioMs)';
}

/// Respuesta de `rewrite_tlen`: `audio=<ms>,tlen=<ms|none>,mismatch=<0|1>,wrote=<0|1>`.
class TlenReport {
  final int audioMs;
  final int? tlenMs;
  final bool mismatch;
  final bool wrote;

  const TlenReport({
    required this.audioMs,
    required this.tlenMs,
    required this.mismatch,
    required this.wrote,
  });

  static TlenReport parse(String raw) {
    int audio = 0;
    int? tlen;
    var mismatch = false;
    var wrote = false;
    for (final String part in raw.split(',')) {
      final int eq = part.indexOf('=');
      if (eq <= 0) continue;
      final String k = part.substring(0, eq).trim();
      final String v = part.substring(eq + 1).trim();
      if (k == 'audio') audio = int.tryParse(v) ?? 0;
      if (k == 'tlen' && v != 'none') tlen = int.tryParse(v);
      if (k == 'mismatch') mismatch = v == '1';
      if (k == 'wrote') wrote = v == '1';
    }
    return TlenReport(
      audioMs: audio,
      tlenMs: tlen,
      mismatch: mismatch,
      wrote: wrote,
    );
  }
}
