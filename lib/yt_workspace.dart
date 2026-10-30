import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:file_selector/file_selector.dart';

// 🛠️ INYECTADO: Backend FFI Nativo y Providers para Auto-Masterización
import 'package:gatomix/core/pipeline_controller.dart';
import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;
import 'providers/metadata_provider.dart';
import 'providers/nlp_provider.dart';
import 'providers/dsp_provider.dart';
import 'providers/db_provider.dart';

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

  @override
  void initState() {
    super.initState();
    _initDefaultPath();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _yt.close();
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

  // 🛠️ PROFESIONAL: Uso de API Nativa Oficial de Google (file_selector)
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
  Future<int> _getAudioDurationMs(String path) async {
    try {
      // Rust/symphonia: sin ffprobe, igual en las 4 plataformas.
      return (await rust_dsp.exactDurationMs(inputPath: path)).toInt();
    } catch (_) {
      return 0;
    }
  }

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

  Future<void> _handleInput(String input) async {
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

        // 🛠️ NLP GARBAGE FILTER INYECTADO (Homologado con el Laboratorio)
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
      setState(() => _statusText = "⚙️ Limpieza de metadatos...");
      currentPath = await ref
          .read(metadataWorkerProvider)
          .processSingleFile(currentPath);

      final lrcPath = currentPath.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );
      final hasPreIngestedLrc = File(lrcPath).existsSync();

      // Omitir extracción si el usuario ya verificó el LRC en el Sandbox Pre-Ingesta
      if (!hasPreIngestedLrc) {
        setState(() => _statusText = "📝 Scraping LRCLIB (NLP)...");
        await ref.read(nlpWorkerProvider).processSingleFile(currentPath);
      } else {
        debugPrint(
          "🟢 [TRACKER PIPELINE] NLP Omitido. Procesando letra verificada por el usuario.",
        );
      }

      setState(() => _statusText = "🔊 Aplicando DSP (C++) & Trim...");
      final durationBeforeMs = await _getAudioDurationMs(currentPath);
      await ref.read(dspWorkerProvider).processSingleFile(currentPath);
      final durationAfterMs = await _getAudioDurationMs(currentPath);
      final trimmedMs = durationBeforeMs - durationAfterMs;

      // Compensación garantizada: Ajusta matemáticamente el LRC aprobado por el usuario
      if (trimmedMs > 50) {
        setState(
          () => _statusText =
              "⏱️ Realineando vector de subtítulos (-$trimmedMs ms)...",
        );
        await _offsetLrcTimeline(lrcPath, trimmedMs);
      }

      setState(() => _statusText = "🔐 Inyectando Sello Watermark...");
      await rust_dsp.injectWatermark(inputPath: currentPath);

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

      setState(() => _statusText = "🥁 Indexando Caché...");
      await ref
          .read(dspWorkerProvider)
          .generateStaticBpmCache(Directory(currentPath).parent.path);

      setState(() => _statusText = "✅ ¡Track inyectado y listo para Automix!");
    } catch (e) {
      setState(
        () => _statusText = "⚠️ Descargado, pero falló el Auto-Master: $e",
      );
    }
  }

  Future<void> _executeDirectDownload(String targetUrl) async {
    if (_selectedFolderPath.isEmpty) {
      setState(
        () => _statusText =
            "🔴 ERROR: Selecciona una carpeta de destino primero.",
      );
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusText = "Iniciando motor híbrido (VR Bypass + MP3 Rust)...";
    });

    try {
      final tempDir = Directory.systemTemp;
      final ytdlpPath = Platform.isWindows
          ? '${tempDir.path}${Platform.pathSeparator}yt-dlp.exe'
          : 'yt-dlp';
      final downloadPath = _selectedFolderPath;

      if (!Directory(downloadPath).existsSync()) {
        Directory(downloadPath).createSync(recursive: true);
      }

      setState(
        () => _statusText = "Resolviendo manifiesto para nombrar archivo...",
      );
      final videoId = VideoId(targetUrl);
      final video = await _yt.videos.get(videoId);
      final safeTitle = video.title
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
          .trim();

      final tempRawPath =
          '${tempDir.path}${Platform.pathSeparator}raw_vr_audio.m4a';
      final tempMp3Path =
          '${tempDir.path}${Platform.pathSeparator}$safeTitle.mp3';

      if (File(tempRawPath).existsSync()) File(tempRawPath).deleteSync();

      setState(
        () => _statusText =
            "Descargando stream crudo vía Android VR (Anti-Throttle)...",
      );

      final process = await Process.start(
        ytdlpPath,
        ytDlpRedownloadArgs(output: tempRawPath, url: targetUrl),
      );

      String errorTrace = "";
      process.stdout.listen((_) {});
      process.stderr.listen((bytes) {
        errorTrace += String.fromCharCodes(bytes);
      });

      final exitCode = await process.exitCode;

      if (exitCode != 0 || !File(tempRawPath).existsSync()) {
        throw Exception("Fallo CLI Extractor. Traza: $errorTrace");
      }

      setState(
        () => _statusText = "Codificando a MP3 320k (motor Rust/LAME)...",
      );

      try {
        await rust_dsp.encodeToMp3(
          inputPath: tempRawPath,
          outputPath: tempMp3Path,
          bitrateKbps: 320,
        );
      } catch (e) {
        throw Exception("Fallo en el codificador MP3: $e");
      }

      try {
        if (File(tempRawPath).existsSync()) File(tempRawPath).deleteSync();
      } catch (_) {}

      // 🛠️ FASE PRE-INGESTA: Scraping en Cuarentena
      setState(
        () => _statusText = "Extrayendo metadatos y letras preliminares...",
      );
      final tempLrcPath = tempMp3Path.replaceAll('.mp3', '.lrc');

      await ref.read(nlpWorkerProvider).processSingleFile(tempMp3Path);
      if (!File(tempLrcPath).existsSync()) {
        await _extractLyricsFromYoutube(targetUrl, tempMp3Path);
      }

      String prelimLrc = "";
      if (File(tempLrcPath).existsSync()) {
        prelimLrc = File(tempLrcPath).readAsStringSync();
      }

      // Detener Pipeline y solicitar Veto de Usuario
      if (!mounted) return;
      final result = await showDialog<Map<String, String>>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) =>
            PreIngestModal(initialTitle: safeTitle, initialLrc: prelimLrc),
      );

      if (result == null) {
        // Descarte Absoluto
        try {
          if (File(tempMp3Path).existsSync()) File(tempMp3Path).deleteSync();
          if (File(tempLrcPath).existsSync()) File(tempLrcPath).deleteSync();
        } catch (_) {}
        setState(() => _statusText = "Descarga descartada por el usuario.");
        return;
      }

      // Volcado Atómico al Destino
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
      } else {
        if (File(finalLrcPath).existsSync()) File(finalLrcPath).deleteSync();
      }

      _searchController.clear();

      if (_autoMasterize) {
        await _runSingleTrackPipeline(finalMp3Path);
      } else {
        setState(
          () => _statusText =
              "✅ ¡Extracción Completada! MP3 ($cleanName) masterizado en disco.",
        );
      }
    } catch (e) {
      debugPrint("🔴 Error en Pipeline Híbrido: $e");
      setState(() => _statusText = "🔴 ERROR FATAL: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobileLandscape = constraints.maxHeight < 500;

        final Widget configBar = Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
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
          padding: const EdgeInsets.all(15),
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
                trailing: ElevatedButton.icon(
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
              ),
            );
          },
        );

        if (isMobileLandscape) {
          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(15.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Buscador Global & Extracción",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00FFFF),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  "Busca pistas en la red o pega una URL para inyectarla directamente al disco duro en formato MP3 (320kbps).",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 20),
                configBar,
                const SizedBox(height: 15),
                searchBar,
                const SizedBox(height: 15),
                statusBar,
                const SizedBox(height: 15),
                if (_results.isNotEmpty)
                  SizedBox(height: 250, child: resultsList),
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
// 🛠️ NUEVO COMPONENTE: MODAL DE PRE-INGESTA
// ==========================================
class PreIngestModal extends StatefulWidget {
  final String initialTitle;
  final String initialLrc;

  const PreIngestModal({
    super.key,
    required this.initialTitle,
    required this.initialLrc,
  });

  @override
  State<PreIngestModal> createState() => _PreIngestModalState();
}

class _PreIngestModalState extends State<PreIngestModal> {
  late TextEditingController _titleController;
  late TextEditingController _lrcController;

  @override
  void initState() {
    super.initState();
    // Limpieza agresiva de strings comerciales de YouTube
    String cleanTitle = widget.initialTitle
        .replaceAll(RegExp(r'\(.*?\)'), '')
        .replaceAll(RegExp(r'\[.*?\]'), '')
        .replaceAll(RegExp(r'official video', caseSensitive: false), '')
        .replaceAll(RegExp(r'official audio', caseSensitive: false), '')
        .replaceAll(RegExp(r'lyric video', caseSensitive: false), '')
        .trim();

    _titleController = TextEditingController(text: cleanTitle);
    _lrcController = TextEditingController(text: widget.initialLrc);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _lrcController.dispose();
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
      title: const Text(
        "Laboratorio Pre-Ingesta",
        style: TextStyle(color: Color(0xFF00FFFF), fontWeight: FontWeight.bold),
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
          onPressed: () => Navigator.pop(context, null),
          child: const Text(
            "Descartar Descarga",
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
        ElevatedButton.icon(
          onPressed: () {
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
