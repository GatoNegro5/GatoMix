import 'dart:convert';
import 'dart:io';
import 'package:gatomix/core/yt_chunked_download.dart';
import 'package:gatomix/core/master_profile.dart';
import 'package:gatomix/services/karaoke_engine.dart';
import 'package:gatomix/services/master_track.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:file_selector/file_selector.dart';
import 'package:media_kit/media_kit.dart';
import '../../core/lrc_timeline.dart';
import '../../core/net/safe_download.dart';
import '../../core/track_name_clean.dart';

import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;
import '../../providers/nlp_provider.dart';
import '../../providers/dsp_provider.dart';
import '../../providers/db_provider.dart';

/// Bitrate de la transcodificación AAC→MP3. Una fuente de 128 no se infla a 320.
int mp3KbpsForSource(int sourceKbps) {
  if (sourceKbps <= 0) return 192;
  if (sourceKbps <= 160) return 192;
  if (sourceKbps >= 256) return 320;
  return 256;
}

/// Letra bajada por la app. `[gmx_manual:1]` se queda manual y no se desplaza.
bool ytLyricCountsAsAuto(String content) =>
    content.trim().isNotEmpty && !lrcIsManual(content);

void registerYtAutoLyric(String lrcPath) {
  final File f = File(lrcPath);
  if (!f.existsSync()) return;
  if (!ytLyricCountsAsAuto(f.readAsStringSync())) return;
  final File reg = File(
    '${f.parent.path}${Platform.pathSeparator}_lyrics_auto.json',
  );
  final Map<String, dynamic> map = <String, dynamic>{};
  if (reg.existsSync()) {
    try {
      final dynamic decoded = jsonDecode(reg.readAsStringSync());
      if (decoded is Map) {
        decoded.forEach((dynamic k, dynamic v) {
          map['$k'] = v;
        });
      }
    } catch (_) {}
  }
  map[f.uri.pathSegments.last] = f.lengthSync();
  reg.writeAsStringSync(jsonEncode(map));
}

// =====================================================================
// MÓDULO 2: BÚSQUEDA, EXTRACCIÓN Y AUTO-MASTER YT
// =====================================================================
class YoutubeSearchAndDownloadWorkspace extends ConsumerStatefulWidget {
  const YoutubeSearchAndDownloadWorkspace({super.key});

  @override
  ConsumerState<YoutubeSearchAndDownloadWorkspace> createState() =>
      _YoutubeSearchAndDownloadWorkspaceState();
}

