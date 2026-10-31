import 'dart:io';
import 'dart:convert';
import 'package:gatomix/core/brand_paths.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/core/pipeline_controller.dart';
import 'package:gatomix/core/lab_quarantine.dart' as labq;
import 'package:gatomix/core/id3_names.dart';
import 'package:gatomix/core/lyric_files.dart';
import 'package:gatomix/core/lyric_match.dart';
import 'package:gatomix/core/track_name_clean.dart';
import 'package:gatomix/djiphone/iphone_library.dart';
import 'package:gatomix/services/id3_title_artist.dart';
import 'package:gatomix/services/karaoke_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../../core/net/safe_download.dart';

import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;
import '../../providers/metadata_provider.dart';
import '../../providers/dsp_provider.dart';
import '../../providers/db_provider.dart';
import '../../providers/nlp_provider.dart';
import '../../providers/directory_provider.dart';
import '../../providers/theme_provider.dart';
import 'lab_lyric_search.dart';
import 'lab_preview_player.dart';

class LabWorkspace extends ConsumerStatefulWidget {
  const LabWorkspace({super.key});

  @override
  ConsumerState<LabWorkspace> createState() => _LabWorkspaceState();
}

/// Valor interno del selector de carpetas que significa "Todas".
/// Alto mínimo del panel derecho del LAB (arsenal + editor de .lrc).
const double kLabRightPanelMinHeight = 600;

const String kLabAllFolders = '\u0000todas';

/// Carpeta de origen (la que contenía el archivo) según el registro del LAB.
String labOriginFolderOf(dynamic registryValue) {
  final originalPath = registryValue is Map
      ? (registryValue['originalPath']?.toString() ?? '')
      : registryValue.toString();
  if (originalPath.isEmpty || originalPath == 'Origen desconocido') {
    return 'Cuarentena';
  }
  final parts = originalPath
      .replaceAll('\\', '/')
      .split('/')
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length >= 2) return parts[parts.length - 2];
  return 'Cuarentena';
}

/// Encabezado de grupo en la lista "Todas" del LAB.
class LabFolderHeader {
  final String name;
  final int count;
  const LabFolderHeader(this.name, this.count);
}

/// Todas las canciones agrupadas por carpeta de origen: cada grupo empieza
/// con un [LabFolderHeader] (con su contador) seguido de sus entradas.
/// Carpetas y canciones van en orden alfabético.
List<Object> labGroupedRows(List<MapEntry<String, dynamic>> entries) {
  final groups = <String, List<MapEntry<String, dynamic>>>{};
  for (final e in entries) {
    groups.putIfAbsent(labOriginFolderOf(e.value), () => []).add(e);
  }
  final names = groups.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  final rows = <Object>[];
  for (final n in names) {
    final list = groups[n]!
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    rows.add(LabFolderHeader(n, list.length));
    rows.addAll(list);
  }
  return rows;
}

class _LabWorkspaceState extends ConsumerState<LabWorkspace> {
  String _labPath = '';
  Map<String, dynamic> _registry = {};
  bool _isLoading = true;
  bool _labTabShown = true;

