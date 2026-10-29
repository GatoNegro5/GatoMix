import 'dart:io';

/// Bitácora de decisiones del mezclador (solo diagnóstico, no toca el audio).
/// Archivo: <temp>/gatomix_livedj_trace.txt (se recorta solo al pasar 300 KB).
void djTrace(String msg) {
  try {
    final File f = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}gatomix_livedj_trace.txt',
    );
    if (f.existsSync() && f.lengthSync() > 300000) f.writeAsStringSync('');
    f.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $msg\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}