class _YoutubeSearchAndDownloadWorkspaceState
    extends ConsumerState<YoutubeSearchAndDownloadWorkspace> {
  final TextEditingController _searchController = TextEditingController();
  final YoutubeExplode _yt = YoutubeExplode();

  List<Video> _results = [];
  bool _isProcessing = false;
  String _statusText =
      "Sistemas en línea. Busca un artista o pega URL directa.";

  // Controles de I/O y Pipeline
  String _selectedFolderPath = '';
  bool _autoMasterize = true;

  // 🛠️ INYECCIÓN: Motor de Streaming para Preview
  final Player _previewPlayer = Player();
  String? _previewingVideoId;
  bool _isPreviewLoading = false;
  bool _isPreviewPlaying = false;

  @override
  void initState() {
    super.initState();
    _initDefaultPath();

    _previewPlayer.stream.playing.listen((playing) {
      if (mounted) {
        setState(() {
          _isPreviewPlaying = playing;
        });
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _yt.close();
    _previewPlayer.dispose();
    super.dispose();
  }

  void _initDefaultPath() {
    String baseMusicPath = '';
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      baseMusicPath = userProfile != null
          ? '$userProfile\\Music\\Descargas'
          : 'C:\\Music\\Descargas';
    } else if (Platform.isMacOS || Platform.isLinux) {
      baseMusicPath = '${Platform.environment['HOME']}/Music/Descargas';
    } else {
      baseMusicPath = '/storage/emulated/0/Music/Descargas';
    }

    final baseDir = Directory(baseMusicPath);
    if (!baseDir.existsSync()) {
      baseDir.createSync(recursive: true);
    }

    setState(() {
      _selectedFolderPath = baseDir.path;
    });
  }

  Future<void> _showFolderSelectionDialog() async {
    try {
      final String? selectedDirectory = await getDirectoryPath(
        confirmButtonText: 'Seleccionar Carpeta',
      );

      if (selectedDirectory != null) {
        setState(() {
          _selectedFolderPath = selectedDirectory;
        });
      }
    } catch (e) {
      debugPrint("🔴 Error invocando el explorador nativo: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🔴 Fallo al abrir el explorador de archivos nativo: $e',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------
  // 🛠️ MÓDULO DE TELEMETRÍA Y COMPENSACIÓN VECTORIAL
  // ---------------------------------------------------------

  Future<String> _resolveBinary(String name) async {
    if (Platform.isAndroid || Platform.isIOS) return name;
    if (Platform.isMacOS || Platform.isLinux) {
      if (File('/opt/homebrew/bin/$name').existsSync()) {
        return '/opt/homebrew/bin/$name';
      }
      if (File('/usr/local/bin/$name').existsSync()) {
        return '/usr/local/bin/$name';
      }
      return name;
    }

    final exeName = '$name.exe';
    final projectDir = Directory.current.path;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final tempDir = Directory.systemTemp.path;

    final List<String> searchPaths = [
      '$projectDir\\$exeName',
      '$exeDir\\$exeName',
      '$projectDir\\windows\\$exeName',
      '$tempDir\\$exeName',
    ];

    for (final path in searchPaths) {
      if (File(path).existsSync()) return path;
    }

    if (name == 'yt-dlp') {
      final targetPath = '$tempDir\\$exeName';
      setState(() => _statusText = "Descargando yt-dlp.exe (Setup inicial)...");
      await downloadFileRobust(
        'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
        targetPath,
      );
      return targetPath;
    }

    throw Exception(
      "🛑 FALTA BINARIO: No se encontró '$exeName'.\n"
      "👉 Por favor, pega '$exeName' en la raíz de tu proyecto:\n$projectDir",
    );
  }

  // ignore: unused_element
  Future<int> _getAudioDurationMs(String path) async {
    try {
      // Rust/symphonia: sin ffprobe, igual en las 4 plataformas.
      return (await rust_dsp.exactDurationMs(inputPath: path)).toInt();
    } catch (_) {
      return 0;
    }
  }

  String _ytStageLabel(String stage) {
    switch (stage) {
      case 'METADATA_CLEANUP':
        return '⚙️ Arreglando el nombre...';
      case 'LYRICS':
        return '📝 Bajando y confirmando la letra...';
      case 'DSP_ANALYSIS':
        return '🔊 Quitando silencios, BPM y −14 LUFS...';
      case 'WATERMARK_ID3':
        return '🔐 Guardando marcas...';
      default:
        return '⚙️ Masterizando...';
    }
  }

  // El pipeline desplaza con los ms exactos de Rust (MasterTrack).
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
      debugPrint("✅ Vector LRC compensado en -$trimmedMs ms.");
    } catch (e) {
      debugPrint("🔴 Error realineando LRC: $e");
    }
  }

  // 🛠️ FIX ARQUITECTÓNICO: Control de estado seguro para media_kit (Anti-Deadlock)
  Future<void> _handleInput(String input) async {
    if (_isProcessing) return;

    if (_previewingVideoId != null) {
      try {
        await _previewPlayer.stop();
      } catch (_) {}
      setState(() {
        _previewingVideoId = null;
        _isPreviewPlaying = false;
      });
    }

    if (input.isEmpty) return;
    if (input.startsWith('http')) {
      await _executeDirectDownload(input);
    } else {
      await _executeSearch(input);
    }
  }

  Future<void> _executeSearch(String query) async {
    setState(() {
      _isProcessing = true;
      _statusText = "Buscando '$query' en los servidores de YouTube...";
      _results.clear();
    });

    try {
      final searchResult = await _yt.search.search('$query official audio');
      setState(() {
        _results = searchResult.take(15).toList();
        _statusText = "Resultados listos. Clic en 'Ingestar' para descargar.";
      });
    } catch (e) {
      setState(() => _statusText = "🔴 ERROR de Búsqueda: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _togglePreview(String videoId) async {
    if (_previewingVideoId == videoId) {
      if (_isPreviewPlaying) {
        await _previewPlayer.pause();
      } else {
        await _previewPlayer.play();
      }
      return;
    }

    if (_previewingVideoId != null) {
      try {
        await _previewPlayer.stop();
      } catch (_) {}
    }

    setState(() {
      _previewingVideoId = videoId;
      _isPreviewLoading = true;
    });

    try {
      final ytdlpPath = await _resolveBinary('yt-dlp');
      final targetUrl = 'https://youtube.com/watch?v=$videoId';

      // 🛠️ FIX ARQUITECTÓNICO: Extracción estricta sin advertencias de consola
      String directStreamUrl;
      if (Platform.isAndroid || Platform.isIOS) {
        // Móvil: sin binarios; la URL directa sale de youtube_explode_dart.
        final manifest = await _yt.videos.streamsClient.getManifest(
          VideoId(videoId),
        );
        directStreamUrl = manifest.audioOnly
            .withHighestBitrate()
            .url
            .toString();
      } else {
        final process = await Process.run(ytdlpPath, [
          '--no-warnings',
          '--print', 'url', // Mucho más estable que -g
          '-f', 'bestaudio',
          targetUrl,
        ]);

        if (process.exitCode != 0) {
          throw Exception("yt-dlp: ${process.stderr.toString().trim()}");
        }

        // Filtramos la basura y nos quedamos solo con la línea HTTP
        final outputLines = process.stdout.toString().trim().split('\n');
        directStreamUrl = outputLines.lastWhere(
          (line) => line.trim().startsWith('http'),
          orElse: () => '',
        );

        if (directStreamUrl.isEmpty) {
          throw Exception(
            "No se extrajo una URL válida. Salida: ${process.stdout}",
          );
        }
      }

      // 🛠️ INYECCIÓN: Disfrazamos al motor nativo como si fuera Google Chrome
      // Esto evita el HTTP 403 Forbidden directo de los servidores de caché de YouTube
      await _previewPlayer.open(
        Media(
          directStreamUrl,
          httpHeaders: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          },
        ),
        play: true,
      );
    } catch (e) {
      debugPrint("🔴 [Preview Error]: $e");
      if (mounted) {
        // Ahora sí imprimiremos en pantalla la verdadera razón si falla
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🔴 Fallo de Preview: ${e.toString().replaceAll('Exception: ', '').split('\n').first}',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() {
          _previewingVideoId = null;
          _isPreviewPlaying = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isPreviewLoading = false;
        });
      }
    }
  }

  int _ytRefresh = 0;

  Future<void> _executeDirectDownload(String targetUrl) async {
    // 🛠️ FIX ARQUITECTÓNICO: Detener preview de forma segura antes del I/O
    if (_previewingVideoId != null) {
      try {
        await _previewPlayer.stop();
      } catch (_) {}
      setState(() {
        _previewingVideoId = null;
        _isPreviewPlaying = false;
      });
    }

    if (_selectedFolderPath.isEmpty) {
      setState(
        () => _statusText =
            "🔴 ERROR: Selecciona una carpeta de destino primero.",
      );
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusText = "Iniciando motor híbrido (Extracción + MP3 Rust)...";
    });

    try {
      final ytdlpPath = await _resolveBinary('yt-dlp');
      final downloadPath = _selectedFolderPath;
      if (!Directory(downloadPath).existsSync()) {
        Directory(downloadPath).createSync(recursive: true);
      }

      setState(
        () => _statusText = "Resolviendo manifiesto para nombrar archivo...",
      );
      final videoId = VideoId(targetUrl);
      final video = await _yt.videos.get(videoId);
      final String trackStem = ytTitleToStem(video.title);

      final tempDir = Directory.systemTemp;
      final String sep = Platform.pathSeparator;
      final tempRawPath =
          '${tempDir.path}$sep'
          'raw_vr_audio.m4a';
      final tempM4aPath = '${tempDir.path}$sep$trackStem.m4a';
      final tempMp3Path = '${tempDir.path}$sep$trackStem.mp3';
      final tempLrcPath = '${tempDir.path}$sep$trackStem.lrc';

      if (File(tempRawPath).existsSync()) File(tempRawPath).deleteSync();
      if (File(tempM4aPath).existsSync()) File(tempM4aPath).deleteSync();

      setState(
        () => _statusText = "Descargando stream crudo de máxima calidad...",
      );

      var sourceKbps = 0;
      if (Platform.isAndroid || Platform.isIOS) {
        // Móvil: no se pueden ejecutar binarios (yt-dlp → "permission
        // denied"). Se baja el AAC/M4A con youtube_explode_dart.
        final manifest = await _yt.videos.streamsClient.getManifest(videoId);
        final m4a = manifest.audioOnly
            .where((s) => s.container == StreamContainer.mp4)
            .toList();
        if (m4a.isEmpty) {
          throw Exception("Sin stream AAC/M4A disponible para este video.");
        }
        m4a.sort((a, b) => b.bitrate.compareTo(a.bitrate));
        sourceKbps = (m4a.first.bitrate.bitsPerSecond / 1000).round();
        // 1.0.14: por trozos en paralelo (como yt-dlp) con timeout y
        // reintentos; la petición única de youtube_explode la estrangula
        // YouTube y en Android tardaba >10 min sin progreso.
        final best = m4a.first;
        final total = best.size.totalBytes;
        await ytChunkedDownload(
          url: best.url,
          deadline: const Duration(minutes: 3),
          totalBytes: total,
          outPath: tempRawPath,
          refreshUrl: () async {
            // Tras un 403 (YouTube corta las URL sin PO token pasado ~1 MB)
            // se pide una URL nueva, rotando clientes.
            final clients = [
              [YoutubeApiClient.androidSdkless],
              [YoutubeApiClient.android],
              [YoutubeApiClient.ios],
            ];
            final fresh = await _yt.videos.streamsClient.getManifest(
              videoId,
              ytClients: clients[(_ytRefresh++) % clients.length],
            );
            for (final s in fresh.audioOnly) {
              if (s.tag == best.tag) return s.url;
            }
            return null;
          },
          onProgress: (done, t) {
            if (!mounted) return;
            setState(
              () => _statusText =
                  "Descargando audio... ${(done * 100 / t).floor()}% "
                  "(${(done / 1048576).toStringAsFixed(1)} de "
                  "${(t / 1048576).toStringAsFixed(1)} MB)",
            );
          },
        );
        if (!File(tempRawPath).existsSync() ||
            File(tempRawPath).lengthSync() == 0) {
          throw Exception("Fallo al bajar el audio (archivo vacío).");
        }
      } else {
        final process = await Process.start(ytdlpPath, [
          '--rm-cache-dir',
          '-f',
          // De mejor a peor calidad entre los AAC/M4A que Rust decodifica.
          'bestaudio[ext=m4a]/141/140/bestaudio',
          '--print',
          '%(abr)s',
          '-o',
          tempRawPath,
          targetUrl,
        ]);

        String errorTrace = "";
        String abrOut = "";
        process.stdout.listen((bytes) {
          abrOut += String.fromCharCodes(bytes);
        });
        process.stderr.listen((bytes) {
          errorTrace += String.fromCharCodes(bytes);
        });

        final exitCode = await process.exitCode;

        if (exitCode != 0 || !File(tempRawPath).existsSync()) {
          throw Exception("Fallo CLI Extractor. Traza: $errorTrace");
        }
        final List<String> abrLines = abrOut
            .split(RegExp(r'\s+'))
            .map((String s) => s.trim())
            .where((String s) => s.isNotEmpty)
            .toList();
        if (abrLines.isNotEmpty) {
          sourceKbps = double.tryParse(abrLines.last)?.round() ?? 0;
        }
      }

      if (tempRawPath != tempM4aPath) {
        if (File(tempM4aPath).existsSync()) File(tempM4aPath).deleteSync();
        File(tempRawPath).renameSync(tempM4aPath);
      }

      setState(() => _statusText = "Buscando letra con el nombre limpio...");
      await ref.read(nlpWorkerProvider).processSingleFile(tempM4aPath);
      if (!File(tempLrcPath).existsSync()) {
        await _extractLyricsFromYoutube(targetUrl, tempMp3Path);
      }

      String prelimLrc = "";
      if (File(tempLrcPath).existsSync()) {
        prelimLrc = File(tempLrcPath).readAsStringSync();
      }

      if (!mounted) return;
      final result = await showDialog<Map<String, String>>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PreIngestModal(
          initialTitle: trackStem,
          initialLrc: prelimLrc,
          audioPath: tempM4aPath,
        ),
      );

      if (result == null) {
        try {
          if (File(tempM4aPath).existsSync()) File(tempM4aPath).deleteSync();
          if (File(tempMp3Path).existsSync()) File(tempMp3Path).deleteSync();
          if (File(tempLrcPath).existsSync()) File(tempLrcPath).deleteSync();
        } catch (_) {}
        setState(() => _statusText = "Descarga descartada por el usuario.");
        return;
      }

      final int kbps = mp3KbpsForSource(sourceKbps);
      setState(
        () => _statusText = "Codificando a MP3 ${kbps}k (motor Rust/LAME)...",
      );
      try {
        await rust_dsp.encodeToMp3(
          inputPath: tempM4aPath,
          outputPath: tempMp3Path,
          bitrateKbps: kbps,
          master: _autoMasterize,
        );
      } catch (e) {
        throw Exception("Fallo en el codificador MP3: $e");
      }
      try {
        if (File(tempM4aPath).existsSync()) File(tempM4aPath).deleteSync();
      } catch (_) {}

      setState(() => _statusText = "Inyectando archivo final al destino...");
      final cleanName = result['fileName']!
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
          .trim();
      final finalLrcContent = result['lrcContent']!;

      final finalMp3Path =
          '$downloadPath${Platform.pathSeparator}$cleanName.mp3';
      final finalLrcPath =
          '$downloadPath${Platform.pathSeparator}$cleanName.lrc';

      File(tempMp3Path).renameSync(finalMp3Path);
      if (finalLrcContent.trim().isNotEmpty) {
        File(finalLrcPath).writeAsStringSync(finalLrcContent);
        registerYtAutoLyric(finalLrcPath);
      } else {
        if (File(finalLrcPath).existsSync()) File(finalLrcPath).deleteSync();
      }

      try {
        if (File(tempLrcPath).existsSync()) File(tempLrcPath).deleteSync();
      } catch (_) {}

      _searchController.clear();

      if (_autoMasterize) {
        await _runSingleTrackPipeline(finalMp3Path);
      } else {
        setState(
          () => _statusText =
              "✅ ¡Extracción Completada! MP3 ($cleanName) guardado.",
        );
      }
    } catch (e) {
      debugPrint("🔴 Error en Pipeline Híbrido: $e");
      setState(
        () => _statusText = ytIsRateLimit(e)
            ? "🟠 $ytRateLimitMsg"
            : e is YtDownloadStalled
            ? "🟠 ${e.toString()}"
            : "🔴 ERROR FATAL: ${e.toString().replaceAll('Exception: ', '')}",
      );
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _extractLyricsFromYoutube(
    String videoUrl,
    String mp3Path,
  ) async {
    try {
      setState(
        () => _statusText = "Interceptando manifiesto de subtítulos nativos...",
      );
      final videoId = VideoId(videoUrl);
      final manifest = await _yt.videos.closedCaptions.getManifest(videoId);

      if (manifest.tracks.isEmpty) {
        debugPrint(
          "⚠️ VETO: El stream de YouTube no contiene pista de subtítulos.",
        );
        return;
      }

      ClosedCaptionTrackInfo? selectedTrack;
      final langs = ['es', 'en'];

      for (var lang in langs) {
        try {
          selectedTrack = manifest.tracks.firstWhere(
            (t) =>
                t.language.code.toLowerCase().contains(lang) &&
                !t.isAutoGenerated,
          );
          break;
        } catch (_) {}
      }
      if (selectedTrack == null) {
        for (var lang in langs) {
          try {
            selectedTrack = manifest.tracks.firstWhere(
              (t) => t.language.code.toLowerCase().contains(lang),
            );
            break;
          } catch (_) {}
        }
      }
      selectedTrack ??= manifest.tracks.first;

      final track = await _yt.videos.closedCaptions.get(selectedTrack);
      if (track.captions.isEmpty) return;

      final lrcBuffer = StringBuffer();
      for (var caption in track.captions) {
        final start = caption.offset;
        final min = start.inMinutes.toString().padLeft(2, '0');
        final sec = (start.inSeconds % 60).toString().padLeft(2, '0');
        final ms = ((start.inMilliseconds % 1000) ~/ 10).toString().padLeft(
          2,
          '0',
        );

        final text = caption.text
            .replaceAll('\n', ' ')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
        final lowerText = text.toLowerCase();
        bool isGarbage = false;

        if (text.length <= 2) isGarbage = true;
        if (lowerText.contains(
          RegExp(
            r'\[música\]|\(música\)|\[aplausos\]|\(aplausos\)|instrumental|♪|🎵',
            caseSensitive: false,
          ),
        )) {
          isGarbage = true;
        }
        if (lowerText.startsWith('[') && lowerText.endsWith(']')) {
          isGarbage = true;
        }
        if (lowerText.startsWith('(') && lowerText.endsWith(')')) {
          isGarbage = true;
        }

        if (!isGarbage && text.isNotEmpty) {
          lrcBuffer.writeln('[$min:$sec.$ms]$text');
        }
      }

      if (lrcBuffer.isNotEmpty) {
        final lrcPath = mp3Path.replaceAll(
          RegExp(r'\.mp3$', caseSensitive: false),
          '.lrc',
        );
        await File(lrcPath).writeAsString(lrcBuffer.toString());
        setState(
          () => _statusText = "✅ Letra purificada (.lrc) inyectada con éxito.",
        );
      }
    } catch (e) {
      debugPrint("🔴 [I/O Scraper Error]: $e");
    }
  }

  Future<void> _runSingleTrackPipeline(String initialPath) async {
    String currentPath = initialPath;

    try {
      setState(() => _statusText = "⚙️ Nombre, letra, corte y −14 LUFS...");
      final outcome = await MasterTrack.run(
        ref: ref,
        path: currentPath,
        withLyrics: true,
        writeCues: false,
        onStage: (String stage) {
          if (!mounted) return;
          setState(() => _statusText = _ytStageLabel(stage));
        },
      );
      currentPath = outcome.path;
      if (outcome.detail.isNotEmpty && mounted) {
        setState(() => _statusText = outcome.detail);
      }

      // Megamix (>16 MB): corte + −14 + BPM de entrada. Sin letra y sin _K.
      final double fileSizeMB = File(currentPath).lengthSync() / (1024 * 1024);
      final bool isHeavyMix = fileSizeMB > 16.0;

      final lrcPath = currentPath.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );

      final marks = await rust_dsp.readGmxMarks(inputPath: currentPath);
      final bool lyricsOk =
          isHeavyMix ||
          marks.lyr == 'SYNC' ||
          marks.lyr == 'PLAIN' ||
          marks.lyr == 'MANUAL' ||
          marks.lyr == 'APPROX' ||
          marks.lyr == 'NA' ||
          marks.lyr == 'NONE';
      if (marks.trimMs >= 0 && marks.lufsDone && marks.bpmOk && lyricsOk) {
        setState(() => _statusText = "🔐 Inyectando Sello Watermark...");
        await rust_dsp.injectWatermark(inputPath: currentPath);
      }

      setState(() => _statusText = "🎛️ Asignando Curvas ISAR...");
      final rawGenre = await rust_dsp.readAudioGenre(inputPath: currentPath);

      String assignedProfile = 'constant_power';
      int assignedDuration = 6000;

      final Map<String, Map<String, dynamic>> mixProfiles = {
        'reggaeton': {'curve': 'eq_kill', 'durationMs': 4000},
        'salsa': {'curve': 'sharp', 'durationMs': 2000},
        'merengue': {'curve': 'sharp', 'durationMs': 2500},
        'balada': {'curve': 'linear', 'durationMs': 8000},
        'rock': {'curve': 'constant_power', 'durationMs': 3500},
        'cumbia': {'curve': 'constant_power', 'durationMs': 3000},
        'electro': {'curve': 'eq_kill', 'durationMs': 7000},
        'latin': {'curve': 'constant_power', 'durationMs': 4500},
        'pop': {'curve': 'constant_power', 'durationMs': 4000},
      };

      if (rawGenre.isNotEmpty && rawGenre != 'desconocido') {
        for (final key in mixProfiles.keys) {
          if (rawGenre.contains(key)) {
            assignedProfile = mixProfiles[key]!['curve'] as String;
            assignedDuration = mixProfiles[key]!['durationMs'] as int;
            break;
          }
        }
      }

      setState(() => _statusText = "🎯 Calculando Cues...");
      final existingMeta = await ref
          .read(dbServiceProvider)
          .getTrackMetadata(currentPath);
      int? calculatedCueIn;
      int? calculatedMixOut;

      final lrcFile = File(lrcPath);
      if (lrcFile.existsSync()) {
        try {
          final lines = await lrcFile.readAsLines();
          final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
          int firstVocalMs = -1;
          int lastVocalMs = -1;

          for (var line in lines) {
            final match = regex.firstMatch(line);
            if (match != null) {
              final text = match.group(4)!.trim().toLowerCase();
              bool isGarbage = false;
              if (text.length < 4 ||
                  text.contains('🎵') ||
                  text.contains('♪') ||
                  text.startsWith('(') ||
                  text.startsWith('[')) {
                isGarbage = true;
              } else if (text.contains('instrumental') ||
                  text.contains('sync') ||
                  text.contains('lyric') ||
                  text.contains('letra no encontrada') ||
                  text.contains('error de conexión') ||
                  text.contains(' - ')) {
                isGarbage = true;
              }

              if (!isGarbage) {
                final min = int.parse(match.group(1)!);
                final sec = int.parse(match.group(2)!);
                int ms = int.parse(match.group(3)!);
                if (match.group(3)!.length == 2) ms *= 10;

                int currentMs = (min * 60000) + (sec * 1000) + ms;
                if (firstVocalMs == -1) firstVocalMs = currentMs;
                lastVocalMs = currentMs;
              }
            }
          }

          if (firstVocalMs != -1) {
            int optimalBuffer = assignedDuration + 4000;
            calculatedCueIn = (firstVocalMs >= optimalBuffer)
                ? (firstVocalMs - optimalBuffer)
                : 0;
            calculatedMixOut = lastVocalMs + 4000;
          }
        } catch (_) {}
      }

      await ref
          .read(dbServiceProvider)
          .saveTrackMetadata(
            path: currentPath,
            mixProfile: assignedProfile,
            durationMs: assignedDuration,
            genre: rawGenre,
            cueInMs: existingMeta?.cueInMs ?? calculatedCueIn ?? 0,
            mixOutMs: existingMeta?.mixOutMs ?? calculatedMixOut,
          );

      setState(() => _statusText = "🥁 Indexando Caché Estática...");

      await Future.delayed(const Duration(milliseconds: 500));

      final parentDir = Directory(currentPath).parent.path;
      await ref.read(dspWorkerProvider).generateStaticBpmCache(parentDir);

      // 🛠️ INYECCIÓN KRAEOKE FIRE-AND-FORGET POST-MASTERIZACIÓN (BYPASS APLICADO)
      if (!isHeavyMix && MasterProfile.current().allowKaraoke) {
        setState(
          () => _statusText =
              "✅ Automix listo. 🤖 Generando Karaoke en 2do plano...",
        );
        KaraokeAIEngine.spawnBackgroundExtraction(currentPath);
      } else if (!isHeavyMix) {
        setState(
          () => _statusText =
              "✅ Automix listo. Karaoke _K solo en Windows y Mac.",
        );
      } else {
        setState(
          () => _statusText = "✅ Automix listo. (Karaoke IA omitido por peso)",
        );
      }
    } catch (e) {
      setState(
        () => _statusText = "⚠️ Descargado, pero falló el Auto-Master: $e",
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobileLandscape = constraints.maxHeight < 500;

        final Widget configBar = Container(
          padding: EdgeInsets.symmetric(
            horizontal: isMobileLandscape ? 8 : 15,
            vertical: isMobileLandscape ? 4 : 12,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(
              color: const Color(0xFF00FFFF).withValues(alpha: 0.5),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_open, color: Color(0xFF00FFFF), size: 20),
              const SizedBox(width: 10),
              const Text(
                "Destino:",
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: InkWell(
                  onTap: _isProcessing ? null : _showFolderSelectionDialog,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      border: Border.all(color: Colors.white10),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _selectedFolderPath.isEmpty
                                ? "Seleccionar carpeta..."
                                : _selectedFolderPath,
                            style: const TextStyle(
                              color: Color(0xFF00FFFF),
                              fontFamily: 'Consolas',
                              fontSize: 13,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.arrow_drop_down,
                          color: Color(0xFF00FFFF),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                width: 1,
                height: 30,
                color: Colors.white24,
                margin: const EdgeInsets.symmetric(horizontal: 15),
              ),
              Tooltip(
                message:
                    "Ejecuta limpieza, NDK Trim, Sello de agua y descarga letras automáticamente.",
                child: Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      color: Color(0xFF39FF14),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      "Auto-Master",
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    Switch(
                      value: _autoMasterize,
                      activeThumbColor: const Color(0xFF39FF14),
                      inactiveThumbColor: Colors.white54,
                      inactiveTrackColor: Colors.white10,
                      onChanged: _isProcessing
                          ? null
                          : (val) => setState(() => _autoMasterize = val),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

        final Widget searchBar = Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                enabled: !_isProcessing,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  isDense: isMobileLandscape,
                  hintText:
                      "Nombre de canción o https://www.youtube.com/watch?v=...",
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.black,
                  border: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF00FFFF)),
                    borderRadius: BorderRadius.circular(4.0),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search, color: Color(0xFF00FFFF)),
                    onPressed: _isProcessing
                        ? null
                        : () => _handleInput(_searchController.text.trim()),
                  ),
                ),
                onSubmitted: _isProcessing
                    ? null
                    : (val) => _handleInput(val.trim()),
              ),
            ),
          ],
        );

        final Widget statusBar = Container(
          width: double.infinity,
          padding: EdgeInsets.all(isMobileLandscape ? 6 : 15),
          decoration: BoxDecoration(
            color: Colors.black,
            border: Border.all(color: const Color(0xFF333333)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            _statusText,
            style: TextStyle(
              color: _statusText.contains("ERROR")
                  ? Colors.redAccent
                  : const Color(0xFF39FF14),
              fontFamily: 'Consolas',
              fontSize: 13,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        );

        final Widget resultsList = ListView.builder(
          itemCount: _results.length,
          itemBuilder: (context, index) {
            final video = _results[index];
            final bool isThisPreviewing = _previewingVideoId == video.id.value;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: ListTile(
                leading: const Icon(
                  Icons.youtube_searched_for,
                  color: Color(0xFF00FFFF),
                ),
                title: Text(
                  video.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  "${video.author} • ${video.duration?.inMinutes ?? 0}:${((video.duration?.inSeconds ?? 0) % 60).toString().padLeft(2, '0')}",
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 🛠️ INYECCIÓN UI: Botón de Escucha Previa (Preview)
                    if (_isPreviewLoading && isThisPreviewing)
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          color: Color(0xFF39FF14),
                          strokeWidth: 2,
                        ),
                      )
                    else
                      IconButton(
                        icon: Icon(
                          isThisPreviewing && _isPreviewPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                        ),
                        color: const Color(0xFF39FF14),
                        iconSize: 30,
                        tooltip: isThisPreviewing && _isPreviewPlaying
                            ? "Pausar"
                            : "Escuchar Previo",
                        onPressed: _isProcessing
                            ? null
                            : () => _togglePreview(video.id.value),
                      ),
                    const SizedBox(width: 10),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.download),
                      label: const Text("Ingestar"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FFFF),
                        foregroundColor: Colors.black,
                      ),
                      onPressed: _isProcessing
                          ? null
                          : () => _executeDirectDownload(
                              'https://youtube.com/watch?v=${video.id.value}',
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );

        if (isMobileLandscape) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Buscador Global & Extracción",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00FFFF),
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  "Busca pistas en la red o pega una URL para inyectarla directamente al disco duro en formato MP3 (320kbps).",
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                configBar,
                const SizedBox(height: 6),
                searchBar,
                const SizedBox(height: 6),
                statusBar,
                const SizedBox(height: 6),
                if (_results.isNotEmpty)
                  Expanded(child: resultsList)
                else
                  const Spacer(),
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
                "Buscador Global & Extracción",
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF00FFFF),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                "Busca pistas en la red o pega una URL para inyectarla directamente al disco duro en formato MP3 (320kbps).",
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 25),
              configBar,
              const SizedBox(height: 20),
              searchBar,
              const SizedBox(height: 20),
              statusBar,
              const SizedBox(height: 20),
              if (_results.isNotEmpty) Expanded(child: resultsList),
            ],
          ),
        );
      },
    );
  }
}

