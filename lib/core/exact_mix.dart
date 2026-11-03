/// Fundido ya medido contra la duración exacta.
///
/// [mixOutMs] es el punto de la estructura (porcentaje, outro, frase). No se
/// corre a «N segundos antes del final». Si el fundido pedido no cabe en lo
/// que queda, se escala por resto/pedido.
class FittedFade {
  final int mixOutMs;
  final int fadeMs;
  final int wantedFadeMs;
  final bool shortened;

  const FittedFade({
    required this.mixOutMs,
    required this.fadeMs,
    required this.wantedFadeMs,
    required this.shortened,
  });

  String get note => shortened
      ? 'FUNDIADO mixOut=$mixOutMs wanted=${wantedFadeMs} fade=$fadeMs'
      : '';
}

/// Elige el primer punto de [mixOutMs] y [structuralMs] donde cabe
/// [wantedFadeMs]. Si ninguno deja sitio, el punto principal se queda y el
/// fundido pasa a ser la fracción resto/pedido.
FittedFade fitMixFade({
  required int exactDurationMs,
  required int mixOutMs,
  required int wantedFadeMs,
  List<int> structuralMs = const <int>[],
}) {
  final int wanted = wantedFadeMs < 0 ? 0 : wantedFadeMs;
  if (exactDurationMs <= 0) {
    return FittedFade(
      mixOutMs: mixOutMs,
      fadeMs: wanted,
      wantedFadeMs: wanted,
      shortened: false,
    );
  }
  for (final int raw in <int>[mixOutMs, ...structuralMs]) {
    if (raw < 0 || raw >= exactDurationMs) continue;
    if (exactDurationMs - raw >= wanted) {
      return FittedFade(
        mixOutMs: raw,
        fadeMs: wanted,
        wantedFadeMs: wanted,
        shortened: false,
      );
    }
  }
  final int point = mixOutMs < 0
      ? 0
      : (mixOutMs > exactDurationMs ? exactDurationMs : mixOutMs);
  final int room = exactDurationMs - point;
  final int fade = room < 0 ? 0 : room;
  return FittedFade(
    mixOutMs: point,
    fadeMs: fade,
    wantedFadeMs: wanted,
    shortened: fade != wanted,
  );
}

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
