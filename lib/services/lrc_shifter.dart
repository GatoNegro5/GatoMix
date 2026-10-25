import 'dart:io';

// ❌ CERO DEPENDENCIAS DE FLUTTER AQUÍ

void main() {
  // Ruta estricta al archivo .lrc que quieres reparar
  final lrcPath =
      r"C:\Users\ASUS\Music\ReGenial\Cumbias\Angeles Azules Gilberto Santa Rosa Paso La Vida Pensando.lrc";

  // Positivo atrasa la letra (empieza más tarde). Negativo adelanta la letra.
  // Ejemplo: +33.75 segundos de desfase = 33750 ms
  final offsetMilliseconds = 33750;

  _shiftLrcTime(lrcPath, offsetMilliseconds);
}

void _shiftLrcTime(String path, int offsetMs) {
  final file = File(path);
  if (!file.existsSync()) {
    print("🔴 Error: Archivo LRC no encontrado en I/O.");
    return;
  }

  final lines = file.readAsLinesSync();
  final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
  final newLines = <String>[];

  for (var line in lines) {
    final match = regex.firstMatch(line);
    if (match != null) {
      final min = int.parse(match.group(1)!);
      final sec = int.parse(match.group(2)!);
      int ms = int.parse(match.group(3)!);

      // Normalización a milisegundos reales (si el LRC trae 2 dígitos, ej .25 = 250ms)
      if (match.group(3)!.length == 2) ms *= 10;

      // Matemática de tiempo
      int totalMs = (min * 60000) + (sec * 1000) + ms;
      totalMs += offsetMs;

      // Failsafe: Evitar tiempos negativos
      if (totalMs < 0) totalMs = 0;

      final newMin = (totalMs ~/ 60000).toString().padLeft(2, '0');
      final newSec = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
      final newMs = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');

      final text = match.group(4)!;
      newLines.add('[$newMin:$newSec.$newMs]$text');
    } else {
      // Inyección intacta de líneas de metadatos (ej. [ar:Artista])
      newLines.add(line);
    }
  }

  // Escritura atómica O(1)
  file.writeAsStringSync(newLines.join('\n'));
  print("🟢 Operación de Offset completada. LRC desplazado por $offsetMs ms.");
}
