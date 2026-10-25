import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;

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
      if (usableInstrumental(karaokePathFor(p), p)) continue;
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
        onStatus?.call('Analizando: $label');
        final timer = Timer.periodic(const Duration(seconds: 1), (_) async {
          try {
            final p = await rust_dsp.karaokeProgress();
            onStatus?.call('Aislando Voces: ${(p * 100).round()}% - $label');
          } catch (_) {}
        });
        try {
          await rust_dsp.karaokeSeparate(
            inputPath: src,
            modelPath: model,
            outputPath: karaokePathFor(src),
          );
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