// ==========================================
// 🛠️ NUEVO COMPONENTE: MODAL DE PRE-INGESTA (Con Motor de Preview)
// ==========================================
class PreIngestModal extends StatefulWidget {
  final String initialTitle;
  final String initialLrc;
  final String audioPath;

  const PreIngestModal({
    super.key,
    required this.initialTitle,
    required this.initialLrc,
    required this.audioPath,
  });

  @override
  State<PreIngestModal> createState() => _PreIngestModalState();
}

class _PreIngestModalState extends State<PreIngestModal> {
  late TextEditingController _titleController;
  late TextEditingController _lrcController;
  late final Player _player;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    String cleanTitle = widget.initialTitle
        .replaceAll(RegExp(r'\(.*?\)'), '')
        .replaceAll(RegExp(r'\[.*?\]'), '')
        .replaceAll(RegExp(r'official video', caseSensitive: false), '')
        .replaceAll(RegExp(r'official audio', caseSensitive: false), '')
        .replaceAll(RegExp(r'lyric video', caseSensitive: false), '')
        .trim();

    _titleController = TextEditingController(text: cleanTitle);
    _lrcController = TextEditingController(text: widget.initialLrc);

    _player = Player();
    _player.open(Media(widget.audioPath), play: false);
    _player.stream.playing.listen((playing) {
      if (mounted) {
        setState(() {
          _isPlaying = playing;
        });
      }
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _lrcController.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return AlertDialog(
      backgroundColor: const Color(0xFF121212),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFF00FFFF)),
        borderRadius: BorderRadius.circular(8),
      ),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            "Laboratorio Pre-Ingesta",
            style: TextStyle(
              color: Color(0xFF00FFFF),
              fontWeight: FontWeight.bold,
            ),
          ),
          IconButton(
            icon: Icon(
              _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
            ),
            color: const Color(0xFF39FF14),
            iconSize: 32,
            tooltip: _isPlaying ? "Pausar Preview" : "Auditar Audio",
            onPressed: () {
              _isPlaying ? _player.pause() : _player.play();
            },
          ),
        ],
      ),
      content: SizedBox(
        width: isMobile ? MediaQuery.of(context).size.width * 0.9 : 600,
        height: isMobile ? MediaQuery.of(context).size.height * 0.7 : 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "1. Renombrar Archivo (Sin extensión)",
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _titleController,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'Consolas',
              ),
              decoration: const InputDecoration(
                filled: true,
                fillColor: Colors.black,
                border: OutlineInputBorder(),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF00FFFF)),
                ),
              ),
            ),
            const SizedBox(height: 15),
            const Text(
              "2. Revisión de Letra Sincronizada (.lrc)",
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: _lrcController,
                maxLines: null,
                expands: true,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFamily: 'Consolas',
                ),
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Color(0xFF0A0A0A),
                  border: OutlineInputBorder(),
                  hintText:
                      "Pista sin letra detectada. Puedes pegar un LRC externo aquí.",
                  hintStyle: TextStyle(color: Colors.white24),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _player.stop();
            Navigator.pop(context, null);
          },
          child: const Text(
            "Descartar Descarga",
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
        ElevatedButton.icon(
          onPressed: () {
            _player.stop();
            Navigator.pop(context, {
              'fileName': _titleController.text.trim(),
              'lrcContent': _lrcController.text,
            });
          },
          icon: const Icon(Icons.download),
          label: const Text("Aprobar e Inyectar"),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00FFFF),
            foregroundColor: Colors.black,
          ),
        ),
      ],
    );
  }
}

class KaraokeAIEngine {
  static void spawnBackgroundExtraction(String path) {
    final isFile = File(path).existsSync();
    final isDir = Directory(path).existsSync();

    // 1. Verificamos que la ruta exista física en el disco
    if (!isFile && !isDir) {
      debugPrint("🔴 [AI ENGINE] Ruta ignorada (No existe): $path");
      return;
    }

    // 2. Si es archivo, exigimos MP3. Si es carpeta, lo dejamos pasar libremente.
    if (isFile && !path.toLowerCase().endsWith('.mp3')) {
      debugPrint("🔴 [AI ENGINE] Archivo ignorado (No es MP3): $path");
      return;
    }

    debugPrint("🤖 [AI ENGINE] Karaoke IA (Rust/ONNX) en: $path");
    KaraokeEngine.run(
      path,
      onStatus: (s) => debugPrint("🔵 [KARAOKE]: $s"),
    ).whenComplete(() => debugPrint("✅ [AI ENGINE] Extracción IA terminada"));
  }
}
