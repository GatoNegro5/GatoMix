import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../core/brand_paths.dart';
import '../core/lab_quarantine.dart';
import 'core_metadata.dart';
import 'core_dsp.dart';
import 'core_nlp.dart';
import 'core_bpm.dart';

class PipelineState {
  final int total;
  final int current;
  final String fileName;
  final String moduleStatus;
  final bool isIdle;

  PipelineState({
    required this.total,
    required this.current,
    required this.fileName,
    required this.moduleStatus,
    required this.isIdle,
  });
}

class PipelineController {
  final BpmEngine _bpm = BpmEngine();
  final MetadataEngine _m1 = MetadataEngine();
  final DspEngine _dsp = DspEngine();
  final NlpEngine _nlp = NlpEngine();

  final StreamController<PipelineState> _streamController =
      StreamController<PipelineState>.broadcast();
  Stream<PipelineState> get stream => _streamController.stream;

  bool _isProcessing = false;
  bool _abortRequested = false; // <-- Bandera de interrupción en memoria

  /// Gatillo para detener la cola de forma segura
  void abortPipeline() {
    if (_isProcessing) {
      _abortRequested = true;
      debugPrint(
        "🛑 [PIPELINE] Señal de aborto recibida. Esperando cierre atómico...",
      );
    }
  }

  // 🛠️ NUEVA ARQUITECTURA: Aislamiento Físico Atómico
  Future<void> _isolatePoisonPill(
    String filePath,
    int total,
    int current,
    String fileName,
  ) async {
    try {
      // 1. Sin binarios externos (FFmpeg eliminado): nada que matar.

      // 2. Pausa crítica para que el Kernel libere el Handle del archivo
      await Future.delayed(const Duration(milliseconds: 1500));

      final file = File(filePath);
      if (!file.existsSync()) return;

      // 3. Auto-crear directorio de cuarentena (Setup Proactivo)
      final quarantine = quarantineDir(file.parent.path);

      final newPath = '${quarantine.path}${Platform.pathSeparator}$fileName';

      // 4. Mover la pista y sus compañeros. No pisa un destino que ya existe.
      for (final String p in companionsOf(filePath)) {
        final String dest =
            '${quarantine.path}${Platform.pathSeparator}${File(p).uri.pathSegments.last}';
        if (File(dest).existsSync()) {
          debugPrint("☣️ [CUARENTENA] No se pisa: $dest");
          continue;
        }
        moveOneNoOverwriteSync(p, dest);
      }

      // 5. Notificar a la UI
      _emit(
        total,
        current,
        fileName,
        "☣️ AISLADO: Movido a Cuarentena_GatoMix",
      );
      debugPrint("☣️ [CUARENTENA] Archivo extraído físicamente a: $newPath");
    } catch (e) {
      debugPrint("🔴 [CUARENTENA FALLO] No se pudo aislar el archivo: $e");
    }
  }

  Future<void> runBatch(List<String> filePaths) async {
    if (_isProcessing) return;
    _isProcessing = true;
    _abortRequested = false;

    final int total = filePaths.length;
    int current = 0;

    for (String path in filePaths) {
      if (_abortRequested) {
        debugPrint(
          "🛑 [PIPELINE] Cola abortada por el usuario en la pista $current.",
        );
        break;
      }

      current++;
      final fileName = path.split(RegExp(r'[\\/]')).last;

      _emit(total, current, fileName, "🔍 Validando...");

      try {
        bool isOptimized = await _dsp
            .checkWatermark(path)
            .timeout(const Duration(seconds: 30));

        if (!isOptimized) {
          if (_abortRequested) break;
          _emit(total, current, fileName, "⚙️ M1: Limpiando Metadatos");
          await _m1.processFile(path).timeout(const Duration(seconds: 30));

          if (_abortRequested) break;
          _emit(total, current, fileName, "🔊 M3: Ajustando Volumen (LUFS)");
          await _dsp.normalizeLUFS(path).timeout(const Duration(seconds: 90));

          if (_abortRequested) break;
          _emit(total, current, fileName, "✂️ M2: Cortando Silencios");
          await _dsp.autoTrim(path).timeout(const Duration(seconds: 90));

          if (_abortRequested) break;
          _emit(total, current, fileName, "🔐 M3: Sellando Archivo");
          await _dsp.injectWatermark(path).timeout(const Duration(seconds: 30));
        } else {
          debugPrint("⏭️ [BYPASS DSP] $fileName ya está optimizado en audio.");
        }

        if (_abortRequested) break;
        _emit(
          total,
          current,
          fileName,
          "📝 M5: Obteniendo Letras Sincronizadas",
        );
        await _nlp.fetchLyrics(path).timeout(const Duration(seconds: 45));

        if (_abortRequested) break;
        _emit(total, current, fileName, "🥁 M4: Calculando BPM");
        await _bpm.processBpm(path).timeout(const Duration(seconds: 60));
      } on TimeoutException {
        // 🛠️ CIRCUIT BREAKER + CUARENTENA FÍSICA
        debugPrint("🔴 [CIRCUIT BREAKER] Poison Pill detectada en: $fileName");
        await _isolatePoisonPill(path, total, current, fileName);

        // Enfriamiento del procesador antes de seguir con el lote
        await Future.delayed(const Duration(seconds: 3));
        continue;
      } catch (e) {
        debugPrint("🔴 [PIPELINE FATAL] Error en $fileName: $e");
      }
    }

    _isProcessing = false;
    _abortRequested = false;

    _streamController.add(
      PipelineState(
        total: total,
        current: current,
        fileName: "-",
        moduleStatus: "Idle",
        isIdle: true,
      ),
    );
    debugPrint("🟢 [PIPELINE LIBERADO] Motor en reposo.");
  }

  void _emit(int total, int current, String fileName, String status) {
    _streamController.add(
      PipelineState(
        total: total,
        current: current,
        fileName: fileName,
        moduleStatus: status,
        isIdle: false,
      ),
    );
  }

  void dispose() {
    _streamController.close();
  }
}
