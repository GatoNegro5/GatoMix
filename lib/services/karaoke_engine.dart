import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;

import '../providers/pipeline_provider.dart' show HeavyWorkGate;

/// Karaoke IA 100 % en proceso (Rust + ONNX, modelo MDX-Net/UVR).
/// Sin Python, sin Demucs, sin FFmpeg. Genera `<nombre>_K.mp3` junto a la
/// pista original. El modelo (~64 MB) se descarga la primera vez.
class KaraokeEngine {
  static const String modelFile = 'UVR-MDX-NET-Inst_HQ_3.onnx';
  static const String modelUrl =
      'https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/$modelFile';
  static const int _modelMinBytes = 60 * 1024 * 1024;
  static const String suffix = '_K';

  /// La cola se detiene al terminar la pista en curso.
  static bool stopQueue = false;
  static bool _busy = false;
  static bool get busy => _busy;

  static String karaokePathFor(String src) {
    final dot = src.lastIndexOf('.');
    return '${src.substring(0, dot)}$suffix.mp3';
  }

  /// Un _K existente solo vale si no está truncado.
  static bool usableInstrumental(String karaoke, String source) {
    final f = File(karaoke);
    if (!f.existsSync()) return false;
    final len = f.lengthSync();
    if (len < 256 * 1024) return false;
    final s = File(source);
    if (s.existsSync()) {
      final srcLen = s.lengthSync();
      if (srcLen > 0 && len < srcLen * 0.45) return false;
    }
    return true;
  }

  /// 3.1.08-3.1.15: tope de RAM del karaoke en Rust: 30:00. Desde 3.1.16
  /// `karaoke_separate` va por ventanas sin tope; queda para los _K viejos.
  static const int capMs = 1800000;

  /// 1800 s a 320 kbps CBR (salida fija de `Mp3Sink`) = 72.000.000 B.
  /// Un _K mas chico no pudo cortarse en el tope: no se mide su duracion.
  static const int capBytes = 1800 * 320000 ~/ 8;

  /// Tolerancia por el delay/padding de LAME entre fuente y _K.
  static const int padToleranceMs = 1000;

  static bool needsDurationCheck(int karaokeBytes) => karaokeBytes >= capBytes;

  /// Decision pura. `kMs` null = sin _K que revisar. `srcMs` null = no se pudo
  /// medir (se encola y la guardia de Rust decide).
  static KaraokeWork karaokeNeedsWork({int? srcMs, int? kMs}) {
    if (srcMs != null && kMs != null && kMs + padToleranceMs >= srcMs) {
      return KaraokeWork.done;
    }
    return KaraokeWork.queue;
  }

  /// 3.1.16: espera maxima de una separacion: 3 veces la duracion (factor sin
  /// medir, se ajusta con un log real), minimo 10 min; sin duracion, 60 min.
  static Duration karaokeTimeout(int? srcMs) {
    if (srcMs == null || srcMs <= 0) return const Duration(minutes: 60);
    final int ms = srcMs * 3;
    return Duration(milliseconds: ms < 600000 ? 600000 : ms);
  }

  static Future<(KaraokeWork, int?)> _decide(String src) async {
    int? srcMs;
    int? kMs;
    try {
      srcMs = (await rust_dsp.exactDurationMs(inputPath: src)).toInt();
      final String k = karaokePathFor(src);
      if (usableInstrumental(k, src) &&
          needsDurationCheck(File(k).lengthSync())) {
        kMs = (await rust_dsp.exactDurationMs(inputPath: k)).toInt();
      }
    } catch (e) {
      debugPrint('[KARAOKE] duracion no medida: $e');
    }
    return (karaokeNeedsWork(srcMs: srcMs, kMs: kMs), srcMs);
  }

