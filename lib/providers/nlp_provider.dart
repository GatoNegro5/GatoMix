import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pipeline_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;
import '../core/brand_paths.dart';
import '../core/lrc_timeline.dart';
import '../core/lyric_files.dart';
import '../core/lyric_match.dart';
import '../services/id3_title_artist.dart';
import 'db_provider.dart'; // 🛠️ Requerido para inyectar Cues a la BD

bool _enCarpetaOriginal(String path) {
  final String p = path.replaceAll('\\', '/').toLowerCase();
  return p.contains('/.gatomix_original/') || p.endsWith('/.gatomix_original');
}

final nlpWorkerProvider = Provider((ref) => NlpWorker(ref));

class NlpWorker {
  final Ref ref;

  final Map<String, String> _headers = {
    'User-Agent': 'GatoMixPlayer/1.0.0 (Custom Build)',
  };

  NlpWorker(this.ref);

  Future<http.Response> _resilientGet(String targetUrl) async {
    final directUri = Uri.parse(targetUrl);
    final int maxRetries = kLyricHttpTries;

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final res = await http
            .get(directUri, headers: _headers)
            .timeout(const Duration(seconds: 4));

        if (res.statusCode == 200) return res;

        // 🛠️ EXPONENTIAL BACKOFF: Si es Rate Limit (429) o Server Error (5xx), esperamos y reintentamos.
        // 429 / 503 / 5xx: reintento. No es "no hay letra".
        if (lyricHttpTransient(res.statusCode)) {
          if (attempt == maxRetries - 1) {
            return res;
          }

          final delay = lyricRetryDelayMs(attempt);
          debugPrint(
            "🟡 [NLP Rate Limit] HTTP ${res.statusCode}. Pausando hilo $delay ms (Intento ${attempt + 1})...",
          );
          await Future.delayed(Duration(milliseconds: delay));
          continue;
        }

        return res; // Para 404 (Not Found) u otros errores de cliente, devolvemos directo.
      } catch (e) {
        if (attempt == maxRetries - 1) {
          debugPrint(
            "🟡 [NLP] LRCLIB no respondió tras $maxRetries intentos: $e",
          );
          break;
        }
        await Future.delayed(
          Duration(milliseconds: lyricRetryDelayMs(attempt)),
        );
      }
    }

    throw Exception('LRCLIB no responde');
  }

  /// Último detalle para mostrarlo en pantalla (servidor caído, sin coincidencia).
  String lastDetail = '';

  // 🛠️ MÓDULO V4.1: CÁLCULO DE COLISIÓN VOCAL CON ESCUDO ANTI-BASURA
  // 🛠️ MÓDULO V4.2: CÁLCULO DE COLISIÓN VOCAL (BLINDADO CONTRA CUES MANUALES)
  Future<void> _processVocalBoundingBox(
    String audioPath,
    String syncedLyrics,
    int durationSec,
  ) async {
    try {
      final db = ref.read(dbServiceProvider);
      final existingMeta = await db.getTrackMetadata(audioPath);

      // 🛡️ REGLA MAESTRA: Si el usuario ya fijó puntos en el Laboratorio, el NLP retrocede.
      if (existingMeta != null && existingMeta.isManualCue) {
        debugPrint(
          "⏭️ [AUTO-MASTER] NLP Evadido. Cues manuales detectados para: $audioPath",
        );
        return;
      }

      final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
      int? firstMs;
      int? lastMs;

      final lines = syncedLyrics.split('\n');
      for (var line in lines) {
        final match = regex.firstMatch(line);
        if (match != null) {
          final text = match.group(4)!.trim().toLowerCase();

          bool isGarbage =
              text.isEmpty ||
              text.startsWith('by:') ||
              text.startsWith('artist:') ||
              text.startsWith('title:') ||
              text.contains('synced') ||
              text.contains('lyric') ||
              text.contains('www.') ||
              text.length < 3;

          if (!isGarbage) {
            final min = int.parse(match.group(1)!);
            final sec = int.parse(match.group(2)!);
            int ms = int.parse(match.group(3)!);
            if (match.group(3)!.length == 2) ms *= 10;
            final totalMs = (min * 60000) + (sec * 1000) + ms;

            firstMs ??= totalMs;
            lastMs = totalMs;
          }
        }
      }

      if (firstMs != null && lastMs != null) {
        int cueIn = firstMs - 5000;
        if (cueIn < 0) cueIn = 0;

        // 🛠️ FIX: Dinámica de Coda para Outpoints.
        // En lugar de recortar a 6s estáticos, medimos si la canción tiene "Outro" instrumental.
        int mixOut = lastMs + 1000; // Solo damos 1s de respiro post-letra
        int totalMs = durationSec * 1000;

        if (totalMs > 0) {
          final timeRemaining = totalMs - mixOut;
          // Si el instrumental de salida es larguísimo (> 15s), anclamos el mixOut más atrás para no aburrir
          if (timeRemaining > 15000) {
            mixOut = lastMs + 4000;
          } else if (timeRemaining < 3000) {
            // Si la letra llega hasta el mismísimo final, el mixOut debe retroceder para dar espacio al crossfade de la sig canción
            mixOut = totalMs - 4000;
          }
        }
        if (mixOut < 0) mixOut = 0;

        try {
          await db.saveTrackMetadata(
            path: audioPath,
            cueInMs: cueIn,
            mixOutMs: mixOut,
            isManualCue: false,
          );
          debugPrint(
            "🎛️ [AUTO-MASTER] Cues IN: ${cueIn}ms | OUT: ${mixOut}ms -> $audioPath",
          );
        } catch (e) {
          debugPrint("🔴 Error guardando metadata en BD: $e");
        }
      }
    } catch (e) {
      debugPrint("🔴 [AUTO-MASTER] Error calculando Bounding Box: $e");
    }
  }

  Future<void> processDirectory(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp3'))
        .where((f) => !_enCarpetaOriginal(f.path))
        .toList();

    int total = files.length;
    final pipe = ref.read(pipelineProvider.notifier);

    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) {
        debugPrint("🔴 [NLP Worker] Scraping abortado por el usuario.");
        break;
      }

      final file = files[i];
      if (_enCarpetaOriginal(file.path)) continue;
      final filename = file.uri.pathSegments.last;

      final lrcPath = file.path.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );
      final lrcFile = File(lrcPath);

      if (lrcFile.existsSync()) {
        final content = await lrcFile.readAsString();
        if (lrcIsProtected(content)) continue;
        if (!content.contains('Letra no encontrada') &&
            !content.contains('Error de conexión') &&
            !content.contains('Error Auto-Healing') &&
            lrcFile.lengthSync() > 20) {
          // 🛠️ DESTRUCCIÓN DEL BYPASS:
          // Si el CueIn está en cero (o no existe) y no es manual, FORZAMOS el recálculo
          // ignorando si el MixOut ya estaba lleno.
          final meta = await ref
              .read(dbServiceProvider)
              .getTrackMetadata(file.path);
          if (meta == null || (!meta.isManualCue && meta.cueInMs == 0)) {
            final localSec = await _getLocalDurationSec(file.path);
            await _processVocalBoundingBox(file.path, content, localSec);
          }
          continue;
        }
      }

      pipe.updateProgress(i + 1, total, filename, "Scraping LRC");

      await processSingleFile(file.path);

      await Future.delayed(const Duration(milliseconds: 150));
    }
    pipe.reset();
  }

  // Duración EXACTA con Rust (sin ffprobe), igual en las 4 plataformas.
  Future<int> _getLocalDurationSec(String filePath) async {
    try {
      final ms = await rust_dsp.exactDurationMs(inputPath: filePath);
      return (ms.toInt() / 1000).round();
    } catch (_) {}
    return 0;
  }

  Future<List<dynamic>> searchLyricCandidates(
    String query, {
    String? badLyric,
  }) async {
    List<dynamic> allResults = [];
    bool isServerError = false;
    String errorMessage = "No se encontraron resultados.";

    Future<void> fetchTarget(String url) async {
      try {
        final response = await _resilientGet(url);
        if (response.statusCode == 200) {
          final parsed = jsonDecode(response.body);
          if (parsed is List) allResults.addAll(parsed);
        } else if (response.statusCode >= 500) {
          isServerError = true;
          errorMessage =
              "Error ${response.statusCode}: El servidor de letras reporta una caída crítica (Bad Gateway).";
        }
      } catch (e) {
        isServerError = true;
        errorMessage = "El servidor no responde (Tiempo de espera agotado).";
      }
    }

    final globalUrl =
        'https://lrclib.net/api/search?q=${Uri.encodeComponent(query.trim())}';
    await fetchTarget(globalUrl);

    if (query.contains('-')) {
      final parts = query.split('-');
      if (parts.length >= 2) {
        final artist = parts[0].trim();
        final track = parts.sublist(1).join(' ').trim();
        final advancedUrl =
            'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(artist)}&track_name=${Uri.encodeComponent(track)}';
        await fetchTarget(advancedUrl);
      }
    }

    if (allResults.isEmpty && isServerError) throw Exception(errorMessage);

    final uniqueResults = <int, dynamic>{};
    for (var item in allResults) {
      if (item['id'] != null) uniqueResults[item['id']] = item;
    }
    final combinedData = uniqueResults.values.toList();

    return combinedData.where((item) {
      final synced = item['syncedLyrics'];
      if (synced == null || synced.toString().trim().isEmpty) return false;

      if (badLyric != null && badLyric.isNotEmpty) {
        String apiText = synced
            .toString()
            .replaceAll(RegExp(r'\[.*?\]'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        String badText = badLyric
            .replaceAll(RegExp(r'\[.*?\]'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

        String apiSnippet = apiText.length > 40
            ? apiText.substring(0, 40)
            : apiText;
        String badSnippet = badText.length > 40
            ? badText.substring(0, 40)
            : badText;

        if (apiSnippet.isNotEmpty &&
            badSnippet.isNotEmpty &&
            apiSnippet == badSnippet) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  Future<void> writeManualLyric(String audioPath, String syncedLyrics) async {
    final lrcPath = audioPath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    await File(lrcPath).writeAsString(syncedLyrics);
    await _unmarkAuto(lrcPath); // letra fijada a mano: ya no es automática

    // Inyectar el Bounding Box al forzar letra manual
    final localSec = await _getLocalDurationSec(audioPath);
    await _processVocalBoundingBox(audioPath, syncedLyrics, localSec);

    debugPrint(
      "🟢 [NLP Tracker] LRC manual sobreescrito con éxito y Cues calculados.",
    );
  }

  // ----------------------------------------------------- coincidencia segura
  // Una letra equivocada es peor que ninguna. ID3 primero; si no, el nombre
  // del archivo. LRCLIB /api/get con la duración medida y, si no hay, /api/search
  // filtrado por artista, título y ±2 s. La misma función la usa Automix.

  Future<({List<dynamic> items, bool serverDown})> _lrclibSearch(
    String url,
  ) async {
    try {
      final response = await _resilientGet(url);
      if (response.statusCode == 200) {
        final parsed = jsonDecode(response.body);
        if (parsed is List) return (items: parsed, serverDown: false);
        return (items: const [], serverDown: false);
      }
      if (lyricHttpTransient(response.statusCode)) {
        lastDetail = 'LRCLIB respondió HTTP ${response.statusCode}';
        return (items: const [], serverDown: true);
      }
    } catch (e) {
      lastDetail = 'LRCLIB no responde: $e';
      debugPrint("🟡 [NLP Tracker] Búsqueda evadió error: $e");
      return (items: const [], serverDown: true);
    }
    return (items: const [], serverDown: false);
  }

  /// La misma búsqueda que Automix. No escribe el archivo.
  /// Si el ID3 contradice al nombre, prueba los dos y se queda con la duración.
  Future<LyricChoice> lookupSafeLyric(String audioPath) async {
    final id3 = await loadId3TitleArtist(audioPath);
    final int localSec = await _getLocalDurationSec(audioPath);
    final List<LyricIdentity> ids = lyricIdentities(
      path: audioPath,
      id3Artist: id3.artist,
      id3Title: id3.title,
      id3Album: id3.album,
      durationSec: localSec,
    );
    if (ids.every((LyricIdentity e) => e.title.isEmpty) || localSec <= 0) {
      lastDetail = 'Sin coincidencia segura';
      return const LyricChoice.none();
    }

    final List<Map<String, dynamic>> pool = <Map<String, dynamic>>[];
    var serverDown = false;
    for (final LyricIdentity id in ids) {
      final Uri? qUri = lrclibTitleOnlyUri(id);
      if (qUri != null) {
        // Sin artista: solo búsqueda libre por título completo (q=).
        final found = await _lrclibSearch(qUri.toString());
        if (found.serverDown) serverDown = true;
        for (final dynamic raw in found.items) {
          if (raw is Map) pool.add(Map<String, dynamic>.from(raw));
        }
        continue;
      }
      try {
        final response = await _resilientGet(lrclibGetUri(id).toString());
        if (response.statusCode == 200) {
          final parsed = jsonDecode(response.body);
          if (parsed is Map) pool.add(Map<String, dynamic>.from(parsed));
        } else if (lyricHttpTransient(response.statusCode)) {
          serverDown = true;
          lastDetail = 'LRCLIB respondió HTTP ${response.statusCode}';
        }
      } catch (e) {
        serverDown = true;
        lastDetail = 'LRCLIB no responde: $e';
      }
      final found = await _lrclibSearch(lrclibSearchUri(id).toString());
      if (found.serverDown) serverDown = true;
      for (final dynamic raw in found.items) {
        if (raw is Map) pool.add(Map<String, dynamic>.from(raw));
      }
    }
    final LyricChoice choice = chooseLrclibLyric(
      ids.first,
      also: ids.length > 1 ? ids.sublist(1) : const <LyricIdentity>[],
      searched: pool,
    );
    if (choice.hasText) return choice;
    if (lyricFailureIsRetry(serverDown: serverDown, hasText: false)) {
      lastDetail = lastDetail.isEmpty ? 'Servidor de letras caído' : lastDetail;
      return const LyricChoice.down();
    }
    lastDetail = 'Sin coincidencia segura';
    return const LyricChoice.none();
  }

  /// Búsqueda manual del Laboratorio: /api/get, /api/search y /api/search?q=.
  /// Si las tres siguen en 503 o 429, [unavailable] queda en true.
  Future<({List<LyricCandidate> rows, bool unavailable})> searchManualLyrics({
    required String artist,
    required String title,
    required int durationSec,
    String query = '',
    bool medley = false,
    String audioPath = '',
  }) async {
    final Future<int?> onsetFuture = _probeVoiceOnsetMs(audioPath);
    final LyricIdentity id = LyricIdentity(
      artist: artist,
      title: title,
      durationSec: durationSec,
      medley: medley,
    );
    final List<Uri> uris = lrclibManualUris(
      artist: artist,
      title: title,
      durationSec: durationSec,
      query: query,
    );
    final List<({String? body, int status, bool down})> got = await Future.wait(
      uris.map((Uri uri) async {
        try {
          final response = await _resilientGet(uri.toString());
          return (
            body: response.body,
            status: response.statusCode,
            down: lyricHttpTransient(response.statusCode),
          );
        } catch (e) {
          lastDetail = 'LRCLIB no responde: $e';
          return (body: null, status: 0, down: true);
        }
      }),
    );
    final List<Map<String, dynamic>> pool = <Map<String, dynamic>>[];
    var hits = 0;
    var transient = 0;
    for (var i = 0; i < got.length; i++) {
      final ({String? body, int status, bool down}) one = got[i];
      final bool fromGet = i == 0;
      if (one.status == 200 && one.body != null) {
        hits++;
        final parsed = jsonDecode(one.body!);
        void addRow(Map<dynamic, dynamic> raw) {
          final Map<String, dynamic> row = Map<String, dynamic>.from(raw);
          if (fromGet) row[kLyricFromGetKey] = true;
          pool.add(row);
        }

        if (parsed is Map) {
          addRow(parsed);
        } else if (parsed is List) {
          for (final dynamic raw in parsed) {
            if (raw is Map) addRow(raw);
          }
        }
      } else if (one.down) {
        transient++;
        if (one.status != 0) {
          lastDetail = 'LRCLIB respondió HTTP ${one.status}';
        }
      }
    }
    final bool unavailable = hits == 0 && transient == uris.length;
    final int? onset = await onsetFuture;
    return (
      rows: rankLyricCandidates(id: id, rows: pool, voiceOnsetMs: onset),
      unavailable: unavailable,
    );
  }

  /// Energía y onset de la voz en los primeros 40 s. Null si no se puede medir.
  Future<int?> _probeVoiceOnsetMs(String audioPath) async {
    if (audioPath.isEmpty) return null;
    try {
      final Uint8List pcm = await rust_dsp.decodeMonoPcm(
        inputPath: audioPath,
        startSecs: 0,
        lengthSecs: 40,
        targetRate: 8000,
      );
      final int n = pcm.length ~/ 2;
      if (n < 8000) return null;
      final ByteData data = ByteData.sublistView(pcm);
      final List<double> samples = List<double>.filled(n, 0);
      for (var i = 0; i < n; i++) {
        samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
      }
      return lyricVoiceOnsetMs(samples, 8000);
    } catch (_) {
      return null;
    }
  }

  Future<void> rememberManualLyric(String lrcPath, {int? lrclibId}) async {
    try {
      final File f = File(lrcPath);
      final String folder = f.parent.path;
      final Map<String, dynamic> reg = _readAuto(folder);
      reg[f.uri.pathSegments.last] = <String, dynamic>{
        'bytes': f.existsSync() ? f.lengthSync() : 0,
        'id': lrclibId,
        'manual': true,
      };
      await _autoRegistry(folder).writeAsString(jsonEncode(reg));
    } catch (_) {}
  }

  /// Letra sincronizada, plana, sin coincidencia, o servidor caído (reintento).
  /// No pisa un `.lrc` que ya existe.
  Future<LyricStatus> _fetchAndSaveLrc(String audioPath, String lrcPath) async {
    if (!lyricMayDownload(lrcExists: File(lrcPath).existsSync())) {
      return LyricStatus.kept;
    }
    try {
      final LyricChoice choice = await lookupSafeLyric(audioPath);
      if (!lyricMayDownload(lrcExists: File(lrcPath).existsSync())) {
        return LyricStatus.kept;
      }
      if (choice.kind == LyricKind.synced) {
        await File(lrcPath).writeAsString(choice.fileText);
        await _markAuto(lrcPath);
        final int localSec = await _getLocalDurationSec(audioPath);
        await _processVocalBoundingBox(audioPath, choice.body, localSec);
        lastDetail = '';
        debugPrint("🟢 [NLP Tracker] Letra segura: $audioPath");
        return LyricStatus.ok;
      }
      if (choice.kind == LyricKind.plain) {
        await File(lrcPath).writeAsString(choice.fileText);
        await _markAuto(lrcPath);
        lastDetail = 'Letra plana (sin tiempos)';
        return LyricStatus.plain;
      }
      if (choice.serverDown) {
        debugPrint("🟡 [NLP Tracker] Servidor caído, se reintenta: $audioPath");
        return LyricStatus.retry;
      }
      debugPrint("🟡 [NLP Tracker] Sin coincidencia segura: $audioPath");
      return LyricStatus.noMatch;
    } catch (e) {
      lastDetail = '$e';
      debugPrint("🔴 [NLP Tracker] Excepción crítica de I/O: $e");
      final String msg = e.toString();
      if (msg.contains('LRCLIB') ||
          msg.contains('Socket') ||
          msg.contains('Timeout') ||
          msg.contains('ClientException')) {
        return LyricStatus.retry;
      }
      return LyricStatus.failed;
    }
  }

  // ------------------------------------------- registro de letras AUTOMÁTICAS
  // Solo las letras que descargó esta app se anotan aquí. Las que tú arreglaste
  // (o cualquier .lrc que no esté en la lista) nunca se tocan ni se borran.

  File _autoRegistry(String folder) =>
      File('$folder${Platform.pathSeparator}_lyrics_auto.json');

  Map<String, dynamic> _readAuto(String folder) {
    try {
      final f = _autoRegistry(folder);
      if (f.existsSync()) {
        final d = jsonDecode(f.readAsStringSync());
        if (d is Map<String, dynamic>) return d;
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> _markAuto(String lrcPath) async {
    try {
      final f = File(lrcPath);
      final folder = f.parent.path;
      final reg = _readAuto(folder);
      reg[f.uri.pathSegments.last] = f.lengthSync();
      await _autoRegistry(folder).writeAsString(jsonEncode(reg));
    } catch (_) {}
  }

  Future<void> forgetLyricMark(String lrcPath) => _unmarkAuto(lrcPath);

  Future<void> _unmarkAuto(String lrcPath) async {
    try {
      final f = File(lrcPath);
      final folder = f.parent.path;
      final reg = _readAuto(folder);
      if (reg.remove(f.uri.pathSegments.last) != null) {
        await _autoRegistry(folder).writeAsString(jsonEncode(reg));
      }
    } catch (_) {}
  }

  /// RESET DE LETRAS: borra solo los .lrc descargados por la app que siguen
  /// SIN cambios (mismo tamaño). Nunca borra una letra fija o editada.
  /// Devuelve cuántas borró.
  Future<int> resetAutoLyrics(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return 0;
    int removed = 0;
    final folders = <String>{directoryPath};
    try {
      for (final e in dir.listSync(recursive: true)) {
        if (e is Directory) folders.add(e.path);
      }
    } catch (_) {}
    for (final folder in folders) {
      if (isCancelled != null && isCancelled()) break;
      if (_enCarpetaOriginal(folder)) continue;
      final reg = _readAuto(folder);
      if (reg.isEmpty) continue;
      final keep = <String, dynamic>{};
      reg.forEach((name, size) {
        final f = File('$folder${Platform.pathSeparator}$name');
        try {
          if (_autoIsManual(size)) {
            keep[name] = size;
            return;
          }
          final int? bytes = _autoBytes(size);
          if (f.existsSync() && bytes != null && f.lengthSync() == bytes) {
            final String text = f.readAsStringSync();
            if (lrcIsProtected(text) || lrcIsNoRetry(text)) {
              keep[name] = size;
            } else {
              f.deleteSync();
              removed++;
            }
          } else if (f.existsSync()) {
            keep[name] = size; // editada: ya no es automática, se respeta
          }
        } catch (_) {
          keep[name] = size;
        }
      });
      try {
        if (keep.isEmpty) {
          _autoRegistry(folder).deleteSync();
        } else {
          _autoRegistry(folder).writeAsStringSync(jsonEncode(keep));
        }
      } catch (_) {}
    }
    return removed;
  }

  /// Resultado de intentar la letra de una pista.
  /// ok = letra nueva · kept = ya tenía una letra válida (no se toca) ·
  /// noMatch = sin coincidencia segura · failed = error / pista inexistente.
  Future<LyricStatus> processSingleFile(String filePath) async {
    if (_enCarpetaOriginal(filePath)) return LyricStatus.kept;
    final file = File(filePath);
    if (!file.existsSync()) return LyricStatus.failed;

    final lrcPath = filePath.replaceAll(
      RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
      '.lrc',
    );
    final lrcFile = File(lrcPath);

    if (lrcFile.existsSync()) {
      try {
        final content = await lrcFile.readAsString();
        if (lrcIsNoRetry(content) || lrcIsManual(content)) {
          return LyricStatus.kept;
        }
        final bool residual =
            content.contains('Letra no encontrada') ||
            content.contains('Error de conexión') ||
            content.contains('Error Auto-Healing') ||
            (lrcFile.lengthSync() <= 20 && !lrcIsDoubtful(content));
        if (residual) {
          debugPrint(
            "♻️ [NLP Auto-Healing] Letra residual/inválida detectada. Purgando para reintento: $lrcPath",
          );
          await lrcFile.delete();
        } else if (!pathIsLab(filePath)) {
          // Fuera del Laboratorio la letra que ya existe no se toca.
          return LyricStatus.kept;
        } else {
          return await _reviewLabLrc(filePath, lrcPath, content);
        }
      } catch (e) {
        debugPrint(
          "⚠️ [NLP I/O] Imposible leer .lrc existente, no se toca: $e",
        );
        return LyricStatus.failed;
      }
    }

    try {
      return await _fetchAndSaveLrc(filePath, lrcPath);
    } catch (e) {
      debugPrint("🔴 [NLP Scraper Fatal Error]: $e");
      return LyricStatus.failed;
    }
  }

  List<String> _siblingLrcs(String lrcPath) {
    final File self = File(lrcPath);
    final Directory dir = self.parent;
    if (!dir.existsSync()) return const <String>[];
    final String name = self.uri.pathSegments.last.toLowerCase();
    final List<String> out = <String>[];
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is! File) continue;
      final String n = e.uri.pathSegments.last.toLowerCase();
      if (!n.endsWith('.lrc') || n.endsWith('.bak') || n == name) continue;
      try {
        out.add(e.readAsStringSync());
      } catch (_) {}
    }
    return out;
  }

  /// En GatoMix_LAB: si la letra no cuadra y hay una mejor, la vieja queda
  /// en `.lrc.bak`. Si no hay mejor, se marca dudosa y se deja.
  Future<LyricStatus> _reviewLabLrc(
    String audioPath,
    String lrcPath,
    String content,
  ) async {
    final id3 = await loadId3TitleArtist(audioPath);
    final int localSec = await _getLocalDurationSec(audioPath);
    final List<LyricIdentity> ids = lyricIdentities(
      path: audioPath,
      id3Artist: id3.artist,
      id3Title: id3.title,
      id3Album: id3.album,
      durationSec: localSec,
    );
    final LyricIdentity id = ids.first;
    final List<String> siblings = _siblingLrcs(lrcPath);
    final LyricFileVerdict verdict = assessLabLyric(
      lrc: content,
      artist: id.artist,
      title: id.title,
      durationSec: localSec,
      siblingLrcs: siblings,
    );
    if (verdict.fits) return LyricStatus.kept;
    final LyricChoice choice = await lookupSafeLyric(audioPath);
    final bool same =
        choice.hasText && lyricTextsMatch(choice.fileText, content);
    final bool better =
        choice.hasText && !same && !lyricDuplicates(choice.fileText, siblings);
    final LabLyricAction action = decideLabLyric(
      verdict: verdict,
      serverDown: choice.serverDown,
      hasBetter: better,
      sameText: same,
    );
    switch (action) {
      case LabLyricAction.keep:
        return LyricStatus.kept;
      case LabLyricAction.retry:
        return LyricStatus.retry;
      case LabLyricAction.replace:
        await writeLrcKeepingBak(lrcPath, choice.fileText);
        await _markAuto(lrcPath);
        if (choice.kind == LyricKind.synced) {
          await _processVocalBoundingBox(audioPath, choice.body, localSec);
          lastDetail = '';
          return LyricStatus.ok;
        }
        lastDetail = 'Letra plana (sin tiempos)';
        return LyricStatus.plain;
      case LabLyricAction.doubt:
        if (!lrcIsDoubtful(content)) {
          await File(lrcPath).writeAsString(markLrcDoubtful(content));
        }
        lastDetail = 'Letra dudosa';
        return LyricStatus.doubt;
    }
  }

  /// Descarga las letras de una carpeta y devuelve el conteo por resultado.
  Future<Map<LyricStatus, int>> downloadForDirectory(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    final counts = <LyricStatus, int>{for (final s in LyricStatus.values) s: 0};
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return counts;
    final files = dir.listSync(recursive: true).whereType<File>().where((f) {
      if (_enCarpetaOriginal(f.path)) return false;
      final p = f.path.toLowerCase();
      return p.endsWith('.mp3') && !p.endsWith('_k.mp3');
    }).toList();
    final pipe = ref.read(pipelineProvider.notifier);
    final total = files.length;
    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) break;
      final f = files[i];
      if (_enCarpetaOriginal(f.path)) continue;
      final name = f.uri.pathSegments.last;
      pipe.updateProgress(i + 1, total, name, "📝 Letras");
      // Mix pesado (> 16 MB): no tiene letra.
      if (f.lengthSync() / (1024 * 1024) > 16.0) {
        counts[LyricStatus.kept] = counts[LyricStatus.kept]! + 1;
        continue;
      }
      final st = await processSingleFile(f.path);
      counts[st] = counts[st]! + 1;
      await Future.delayed(const Duration(milliseconds: 150));
    }
    return counts;
  }
}

enum LyricStatus { ok, kept, noMatch, failed, retry, plain, doubt }

int? _autoBytes(dynamic size) {
  if (size is num) return size.toInt();
  if (size is Map && size['bytes'] is num)
    return (size['bytes'] as num).toInt();
  return null;
}

bool _autoIsManual(dynamic size) => size is Map && size['manual'] == true;
