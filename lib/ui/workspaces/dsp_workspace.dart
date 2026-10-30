import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;

import '../../core/brand_paths.dart';
import '../../core/lab_quarantine.dart';
import '../../core/exact_mix.dart';
import '../../core/gatomix_store.dart';
import '../../core/gmx_status.dart';
import '../../core/lrc_timeline.dart';
import '../../core/master_cool.dart';
import '../../core/master_skip.dart';
import '../../core/queue_bpm.dart';
import '../../core/stored_grid.dart';
import '../../services/track_tags.dart';
import 'livedj_bpm_badge.dart';
import '../../core/thermal_status.dart';
import '../../core/master_pause.dart';
import '../../core/master_profile.dart';
import '../../djiphone/iphone_library.dart';
import '../../providers/directory_provider.dart';
import '../../services/master_track.dart';
import '../../providers/pipeline_provider.dart';
import '../../providers/metadata_provider.dart';
import '../../providers/nlp_provider.dart';
import '../../providers/dsp_provider.dart';
import '../../providers/db_provider.dart';
import '../../services/karaoke_engine.dart';

// ==========================================
// 🧠 ESTADO GLOBAL DEL MOTOR DE IA
// ==========================================
class AiEngineState {
  final bool isRunning;
  final bool? cancelRequested;
  final String status;
  AiEngineState({
    this.isRunning = false,
    this.cancelRequested = false,
    this.status = '',
  });

  bool get stopping => cancelRequested == true;
}

class AiEngineNotifier extends StateNotifier<AiEngineState> {
  static final File stopFlag = File(
    r'C:\Users\ASUS\Music\ReGenial_TempAI\.karaoke_ai_stop',
  );

  AiEngineNotifier() : super(AiEngineState());

  void start(String path) {
    try {
      if (stopFlag.existsSync()) stopFlag.deleteSync();
    } catch (_) {}
    state = AiEngineState(isRunning: true, status: 'Iniciando Motor IA...');
  }

  void updateStatus(String status) {
    state = AiEngineState(
      isRunning: true,
      cancelRequested: state.cancelRequested,
      status: status,
    );
  }

  void requestStop() {
    if (!state.isRunning || state.stopping) return;
    KaraokeEngine.stopQueue = true;
    try {
      stopFlag.parent.createSync(recursive: true);
      stopFlag.writeAsStringSync('1');
    } catch (_) {}
    state = AiEngineState(
      isRunning: true,
      cancelRequested: true,
      status: 'Cancelando al terminar esta pista…',
    );
  }

  void stop() {
    state = AiEngineState(isRunning: false, status: '');
  }
}

final aiEngineProvider = StateNotifierProvider<AiEngineNotifier, AiEngineState>(
  (ref) {
    return AiEngineNotifier();
  },
);

class DspNlpWorkspace extends ConsumerWidget {
  const DspNlpWorkspace({super.key});

  /// Modo sin clics (`--master-folder`): mismo Masterizar y mismo checkpoint
  /// que el botón, solo sin el aviso previo.
  Future<void> runHeadlessMaster(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) => _executeUniversalPipeline(context, ref, targetPath, skipPreflight: true);