  static Future<String> ensureModel({void Function(double)? onProgress}) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}models');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = '${dir.path}${Platform.pathSeparator}$modelFile';
    final f = File(path);
    if (f.existsSync() && f.lengthSync() >= _modelMinBytes) return path;

    final tmp = File('$path.part');
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(modelUrl)));
      if (resp.statusCode != 200) {
        throw Exception('Descarga del modelo falló (HTTP ${resp.statusCode})');
      }
      final total = resp.contentLength ?? 0;
      var got = 0;
      final sink = tmp.openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress?.call(got / total);
      }
      await sink.close();
      if (tmp.lengthSync() < _modelMinBytes) {
        throw Exception('Modelo incompleto');
      }
      if (f.existsSync()) f.deleteSync();
      await tmp.rename(path);
      return path;
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  static List<String> _collect(String path) {
    if (File(path).existsSync()) return [path];
    final out = <String>[];
    for (final e in Directory(
      path,
    ).listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final p = e.path;
      final low = p.toLowerCase();
      if (!low.endsWith('.mp3') ||
          low.endsWith('${suffix.toLowerCase()}.mp3')) {
        continue;
      }
      final String k = karaokePathFor(p);
      // 3.1.08: un _K que llega al tope de 30:00 se revisa por duracion en run().
      if (usableInstrumental(k, p) && !needsDurationCheck(File(k).lengthSync())) {
        continue;
      }
      out.add(p);
    }
    out.sort();
    return out;
  }

  static String _name(String p) => p
      .split(Platform.pathSeparator)
      .last
      .replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '');

  /// Procesa un archivo o una carpeta, de a una pista. `onStatus` recibe texto
  /// de avance para la UI. Devuelve cuántas pistas quedaron listas.
  static Future<int> run(String path, {void Function(String)? onStatus}) async {
    if (_busy) return 0;
    _busy = true;
    stopQueue = false;
    var done = 0;
    try {
      onStatus?.call('Preparando modelo de IA…');
      final model = await ensureModel(
        onProgress: (p) => onStatus?.call(
          'Descargando modelo de IA (solo la 1.ª vez): ${(p * 100).round()}%',
        ),
      );

      final files = _collect(path);
      if (files.isEmpty) onStatus?.call('No hay pistas pendientes.');
      for (var i = 0; i < files.length; i++) {
        if (stopQueue) {
          onStatus?.call('Cola cancelada. Última pista cerrada.');
          break;
        }
        final src = files[i];
        final name = _name(src);
        final label = files.length > 1
            ? '(${i + 1}/${files.length}) $name'
            : name;
        final (KaraokeWork work, int? srcMs) = await _decide(src);
        if (work == KaraokeWork.done) continue;
        onStatus?.call('Analizando: $label');
        final timer = Timer.periodic(const Duration(seconds: 1), (_) async {
          try {
            final p = await rust_dsp.karaokeProgress();
            onStatus?.call('Aislando Voces: ${(p * 100).round()}% - $label');
          } catch (_) {}
        });
        try {
          // 3.1.19: candado termico global; si cancelan mientras espera turno,
          // no arranca la separacion.
          final bool ran = await HeavyWorkGate.run('karaoke', () async {
            if (stopQueue) return false;
            final Future<bool> sep = rust_dsp.karaokeSeparate(
              inputPath: src,
              modelPath: model,
              outputPath: karaokePathFor(src),
            );
            try {
              await sep.timeout(karaokeTimeout(srcMs));
            } on TimeoutException {
              // 3.1.16: el timeout de Dart no frena a Rust: se cancela y se espera
              // a que cierre el bloque en curso (borra su .part) antes de seguir.
              await rust_dsp.karaokeCancel();
              await sep.then((_) => true, onError: (_) => false);
              rethrow;
            }
            return true;
          });
          if (!ran) break;
          done++;
          onStatus?.call('¡Instrumental Listo!: $label');
        } catch (e) {
          debugPrint('🔴 [KARAOKE] $name: $e');
          onStatus?.call('Falló: $label');
        } finally {
          timer.cancel();
        }
      }
    } catch (e) {
      debugPrint('🔴 [KARAOKE FATAL] $e');
      onStatus?.call('Error: $e');
    } finally {
      _busy = false;
    }
    return done;
  }
}

/// 3.1.08: decision por pista antes de separar.
/// queue = separar, done = _K completo. 3.1.16: sin tooLong (streaming).
enum KaraokeWork { queue, done }