  String? _selectedFileForEdit;
  String? _selectedOriginFolder;
  final TextEditingController _lrcController = TextEditingController();
  final TextEditingController _searchQueryController = TextEditingController();
  final TextEditingController _ytUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initLabEnvironment();
  }

  @override
  void dispose() {
    _lrcController.dispose();
    _editorLyricScroll.dispose();
    _searchQueryController.dispose();
    _ytUrlController.dispose();
    super.dispose();
  }

  void _initLabEnvironment() {
    final labDir = Directory(labFolder(_musicBase()));
    if (!labDir.existsSync()) {
      labDir.createSync(recursive: true);
    }

    _labPath = labDir.path;
    _loadRegistry();
  }

  void _loadRegistry() {
    final registryFile = File(
      '$_labPath${Platform.pathSeparator}quarantine_registry.json',
    );
    if (registryFile.existsSync()) {
      try {
        _registry = jsonDecode(registryFile.readAsStringSync());
      } catch (_) {
        _registry = {};
      }
    } else {
      _registry = {};
    }

    _registry = labq.rescanLabRegistry(_labPath, _registry);

    registryFile.writeAsStringSync(jsonEncode(_registry));

    setState(() => _isLoading = false);
  }

  void _loadLrcForEdit(String fileName) {
    // Al cambiar de canción, la búsqueda escrita para la anterior no sirve.
    if (fileName != _selectedFileForEdit) _searchQueryController.clear();
    try {
      final lrcFileName = fileName.replaceAll(
        RegExp(r'\.(mp3|m4a|webm|wav|flac)$', caseSensitive: false),
        '.lrc',
      );

      String baseMusicPath = _musicBase();

      final labDir = Directory(labFolder(baseMusicPath));
      final lrcFile = File(
        '${labDir.path}${Platform.pathSeparator}$lrcFileName',
      );

      if (lrcFile.existsSync()) {
        final content = lrcFile.readAsStringSync(encoding: utf8);
        setState(() {
          _selectedFileForEdit = fileName;
          _lrcController.text = content;
        });
      } else {
        setState(() {
          _selectedFileForEdit = fileName;
          _lrcController.text = "";
        });
      }
    } catch (e) {
      debugPrint("🔴 Error cargando LRC en UI: $e");
      setState(() {
        _selectedFileForEdit = fileName;
        _lrcController.text = "Error cargando archivo .lrc: $e";
      });
    }
  }

  String _musicBase() {
    if (Platform.isWindows) {
      final String? userProfile = Platform.environment['USERPROFILE'];
      return userProfile != null ? '$userProfile\\Music' : 'C:\\Music';
    }
    if (Platform.isIOS && IphoneLibrary.musicRoot.isNotEmpty) {
      return IphoneLibrary.musicRoot;
    }
    if (Platform.isMacOS || Platform.isLinux) {
      return '${Platform.environment['HOME']}/Music';
    }
    if (Platform.isAndroid) return '/storage/emulated/0/Music';
    final String? home = Platform.environment['HOME'];
    return home != null ? '$home/Music' : '/tmp/Music';
  }

  String _lrcPathOf(String fileName) {
    return lrcPathForAudio('$_labPath${Platform.pathSeparator}$fileName');
  }

  void _saveLrc() {
    if (_selectedFileForEdit == null) return;
    final lrcFile = File(_lrcPathOf(_selectedFileForEdit!));
    keepOriginalLrcBakSync(lrcFile.path);
    lrcFile.writeAsStringSync(_lrcController.text);
    notifyLrcChanged('$_labPath${Platform.pathSeparator}$_selectedFileForEdit');

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("✅ Letra sincronizada (.lrc) guardada en disco."),
        duration: Duration(seconds: 10),
        persist: false,
        backgroundColor: Color(0xFF39FF14),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _restoreFile(String fileName, dynamic registryValue) async {
    try {
      // 🛠️ FIX: Extracción tolerante para soportar JSON Enriquecido o Strings legacy
      String originalPath = registryValue is Map
          ? (registryValue['originalPath']?.toString() ?? '')
          : registryValue.toString();

      if (originalPath.isEmpty || originalPath.contains('Origen Desconocido')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "🔴 ERROR: Ruta original desconocida. Muévelo manualmente.",
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      final file = File('$_labPath${Platform.pathSeparator}$fileName');
      if (file.existsSync()) {
        final targetDir = Directory(File(originalPath).parent.path);
        if (!targetDir.existsSync()) targetDir.createSync(recursive: true);

        final labq.LabReturn back = labq.restoreCompanionsToSync(
          labAudio: file.path,
          originAudio: originalPath,
        );
        if (back.blocked) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  "⚠️ En el origen ya existe un archivo con ese nombre: no se sobrescribe. $fileName sigue en el LAB.",
                ),
                duration: const Duration(seconds: 10),
                backgroundColor: Colors.orangeAccent,
              ),
            );
          }
          return;
        }

        final LabLrcRestore lrcMove = back.lrcKeptAtOrigin
            ? LabLrcRestore.keptOrigin
            : LabLrcRestore.moved;
        notifyLrcChanged(originalPath);

        _registry.remove(fileName);
        final registryFile = File(
          '$_labPath${Platform.pathSeparator}quarantine_registry.json',
        );
        registryFile.writeAsStringSync(jsonEncode(_registry));

        if (_selectedFileForEdit == fileName) {
          _selectedFileForEdit = null;
          _lrcController.clear();
          _searchQueryController.clear();
        }

        _loadRegistry();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                lrcMove == LabLrcRestore.keptOrigin
                    ? "✅ Restaurado: $fileName. En origen ya había .lrc: no se tocó y la letra del LAB quedó en el LAB."
                    : "✅ Restaurado: $fileName a su origen.",
              ),
              duration: const Duration(seconds: 10),
              persist: false,
              backgroundColor: const Color(0xFF39FF14),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("🔴 Error de I/O restaurando: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "🔴 No se pudo restaurar $fileName; queda en el LAB. $e",
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _deleteFile(String fileName) {
    try {
      final file = File('$_labPath${Platform.pathSeparator}$fileName');
      if (file.existsSync()) file.deleteSync();

      // .lrc y .lrc.bak, para cualquier extensión de audio.
      deleteLrcSidecarsSync('$_labPath${Platform.pathSeparator}$fileName');

      _registry.remove(fileName);
      final registryFile = File(
        '$_labPath${Platform.pathSeparator}quarantine_registry.json',
      );
      registryFile.writeAsStringSync(jsonEncode(_registry));

      if (_selectedFileForEdit == fileName) {
        _selectedFileForEdit = null;
        _lrcController.clear();
        _searchQueryController.clear();
      }

      _loadRegistry();
    } catch (e) {
      debugPrint("🔴 Error de I/O eliminando: $e");
    }
  }

  Future<void> _openWebBrowser(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri != null) {
      try {
        final bool ok = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (ok) return;
      } catch (_) {}
    }
    if (Platform.isWindows) {
      await Process.run('start', [url], runInShell: true);
    } else if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [url]);
    }
  }

  final ScrollController _editorLyricScroll = ScrollController();
  int _editorPosMs = 0;
  int _editorActive = -1;

  /// Si el .lrc del editor es sincronizado: líneas con la activa resaltada y
  /// auto-scroll según la vista previa. Si es plano, nada (solo suena).
  Widget _editorKaraokeStrip() {
    final lines = parseLyricStampLines(_lrcController.text);
    if (lines.isEmpty) return const SizedBox.shrink();
    final int active = labActiveLine(_lrcController.text, _editorPosMs);
    if (active != _editorActive) {
      _editorActive = active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_editorLyricScroll.hasClients || active < 0) return;
        _editorLyricScroll.animateTo(
          ((active - 1) * 20.0).clamp(
            0,
            _editorLyricScroll.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      });
    }
    return Container(
      height: 64,
      color: Colors.black,
      child: ListView.builder(
        controller: _editorLyricScroll,
        itemExtent: 20,
        itemCount: lines.length,
        itemBuilder: (BuildContext ctx, int i) {
          final bool on = i == active;
          return Text(
            '${labStamp(lines[i].ms)}  ${lines[i].text}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: on ? const Color(0xFF00FFFF) : Colors.white38,
              fontSize: 12,
              fontWeight: on ? FontWeight.bold : FontWeight.normal,
            ),
          );
        },
      ),
    );
  }

  Future<void> _openLyricSearch() async {
    if (_selectedFileForEdit == null) return;
    final String audio =
        '$_labPath${Platform.pathSeparator}$_selectedFileForEdit';
    final Id3Names id3 = await loadId3TitleArtist(audio);
    final int sec = ((await _getAudioDurationMs(audio)) / 1000).round();
    final List<LyricIdentity> ids = lyricIdentities(
      path: audio,
      id3Artist: id3.artist,
      id3Title: id3.title,
      id3Album: id3.album,
      durationSec: sec,
    );
    final LyricIdentity id = ids.first;
    // Artista y título del diálogo: siempre de la canción seleccionada.
    final LabDialogNames names = labDialogNames(
      fileName: _selectedFileForEdit!,
      id3Artist: id3.artist,
      id3Title: id3.title,
    );
    if (!mounted) return;
    final LyricSearchResult? result = await showDialog<LyricSearchResult>(
      context: context,
      builder: (BuildContext ctx) => LabLyricSearch(
        audioPath: audio,
        key: ValueKey<String>(audio),
        artist: names.artist,
        title: names.title,
        durationSec: sec,
        medley: id.medley,
        fileQuery: cleanTrackFileName(_selectedFileForEdit!).stem,
      ),
    );
    if (result == null || !mounted) return;
    final String lrcPath = _lrcPathOf(_selectedFileForEdit!);
    final bool hadBak = await commitLyricSearch(
      ref: ref,
      lrcPath: lrcPath,
      result: result,
    );
    notifyLrcChanged(audio);
    // El editor muestra lo que quedó escrito en disco, completo.
    String written = result.text;
    try {
      written = await File(lrcPath).readAsString();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _lrcController.text = written;
      _lrcController.selection = const TextSelection.collapsed(offset: 0);
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.noLyric
              ? 'Marcada sin letra. El proceso automático no la reintenta.'
              : hadBak
              ? 'Letra aplicada. La original (previa al LAB) sigue en .lrc.bak.'
              : 'Letra aplicada.',
        ),
        backgroundColor: Colors.orangeAccent,
        duration: const Duration(seconds: 10),
        persist: false,
        action: SnackBarAction(
          label: 'Deshacer',
          textColor: Colors.black,
          onPressed: () async {
            final bool ok = await undoAppliedLrc(lrcPath);
            if (ok) notifyLrcChanged(audio);
            if (!ok || !mounted) return;
            final File f = File(lrcPath);
            if (!f.existsSync()) {
              await ref.read(nlpWorkerProvider).forgetLyricMark(lrcPath);
            }
            if (!mounted) return;
            setState(() {
              _lrcController.text = f.existsSync() ? f.readAsStringSync() : '';
            });
          },
        ),
      ),
    );
  }

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
    } catch (_) {}
  }

  void _reportRescueIssue(String message, String logDir) {
    debugPrint('🔴 [LAB RESCATE] $message');
    GatomixLog.append(logDir, 'LAB RESCATE $message');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🔴 $message'),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _scheduleRescueDelivery({
    required String audioPath,
    required String originDir,
    required bool heavy,
  }) {
    Future<void>(() async {
      var includeKaraoke = false;
      if (!heavy) {
        try {
          final int done = await KaraokeEngine.run(audioPath);
          final String karaoke = KaraokeEngine.karaokePathFor(audioPath);
          includeKaraoke = done > 0 && File(karaoke).existsSync();
          if (!includeKaraoke) {
            _reportRescueIssue(
              'Karaoke no quedó listo: $audioPath',
              File(audioPath).parent.path,
            );
          }
        } catch (e) {
          _reportRescueIssue('Karaoke falló: $e', File(audioPath).parent.path);
        }
      }
      try {
        labq.deliverRescuedTrackSync(
          audioPath,
          originDir,
          includeKaraoke: includeKaraoke,
        );
      } catch (e) {
        _reportRescueIssue(
          'No se pudo enviar al origen: $e',
          File(audioPath).parent.path,
        );
      }
    });
  }

  Future<void> _rescueLabTrackFromYoutube(
    String url,
    String targetOriginalPath,
  ) async {
    if (Platform.isAndroid || Platform.isIOS) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '🔴 VETO TÉCNICO: La extracción nativa (yt-dlp) requiere binarios de escritorio. No disponible en móvil.',
            ),
            backgroundColor: Colors.redAccent,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final ValueNotifier<String> statusNotifier = ValueNotifier<String>(
      "Iniciando conexión...",
    );

    debugPrint("🟢 [LAB TRACKER START] Rescate solicitado para: $url");
    debugPrint("🟢 [LAB TRACKER START] Target Original: $targetOriginalPath");

    try {
      final testFile = File(targetOriginalPath);
      if (testFile.existsSync()) {
        final raf = testFile.openSync(mode: FileMode.append);
        raf.closeSync();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "🔴 ERROR I/O: El archivo está reproduciéndose. Libéralo del reproductor primero.",
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Colors.redAccent),
          borderRadius: BorderRadius.circular(8),
        ),
        content: Row(
          children: [
            const CircularProgressIndicator(color: Colors.redAccent),
            const SizedBox(width: 20),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: statusNotifier,
                builder: (context, value, child) => Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFamily: 'Consolas',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      final tempDir = Directory.systemTemp;

      String ytdlpPath = 'yt-dlp';
      if (Platform.isWindows) {
        ytdlpPath = '${tempDir.path}${Platform.pathSeparator}yt-dlp.exe';
      } else if (Platform.isMacOS) {
        if (File('/opt/homebrew/bin/yt-dlp').existsSync()) {
          ytdlpPath = '/opt/homebrew/bin/yt-dlp';
        } else if (File('/usr/local/bin/yt-dlp').existsSync())
          ytdlpPath = '/usr/local/bin/yt-dlp';
      }

      final tempAudioPrefix =
          '${tempDir.path}${Platform.pathSeparator}lab_rescue_temp';

      debugPrint("🟢 [LAB TRACKER I/O] Directorio Temp: ${tempDir.path}");

      try {
        final existingFiles = tempDir.listSync().where(
          (f) => f.path.startsWith(tempAudioPrefix),
        );
        for (var f in existingFiles) {
          f.deleteSync();
        }
      } catch (_) {}

      if (Platform.isWindows && !File(ytdlpPath).existsSync()) {
        statusNotifier.value = "Descargando motor extractor yt-dlp...";
        await downloadFileRobust(
          'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
          ytdlpPath,
        );
      }

      statusNotifier.value =
          "1/6. Descargando stream crudo nativo (Bypass DRM)...";

      final process = await Process.start(
        ytdlpPath,
        ytDlpRedownloadArgs(output: '$tempAudioPrefix.%(ext)s', url: url),
      );

      String errorTrace = "";
      process.stdout.listen((_) {});
      process.stderr.listen((bytes) {
        errorTrace += String.fromCharCodes(bytes);
      });

      final exitCode = await process.exitCode;

      File? downloadedFile;
      try {
        final files = tempDir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.startsWith(tempAudioPrefix) &&
                  !f.path.endsWith('.lrc'),
            )
            .toList();
        if (files.isNotEmpty) downloadedFile = files.first;
      } catch (_) {}

      if (exitCode == 0 &&
          downloadedFile != null &&
          downloadedFile.existsSync()) {
        final ext = downloadedFile.path.split('.').last;
        statusNotifier.value = "2/6. Sobrescritura Atómica en Laboratorio...";

        final baseOriginalName = targetOriginalPath.replaceAll(
          RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
          '',
        );
        final newTargetFile = '$baseOriginalName.$ext';
        final targetOriginalFile = File(targetOriginalPath);
        final newFile = File(newTargetFile);
        final targetLrcFile = File('$baseOriginalName.lrc');

        await downloadedFile.copy(newFile.path);
        await downloadedFile.delete();

        if (targetOriginalPath != newTargetFile &&
            targetOriginalFile.existsSync()) {
          try {
            targetOriginalFile.deleteSync();
          } catch (_) {}
        }
        try {
          labq.deleteStaleKaraokeSync(newTargetFile);
        } catch (e) {
          debugPrint("🔴 [LAB RESCATE] No se pudo borrar el _K viejo: $e");
        }

        // El .lrc.bak se escribe una sola vez (original o marcador
        // [gmx_no_original:1]); un .bak existente no se pisa.
        if (stashLrcBeforeRedownloadSync(targetLrcFile.path)) {
          debugPrint("🟢 [LAB TRACKER FS] La letra vieja queda en .lrc.bak.");
        }

        String finalPath = newFile.path;

        statusNotifier.value = "3/6. Limpieza Metadata...";
        finalPath = await ref
            .read(metadataWorkerProvider)
            .processSingleFile(finalPath);

        // 🧠 LÓGICA DE BYPASS POR PESO FÍSICO (REMIX/MEGAMIX)
        final double fileSizeMB = File(finalPath).lengthSync() / (1024 * 1024);
        final bool isHeavyMix = fileSizeMB > 16.0;

        if (isHeavyMix) {
          debugPrint(
            "🟢 [LAB TRACKER] Track pesado/Remix detectado (${fileSizeMB.toStringAsFixed(1)}MB). Omitiendo NLP.",
          );
          statusNotifier.value =
              "⏭️ Mix pesado. Omitiendo Scraping de Letras...";
          await Future.delayed(const Duration(seconds: 1));
        } else {
          statusNotifier.value = "3/6. Scraping LRCLIB (NLP)...";
          debugPrint("🟢 [LAB TRACKER NLP] Invocando LRCLIB Prioritario...");
          await ref.read(nlpWorkerProvider).processSingleFile(finalPath);

          if (!targetLrcFile.existsSync()) {
            debugPrint(
              "⚠️ [LAB TRACKER NLP] Sin éxito. Usando Fallback VTT...",
            );
            statusNotifier.value = "⚠️ Extrayendo subtítulos de YouTube...";
            try {
              final yt = YoutubeExplode();
              final videoId = VideoId(url);
              final manifest = await yt.videos.closedCaptions.getManifest(
                videoId,
              );

              if (manifest.tracks.isNotEmpty) {
                ClosedCaptionTrackInfo? selectedTrack;
                for (var lang in ['es', 'en']) {
                  try {
                    selectedTrack = manifest.tracks.firstWhere(
                      (t) =>
                          t.language.code.toLowerCase().contains(lang) &&
                          !t.isAutoGenerated,
                    );
                    break;
                  } catch (_) {}
                }
                selectedTrack ??= manifest.tracks.firstWhere(
                  (t) => t.language.code.toLowerCase().contains('es'),
                  orElse: () => manifest.tracks.first,
                );

                final track = await yt.videos.closedCaptions.get(selectedTrack);
                final lrcBuffer = StringBuffer();

                for (var caption in track.captions) {
                  final start = caption.offset;
                  final min = start.inMinutes.toString().padLeft(2, '0');
                  final sec = (start.inSeconds % 60).toString().padLeft(2, '0');
                  final ms = ((start.inMilliseconds % 1000) ~/ 10)
                      .toString()
                      .padLeft(2, '0');

                  final text = caption.text
                      .replaceAll('\n', ' ')
                      .replaceAll(RegExp(r'<[^>]*>'), '')
                      .trim();
                  final lowerText = text.toLowerCase();
                  final normalizedText = lowerText
                      .replaceAll('ú', 'u')
                      .replaceAll('í', 'i')
                      .replaceAll('ó', 'o');
                  bool isGarbage = false;

                  if (normalizedText.contains(
                    RegExp(
                      r'\[musica\]|\(musica\)|\[aplausos\]|\(aplausos\)|instrumental|♪|🎵',
                    ),
                  )) {
                    isGarbage = true;
                  }
                  if (normalizedText.startsWith('[') &&
                      normalizedText.endsWith(']')) {
                    isGarbage = true;
                  }
                  if (normalizedText.startsWith('(') &&
                      normalizedText.endsWith(')')) {
                    isGarbage = true;
                  }

                  final alphaNumOnly = lowerText.replaceAll(
                    RegExp(r'[^a-z0-9]'),
                    '',
                  );
                  if (alphaNumOnly.length <= 2) isGarbage = true;

                  if (!isGarbage && text.isNotEmpty) {
                    lrcBuffer.writeln('[$min:$sec.$ms]$text');
                  }
                }
                if (lrcBuffer.isNotEmpty) {
                  final int durSec =
                      ((await _getAudioDurationMs(finalPath)) / 1000).round();
                  final String vtt = lrcBuffer.toString();
                  if (durSec > 0 && lrcEndsWithAudio(vtt, durSec)) {
                    await targetLrcFile.writeAsString(vtt);
                    debugPrint(
                      "🟢 [LAB TRACKER I/O] Letra VTT generada y blindada.",
                    );
                  } else {
                    debugPrint(
                      "⚠️ [LAB TRACKER NLP] VTT fuera de la duración, no se usa.",
                    );
                  }
                }
              }
              yt.close();
            } catch (e) {
              debugPrint("⚠️ [LAB TRACKER NLP] Fallo en Fallback YouTube: $e");
            }
          }
        }

        statusNotifier.value =
            "4/6. Aplicando Auto-Trim C++ (Cortando silencios)...";
        final durationBeforeMs = await _getAudioDurationMs(finalPath);
        await ref.read(dspWorkerProvider).processSingleFile(finalPath);
        final durationAfterMs = await _getAudioDurationMs(finalPath);

        statusNotifier.value =
            "5/6. Compensación del Vector de Tiempo (LRC)...";
        final trimmedMs = durationBeforeMs - durationAfterMs;
        debugPrint("🟢 [LAB TRACKER DSP] Audio cortado en: $trimmedMs ms");

        if (trimmedMs > 50) {
          final lrcToPatch = finalPath.replaceAll(
            RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
            '.lrc',
          );
          await _offsetLrcTimeline(lrcToPatch, trimmedMs);
        }

        statusNotifier.value = "6/6. Indexando en Base de Datos ISAR...";
        await rust_dsp.injectWatermark(inputPath: finalPath);
        final rawGenre = await rust_dsp.readAudioGenre(inputPath: finalPath);
        await ref
            .read(dbServiceProvider)
            .saveTrackMetadata(
              path: finalPath,
              mixProfile: 'constant_power',
              durationMs: 6000,
              genre: rawGenre,
              cueInMs: 0,
              mixOutMs: null,
            );
        await ref
            .read(dspWorkerProvider)
            .generateStaticBpmCache(Directory(finalPath).parent.path);

        final oldFileName = targetOriginalPath
            .split(Platform.pathSeparator)
            .last;
        final finalFileName = finalPath.split(Platform.pathSeparator).last;

        if (oldFileName != finalFileName &&
            _registry.containsKey(oldFileName)) {
          final originalOrigin = _registry[oldFileName];
          _registry.remove(oldFileName);

          if (originalOrigin is Map) {
            originalOrigin['originalPath'] = originalOrigin['originalPath']
                ?.toString()
                .replaceAll(
                  RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
                  '.$ext',
                );
            _registry[finalFileName] = originalOrigin;
          } else {
            final newOrigin = originalOrigin.toString().replaceAll(
              RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
              '.$ext',
            );
            _registry[finalFileName] = newOrigin;
          }

          File(
            '$_labPath${Platform.pathSeparator}quarantine_registry.json',
          ).writeAsStringSync(jsonEncode(_registry));

          if (_selectedFileForEdit == oldFileName) {
            _selectedFileForEdit = finalFileName;
          }
        }

        _loadRegistry();
        _loadLrcForEdit(finalFileName);

        // Karaoke nuevo en segundo plano; al terminar (o si falla) los
        // archivos vuelven a la carpeta original sin pisar.
        _scheduleRescueDelivery(
          audioPath: finalPath,
          originDir: File(targetOriginalPath).parent.path,
          heavy: isHeavyMix,
        );

        if (mounted) {
          Navigator.pop(context);
          _ytUrlController.clear();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isHeavyMix
                    ? '✅ Rescate completado (Karaoke omitido por peso).'
                    : '✅ Rescate listo. 🤖 Generando Karaoke en fondo...',
              ),
              backgroundColor: const Color(0xFF39FF14),
            ),
          );
        }
      } else {
        throw Exception(
          "CLI Exit $exitCode | Traza: ${errorTrace.isNotEmpty ? errorTrace : 'Archivo físico no generado.'}",
        );
      }
    } catch (e) {
      debugPrint("🔴 [LAB TRACKER FATAL] $e");
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🔴 Fallo de Rescate: $e'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------
  // 🛠️ WIDGETS DE RENDERIZADO MODULAR
  // ---------------------------------------------------------

  Widget _buildDiagnosticCard(Map<String, dynamic> telemetryData) {
    final errorCode = telemetryData['errorCode'] ?? 'UNKNOWN';
    final msg = telemetryData['errorMsg'] ?? 'Error desconocido';
    final action =
        telemetryData['recommendedAction'] ?? 'Revise manualmente el archivo.';
    final stage = telemetryData['failedAtStage'] ?? 'N/A';

    Color badgeColor = Colors.redAccent;
    IconData badgeIcon = Icons.error_outline;

    if (errorCode == 'ERR_TIMEOUT') {
      badgeColor = Colors.orangeAccent;
      badgeIcon = Icons.thermostat;
    } else if (errorCode == 'ERR_CODEC') {
      badgeColor = Colors.purpleAccent;
      badgeIcon = Icons.broken_image;
    } else if (errorCode == 'ERR_FILE_IO') {
      badgeColor = Colors.yellowAccent;
      badgeIcon = Icons.lock_outline;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 15),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.1),
        border: Border.all(color: badgeColor.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(badgeIcon, color: badgeColor, size: 20),
              const SizedBox(width: 10),
              Text(
                "Diagnóstico de Falla: $errorCode",
                style: TextStyle(
                  color: badgeColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  "Stage: $stage",
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontFamily: 'Consolas',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            msg,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontFamily: 'Consolas',
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb, color: Colors.yellow, size: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Recomendación: $action",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderPanel(
    List<String> folders,
    String? selectedFolder,
    Map<String, int> counts,
    bool isMobile,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: isMobile ? 4 : 8,
            ),
            color: GatoMixTheme.bgPanel,
            child: Row(
              children: [
                Icon(
                  Icons.folder_open,
                  size: isMobile ? 14 : 16,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Explorador",
                    style: TextStyle(
                      color: Colors.orangeAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: isMobile ? 11 : 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: folders.isEmpty
                ? const Center(
                    child: Text(
                      "Sin carpetas en cuarentena.",
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: folders.length + 1,
                    itemBuilder: (context, index) {
                      final name = index == 0
                          ? kLabAllFolders
                          : folders[index - 1];
                      final isAll = name == kLabAllFolders;
                      final label = isAll ? 'Todas' : name;
                      final count = isAll
                          ? counts.values.fold<int>(0, (a, b) => a + b)
                          : (counts[name] ?? 0);
                      final active = name == selectedFolder;
                      return ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        selected: active,
                        selectedTileColor: Colors.orangeAccent.withValues(
                          alpha: 0.12,
                        ),
                        leading: Icon(
                          isAll ? Icons.library_music : Icons.folder,
                          size: 18,
                          color: active ? Colors.orangeAccent : Colors.white38,
                        ),
                        title: Text(
                          label,
                          style: TextStyle(
                            color: active
                                ? Colors.orangeAccent
                                : Colors.white70,
                            fontSize: isMobile ? 11 : 12,
                            fontWeight: active
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          '$count',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontFamily: 'Consolas',
                            fontSize: 11,
                          ),
                        ),
                        onTap: () {
                          setState(() {
                            _selectedOriginFolder = name;
                            _selectedFileForEdit = null;
                          });
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _originFolderOf(dynamic registryValue) =>
      labOriginFolderOf(registryValue);

  Widget _buildLeftPanel(List<Object> entries, bool isMobile) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final row = entries[index];
          if (row is LabFolderHeader) {
            return Container(
              color: GatoMixTheme.bgPanel,
              padding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: isMobile ? 4 : 6,
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder,
                    size: 16,
                    color: Colors.orangeAccent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      row.name,
                      style: TextStyle(
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: isMobile ? 11 : 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${row.count}',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontFamily: 'Consolas',
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            );
          }
          final entry = row as MapEntry<String, dynamic>;
          final fileName = entry.key;
          final registryValue = entry.value;
          final isSelected = _selectedFileForEdit == fileName;

          // 🛠️ FIX: Extracción tolerante de la ruta original
          final originalPath = registryValue is Map
              ? (registryValue['originalPath']?.toString() ??
                    'Origen desconocido')
              : registryValue.toString();

          final hasTelemetry =
              registryValue is Map && registryValue.containsKey('errorCode');

          return Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.orangeAccent.withValues(alpha: 0.1)
                  : Colors.transparent,
              border: const Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: ListTile(
              onTap: () => _loadLrcForEdit(fileName),
              leading: Icon(
                hasTelemetry ? Icons.healing : Icons.audio_file,
                color: isSelected
                    ? Colors.orangeAccent
                    : (hasTelemetry ? Colors.redAccent : Colors.white38),
              ),
              title: Text(
                fileName,
                style: TextStyle(
                  color: isSelected ? Colors.orangeAccent : Colors.white,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: isMobile ? 12 : 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                "Origen: ${originalPath.split(Platform.pathSeparator).reversed.skip(1).take(2).toList().reversed.join('/')}",
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: isMobile ? 9 : 10,
                  fontFamily: 'Consolas',
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white54),
                color: const Color(0xFF1A1A1A),
                onSelected: (value) {
                  if (value == 'restore') _restoreFile(fileName, registryValue);
                  if (value == 'delete') _deleteFile(fileName);
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.restore, color: Color(0xFF39FF14), size: 18),
                        SizedBox(width: 10),
                        Text(
                          'Restaurar a Origen',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_forever,
                          color: Colors.redAccent,
                          size: 18,
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Destruir Archivos',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRightPanel(bool isMobile) {
    if (_selectedFileForEdit == null) {
      return Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF121212),
          border: Border.all(color: Colors.white10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          "Selecciona una pista para abrir el instrumental del Laboratorio.",
          style: TextStyle(color: Colors.white38),
          textAlign: TextAlign.center,
        ),
      );
    }

    final registryValue = _registry[_selectedFileForEdit];
    final bool hasTelemetry = registryValue is Map;

    // En pantallas bajas (celular horizontal) el editor quedaba de 1 línea
    // y solo se veía `[gmx_plain:1]`: el panel pasa a scroll con alto mínimo.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final Widget panel = _buildRightPanelBody(
          isMobile,
          hasTelemetry,
          registryValue,
        );
        if (!box.hasBoundedHeight || box.maxHeight >= kLabRightPanelMinHeight) {
          return panel;
        }
        return SingleChildScrollView(
          child: SizedBox(height: kLabRightPanelMinHeight, child: panel),
        );
      },
    );
  }

  Widget _buildRightPanelBody(
    bool isMobile,
    bool hasTelemetry,
    dynamic registryValue,
  ) {
    return Column(
      children: [
        // 🛠️ INYECCIÓN: Tarjeta de Diagnóstico Activa si hay Telemetría DLQ
        if (hasTelemetry)
          _buildDiagnosticCard(Map<String, dynamic>.from(registryValue)),

        Container(
          padding: EdgeInsets.all(isMobile ? 6 : 15),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(
              color: Colors.orangeAccent.withValues(alpha: 0.5),
            ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(8),
              topRight: Radius.circular(8),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Arsenal de Búsqueda y Sincronización",
                style: TextStyle(
                  color: Colors.orangeAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: isMobile ? 11 : 12,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchQueryController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: Colors.black,
                        hintText: "Nombre de canción para buscar letra...",
                        hintStyle: TextStyle(color: Colors.white38),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: _selectedFileForEdit == null
                        ? null
                        : _openLyricSearch,
                    icon: const Icon(Icons.search, size: 16),
                    label: const Text("🔎 Buscar letra"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00FFFF),
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
              SizedBox(height: isMobile ? 4 : 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ytUrlController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: Color(0xFF2A0000),
                        hintText:
                            "Pega el link de YouTube aquí para descargar/sobrescribir...",
                        hintStyle: TextStyle(color: Colors.white38),
                        border: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.redAccent),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.redAccent),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: () {
                      final url = _ytUrlController.text.trim();
                      if (url.startsWith('http')) {
                        // 🛠️ FIX: Extracción tolerante para inyectar la URL al motor yt-dlp
                        final originalPath = registryValue is Map
                            ? (registryValue['originalPath']?.toString() ??
                                  '$_labPath${Platform.pathSeparator}$_selectedFileForEdit')
                            : (registryValue?.toString() ??
                                  '$_labPath${Platform.pathSeparator}$_selectedFileForEdit');

                        _rescueLabTrackFromYoutube(url, originalPath);
                      } else {
                        final q = Uri.encodeComponent(
                          '${_searchQueryController.text} official audio',
                        );
                        _openWebBrowser(
                          'https://www.youtube.com/results?search_query=$q',
                        );
                      }
                    },
                    icon: const Icon(Icons.video_library, size: 16),
                    label: const Text("Reemplazo YouTube"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
              SizedBox(height: isMobile ? 4 : 15),
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      final q = Uri.encodeComponent(
                        _searchQueryController.text,
                      );
                      _openWebBrowser('https://genius.com/search?q=$q');
                    },
                    icon: const Icon(
                      Icons.text_snippet,
                      color: Colors.yellowAccent,
                      size: 14,
                    ),
                    label: const Text(
                      "Genius",
                      style: TextStyle(
                        color: Colors.yellowAccent,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        _openWebBrowser('https://lrc-maker.github.io/'),
                    icon: const Icon(
                      Icons.tap_and_play,
                      color: Color(0xFF39FF14),
                      size: 14,
                    ),
                    label: const Text(
                      "LRC Maker",
                      style: TextStyle(color: Color(0xFF39FF14), fontSize: 11),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      final q = Uri.encodeComponent(
                        _searchQueryController.text,
                      );
                      _openWebBrowser('https://www.musixmatch.com/search/$q');
                    },
                    icon: const Icon(
                      Icons.library_music,
                      color: Colors.pinkAccent,
                      size: 14,
                    ),
                    label: const Text(
                      "Musixmatch",
                      style: TextStyle(color: Colors.pinkAccent, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        Expanded(
          child: Container(
            padding: EdgeInsets.all(isMobile ? 4 : 20),
            decoration: BoxDecoration(
              color: const Color(0xFF121212),
              border: Border(
                left: BorderSide(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                ),
                right: BorderSide(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                ),
                bottom: BorderSide(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                ),
              ),
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (isMobile)
                      IconButton(
                        icon: const Icon(
                          Icons.arrow_back,
                          color: Colors.orangeAccent,
                        ),
                        onPressed: () =>
                            setState(() => _selectedFileForEdit = null),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    if (isMobile) const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Editando LRC: ${_selectedFileForEdit!.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}",
                        style: TextStyle(
                          color: Colors.orangeAccent,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Consolas',
                          fontSize: isMobile ? 11 : 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: _saveLrc,
                      icon: Icon(Icons.save, size: isMobile ? 14 : 18),
                      label: Text(
                        isMobile ? "Guardar" : "Guardar en Disco",
                        style: TextStyle(fontSize: isMobile ? 10 : 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent,
                        foregroundColor: Colors.black,
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: Size(
                          isMobile ? 0 : 64,
                          isMobile ? 28 : 36,
                        ),
                        padding: EdgeInsets.symmetric(
                          horizontal: isMobile ? 8 : 16,
                        ),
                      ),
                    ),
                  ],
                ),
                LabPreviewPlayer(
                  key: ValueKey<String>('lab-prev-$_selectedFileForEdit'),
                  audioPath:
                      '$_labPath${Platform.pathSeparator}$_selectedFileForEdit',
                  compact: isMobile,
                  onPosition: (int ms) {
                    if (_editorPosMs ~/ 200 != ms ~/ 200) {
                      setState(() => _editorPosMs = ms);
                    }
                  },
                ),
                _editorKaraokeStrip(),
                SizedBox(height: isMobile ? 4 : 8),
                Expanded(
                  child: TextField(
                    controller: _lrcController,
                    maxLines: null,
                    expands: true,
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'Consolas',
                      fontSize: isMobile ? 11 : 13,
                    ),
                    decoration: InputDecoration(
                      hintText:
                          "Pega aquí la letra sincronizada (.lrc)...\n\n[00:15.30] Una morena me dijo\n[00:18.45] que la llevara a Jamapa",
                      hintStyle: const TextStyle(color: Colors.white24),
                      filled: true,
                      fillColor: const Color(0xFF0A0A0A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool labShown = TickerMode.valuesOf(context).enabled;
    if (labShown && !_labTabShown && _labPath.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _labTabShown) _loadRegistry();
      });
    }
    _labTabShown = labShown;

    final entries = _registry.entries.toList();
    // Se sigue escuchando la carpeta actual para refrescar el LAB al cambiarla.
    ref.watch(directoryProvider);

    final counts = <String, int>{};
    for (final e in entries) {
      final folder = _originFolderOf(e.value);
      counts[folder] = (counts[folder] ?? 0) + 1;
    }
    final folders = counts.keys.toList()..sort();
    // Por defecto "Todas": el LAB muestra cada canción, agrupada por carpeta.
    final selectedFolder =
        (_selectedOriginFolder != null &&
            (_selectedOriginFolder == kLabAllFolders ||
                folders.contains(_selectedOriginFolder)))
        ? _selectedOriginFolder!
        : kLabAllFolders;
    final List<Object> filtered = selectedFolder == kLabAllFolders
        ? labGroupedRows(entries)
        : entries
              .where((e) => _originFolderOf(e.value) == selectedFolder)
              .toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobile = constraints.maxWidth < 850;
        return Padding(
          padding: EdgeInsets.all(isMobile ? 4.0 : 30.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.science,
                    color: Colors.orangeAccent,
                    size: isMobile ? 20 : 30,
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Text(
                      "Laboratorio de Cuarentena (DLQ)",
                      style: TextStyle(
                        fontSize: isMobile ? 16 : 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.orangeAccent,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (!isMobile) ...[
                const SizedBox(height: 10),
                const Text(
                  "Entorno de aislamiento y manipulación cruda. Extrae, sincroniza o reemplaza audios/letras defectuosas antes de reinyectarlos.",
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 20),
              ] else
                const SizedBox(height: 8),
              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(color: Colors.orangeAccent),
                )
              else
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 2,
                        child: _buildFolderPanel(
                          folders,
                          selectedFolder,
                          counts,
                          isMobile,
                        ),
                      ),
                      SizedBox(width: isMobile ? 6 : 12),
                      Expanded(
                        flex: 3,
                        child: entries.isEmpty
                            ? Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: Colors.black45,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white10),
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text(
                                    "✅ Cuarentena limpia. No hay archivos defectuosos.",
                                    style: TextStyle(
                                      color: Color(0xFF39FF14),
                                      fontSize: 14,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              )
                            : _buildLeftPanel(filtered, isMobile),
                      ),
                      SizedBox(width: isMobile ? 6 : 12),
                      Expanded(flex: 5, child: _buildRightPanel(isMobile)),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
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
