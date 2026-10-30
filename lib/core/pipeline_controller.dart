// Decisiones del Masterizar que el checkpoint tiene que dejar escritas.
// No mide el BPM: solo registra lo que ya devolvió el motor.
import 'gatomix_store.dart';

/// Descarga de YouTube que imprime el bitrate y deja el archivo en disco.
/// `--print` solo implica `--simulate` si no se pasa `--no-simulate`.
List<String> ytDlpAbrDownloadArgs({
  required String output,
  required String url,
}) => <String>[
  '--rm-cache-dir',
  '-f',
  'bestaudio[ext=m4a]/141/140/bestaudio',
  '--no-simulate',
  '--print',
  '%(abr)s',
  '-o',
  output,
  url,
];

/// Re-descarga del LAB y del buscador. Sin `player_client=android_vr`
/// (yt-dlp 2026.10.26: «Requested format is not available»).
/// La conversión `-x` a mp3, si el llamador ya la tenía, no va aquí.
List<String> ytDlpRedownloadArgs({
  required String output,
  required String url,
}) => <String>['--rm-cache-dir', '-f', 'bestaudio/best', '-o', output, url];

class MasterBpmSettle {
  final bool failed;
  final double bpm;
  const MasterBpmSettle({required this.failed, required this.bpm});
}

/// BPM <= 0 al terminar una pista: se re-mide una vez. Si sigue en 0,
/// la pista queda en `failed` con razón `bpm` y el lote no se marca
/// `completed`.
Future<MasterBpmSettle> settleMasterBpm({
  required Map<String, dynamic> checkpoint,
  required String fileName,
  required double measured,
  required Future<double> Function() remeasure,
  String? logDir,
}) async {
  var bpm = measured;
  if (bpm <= 0) {
    try {
      bpm = await remeasure();
    } catch (_) {
      bpm = 0;
    }
  }
  if (bpm > 0) {
    return MasterBpmSettle(failed: false, bpm: bpm);
  }
  final List<dynamic> failed = List<dynamic>.from(
    checkpoint['failed'] as List? ?? const <dynamic>[],
  );
  if (!failed.contains(fileName)) failed.add(fileName);
  checkpoint['failed'] = failed;
  final List<dynamic> processed = List<dynamic>.from(
    checkpoint['processed'] as List? ?? const <dynamic>[],
  );
  processed.remove(fileName);
  checkpoint['processed'] = processed;
  final dynamic inc = checkpoint['incomplete'];
  if (inc is Map) {
    final Map<String, dynamic> next = Map<String, dynamic>.from(inc);
    next.remove(fileName);
    checkpoint['incomplete'] = next;
  }
  final Map<String, dynamic> reasons = Map<String, dynamic>.from(
    checkpoint['failed_reasons'] as Map? ?? const <String, dynamic>{},
  );
  reasons[fileName] = 'bpm';
  checkpoint['failed_reasons'] = reasons;
  if (logDir != null && logDir.isNotEmpty) {
    GatomixLog.append(logDir, 'AVISO $fileName BPM 0.0 incompleta: bpm');
  }
  return const MasterBpmSettle(failed: true, bpm: 0);
}

/// `completed` solo si ninguna pista quedó failed por BPM 0.
String masterCheckpointStatus({
  required Map<String, dynamic> checkpoint,
  required bool critical,
}) {
  if (critical) return '${checkpoint['status'] ?? 'in_progress'}';
  final Map<dynamic, dynamic> reasons =
      checkpoint['failed_reasons'] as Map? ?? const <dynamic, dynamic>{};
  if (reasons.containsValue('bpm')) return 'incomplete';
  return 'completed';
}
