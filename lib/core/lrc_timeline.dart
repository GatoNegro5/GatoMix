/// Desplazamiento de un `.lrc` por los milisegundos EXACTOS que Rust cortó
/// al inicio. Marcas:
/// * `[gmx_shift:ms]` — la letra ya se rearmó esa cantidad.
/// * `[gmx_manual:1]` — letra ajustada a mano: no se vuelve a mover.
class LrcShift {
  final String text;
  final bool changed;
  final bool skippedManual;
  final bool alreadyShifted;

  const LrcShift({
    required this.text,
    required this.changed,
    required this.skippedManual,
    required this.alreadyShifted,
  });
}

final RegExp _stamp = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{2,3})\]');
final RegExp _manualMark = RegExp(r'\[gmx_manual:\s*1\]', caseSensitive: false);
final RegExp _shiftMark = RegExp(
  r'\[gmx_shift:\s*(-?\d+)\]',
  caseSensitive: false,
);
final RegExp _plainMark = RegExp(r'\[gmx_plain:\s*1\]', caseSensitive: false);

bool lrcIsManual(String content) => _manualMark.hasMatch(content);

bool lrcIsPlain(String content) => _plainMark.hasMatch(content);

/// Letra que Letras no puede borrar ni reescribir: ajustada a mano o ya
/// rearmada por un corte / un retardo de encoder.
bool lrcIsProtected(String content) =>
    lrcIsManual(content) || lrcShiftMs(content) != null;

/// Milisegundos ya restados, o null si la letra no tiene la marca.
int? lrcShiftMs(String content) {
  final Match? m = _shiftMark.firstMatch(content);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

int _stampToMs(Match m) {
  final int min = int.parse(m.group(1)!);
  final int sec = int.parse(m.group(2)!);
  int ms = int.parse(m.group(3)!);
  if (m.group(3)!.length == 2) ms *= 10;
  return (min * 60000) + (sec * 1000) + ms;
}

String _msToStamp(int totalMs) {
  if (totalMs < 0) totalMs = 0;
  final String min = (totalMs ~/ 60000).toString().padLeft(2, '0');
  final String sec = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
  final String cs = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
  return '[$min:$sec.$cs]';
}

String _mapStamps(String content, int deltaMs) {
  return content.replaceAllMapped(_stamp, (Match m) {
    return _msToStamp(_stampToMs(m) + deltaMs);
  });
}

/// Milisegundos a mover la letra, o null si esta pasada no midió un corte.
///
/// Solo cuenta un recorte de audio de esta pasada (`audioCut`) con
/// [trimHeadMs] > 0. Un `GMX_TRIM` guardado de antes no se reaplica: la
/// letra se buscó contra el archivo como está. Take On Me llevaba
/// `[gmx_shift:1010]` sin ese corte y la letra quedaba ~0,6 s adelantada.
int? measuredLyricShiftMs({
  required bool audioCut,
  required int trimHeadMs,
  required int residualMs,
}) {
  if (!audioCut || trimHeadMs <= 0) return null;
  final int net = trimHeadMs - residualMs;
  if (net == 0) return null;
  return net;
}

/// Mueve cada sello por el neto `trimMs - extraDelayMs`.
/// El corte adelanta la letra; el retardo residual del encoder (si el
/// reproductor no honra el tag) la atrasa. La marca guarda ese neto, que
/// puede ser negativo. Una letra manual o ya rearmada se devuelve igual.
LrcShift shiftLrcText(String content, int trimMs, {int extraDelayMs = 0}) {
  final int net = trimMs - extraDelayMs;
  if (net == 0) {
    return LrcShift(
      text: content,
      changed: false,
      skippedManual: false,
      alreadyShifted: lrcShiftMs(content) != null,
    );
  }
  if (lrcIsManual(content)) {
    return LrcShift(
      text: content,
      changed: false,
      skippedManual: true,
      alreadyShifted: false,
    );
  }
  if (lrcShiftMs(content) != null) {
    return LrcShift(
      text: content,
      changed: false,
      skippedManual: false,
      alreadyShifted: true,
    );
  }
  final String shifted = _mapStamps(content, -net);
  return LrcShift(
    text: '[gmx_shift:$net]\n$shifted',
    changed: true,
    skippedManual: false,
    alreadyShifted: false,
  );
}

/// Al restaurar se deshace el neto guardado en `[gmx_shift:]`.
/// Si la marca no está, se usa [trimMs].
String unshiftLrcText(String content, int trimMs) {
  if (lrcIsManual(content)) return content;
  final int delta = lrcShiftMs(content) ?? trimMs;
  if (delta == 0) return content;
  final String without = content
      .replaceAll(_shiftMark, '')
      .replaceFirst(RegExp(r'^\s*\n'), '');
  return _mapStamps(without, delta);
}

/// Primer verso real, en ms. Ignora sellos vacíos, marcas gmx y basura.
int? firstVerseMs(String content) {
  final RegExp lineRe = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{2,3})\](.*)');
  for (final String line in content.split('\n')) {
    if (_manualMark.hasMatch(line) ||
        _shiftMark.hasMatch(line) ||
        _plainMark.hasMatch(line)) {
      continue;
    }
    final Match? m = lineRe.firstMatch(line);
    if (m == null) continue;
    final String text = (m.group(4) ?? '').trim().toLowerCase();
    if (text.isEmpty || text.length < 2) continue;
    if (text.startsWith('[') || text.startsWith('(')) continue;
    if (text.contains('♪') || text.contains('🎵')) continue;
    if (text.contains('instrumental') ||
        text.contains('letra no encontrada') ||
        text.contains('www.')) {
      continue;
    }
    return _stampToMs(m);
  }
  return null;
}