  void _showSummaryDialog(
    BuildContext context,
    String title,
    int total,
    List<String> failedTracks, {
    bool isAborted = false,
    int current = 0,
    List<String> lenMismatch = const <String>[],
  }) {
    final int processed = isAborted ? current : (total - failedTracks.length);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: isAborted ? Colors.orangeAccent : const Color(0xFF39FF14),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        title: Row(
          children: [
            Icon(
              isAborted ? Icons.warning_amber_rounded : Icons.fact_check,
              color: isAborted ? Colors.orangeAccent : const Color(0xFF39FF14),
            ),
            const SizedBox(width: 10),
            Text(
              isAborted ? "cancelado" : "Reporte: $title",
              style: TextStyle(
                color: isAborted
                    ? Colors.orangeAccent
                    : const Color(0xFF39FF14),
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          height: (failedTracks.isEmpty && lenMismatch.isEmpty) ? 100 : 300,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isAborted
                    ? "⚠️ Proceso detenido en la pista: $processed / $total"
                    : "✅ Procesados con éxito: $processed / $total",
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              if (lenMismatch.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  "posible audio pegado / versión distinta",
                  style: TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                SizedBox(
                  height: 100,
                  child: ListView.builder(
                    itemCount: lenMismatch.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          "• ${lenMismatch[index]}",
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                            fontFamily: 'Consolas',
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              if (failedTracks.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  "❌ Archivos con error o saltados (Cuarentena):",
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      border: Border.all(color: Colors.white10),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: ListView.builder(
                      itemCount: failedTracks.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Text(
                            "• ${failedTracks[index]}",
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontFamily: 'Consolas',
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: isAborted
                  ? Colors.orangeAccent
                  : const Color(0xFF39FF14),
              foregroundColor: Colors.black,
            ),
            child: const Text(
              "Entendido",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // El corte real desplaza con los ms de Rust (MasterTrack / lrc_timeline).
  // ignore: unused_element
  Future<void> _offsetLrcTimeline(String lrcPath, int trimmedMs) async {
    final file = File(lrcPath);
    if (!file.existsSync() || trimmedMs <= 0) return;

    try {
      final lines = await file.readAsLines();
      final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
      final newLines = <String>[];

      for (var line in lines) {
        final match = regex.firstMatch(line);
        if (match != null) {
          final min = int.parse(match.group(1)!);
          final sec = int.parse(match.group(2)!);
          int ms = int.parse(match.group(3)!);
          if (match.group(3)!.length == 2) ms *= 10;

          int totalMs = (min * 60000) + (sec * 1000) + ms - trimmedMs;
          if (totalMs < 0) totalMs = 0;

          final newMin = (totalMs ~/ 60000).toString().padLeft(2, '0');
          final newSec = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
          final newMs = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
          final text = match.group(4)!;

          newLines.add('[$newMin:$newSec.$newMs]$text');
        } else {
          newLines.add(line);
        }
      }
      await file.writeAsString(newLines.join('\n'));
    } catch (_) {}
  }

  Future<bool> _showPreFlightCheck(BuildContext context) async {
    final bool isMobile = Platform.isAndroid || Platform.isIOS;

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121212),
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Color(0xFF00FFFF), width: 1.5),
                borderRadius: BorderRadius.circular(12),
              ),
              title: Row(
                children: [
                  Icon(
                    isMobile ? Icons.phone_android : Icons.computer,
                    color: const Color(0xFF00FFFF),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    "Revisión antes de iniciar",
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Masterizado no destructivo (el audio no se recodifica y tus letras no se tocan):",
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 20),

                    _buildCapabilityRow(
                      Icons.check_circle,
                      const Color(0xFF39FF14),
                      "Limpiar los nombres de los archivos",
                    ),
                    _buildCapabilityRow(
                      Icons.check_circle,
                      const Color(0xFF39FF14),
                      "Calcular el momento exacto para mezclar",
                    ),
                    _buildCapabilityRow(
                      Icons.check_circle,
                      const Color(0xFF39FF14),
                      "Detectar la velocidad (Ritmo)",
                    ),

                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Divider(color: Colors.white10),
                    ),

                    _buildCapabilityRow(
                      Icons.check_circle,
                      const Color(0xFF39FF14),
                      "Medir el volumen de cada pista (igualarlo al sonar)",
                    ),
                    _buildCapabilityRow(
                      Icons.check_circle,
                      const Color(0xFF39FF14),
                      "Detectar los espacios vacíos al inicio y final",
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text(
                    "CANCELAR",
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00FFFF),
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text("INICIAR PREPARACIÓN"),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Widget _buildCapabilityRow(
    IconData icon,
    Color color,
    String title, [
    String? badge,
  ]) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: color == Colors.white24 ? Colors.white54 : Colors.white,
                fontSize: 13,
              ),
            ),
          ),
          if (badge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                badge,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _executeKaraokeBatch(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) {
    if (Platform.isAndroid || Platform.isIOS) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("🔴 VETO TÉCNICO: La IA de Karaoke requiere PC/Mac."),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    if (targetPath.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "🤖 Motor IA Activado. Puedes navegar a otros módulos mientras trabaja.",
        ),
        backgroundColor: Color(0xFFB026FF),
      ),
    );

    // Dispara el Job masivo hacia Python pasándole el puente de la UI
    KaraokeAIEngine.spawnBackgroundExtraction(targetPath, ref: ref);
  }

  Future<void> _executeUniversalPipeline(
    BuildContext context,
    WidgetRef ref,
    String targetPath, {
    bool skipPreflight = false,
  }) async {
    if (!skipPreflight && context.mounted) {
      bool isAuthorized = await _showPreFlightCheck(context);
      if (!isAuthorized) return;
    }

    final pipe = ref.read(pipelineProvider.notifier);
    await rust_dsp.masterArm();
    ref.read(directoryProvider.notifier).scanPath(targetPath);
    bool latchedAbort = false;
    bool checkAbort() {
      if (ref.read(pipelineProvider).isAborted) latchedAbort = true;
      return latchedAbort;
    }

    int consecutiveErrors = 0;
    final List<String> lyricReview = <String>[];
    final List<String> lenMismatch = <String>[];
    int lyricFixed = 0;
    String? criticalFailureMessage;
    bool isThermalThrottling = false;

    Map<String, dynamic> checkpoint = {
      'schema': 2,
      'status': 'started',
      'timestamp': DateTime.now().toIso8601String(),
      'processed': <String>[],
      'failed': <String>[],
    };
    void persistCheckpoint() =>
        GatomixStore.writeCheckpoint(targetPath, checkpoint);

    final Map<String, dynamic>? existingData = GatomixStore.readCheckpoint(
      targetPath,
    );
    if (existingData != null) {
      try {
        final String lastStatus = existingData['status'] ?? 'unknown';

        if (existingData['schema'] == 2 && lastStatus != 'completed') {
          checkpoint['processed'] = existingData['processed'] ?? <String>[];
          checkpoint['failed'] = existingData['failed'] ?? <String>[];
          final int recoveredCount = (checkpoint['processed'] as List).length;

          debugPrint(
            "🔄 [PROCESS VALIDATOR] Sesión inconclusa detectada ($lastStatus). Recuperando $recoveredCount pistas.",
          );

          if (context.mounted && recoveredCount > 0) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '🔄 Validador Activo: Retomando sesión. Se saltarán $recoveredCount pistas.',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
                backgroundColor: const Color(0xFF00FFFF),
                duration: const Duration(seconds: 4),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        } else if (existingData['schema'] == 2) {
          GatomixStore.clearCheckpoint(targetPath);
        } else {
          debugPrint(
            "🔄 [PROCESS VALIDATOR] Checkpoint anterior (solo etiquetas). Este pase mira las marcas GMX.",
          );
        }
      } catch (e) {
        debugPrint(
          "⚠️ [PROCESS VALIDATOR] Checkpoint corrupto. Iniciando en limpio.",
        );
      }
    }

    try {
      final dir = Directory(targetPath);
      if (!dir.existsSync()) return;

      final files = dir.listSync(recursive: true).whereType<File>().where((f) {
        final lowerPath = f.path.toLowerCase().replaceAll('\\', '/');
        if (lowerPath.contains('/.gatomix_original/')) return false;
        return (lowerPath.endsWith('.mp3') && !lowerPath.endsWith('_k.mp3')) ||
            lowerPath.endsWith('.webm');
      }).toList();

      int total = files.length;
      if (total == 0) return;

      checkpoint['status'] = 'in_progress';
      persistCheckpoint();

      final MasterProfile profile = MasterProfile.current();
      // 1.0.20: índice por carpeta para saltar en milisegundos las pistas
      // ya completas (sin decodificar ni buscar letra).
      final MasterSkipIndex skipIndex = MasterSkipIndex.load(targetPath);
      int skipped = 0;
      int cursor = 0;
      int finished = 0;
      bool stopAll = false;

      Future<void> lane() async {
        while (true) {
          if (stopAll || checkAbort()) {
            stopAll = true;
            return;
          }
          final int i = cursor;
          if (i >= total) return;
          cursor = i + 1;

          final file = files[i];
          final originalName = file.uri.pathSegments.last;
          String currentPath = file.path;
          String currentStage = "INIT";

          // 1.0.20: un 'processed' de una corrida vieja (1.0.19) se vuelve a
          // validar por tags: si faltan marcas (Indeep) no se salta.
          final bool inProcessed = (checkpoint['processed'] as List).contains(
            originalName,
          );
          final bool staleProcessed =
              inProcessed &&
              originalName.toLowerCase().endsWith('.mp3') &&
              !skipIndex.decide(currentPath).skip;
          if (staleProcessed) {
            (checkpoint['processed'] as List).remove(originalName);
          }
          if ((inProcessed && !staleProcessed) ||
              (checkpoint['failed'] as List).contains(originalName)) {
            finished++;
            pipe.updateProgress(
              finished,
              total,
              originalName,
              "⏭️ Validador de I/O: Pista ya procesada. Saltando...",
            );
            await Future.delayed(const Duration(milliseconds: 10));
            continue;
          }

          if (originalName.toLowerCase().endsWith('.mp3')) {
            final SkipDecision quick = skipIndex.decide(currentPath);
            if (quick.skip) {
              skipped++;
              finished++;
              (checkpoint['processed'] as List).add(originalName);
              pipe.updateProgress(
                finished,
                total,
                originalName,
                '⏭️ Ya masterizada (${quick.reason}). Saltando...',
              );
              if (skipped % 25 == 0) {
                skipIndex.save();
                persistCheckpoint();
              }
              await Future<void>.delayed(Duration.zero);
              continue;
            }
            debugPrint('MASTER pendiente (${quick.reason}) $originalName');
          }

          final Stopwatch trackClock = Stopwatch()..start();
          Future<void> logSong(int pauseMs) async {
            if (trackClock.isRunning) trackClock.stop();
            var prio = MasterCool.priorityLabel(ThermalProbe.platform);
            try {
              final String got = await rust_dsp.masterPriority();
              if (got.isNotEmpty) prio = got;
            } catch (_) {}
            final String termico = await ThermalProbe.label();
            debugPrint(
              'MASTER prio=$prio proceso=${trackClock.elapsedMilliseconds}ms pausa=${pauseMs}ms termico=$termico $originalName',
            );
          }

          try {
            final bool isMp3 = currentPath.toLowerCase().endsWith('.mp3');
            if (!isMp3) {
              currentStage = "METADATA_CLEANUP";
              pipe.updateProgress(
                finished + 1,
                total,
                originalName,
                "📝 Limpiando nombres...",
              );
              currentPath = await ref
                  .read(metadataWorkerProvider)
                  .processSingleFile(currentPath);
              if (stopAll || checkAbort()) {
                stopAll = true;
                await logSong(0);
                return;
              }
              currentStage = "DSP_ANALYSIS";
              pipe.updateProgress(
                finished + 1,
                total,
                originalName,
                "🪄 Midiendo volumen, espacios y ritmo...",
              );
              final bool analyzed = await ref
                  .read(dspWorkerProvider)
                  .analyzeTrack(currentPath);
              if (stopAll || checkAbort()) {
                stopAll = true;
                await logSong(0);
                return;
              }
              if (analyzed) {
                currentStage = "WATERMARK_ID3";
                await rust_dsp
                    .injectWatermark(inputPath: currentPath)
                    .timeout(
                      const Duration(seconds: 30),
                      onTimeout: () => throw Exception(
                        "Timeout: Bloqueo de disco al inyectar ID3v2.",
                      ),
                    );
              }
              if (stopAll || checkAbort()) {
                stopAll = true;
                await logSong(0);
                return;
              }
              (checkpoint['processed'] as List).add(originalName);
            } else {
              currentStage = 'METADATA_CLEANUP';
              final Timer tick = Timer.periodic(const Duration(seconds: 1), (
                _,
              ) {
                pipe.updateProgress(
                  finished + 1,
                  total,
                  originalName,
                  '${_masterStageLabel(currentStage)} · ${trackClock.elapsed.inSeconds}s',
                );
              });
              try {
                final outcome = await MasterTrack.run(
                  ref: ref,
                  path: currentPath,
                  withLyrics: true,
                  shouldStop: checkAbort,
                  onStage: (String stage) {
                    currentStage = stage;
                    pipe.updateProgress(
                      finished + 1,
                      total,
                      originalName,
                      '${_masterStageLabel(stage)} · ${trackClock.elapsed.inSeconds}s',
                    );
                  },
                );
                currentPath = outcome.path;
                if (outcome.lenNote.isNotEmpty) {
                  lenMismatch.add(outcome.lenNote);
                }
                if (outcome.lyricCheck == 'REVIEW') {
                  lyricReview.add(
                    '${File(outcome.path).uri.pathSegments.last} — ${outcome.lyricCheckReason}',
                  );
                } else if (outcome.lyricCheck == 'FIXED') {
                  lyricFixed++;
                }
                if (outcome.detail.contains('decode_errors')) {
                  pipe.updateProgress(
                    finished + 1,
                    total,
                    originalName,
                    'Audio intacto · ${outcome.detail}',
                  );
                }
                if (outcome.stopped || stopAll || checkAbort()) {
                  stopAll = true;
                  await logSong(0);
                  return;
                }
                final String? miss = skipIndex.record(outcome.path);
                skipIndex.save();
                final String? bucket = checkpointBucket(
                  lyricRetry: outcome.lyric == LyricStatus.retry,
                  miss: miss,
                );
                if (bucket == 'processed') {
                  (checkpoint['processed'] as List).add(originalName);
                } else if (bucket == 'incomplete') {
                  final Map<String, dynamic> inc =
                      (checkpoint['incomplete'] as Map<String, dynamic>?) ??
                      <String, dynamic>{};
                  inc[originalName] = outcome.detail.isEmpty
                      ? miss
                      : '$miss · ${outcome.detail}';
                  checkpoint['incomplete'] = inc;
                  debugPrint('MASTER incompleta ($miss) $originalName');
                }
              } finally {
                tick.cancel();
              }
            }
            consecutiveErrors = 0;
            checkpoint['timestamp'] = DateTime.now().toIso8601String();
            persistCheckpoint();
          } catch (e) {
            debugPrint(
              "🔴 Error preparando la pista $originalName en stage $currentStage: $e",
            );
            pipe.addQuarantine(originalName);

            (checkpoint['failed'] as List).add(originalName);
            checkpoint['timestamp'] = DateTime.now().toIso8601String();
            persistCheckpoint();

            String errorCode = "ERR_UNKNOWN";
            String recommendedAction =
                "Archivo corrupto. Considera eliminarlo y descargar otra versión.";

            if (currentStage == "METADATA_CLEANUP") {
              errorCode = "ERR_FILE_IO";
              recommendedAction = "El archivo está bloqueado por otro programa (ej. Rekordbox, Serato o un reproductor). Ciérralos e inténtalo de nuevo.";
            } else if (currentStage == "DSP_FFMPEG") {
              errorCode = "ERR_CODEC";
              recommendedAction = "El codec del archivo MP3/M4A está roto o vacío. Reemplázalo descargando una nueva copia desde YouTube DL.";
            } else if (currentStage == "WATERMARK_ID3") {
              errorCode = "ERR_TAGS";
              recommendedAction = "Fallo al inyectar firmas ID3v2. Las etiquetas originales están corruptas. Intenta limpiar las etiquetas del archivo.";
            } else if (currentStage == "DB_ISAR") {
              errorCode = "ERR_DATABASE";
              recommendedAction = "Fallo al guardar en ISAR Database. Ejecuta un Reset de Fábrica si el problema persiste.";
            } else if (e.toString().contains("Timeout DSP")) {
              errorCode = "ERR_TIMEOUT";
              recommendedAction = "Fallo por alta temperatura de la CPU al normalizar el audio. Intenta masterizar esta pista sola más tarde.";
            }

            try {
              final baseDir = Directory(targetPath).parent;
              final labDir = Directory(labFolder(baseDir.path));
              if (!labDir.existsSync()) labDir.createSync(recursive: true);

              final registryFile = File(
                '${labDir.path}${Platform.pathSeparator}quarantine_registry.json',
              );
              Map<String, dynamic> registry = {};
              if (registryFile.existsSync()) {
                try {
                  registry = jsonDecode(registryFile.readAsStringSync());
                } catch (_) {}
              }

              final failFile = File(currentPath);
              if (failFile.existsSync()) {
                final newPath =
                    '${labDir.path}${Platform.pathSeparator}$originalName';
                failFile.renameSync(newPath);

                registry[originalName] = {
                  "originalPath": currentPath,
                  "errorCode": errorCode,
                  "errorMsg": e.toString(),
                  "recommendedAction": recommendedAction,
                  "failedAtStage": currentStage,
                  "timestamp": DateTime.now().toIso8601String(),
                };

                final lrcFile = File(
                  currentPath.replaceAll(
                    RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
                    '.lrc',
                  ),
                );
                if (lrcFile.existsSync()) {
                  lrcFile.renameSync(
                    '${labDir.path}${Platform.pathSeparator}${originalName.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
                  );
                }
                registryFile.writeAsStringSync(jsonEncode(registry));
              }
            } catch (ioErr) {
              debugPrint("🔴 Error crítico de I/O al aislar archivo: $ioErr");
            }

            consecutiveErrors++;
            final errorMessage = e.toString();

            if (errorMessage.contains("Timeout DSP")) {
              isThermalThrottling = true;
              criticalFailureMessage = "🌡️ ALERTA TÉRMICA: Tu procesador se ha sobrecalentado y el motor DSP colapsó.\n\n👉 ACCIÓN: Deja enfriar el equipo unos minutos y luego vuelve a darle a 'Masterización Global'. El Validador de Procesos saltará todo el trabajo anterior y retomará justo donde te quedaste.";
              checkpoint['status'] = 'thermal_halt';
              persistCheckpoint();
              pipe.abort();
              stopAll = true;
              await logSong(0);
              return;
            } else if (consecutiveErrors >= 3) {
              isThermalThrottling = false;
              criticalFailureMessage = "💥 COLAPSO I/O: Se han detectado múltiples fallos consecutivos de disco o base de datos.\n\n👉 ACCIÓN: Es OBLIGATORIO que ejecutes el 'Reset de Fábrica' antes de intentar masterizar. Recuerda borrar la sección checkpoint del archivo oculto .gatomix.json en tu carpeta si quieres forzar un re-procesamiento total.";
              checkpoint['status'] = 'io_crash';
              persistCheckpoint();
              pipe.abort();
              stopAll = true;
              await logSong(0);
              return;
            }
          }

          if (trackClock.isRunning) trackClock.stop();
          if (stopAll || checkAbort()) {
            await logSong(0);
            stopAll = true;
            return;
          }
          var pauseMs = 0;
          final int nextSong = i + 2;
          if (profile.thermalPause &&
              MasterCool.pauseBeforeSong(nextSong) &&
              _batchHasPending(files, cursor, total, checkpoint)) {
            pauseMs = await MasterPause.run(
              baseMs: profile.thermalGap.inMilliseconds,
              cancelled: checkAbort,
              allowThermal: MasterCool.thermalBeforeSong(nextSong),
              onTick: (String label) {
                pipe.updateProgress(finished + 1, total, originalName, label);
              },
            );
          }
          await logSong(pauseMs);
          if (stopAll || checkAbort()) {
            stopAll = true;
            return;
          }
          finished++;
        }
      }

      await lane();
      skipIndex.save();

      if (checkAbort()) {
        pipe.confirmCancelled();
      } else {
        pipe.updateProgress(
          total,
          total,
          "Organizando biblioteca...",
          "🥁 Analizando velocidades (Ritmo)",
        );
        await ref.read(dspWorkerProvider).generateStaticBpmCache(targetPath);

        if (criticalFailureMessage == null) {
          checkpoint['status'] = 'completed';
          checkpoint['timestamp'] = DateTime.now().toIso8601String();
          persistCheckpoint();
        }
      }
    } catch (e) {
      debugPrint("🔴 [ERROR AL PREPARAR CARPETA]: $e");
    } finally {
      if (context.mounted) {
        final state = ref.read(pipelineProvider);

        if (criticalFailureMessage != null) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF121212),
              shape: RoundedRectangleBorder(
                side: BorderSide(
                  color: isThermalThrottling
                      ? Colors.orangeAccent
                      : Colors.redAccent,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              title: Row(
                children: [
                  Icon(
                    isThermalThrottling
                        ? Icons.thermostat
                        : Icons.warning_amber_rounded,
                    color: isThermalThrottling
                        ? Colors.orangeAccent
                        : Colors.redAccent,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    isThermalThrottling
                        ? "Corte Térmico (Thermal Throttling)"
                        : "Colapso del Pipeline",
                    style: TextStyle(
                      color: isThermalThrottling
                          ? Colors.orangeAccent
                          : Colors.redAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              content: Text(
                criticalFailureMessage!,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isThermalThrottling
                        ? Colors.orangeAccent
                        : Colors.redAccent,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(
                    "ENTENDIDO",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          );
        } else if (state.total > 0) {
          _showSummaryDialog(
            context,
            "Preparación Completada",
            state.total,
            state.quarantinedTracks,
            isAborted: state.isAborted,
            current: state.current,
            lenMismatch: lenMismatch,
          );
        }
        if (lyricReview.isNotEmpty || lyricFixed > 0) {
          _showLyricReviewDialog(context, lyricReview, lyricFixed);
        }
        ref.read(directoryProvider.notifier).scanPath(targetPath);
      }
      pipe.reset();
    }
  }

  // ==========================================
  // 📝 LETRAS (independiente del masterizado de sonido)
  // ==========================================
  Future<void> _executeLyrics(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final pipe = ref.read(pipelineProvider.notifier);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;
    Map<LyricStatus, int> counts = {};
    try {
      pipe.updateProgress(0, 1, "Preparando letras...", "📝 Letras");
      counts = await ref
          .read(nlpWorkerProvider)
          .downloadForDirectory(targetPath, isCancelled: checkAbort);
    } catch (e) {
      debugPrint("🔴 [LETRAS ERROR]: $e");
    } finally {
      pipe.reset();
      if (context.mounted) {
        final int ok = counts[LyricStatus.ok] ?? 0;
        final int kept = counts[LyricStatus.kept] ?? 0;
        final int none = counts[LyricStatus.noMatch] ?? 0;
        final int bad = counts[LyricStatus.failed] ?? 0;
        final int retry = counts[LyricStatus.retry] ?? 0;
        final int plain = counts[LyricStatus.plain] ?? 0;
        final int doubt = counts[LyricStatus.doubt] ?? 0;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "📝 Letras: $ok nuevas · $plain en texto · $kept ya estaban (intactas) · $doubt dudosas · $none sin coincidencia segura · $retry para reintentar · $bad con error",
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            backgroundColor: const Color(0xFF00FFFF),
            duration: const Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _executeLyricsReset(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text(
          "Borrar letras automáticas",
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: const Text(
          "Solo se borran las letras que descargó la app y que no has tocado. "
          "Las letras que arreglaste tú NO se borran.",
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("CANCELAR"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("BORRAR AUTOMÁTICAS"),
          ),
        ],
      ),
    );
    if (go != true) return;
    final int n = await ref.read(nlpWorkerProvider).resetAutoLyrics(targetPath);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "📝 $n letras automáticas borradas. Las tuyas siguen intactas.",
          ),
        ),
      );
    }
  }

  // RESET DE SONIDO: quita el sello y las etiquetas de masterizado y purga
  // la base ISAR SIN tocar letras ni cues fijados a mano.
  Future<void> _executeFactoryReset(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text(
          'Reset de fábrica',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: const Text(
          'Reset no devuelve el audio original; para eso use Restaurar.',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('SEGUIR'),
          ),
        ],
      ),
    );
    if (go != true) return;

    final pipe = ref.read(pipelineProvider.notifier);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    try {
      pipe.updateProgress(0, 1, "Preparando purga...", "Iniciando Reset...");
      await ref
          .read(dspWorkerProvider)
          .clearPipelineWatermarks(targetPath, isCancelled: checkAbort);

      if (!checkAbort()) {
        await ref
            .read(dspWorkerProvider)
            .clearIsarDspData(targetPath, isCancelled: checkAbort);
      }
    } catch (e) {
      debugPrint("🔴 [FACTORY RESET ERROR]: $e");
    } finally {
      final state = ref.read(pipelineProvider);
      if (context.mounted && state.total > 0) {
        _showSummaryDialog(
          context,
          "Reset de Fábrica (Audio + ISAR)",
          state.total,
          state.quarantinedTracks,
          isAborted: state.isAborted,
          current: state.current,
        );
      }
      pipe.reset();
    }
  }

  void _showQuickFolderMenu(
    BuildContext rootContext,
    WidgetRef ref,
    String currentPath,
  ) {
    Directory baseDir;
    if (currentPath.isNotEmpty) {
      baseDir = Directory(currentPath).parent;
    } else {
      if (Platform.isIOS) {
        baseDir = Directory(IphoneLibrary.musicRoot);
      } else if (Platform.isWindows) {
        baseDir = Directory('${Platform.environment['USERPROFILE']}\\Music');
      } else if (Platform.isMacOS || Platform.isLinux) {
        baseDir = Directory('${Platform.environment['HOME']}/Music');
      } else {
        baseDir = Directory('/storage/emulated/0/Music');
      }
    }

    List<FileSystemEntity> subFolders = [];
    try {
      if (baseDir.existsSync()) {
        subFolders = baseDir.listSync().whereType<Directory>().toList();
        subFolders.sort((a, b) => a.path.compareTo(b.path));
      }
    } catch (e) {
      debugPrint("⚠️ [I/O ERROR]: Permiso denegado al leer $baseDir");
    }

    showDialog(
      context: rootContext,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFFF007F)),
          ),
          title: const Text(
            "Selección Rápida (Auto-Pipeline)",
            style: TextStyle(
              color: Color(0xFFFF007F),
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SizedBox(
            width: 500,
            height: 400,
            child: subFolders.isEmpty
                ? const Text(
                    "No se encontraron subcarpetas o faltan permisos de almacenamiento.",
                    style: TextStyle(color: Colors.white54),
                  )
                : ListView.builder(
                    itemCount: subFolders.length,
                    itemBuilder: (context, index) {
                      final folder = subFolders[index];
                      final folderName = folder.path
                          .split(Platform.pathSeparator)
                          .last;
                      return ListTile(
                        leading: const Icon(
                          Icons.folder_special,
                          color: Color(0xFF39FF14),
                        ),
                        title: Text(
                          folderName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          folder.path,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        hoverColor: Colors.white10,
                        onTap: () {
                          Navigator.pop(context);
                          _executeUniversalPipeline(
                            rootContext,
                            ref,
                            folder.path,
                          );
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Abortar",
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                ref.read(directoryProvider.notifier).loadDirectory();
              },
              child: const Text(
                "Usar Explorador de Sistema",
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirState = ref.watch(directoryProvider);
    final pipeState = ref.watch(pipelineProvider);
    final aiState = ref.watch(aiEngineProvider); // 🧠 Escucha a la IA

    // 🛠️ BLOQUEO TOTAL: Si el DSP o la IA están trabajando, bloquea interacciones en esta ruta
    final bool isBusy = !pipeState.isIdle || aiState.isRunning;

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobileLandscape = constraints.maxHeight < 500;
        final bool isMobileOS = Platform.isAndroid || Platform.isIOS;

        final Widget directoryPanel = Container(
          padding: EdgeInsets.all(isMobileLandscape ? 10 : 15),
          decoration: BoxDecoration(
            color: Colors.black45,
            border: Border.all(
              color: pipeState.isAborted
                  ? Colors.redAccent
                  : const Color(0xFFFF007F),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                Icons.folder_open,
                color: pipeState.isAborted
                    ? Colors.redAccent
                    : const Color(0xFFFF007F),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Directorio Objetivo:",
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      dirState.currentPath.isEmpty
                          ? "NINGUNA CARPETA SELECCIONADA"
                          : dirState.currentPath,
                      style: TextStyle(
                        color: dirState.currentPath.isEmpty
                            ? Colors.redAccent
                            : (pipeState.isAborted
                                  ? Colors.redAccent
                                  : const Color(0xFFFF007F)),
                        fontFamily: 'Consolas',
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ],
                ),
              ),
              if (!isBusy)
                ElevatedButton.icon(
                  onPressed: () =>
                      _showQuickFolderMenu(context, ref, dirState.currentPath),
                  icon: const Icon(Icons.flash_on),
                  label: const Text("Explorar"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A1A1A),
                    foregroundColor: const Color(0xFF39FF14),
                    side: const BorderSide(color: Color(0xFF39FF14)),
                  ),
                ),
              if (!pipeState.isIdle)
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              "[${pipeState.current}/${pipeState.total}] ${pipeState.moduleStatus}",
                              style: TextStyle(
                                color: pipeState.isAborted
                                    ? Colors.orangeAccent
                                    : const Color(0xFF39FF14),
                                fontFamily: 'Consolas',
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 5),
                            LinearProgressIndicator(
                              value: pipeState.total == 0
                                  ? 0
                                  : pipeState.current / pipeState.total,
                              backgroundColor: Colors.white10,
                              color: pipeState.isAborted
                                  ? Colors.orangeAccent
                                  : const Color(0xFF39FF14),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 15),
                      IconButton(
                        onPressed: pipeState.isAborted
                            ? null
                            : () => ref.read(pipelineProvider.notifier).abort(),
                        icon: const Icon(
                          Icons.cancel,
                          color: Colors.redAccent,
                          size: 35,
                        ),
                        tooltip: "Freno de Emergencia",
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );

        final List<Widget> cardNodes = [];

        if (!isMobileOS) {
          cardNodes.add(
            _buildActionCard(
              title: "MASTERIZACIÓN PROFESIONAL",
              description: "TODO EN UNO en PC/Mac: nombre, letra, corte real de silencios, BPM y −14 LUFS (una generación, sin EQ), una canción a la vez con enfriamiento. El _K va al final. Retoma si se corta.",
              icon: Icons.rocket_launch,
              color: const Color(0xFF39FF14),
              isPrimary: true,
              onTap: (dirState.currentPath.isEmpty || isBusy)
                  ? null
                  : () => _executeUniversalPipeline(
                      context,
                      ref,
                      dirState.currentPath,
                    ),
              footer: _masterCardFooter(
                context,
                ref,
                dirState.currentPath,
                isBusy,
              ),
            ),
          );
        } else {
          cardNodes.add(
            _buildActionCard(
              title: "PREPARACIÓN MÓVIL",
              description: "TODO EN UNO: nombre, letra, corte real, BPM y −14 LUFS, una canción a la vez, con enfriamiento. Sin _K (eso es de PC/Mac). Retoma si se corta.",
              icon: Icons.phone_android,
              color: Colors.cyanAccent,
              isPrimary: true,
              onTap: (dirState.currentPath.isEmpty || isBusy)
                  ? null
                  : () => _executeUniversalPipeline(
                      context,
                      ref,
                      dirState.currentPath,
                    ),
              footer: _masterCardFooter(
                context,
                ref,
                dirState.currentPath,
                isBusy,
              ),
            ),
          );
        }

        cardNodes.addAll([
          _buildActionCard(
            title: "LETRAS",
            description: "Descarga letras solo si coinciden artista, título y duración. Nunca pisa una letra que ya tengas.",
            icon: Icons.lyrics_outlined,
            color: const Color(0xFFFFC107),
            isPrimary: false,
            onTap: (dirState.currentPath.isEmpty || isBusy)
                ? null
                : () => _executeLyrics(context, ref, dirState.currentPath),
            footer: OutlinedButton.icon(
              onPressed: (dirState.currentPath.isEmpty || isBusy)
                  ? null
                  : () =>
                        _executeLyricsReset(context, ref, dirState.currentPath),
              icon: const Icon(Icons.delete_sweep_outlined, size: 16),
              label: const Text(
                'BORRAR LETRAS AUTOMÁTICAS',
                style: TextStyle(fontSize: 10),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFFC107),
                side: const BorderSide(color: Color(0xFFFFC107)),
              ),
            ),
          ),
          // 🛠️ TARJETA MUTANTE: Se transforma y muestra el porcentaje al activarse
          if (MasterProfile.current().allowKaraoke)
            _buildActionCard(
              title: aiState.isRunning
                  ? "IA TRABAJANDO..."
                  : "EXTRACCIÓN KARAOKE IA",
              description: aiState.isRunning ? aiState.status : "Procesa la carpeta aislando las voces (Crea pistas _K.mp3) en segundo plano (Requiere PC).",
              icon: aiState.isRunning ? Icons.memory : Icons.mic_external_off,
              color: aiState.isRunning
                  ? Colors.orangeAccent
                  : const Color(0xFFB026FF),
              isPrimary: false,
              onTap:
                  (aiState.isRunning || dirState.currentPath.isEmpty || isBusy)
                  ? null
                  : () => _executeKaraokeBatch(
                      context,
                      ref,
                      dirState.currentPath,
                    ),
              footer: aiState.isRunning
                  ? OutlinedButton.icon(
                      onPressed: aiState.stopping
                          ? null
                          : () => ref
                                .read(aiEngineProvider.notifier)
                                .requestStop(),
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: Text(
                        aiState.stopping
                            ? 'CIERRA ESTA PISTA…'
                            : 'CANCELAR COLA',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: aiState.stopping
                            ? Colors.white38
                            : Colors.redAccent,
                        side: BorderSide(
                          color: aiState.stopping
                              ? Colors.white24
                              : Colors.redAccent,
                        ),
                      ),
                    )
                  : null,
            ),
          _buildActionCard(
            title: "INFORME DE AUDITORÍA",
            description: "Identifica cuellos de botella: faltantes de letras, BPMs o errores de volumen.",
            icon: Icons.analytics_outlined,
            color: Colors.cyanAccent,
            isPrimary: false,
            onTap: (dirState.currentPath.isEmpty || isBusy)
                ? null
                : () => _executeAuditReport(context, ref, dirState.currentPath),
          ),
          _buildActionCard(
            title: "RESET DE FÁBRICA",
            description: "Quita el sello y las etiquetas de sonido y purga ISAR. NO toca letras, cues manuales ni el corte (para volver al audio original: Restaurar).",
            icon: Icons.dangerous,
            color: Colors.redAccent,
            isPrimary: false,
            onTap: (dirState.currentPath.isEmpty || isBusy)
                ? null
                : () =>
                      _executeFactoryReset(context, ref, dirState.currentPath),
          ),
        ]);

        if (isMobileLandscape) {
          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(15.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Laboratorio de Masterización Automática",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFF007F),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  "Centro de control universal. Analiza espectro, normaliza niveles, extrae letras e inyecta BPMs de forma desatendida.",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 20),
                directoryPanel,
                const SizedBox(height: 20),
                SizedBox(
                  height: 200,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: cardNodes.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 15),
                    itemBuilder: (_, i) =>
                        SizedBox(width: 240, child: cardNodes[i]),
                  ),
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(30.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Laboratorio de Masterización Automática",
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFFF007F),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                "Centro de control universal. Analiza espectro, normaliza niveles, extrae letras e inyecta BPMs de forma desatendida.",
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 30),
              directoryPanel,
              const SizedBox(height: 30),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int i = 0; i < cardNodes.length; i++) ...[
                      if (i > 0) const SizedBox(width: 15),
                      Expanded(flex: 2, child: cardNodes[i]),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionCard({
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    required bool isPrimary,
    VoidCallback? onTap,
    Widget? footer,
  }) {
    final bool isDisabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      splashColor: color.withValues(alpha: 0.3),
      highlightColor: color.withValues(alpha: 0.1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDisabled
                ? [const Color(0xFF1A1A1A), const Color(0xFF121212)]
                : [
                    color.withValues(alpha: isPrimary ? 0.15 : 0.08),
                    const Color(0xFF121212),
                  ],
          ),
          border: Border.all(
            color: isDisabled ? Colors.white10 : color.withValues(alpha: 0.5),
            width: isPrimary ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: isDisabled
              ? []
              : [
                  BoxShadow(
                    color: color.withValues(alpha: isPrimary ? 0.25 : 0.1),
                    blurRadius: 20,
                    spreadRadius: 1,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDisabled
                      ? Colors.white10
                      : color.withValues(alpha: 0.1),
                  boxShadow: isDisabled
                      ? []
                      : [
                          BoxShadow(
                            color: color.withValues(alpha: 0.4),
                            blurRadius: 15,
                            spreadRadius: 2,
                          ),
                        ],
                ),
                child: Icon(
                  icon,
                  size: isPrimary ? 40 : 25,
                  color: isDisabled ? Colors.white24 : color,
                ),
              ),
              const SizedBox(height: 15),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isPrimary ? 14 : 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: isDisabled ? Colors.white38 : Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                description,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: isDisabled ? Colors.white24 : Colors.white70,
                ),
              ),
              if (footer != null) ...[const SizedBox(height: 12), footer],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportAuditToCSV(
    BuildContext context,
    String targetPath,
    List<SongAudit> rows,
  ) async {
    try {
      final file = File(
        '$targetPath${Platform.pathSeparator}Auditoria_DataHealth.csv',
      );
      final buffer = StringBuffer();
      buffer.writeln(
        'ARCHIVO;TIPO;NOMBRE;LETRA;CORTE;SHIFT;BPM;LUFS;CUES;K;BACKUP;MOTIVO',
      );
      for (final SongAudit row in rows) {
        buffer.writeln(row.csvLine());
      }
      await file.writeAsString(buffer.toString());

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "✅ Reporte exportado exitosamente a CSV: ${file.path}",
            ),
            backgroundColor: const Color(0xFF39FF14),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint("🔴 Error de I/O al exportar CSV: $e");
    }
  }

  Future<void> _sendToLab(
    BuildContext context,
    String targetPath,
    Set<String> badPaths,
  ) async {
    if (badPaths.isEmpty) return;

    final baseDir = Directory(targetPath).parent;
    final labDir = Directory(labFolder(baseDir.path));
    if (!labDir.existsSync()) labDir.createSync(recursive: true);

    final registryFile = File(
      '${labDir.path}${Platform.pathSeparator}quarantine_registry.json',
    );
    Map<String, dynamic> registry = {};
    if (registryFile.existsSync()) {
      try {
        registry = jsonDecode(registryFile.readAsStringSync());
      } catch (_) {}
    }

    int movedCount = 0;
    int blockedCount = 0;
    for (String path in badPaths) {
      final file = File(path);
      if (file.existsSync()) {
        final fileName = file.uri.pathSegments.last;

        try {
          if (!moveCompanionsToSync(path, labDir.path)) {
            blockedCount++;
            continue;
          }
          registry[fileName] = path;
          movedCount++;
        } catch (e) {
          debugPrint("🔴 Error moviendo archivo al LAB: $e");
        }
      }
    }

    registryFile.writeAsStringSync(jsonEncode(registry));

    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            blockedCount > 0
                ? "⚠️ $blockedCount ya estaban en el LAB (no se pisó nada). ✅ $movedCount archivos aislados en el LAB."
                : "✅ $movedCount archivos aislados en el LAB.",
          ),
          backgroundColor: Colors.orangeAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showAuditDialog(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
    List<SongAudit> rows,
  ) {
    final Set<String> allBadPaths = {
      for (final SongAudit row in rows)
        if (row.sendToLab) row.path,
    };
    final List<String> unsealed = [
      for (final SongAudit row in rows)
        if (!row.sealed) row.path,
    ];
    final List<String> noLyrics = [
      for (final SongAudit row in rows)
        if (row.lyrics == AuditCell.bad) row.path,
    ];
    final List<String> noBpm = [
      for (final SongAudit row in rows)
        if (row.bpm == AuditCell.bad) row.path,
    ];
    final List<String> noCues = [
      for (final SongAudit row in rows)
        if (row.cues == AuditCell.bad) row.path,
    ];
    final List<String> noTrim = [
      for (final SongAudit row in rows)
        if (row.trim == AuditCell.bad) row.path,
    ];
    final List<String> noLufs = [
      for (final SongAudit row in rows)
        if (row.lufs == AuditCell.bad) row.path,
    ];
    final List<String> badName = [
      for (final SongAudit row in rows)
        if (row.name == AuditCell.bad) row.path,
    ];
    final List<String> megamix = [
      for (final SongAudit row in rows)
        if (row.megamix) row.path,
    ];
    final bool pending = rows.any((SongAudit row) => row.needsWork);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Colors.cyanAccent),
          borderRadius: BorderRadius.circular(8),
        ),
        title: Row(
          children: [
            const Icon(Icons.analytics, color: Colors.cyanAccent),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                "Auditoría de Salud (Data Health)",
                style: TextStyle(
                  color: Colors.cyanAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.file_download, color: Color(0xFF39FF14)),
              tooltip: "Exportar a CSV",
              onPressed: () => _exportAuditToCSV(ctx, targetPath, rows),
            ),
          ],
        ),
        content: SizedBox(
          width: 760,
          height: 460,
          child: DefaultTabController(
            length: 9,
            child: Column(
              children: [
                Text(
                  "Pistas analizadas: ${rows.length}",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                const TabBar(
                  isScrollable: true,
                  indicatorColor: Colors.cyanAccent,
                  labelColor: Colors.cyanAccent,
                  unselectedLabelColor: Colors.white54,
                  labelStyle: TextStyle(fontSize: 11),
                  tabs: [
                    Tab(text: "Audio Crudo"),
                    Tab(text: "Sin Letras"),
                    Tab(text: "Falta BPM/Curva"),
                    Tab(text: "Sin Cues"),
                    Tab(text: "Sin corte"),
                    Tab(text: "Sin −14 LUFS"),
                    Tab(text: "Nombre"),
                    Tab(text: "Megamix"),
                    Tab(text: "Por pista"),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildAuditList(
                        unsealed,
                        "Archivos sin procesar por DSP (Sin sello ID3v2)",
                      ),
                      _buildAuditList(
                        noLyrics,
                        "Archivos sin .lrc válido asociado",
                      ),
                      _buildAuditList(
                        noBpm,
                        "Pistas sin BPM en el rango 60–200",
                      ),
                      _buildAuditList(
                        noCues,
                        "Falta Set In/Out en ISAR (Se configuran en Live DJ)",
                      ),
                      _buildAuditList(
                        noTrim,
                        "Todavía no se cortaron los silencios",
                      ),
                      _buildAuditList(noLufs, "Todavía no están en −14 LUFS"),
                      _buildAuditList(
                        badName,
                        "El nombre todavía no quedó Artista - Título",
                      ),
                      _buildAuditList(
                        megamix,
                        "Megamix: corte, −14 LUFS y BPM de la entrada. Sin letra y sin _K.",
                      ),
                      _buildAuditTable(rows),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          ElevatedButton.icon(
            onPressed: pending
                ? () {
                    Navigator.pop(ctx);
                    _executeUniversalPipeline(context, ref, targetPath);
                  }
                : null,
            icon: const Icon(Icons.playlist_add_check),
            label: const Text("Completar lo que falta"),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF39FF14),
              foregroundColor: Colors.black,
            ),
          ),
          if (allBadPaths.isNotEmpty)
            ElevatedButton.icon(
              onPressed: () => _sendToLab(ctx, targetPath, allBadPaths),
              icon: const Icon(Icons.science),
              label: Text("Extraer al LAB (${allBadPaths.length})"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orangeAccent,
                foregroundColor: Colors.black,
              ),
            ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent,
              foregroundColor: Colors.black,
            ),
            child: const Text(
              "Cerrar",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuditList(List<String> items, String description) {
    if (items.isEmpty) {
      return const Center(
        child: Text(
          "✅ Todo en orden. 0 anomalías detectadas.",
          style: TextStyle(color: Color(0xFF39FF14)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  description,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF39FF14).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFF39FF14).withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  "${items.length} archivos",
                  style: const TextStyle(
                    color: Color(0xFF39FF14),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black45,
              border: Border.all(color: Colors.white10),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final displayPath = items[index]
                    .split(Platform.pathSeparator)
                    .last;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    "• $displayPath",
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontFamily: 'Consolas',
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _executeAuditReport(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final pipe = ref.read(pipelineProvider.notifier);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;
    final bool allowKaraoke = MasterProfile.current().allowKaraoke;

    try {
      final dir = Directory(targetPath);
      if (!dir.existsSync()) return;

      final files = dir.listSync(recursive: true).whereType<File>().where((f) {
        final String lower = f.path.toLowerCase().replaceAll('\\', '/');
        if (!lower.endsWith('.mp3')) return false;
        if (lower.endsWith('_k.mp3')) return false;
        if (lower.contains('/.gatomix_original/')) return false;
        return true;
      }).toList();

      final int total = files.length;
      if (total == 0) return;

      final List<SongAudit> rows = [];
      for (int i = 0; i < total; i++) {
        if (checkAbort()) break;
        final file = files[i];
        final filename = file.uri.pathSegments.last;
        pipe.updateProgress(i + 1, total, filename, "Auditoría en progreso...");

        final marks = await rust_dsp.readGmxMarks(inputPath: file.path);
        final lrcPath = file.path.replaceAll(
          RegExp(r'\.mp3$', caseSensitive: false),
          '.lrc',
        );
        final lrcFile = File(lrcPath);
        String lrcText = '';
        if (lrcFile.existsSync()) {
          try {
            lrcText = await lrcFile.readAsString();
          } catch (_) {}
        }
        final bool garbageLrc =
            lrcText.contains('Letra no encontrada') ||
            lrcText.contains('Error de conexión');
        final bool lrcExists = lrcFile.existsSync() && !garbageLrc;
        final bool manual =
            lrcIsManual(lrcText) || (lrcExists && !_lrcListedAsAuto(lrcFile));
        final meta = await ref
            .read(dbServiceProvider)
            .getTrackMetadata(file.path);
        final String kPath = file.path.replaceAll(
          RegExp(r'\.mp3$', caseSensitive: false),
          '_K.mp3',
        );
        rows.add(
          auditSong(
            file.path,
            filename,
            GmxSnapshot(
              type: marks.trackType,
              nameOk: marks.nameOk,
              lyr: marks.lyr,
              trimMarked: marks.trimMs >= 0,
              lrcShiftTag: marks.lrcShift,
              bpmOk: marks.bpmOk,
              lufsDone: marks.lufsDone,
              backup: marks.backup,
              sealed: marks.sealed,
              lrcExists: lrcExists,
              lrcManual: manual,
              lrcShiftFile: lrcShiftMs(lrcText) != null,
              hasManualCue: meta?.isManualCue ?? false,
              reason: marks.reason,
              karaokeFile: File(kPath).existsSync() || marks.karaoke,
              allowKaraoke: allowKaraoke,
              megamixBySize: false,
            ),
          ),
        );
      }

      if (!checkAbort() && context.mounted) {
        _showAuditDialog(context, ref, targetPath, rows);
      }
    } catch (e) {
      debugPrint("🔴 [AUDIT ERROR]: $e");
    } finally {
      pipe.reset();
    }
  }

  Widget _masterCardFooter(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
    bool isBusy,
  ) {
    final bool blocked = targetPath.isEmpty || isBusy;
    return Column(
      children: [
        OutlinedButton.icon(
          onPressed: blocked
              ? null
              : () => _executeUniversalPipeline(context, ref, targetPath),
          icon: const Icon(Icons.playlist_add_check, size: 16),
          label: const Text('TODO EN UNO', style: TextStyle(fontSize: 10)),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF39FF14),
            side: const BorderSide(color: Color(0xFF39FF14)),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: blocked
              ? null
              : () => _executeDurationSweep(context, ref, targetPath),
          icon: const Icon(Icons.timer_outlined, size: 16),
          label: const Text(
            'REVISAR DURACIONES',
            style: TextStyle(fontSize: 10),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.orangeAccent,
            side: const BorderSide(color: Colors.orangeAccent),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: blocked
              ? null
              : () => _executeBpmSweep(context, ref, targetPath),
          icon: const Icon(Icons.speed_outlined, size: 16),
          label: const Text(
            'REVISAR BPM',
            style: TextStyle(fontSize: 10),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.orangeAccent,
            side: const BorderSide(color: Colors.orangeAccent),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: blocked
              ? null
              : () => _executeRestore(context, ref, targetPath),
          icon: const Icon(Icons.restore, size: 16),
          label: const Text(
            'RESTAURAR ORIGINAL',
            style: TextStyle(fontSize: 10),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.orangeAccent,
            side: const BorderSide(color: Colors.orangeAccent),
          ),
        ),
      ],
    );
  }

  Future<void> _executeDurationSweep(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final pipe = ref.read(pipelineProvider.notifier);
    final Directory root = Directory(targetPath);
    if (!root.existsSync()) return;
    final List<File> files = root.listSync(recursive: true).whereType<File>().where((
      File f,
    ) {
      final String lower = f.path.toLowerCase().replaceAll('\\', '/');
      if (!lower.endsWith('.mp3')) return false;
      if (lower.contains('/.gatomix_original/')) return false;
      return true;
    }).toList();
    if (files.isEmpty) return;
    final List<String> marked = <String>[];
    try {
      for (int i = 0; i < files.length; i++) {
        if (ref.read(pipelineProvider).isAborted) break;
        final File file = files[i];
        final String name = file.uri.pathSegments.last;
        pipe.updateProgress(
          i + 1,
          files.length,
          name,
          'Revisando duración (solo etiqueta)...',
        );
        try {
          final TlenReport report = await MasterTrack.rewriteDurationTag(
            file.path,
          );
          final String? line = stuckAudioLine(
            name: name,
            tlenMs: report.tlenMs,
            audioMs: report.audioMs,
            mismatch: report.mismatch,
          );
          if (line != null) marked.add(line);
        } catch (e) {
          debugPrint('🔴 [TLEN] $name $e');
        }
      }
    } finally {
      pipe.reset();
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: Text(
          'Duraciones (${marked.length})',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: SizedBox(
          width: 520,
          height: marked.isEmpty ? 80 : 360,
          child: marked.isEmpty
              ? const Text(
                  'Ninguna pista con TLEN y audio separados más de 10 s. '
                  'El audio no se recortó.',
                  style: TextStyle(color: Colors.white70),
                )
              : ListView(
                  children: [
                    const Text(
                      'posible audio pegado / versión distinta',
                      style: TextStyle(
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final String line in marked)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          line,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CERRAR'),
          ),
        ],
      ),
    );
  }

  Future<void> _executeBpmSweep(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final pipe = ref.read(pipelineProvider.notifier);
    final Directory root = Directory(targetPath);
    if (!root.existsSync()) return;
    final List<File> files = root.listSync(recursive: true).whereType<File>().where((
      File f,
    ) {
      final String lower = f.path.toLowerCase().replaceAll('\\', '/');
      if (!lower.endsWith('.mp3')) return false;
      if (lower.contains('/.gatomix_original/')) return false;
      return true;
    }).toList();
    if (files.isEmpty) return;
    final List<String> lines = <String>[];
    var skipped = 0;
    try {
      for (int i = 0; i < files.length; i++) {
        if (ref.read(pipelineProvider).isAborted) break;
        final File file = files[i];
        final String name = file.uri.pathSegments.last;
        final Map<String, String> tags = readGmxTagsFromFile(file.path);
        if (tags['GMX_ANALYSIS'] == kGmxAnalysis) {
          skipped++;
          pipe.updateProgress(i + 1, files.length, name, 'BPM ya medido');
          continue;
        }
        pipe.updateProgress(i + 1, files.length, name, 'Re-midiendo BPM (solo etiqueta)...');
        try {
          final double oldBpm = readTbpmSync(file.path);
          final double neu = await rust_dsp.autoDetectAndInjectBpm(inputPath: file.path);
          final String line = 'BPM_FIX $name $oldBpm->$neu';
          debugPrint(line);
          lines.add(line);
          TrackTags.forget(file.path);
          if (neu > 0) {
            TrackTags.rememberBpm(file.path, neu);
            saveTrackMusic(file.path, bpm: neu);
          }
          forgetKnownBpm(file.path);
          forgetLiveDjBpm(file.path);
          forgetStoredGrid(file.path);
        } catch (e) {
          debugPrint('🔴 [BPM] $name $e');
        }
      }
    } finally {
      pipe.reset();
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: Text(
          'BPM (${lines.length})',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: SizedBox(
          width: 520,
          height: lines.isEmpty ? 80 : 360,
          child: lines.isEmpty
              ? Text(
                  'Nada que re-medir. $skipped ya tenían el análisis $kGmxAnalysis. El audio no se tocó.',
                  style: const TextStyle(color: Colors.white70),
                )
              : ListView(
                  children: [
                    for (final String line in lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          line,
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CERRAR')),
        ],
      ),
    );
  }

  Future<void> _executeRestore(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final List<File> backups = [];
    final Directory root = Directory(targetPath);
    if (root.existsSync()) {
      for (final File f in root.listSync(recursive: true).whereType<File>()) {
        final String lower = f.path.toLowerCase().replaceAll('\\', '/');
        if (lower.contains('/.gatomix_original/') && lower.endsWith('.mp3')) {
          backups.add(f);
        }
      }
    }
    if (!context.mounted) return;
    if (backups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay originales en .gatomix_original.'),
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text(
          'Restaurar original',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: SizedBox(
          width: 520,
          height: 360,
          child: ListView(
            children: [
              for (final File backup in backups)
                ListTile(
                  title: Text(
                    backup.uri.pathSegments.last,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      final String live =
                          '${backup.parent.parent.path}${Platform.pathSeparator}${backup.uri.pathSegments.last}';
                      try {
                        await MasterTrack.restore(ref, live);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Restaurado: ${backup.uri.pathSegments.last}',
                              ),
                            ),
                          );
                        }
                      } catch (e) {
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('No se pudo restaurar: $e')),
                          );
                        }
                      }
                    },
                    child: const Text('RESTAURAR'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CERRAR'),
          ),
        ],
      ),
    );
  }

  Widget _buildAuditTable(List<SongAudit> rows) {
    const TextStyle header = TextStyle(
      color: Colors.cyanAccent,
      fontSize: 10,
      fontWeight: FontWeight.bold,
    );
    const TextStyle cell = TextStyle(color: Colors.white70, fontSize: 11);
    Widget h(String t) => Padding(
      padding: const EdgeInsets.all(4),
      child: Text(t, style: header),
    );
    Widget c(String t) => Padding(
      padding: const EdgeInsets.all(4),
      child: Text(t, style: cell),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          children: [
            TableRow(
              children: [
                h('Pista'),
                h('Tipo'),
                h('Nombre'),
                h('Letra'),
                h('Corte'),
                h('Letra rearmada'),
                h('BPM'),
                h('LUFS'),
                h('Cues'),
                h('_K'),
                h('Respaldo'),
                h('Motivo'),
              ],
            ),
            for (final SongAudit row in rows)
              TableRow(
                children: [
                  c(row.fileName),
                  c(row.megamix ? 'MEGAMIX' : 'CANCIÓN'),
                  c(auditGlyph(row.name)),
                  c(auditGlyph(row.lyrics)),
                  c(auditGlyph(row.trim)),
                  c(auditGlyph(row.shift)),
                  c(auditGlyph(row.bpm)),
                  c(auditGlyph(row.lufs)),
                  c(auditGlyph(row.cues)),
                  c(auditGlyph(row.karaoke)),
                  c(auditGlyph(row.backup)),
                  c(row.reason),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

bool _batchHasPending(
  List<File> files,
  int cursor,
  int total,
  Map<String, dynamic> checkpoint,
) {
  final List<dynamic> processed = checkpoint['processed'] as List<dynamic>;
  final List<dynamic> failed = checkpoint['failed'] as List<dynamic>;
  for (int j = cursor; j < total; j++) {
    final String name = files[j].uri.pathSegments.last;
    if (!processed.contains(name) && !failed.contains(name)) return true;
  }
  return false;
}

/// Fin de Masterizar: letras corregidas y las que quedan para el LAB.
void _showLyricReviewDialog(
  BuildContext context,
  List<String> review,
  int fixed,
) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Revisar en Laboratorio (${review.length})'),
      content: SizedBox(
        width: 520,
        height: review.isEmpty ? 60 : 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '⏱️ Letras corregidas solas: $fixed · Para revisar: ${review.length}',
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [for (final String r in review) SelectableText(r)],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

String _masterStageLabel(String stage) {
  switch (stage) {
    case 'METADATA_CLEANUP':
      return '📝 Limpiando nombres...';
    case 'LYRICS':
      return '📝 Letras...';
    case 'DSP_ANALYSIS':
      return '✂️ Corte, BPM y −14 LUFS...';
    case 'WATERMARK_ID3':
      return '🔒 Guardando cambios...';
    case 'DB_ISAR':
      return '🎧 Calculando la mezcla...';
    case 'LYRIC_CHECK':
      return '⏱️ Revisando tiempo de la letra...';
    case 'TLEN':
      return '⏱️ Duración real en la etiqueta...';
    default:
      return stage;
  }
}

bool _lrcListedAsAuto(File lrc) {
  try {
    return readLyricsAuto(lrc.parent.path)
        .containsKey(lrc.uri.pathSegments.last);
  } catch (_) {
    return false;
  }
}

class KaraokeAIEngine {
  static void spawnBackgroundExtraction(String path, {WidgetRef? ref}) {
    final isFile = File(path).existsSync();
    final isDir = Directory(path).existsSync();

    if (!isFile && !isDir) return;
    if (isFile && !path.toLowerCase().endsWith('.mp3')) return;

    if (ref != null && ref.read(aiEngineProvider).isRunning) {
      debugPrint("⚠️ [AI ENGINE] Veto: Ya hay un proceso neuronal corriendo.");
      return;
    }

    ref?.read(aiEngineProvider.notifier).start(path);
    debugPrint("🤖 [AI ENGINE] Karaoke IA (Rust/ONNX) en: $path");

    KaraokeEngine.run(
      path,
      onStatus: (s) {
        ref?.read(aiEngineProvider.notifier).updateStatus(s);
      },
    ).whenComplete(() {
      debugPrint("✅ [AI ENGINE] Extracción IA terminada");
      ref?.read(aiEngineProvider.notifier).stop();
    });
  }
}
