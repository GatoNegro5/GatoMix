import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/bpm_range.dart';
import '../../core/brand_paths.dart';
import '../../djiphone/iphone_library.dart';
import '../../providers/directory_provider.dart';
import '../../providers/automix_provider.dart';
import '../../providers/pipeline_provider.dart';
import '../../providers/theme_provider.dart';

final automixSyncArmedProvider = StateProvider<bool>((ref) => false);

// =====================================================================
// ROUTE 0: UNIFIED DJ WORKSPACE (IDE 3-PANEL REKORDBOX STYLE)
// =====================================================================
class AutomixWorkspace extends ConsumerStatefulWidget {
  const AutomixWorkspace({super.key});

  @override
  ConsumerState<AutomixWorkspace> createState() => _AutomixWorkspaceState();
}

class _AutomixWorkspaceState extends ConsumerState<AutomixWorkspace> {
  final GlobalKey _mixerKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(automixProvider.select((p) => p.isPlaying), (
      previous,
      isPlaying,
    ) {
      if (isPlaying) {
        ref.read(hardwareGovernorProvider.notifier).lockForLivePerformance();
        debugPrint(
          "🔒 [MUTEX] Live DJ Activo: Procesador bloqueado para rendimiento en vivo.",
        );
      } else {
        ref.read(hardwareGovernorProvider.notifier).releaseLock();
        debugPrint(
          "🔓 [MUTEX] Live DJ en Pausa: Liberando núcleos para el Auto-Master.",
        );
      }
    });

    final Widget threeSelectorPanels = Row(
      children: [
        const Expanded(
          flex: 2,
          child: Material(
            color: GatoMixTheme.bgPanel,
            child: LibraryTreePanel(),
          ),
        ),
        const VerticalDivider(width: 1, color: Colors.white10),
        const Expanded(flex: 4, child: FolderContentPanel()),
        const VerticalDivider(width: 1, color: Colors.white10),
        const Expanded(flex: 5, child: AutomixPanel()),
      ],
    );

    final compact = Platform.isAndroid || Platform.isIOS;
    final bool syncArmed = compact && ref.watch(automixSyncArmedProvider);
    return Column(
      children: [
        if (compact)
          syncArmed
              ? Expanded(flex: 8, child: MixerPanel(key: _mixerKey))
              : MixerPanel(key: _mixerKey)
        else
          const Expanded(flex: 5, child: MixerPanel()),
        const Divider(height: 1, color: Colors.white10),
        Expanded(
          flex: compact ? (syncArmed ? 2 : 6) : 5,
          child: threeSelectorPanels,
        ),
      ],
    );
  }
}

// --- COMPONENTE 1: ÁRBOL DE DIRECTORIOS ---
class LibraryTreePanel extends ConsumerStatefulWidget {
  /// Explorador a usar. Null = el de Automix (`directoryProvider`).
  /// Live DJ pasa el suyo para no compartir carpeta ni árbol.
  final NotifierProvider<DirectoryNotifier, DirectoryState>? provider;

  const LibraryTreePanel({super.key, this.provider});

  @override
  ConsumerState<LibraryTreePanel> createState() => _LibraryTreePanelState();
}

class _LibraryTreePanelState extends ConsumerState<LibraryTreePanel> {
  String _rootPath = '';
  List<Directory> _subDirs = [];

  NotifierProvider<DirectoryNotifier, DirectoryState> get _dir =>
      widget.provider ?? directoryProvider;

  @override
  void initState() {
    super.initState();
    _initializeRoot();
  }

  void _initializeRoot() {
    if (Platform.isIOS) {
      _rootPath = IphoneLibrary.musicRoot;
      _loadSubDirs();
      return;
    }
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      _rootPath = userProfile != null ? '$userProfile\\Music' : 'C:\\Music';
    } else if (Platform.isAndroid) {
      _rootPath = '/storage/emulated/0/Music';
    } else if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      _rootPath = home != null ? '$home/Music' : '/';
    } else {
      _rootPath = '/';
    }
    _loadSubDirs();
  }

  void _loadSubDirs() {
    final dir = Directory(_rootPath);
    try {
      if (dir.existsSync()) {
        setState(() {
          _subDirs = dir.listSync().whereType<Directory>().toList()
            ..sort((a, b) => a.path.compareTo(b.path));
        });
      }
    } catch (e) {
      debugPrint(
        "⚠️ [I/O ERROR]: Acceso denegado o ruta inválida en $_rootPath: $e",
      );
      setState(() {
        _subDirs = [];
      });
    }
  }

  Future<void> _changeRootDirectory() async {
    await ref.read(_dir.notifier).loadDirectory();
    final newPath = ref.read(_dir).currentPath;
    if (newPath.isNotEmpty && newPath != _rootPath) {
      setState(() {
        _rootPath = newPath;
        _loadSubDirs();
      });
    }
  }

  Widget _buildFolderNode(Directory dir, int depth, Set<String> expandedPaths) {
    List<Directory> childDirs = [];
    try {
      childDirs = dir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } catch (_) {}

    if (childDirs.isEmpty || depth >= 2) {
      return Material(
        color: Colors.transparent,
        child: ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -4),
          minVerticalPadding: 0,
          contentPadding: EdgeInsets.only(
            left: 15.0 + (depth * 15.0),
            right: 10.0,
          ),
          leading: const Icon(Icons.folder, color: Colors.white54, size: 16),
          title: Text(
            dir.path.replaceAll('\\', '/').split('/').last,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => ref.read(_dir.notifier).scanPath(dir.path),
          hoverColor: Colors.white10,
        ),
      );
    }

    final isExpanded = expandedPaths.contains(dir.path);

    return Theme(
      data: ThemeData(
        dividerColor: Colors.transparent,
        listTileTheme: const ListTileThemeData(
          dense: true,
          visualDensity: VisualDensity(vertical: -4),
          minVerticalPadding: 0,
        ),
      ),
      child: ExpansionTile(
        key: Key('${dir.path}_$isExpanded'),
        initiallyExpanded: isExpanded,
        onExpansionChanged: (expanded) {
          ref.read(_dir.notifier).toggleNode(dir.path, expanded);
        },
        tilePadding: EdgeInsets.only(left: 15.0 + (depth * 15.0), right: 10.0),
        leading: const Icon(
          Icons.folder_open,
          color: Color(0xFF00FFFF),
          size: 16,
        ),
        title: Text(
          dir.path.replaceAll('\\', '/').split('/').last,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        children: childDirs
            .map(
              (childDir) =>
                  _buildFolderNode(childDir, depth + 1, expandedPaths),
            )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final expandedPaths = ref.watch(_dir.select((s) => s.expandedPaths));
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    return Column(
      children: [
        Container(
          padding: EdgeInsets.all(isMobile ? 6.0 : 12.0),
          decoration: const BoxDecoration(
            color: GatoMixTheme.bgPanel,
            border: Border(bottom: BorderSide(color: Colors.white10)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Explorador",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: isMobile ? 11 : 13,
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.add_to_drive,
                  color: const Color(0xFF00FFFF),
                  size: isMobile ? 15 : 18,
                ),
                onPressed: _changeRootDirectory,
                tooltip: "Cambiar Raíz",
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
        Expanded(
          child: _subDirs.isEmpty
              ? const Center(
                  child: Text(
                    "Vacío",
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: _subDirs.length,
                  itemBuilder: (context, index) =>
                      _buildFolderNode(_subDirs[index], 0, expandedPaths),
                ),
        ),
      ],
    );
  }
}

// --- COMPONENTE 2: BROWSER (Contenido Bruto de la Carpeta) ---
class FolderContentPanel extends ConsumerWidget {
  final VoidCallback? onLoaded;

  const FolderContentPanel({super.key, this.onLoaded});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirState = ref.watch(directoryProvider);
    final bpmCache = ref.watch(bpmCacheProvider);
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    ref.listen<String>(directoryProvider.select((d) => d.currentPath), (
      previous,
      next,
    ) {
      if (next != previous) ref.read(bpmCacheProvider.notifier).loadCache(next);
    });

    double getTrackBpm(String filename) {
      double? raw;
      if (bpmCache.containsKey(filename)) {
        raw = bpmCache[filename];
      } else {
        final String slash = filename.replaceAll('\\', '/');
        for (final MapEntry<String, double> entry in bpmCache.entries) {
          final String key = entry.key.replaceAll('\\', '/');
          if (key == slash || key.endsWith('/$slash')) {
            raw = entry.value;
            break;
          }
        }
      }
      if (raw != null && raw > 0) return fixBpmRange(raw) ?? 0.0;
      final match = RegExp(
        r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
        caseSensitive: false,
      ).firstMatch(filename);
      if (match == null) return 0.0;
      return fixBpmRange(double.parse(match.group(1)!)) ?? 0.0;
    }

    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: isMobile ? 4 : 8,
          ),
          color: GatoMixTheme.bgPanel,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  dirState.currentPath.isEmpty
                      ? "Selecciona carpeta..."
                      : dirState.currentPath
                            .replaceAll('\\', '/')
                            .split('/')
                            .last,
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                    fontSize: isMobile ? 11 : 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ElevatedButton.icon(
                onPressed: dirState.files.isEmpty
                    ? null
                    : () {
                        for (var f in dirState.files) {
                          ref
                              .read(playedTracksProvider.notifier)
                              .removeTrack(f.path);
                        }
                        ref
                            .read(automixQueueProvider.notifier)
                            .addAll(dirState.files);
                        onLoaded?.call();
                      },
                icon: Icon(Icons.playlist_add, size: isMobile ? 14 : 16),
                label: Text(
                  "Cargar Todo",
                  style: TextStyle(fontSize: isMobile ? 10 : 11),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white10,
                  foregroundColor: const Color(0xFF39FF14),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: Size(0, isMobile ? 24 : 30),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: dirState.files.isEmpty
              ? const Center(
                  child: Text(
                    "Carpeta vacía o sin MP3.",
                    style: TextStyle(color: Colors.white38),
                  ),
                )
              : ListView.builder(
                  itemCount: dirState.files.length,
                  itemBuilder: (context, index) {
                    final file = dirState.files[index];
                    final fileName = file.uri.pathSegments.last;
                    final bpm = getTrackBpm(fileName);

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: SizedBox(
                          width: 28,
                          child: Text(
                            '${index + 1}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFF00FFFF),
                              fontFamily: 'Consolas',
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          fileName,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              bpm > 0 ? bpm.toStringAsFixed(1) : "---",
                              style: TextStyle(
                                color: bpm > 0
                                    ? const Color(0xFFFF007F)
                                    : Colors.white24,
                                fontFamily: 'Consolas',
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(
                                Icons.add_circle_outline,
                                color: Color(0xFF00FFFF),
                                size: 20,
                              ),
                              onPressed: () {
                                ref
                                    .read(playedTracksProvider.notifier)
                                    .removeTrack(file.path);
                                ref
                                    .read(automixQueueProvider.notifier)
                                    .addTrack(file);
                              },
                              tooltip: "Añadir al Automix",
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// --- COMPONENTE 3: AUTOMIX (AISLADO PARA PERFORMANCE) ---
class AutomixPanel extends ConsumerWidget {
  const AutomixPanel({super.key});

  String _getPlaylistsDir() {
    if (Platform.isIOS) return IphoneLibrary.playlistsDir;
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      return userProfile != null
          ? '$userProfile\\Music\\DjPlaylists'
          : 'C:\\Music\\DjPlaylists';
    } else if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      return home != null ? '$home/Music/DjPlaylists' : '/tmp/DjPlaylists';
    } else {
      return '/storage/emulated/0/Music/DjPlaylists';
    }
  }

  Future<void> _playLocalTrack(
    WidgetRef ref,
    List<String> playlist,
    int index,
  ) async {
    try {
      await ref
          .read(automixProvider.notifier)
          .loadContextAndPlay(playlist, index);
    } catch (e) {
      debugPrint("🔴 [TRACKER ERROR FATAL]: $e");
    }
  }

  Future<void> _saveAutomixQueue(
    BuildContext context,
    List<File> currentQueue,
  ) async {
    if (currentQueue.isEmpty) return;
    try {
      final baseDir = _getPlaylistsDir();
      final dir = Directory(baseDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final dateStr = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;

      final sep = Platform.isWindows ? '\\' : '/';
      final file = File('$baseDir${sep}Set_$dateStr.json');

      final paths = currentQueue.map((f) => f.path).toList();
      await file.writeAsString(jsonEncode({"playlist": paths}));

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lista serializada: Set_$dateStr.json',
              style: const TextStyle(
                color: Color(0xFF39FF14),
                fontFamily: 'Consolas',
                fontSize: 12,
              ),
            ),
            backgroundColor: const Color(0xFF181818),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _loadAutomixQueue(BuildContext context, WidgetRef ref) async {
    try {
      final baseDir = _getPlaylistsDir();
      final dir = Directory(baseDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      if (files.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No existen Playlists guardadas.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              backgroundColor: Colors.black,
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      files.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );

      if (context.mounted) {
        showDialog(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121212),
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Color(0xFFFF007F)),
                borderRadius: BorderRadius.circular(8),
              ),
              title: const Text(
                "Librería de Sets (Playlists)",
                style: TextStyle(
                  color: Color(0xFFFF007F),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              content: SizedBox(
                width: 400,
                height: 400,
                child: ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) {
                    final file = files[index];
                    final fileName = file.path
                        .replaceAll('\\', '/')
                        .split('/')
                        .last
                        .replaceAll('.json', '');
                    final date = file.lastModifiedSync();
                    final dateString =
                        "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        leading: const Icon(
                          Icons.queue_music,
                          color: Color(0xFF39FF14),
                        ),
                        title: Text(
                          fileName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          dateString,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
                            size: 18,
                          ),
                          onPressed: () {
                            file.deleteSync();
                            Navigator.pop(dialogContext);
                            _loadAutomixQueue(context, ref);
                          },
                        ),
                        onTap: () async {
                          try {
                            final content = await file.readAsString();
                            final data =
                                jsonDecode(content) as Map<String, dynamic>;
                            final List<dynamic> rawPaths =
                                data['playlist'] ?? [];
                            final List<String> paths = rawPaths
                                .map((e) => e.toString())
                                .toList();
                            ref
                                .read(automixQueueProvider.notifier)
                                .restoreQueue(paths);
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                          } catch (_) {}
                        },
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text(
                    "Cerrar",
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ],
            );
          },
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTrackPath = ref.watch(
      automixProvider.select((p) => p.currentTrackPath),
    );
    final isPlaying = ref.watch(automixProvider.select((p) => p.isPlaying));
    final durationMs = ref.watch(
      automixProvider.select((p) => p.duration.inMilliseconds),
    );
    final automixNotifier = ref.read(automixProvider.notifier);

    final automixQueue = ref.watch(automixQueueProvider);
    final sortMode = ref.watch(trackSortProvider);
    final mixStrategy = ref.watch(automixProvider.select((p) => p.mixStrategy));
    final playlist = ref.watch(automixProvider.select((p) => p.playlist));
    final playedTracks = ref.watch(playedTracksProvider);
    final bpmCache = ref.watch(bpmCacheProvider);
    final isBusy = ref.watch(pipelineProvider.select((p) => !p.isIdle));
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    ref.listen<String?>(automixProvider.select((p) => p.currentTrackPath), (
      previous,
      next,
    ) {
      if (next != null && !playedTracks.contains(next)) {
        Future.microtask(
          () => ref.read(playedTracksProvider.notifier).addTrack(next),
        );
      }
    });

    List<File> displayFiles = List.from(automixQueue);
    displayFiles.removeWhere(
      (file) =>
          playedTracks.contains(file.path) && file.path != currentTrackPath,
    );

    double getTrackBpm(String filename) {
      double? raw;
      if (bpmCache.containsKey(filename)) {
        raw = bpmCache[filename];
      } else {
        final String slash = filename.replaceAll('\\', '/');
        for (final MapEntry<String, double> entry in bpmCache.entries) {
          final String key = entry.key.replaceAll('\\', '/');
          if (key == slash || key.endsWith('/$slash')) {
            raw = entry.value;
            break;
          }
        }
      }
      if (raw != null && raw > 0) return fixBpmRange(raw) ?? 0.0;
      final match = RegExp(
        r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
        caseSensitive: false,
      ).firstMatch(filename);
      if (match == null) return 0.0;
      return fixBpmRange(double.parse(match.group(1)!)) ?? 0.0;
    }

    if (mixStrategy == MixStrategy.random) {
      final rank = <String, int>{
        for (var i = 0; i < playlist.length; i++) playlist[i]: i,
      };
      displayFiles.sort((a, b) {
        final ia = rank[a.path] ?? 1 << 20;
        final ib = rank[b.path] ?? 1 << 20;
        return ia.compareTo(ib);
      });
    } else if (sortMode == TrackSortMode.alphabetical) {
      displayFiles.sort(
        (a, b) => a.uri.pathSegments.last.toLowerCase().compareTo(
          b.uri.pathSegments.last.toLowerCase(),
        ),
      );
    } else if (sortMode == TrackSortMode.bpmDesc) {
      displayFiles.sort(
        (a, b) => getTrackBpm(
          b.uri.pathSegments.last,
        ).compareTo(getTrackBpm(a.uri.pathSegments.last)),
      );
    } else if (sortMode == TrackSortMode.bpmAsc) {
      displayFiles.sort(
        (a, b) => getTrackBpm(
          a.uri.pathSegments.last,
        ).compareTo(getTrackBpm(b.uri.pathSegments.last)),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isPlaying || currentTrackPath != null) {
        final currentOrderedPaths = displayFiles.map((f) => f.path).toList();
        automixNotifier.syncDynamicPlaylist(currentOrderedPaths);
      }
    });

    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: isMobile ? 4 : 8,
          ),
          color: GatoMixTheme.bgPanel,
          child: Row(
            children: [
              Icon(
                Icons.shuffle,
                color: const Color(0xFFFF007F),
                size: isMobile ? 14 : 18,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  "AUTOMIX (${displayFiles.length})",
                  style: TextStyle(
                    color: const Color(0xFFFF007F),
                    fontWeight: FontWeight.bold,
                    fontSize: isMobile ? 11 : 13,
                    letterSpacing: 1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                flex: 2,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: displayFiles.isEmpty || isBusy
                            ? null
                            : () {
                                final allPaths = displayFiles
                                    .map((f) => f.path)
                                    .toList();
                                _playLocalTrack(ref, allPaths, 0);
                              },
                        icon: Icon(Icons.play_arrow, size: isMobile ? 13 : 16),
                        label: Text(
                          "PLAY",
                          style: TextStyle(
                            fontSize: isMobile ? 9 : 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF007F),
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(
                            horizontal: isMobile ? 6 : 8,
                          ),
                          minimumSize: Size(0, isMobile ? 22 : 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      if (automixQueue.isNotEmpty) ...[
                        IconButton(
                          icon: Icon(
                            Icons.delete_sweep,
                            color: Colors.redAccent,
                            size: isMobile ? 16 : 18,
                          ),
                          onPressed: () => ref
                              .read(automixQueueProvider.notifier)
                              .clearQueue(),
                          tooltip: "Limpiar Cola",
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.save,
                            color: const Color(0xFF00FFFF),
                            size: isMobile ? 16 : 18,
                          ),
                          onPressed: () =>
                              _saveAutomixQueue(context, automixQueue),
                          tooltip: "Guardar Lista en Disco",
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                      IconButton(
                        icon: Icon(
                          Icons.folder_open,
                          color: const Color(0xFF39FF14),
                          size: isMobile ? 16 : 18,
                        ),
                        onPressed: () => _loadAutomixQueue(context, ref),
                        tooltip: "Cargar Lista",
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      PopupMenuButton<TrackSortMode>(
                        initialValue: sortMode,
                        padding: EdgeInsets.zero,
                        iconSize: isMobile ? 16 : 20,
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        icon: Icon(
                          Icons.sort,
                          color: Colors.white70,
                          size: isMobile ? 16 : 20,
                        ),
                        color: GatoMixTheme.bgDark,
                        shape: RoundedRectangleBorder(
                          side: const BorderSide(color: Color(0xFFFF007F)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        tooltip: "Ordenar Automix",
                        onSelected: (mode) => ref
                            .read(trackSortProvider.notifier)
                            .updateMode(mode),
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: TrackSortMode.alphabetical,
                            child: Text(
                              "Alfabético (A-Z)",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          PopupMenuItem(
                            value: TrackSortMode.bpmDesc,
                            child: Text(
                              "BPM (Mayor a Menor)",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          PopupMenuItem(
                            value: TrackSortMode.bpmAsc,
                            child: Text(
                              "BPM (Menor a Mayor)",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: displayFiles.isEmpty
              ? const Center(
                  child: Text(
                    "La cola Automix está vacía.\nAñade pistas o carga una Playlist guardada.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: displayFiles.length,
                  itemBuilder: (context, index) {
                    final file = displayFiles[index];
                    final fileName = file.uri.pathSegments.last;
                    final isPlayingThisTrack = currentTrackPath == file.path;
                    final bpm = getTrackBpm(fileName);

                    return Material(
                      color: isPlayingThisTrack
                          ? GatoMixTheme.deckA.withValues(alpha: 0.15)
                          : Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: Icon(
                          isPlayingThisTrack
                              ? Icons.volume_up
                              : Icons.drag_handle,
                          color: isPlayingThisTrack
                              ? const Color(0xFFFF007F)
                              : Colors.white24,
                          size: 18,
                        ),
                        title: Text(
                          fileName,
                          style: TextStyle(
                            color: isPlayingThisTrack
                                ? const Color(0xFFFF007F)
                                : Colors.white,
                            fontWeight: isPlayingThisTrack
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              bpm > 0 ? bpm.toStringAsFixed(1) : "---",
                              style: TextStyle(
                                color: bpm > 0
                                    ? const Color(0xFFFF007F)
                                    : Colors.white24,
                                fontFamily: 'Consolas',
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (!isPlayingThisTrack)
                              IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.redAccent,
                                  size: 18,
                                ),
                                onPressed: () => ref
                                    .read(automixQueueProvider.notifier)
                                    .removeTrack(file.path),
                                tooltip: "Quitar",
                              ),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                if (isPlayingThisTrack &&
                                    isPlaying &&
                                    durationMs > 0) {
                                  automixNotifier.togglePlayPause();
                                } else {
                                  final allPaths = displayFiles
                                      .map((f) => f.path)
                                      .toList();
                                  _playLocalTrack(ref, allPaths, index);
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(2.0),
                                child: Icon(
                                  (isPlayingThisTrack && isPlaying)
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: const Color(0xFF39FF14),
                                  size: 20,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// --- COMPONENTE: MEZCLADORA (AISLADA PARA PERFORMANCE) ---
class MixerPanel extends ConsumerStatefulWidget {
  const MixerPanel({super.key});

  @override
  ConsumerState<MixerPanel> createState() => _MixerPanelState();
}

class _MixerPanelState extends ConsumerState<MixerPanel> {
  final FixedExtentScrollController _lyricsController =
      FixedExtentScrollController();
  final ScrollController _lyricsListController = ScrollController();
  bool _lyricPickArmed = false;
  int _anchorMode = 1;

  @override
  void dispose() {
    _lyricsController.dispose();
    _lyricsListController.dispose();
    super.dispose();
  }

  double _lyricRowExtent() =>
      Platform.isAndroid || Platform.isIOS ? 22.0 : 28.0;

  void _followArmedList(int index, {required bool animate}) {
    if (!_lyricPickArmed || !mounted) return;
    final int line = index < 0 ? 0 : index;
    final bool ready =
        _lyricsListController.hasClients &&
        _lyricsListController.position.hasContentDimensions;
    if (!ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_lyricPickArmed) return;
        if (!_lyricsListController.hasClients ||
            !_lyricsListController.position.hasContentDimensions) {
          return;
        }
        _jumpArmedList(line, animate);
      });
      return;
    }
    _jumpArmedList(line, animate);
  }

  void _jumpArmedList(int line, bool animate) {
    final position = _lyricsListController.position;
    final double extent = _lyricRowExtent();
    final double raw =
        (line * extent) - (position.viewportDimension / 2) + (extent / 2);
    final double maxExtent = position.maxScrollExtent;
    final double target = raw.clamp(0.0, maxExtent < 0 ? 0.0 : maxExtent);
    if ((position.pixels - target).abs() < 0.5) return;
    if (animate) {
      _lyricsListController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } else {
      _lyricsListController.jumpTo(target);
    }
  }

  void _followCylinder(int index, {required bool animate}) {
    if (_lyricPickArmed || !mounted || index < 0) return;
    if (!_lyricsController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _lyricPickArmed || !_lyricsController.hasClients) {
          return;
        }
        _jumpCylinder(index, animate);
      });
      return;
    }
    _jumpCylinder(index, animate);
  }

  void _jumpCylinder(int index, bool animate) {
    final int count = ref.read(automixProvider).lyrics.length;
    if (count <= 0 || !_lyricsController.hasClients) return;
    final int line = index.clamp(0, count - 1);
    if (_lyricsController.selectedItem == line) return;
    if (animate) {
      _lyricsController.animateToItem(
        line,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } else {
      _lyricsController.jumpToItem(line);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentTrackPath = ref.watch(
      automixProvider.select((s) => s.currentTrackPath),
    );
    final isPlaying = ref.watch(automixProvider.select((s) => s.isPlaying));
    final lyrics = ref.watch(automixProvider.select((s) => s.lyrics));
    final mixStrategy = ref.watch(automixProvider.select((s) => s.mixStrategy));
    final autoMixArmed = ref.watch(
      automixProvider.select((s) => s.autoMixArmed),
    );
    final isRecording = ref.watch(wasapiRecordProvider);
    final automixNotifier = ref.read(automixProvider.notifier);

    final bool canRecord = Platform.isWindows || Platform.isMacOS;

    ref.listen<int>(automixProvider.select((state) => state.activeLyricIndex), (
      previous,
      next,
    ) {
      if (next < 0) {
        if (_lyricPickArmed) {
          _followArmedList(0, animate: false);
        } else {
          _followCylinder(0, animate: false);
        }
        return;
      }
      if (_lyricPickArmed) {
        _followArmedList(next, animate: true);
        return;
      }
      _followCylinder(next, animate: true);
    });

    ref.listen<int>(automixProvider.select((state) => state.lyrics.length), (
      previous,
      next,
    ) {
      if (next <= 0) return;
      if (ref.read(automixProvider).activeLyricIndex >= 0) return;
      if (_lyricPickArmed) {
        _followArmedList(0, animate: false);
      } else {
        _followCylinder(0, animate: false);
      }
    });

    String displayTitle = "Esperando pista...";
    if (currentTrackPath != null) {
      displayTitle = currentTrackPath.replaceAll('\\', '/').split('/').last;
    }

    String displaySubtitle = isPlaying
        ? (lyrics.isEmpty
              ? "⚠️ Letras no encontradas. Usa 'Mejorar Pista'."
              : "Reproduciendo (Mezcla Semántica Activa)")
        : (currentTrackPath != null
              ? "Pista en Pausa"
              : "Motor libmpv en espera");

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool compact = Platform.isAndroid || Platform.isIOS;
        final bool menuOpen = compact
            ? ref.watch(mobileNavOpenProvider)
            : false;
        final bool syncExpand = compact && ref.watch(automixSyncArmedProvider);

        final Widget lyricsBox = ClipRect(
          child: Container(
            decoration: BoxDecoration(
              color: GatoMixTheme.bgPanel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isRecording
                    ? Colors.redAccent.withValues(alpha: 0.5)
                    : Colors.white10,
              ),
            ),
            child: LyricsSyncPanel(
              title: displayTitle,
              hasLyrics: lyrics.isNotEmpty,
              noLyricsWidget: Center(
                child: Text(
                  displaySubtitle,
                  style: TextStyle(
                    color: isPlaying ? const Color(0xFFFF007F) : Colors.white54,
                    fontSize: 14,
                    fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              onSync: () {
                automixNotifier.autoSyncFirstLyric();
              },
              onSyncMed: (line) {
                if (lyrics.isEmpty) return;
                automixNotifier.autoSyncFromCurrentLyric(lineIndex: line);
              },
              onSyncSingle: (line) {
                if (lyrics.isEmpty) return;
                automixNotifier.autoSyncSingleLyric(lineIndex: line);
              },
              onUndo: () {
                automixNotifier.undoLastLyricSync();
              },
              syncArmed: _lyricPickArmed,
              anchorMode: _anchorMode,
              onAnchorMode: (mode) {
                setState(() => _anchorMode = mode);
              },
              onArmedChanged: (armed) {
                setState(() {
                  _lyricPickArmed = armed;
                  if (!armed) _anchorMode = 1;
                });
                if (lyrics.isNotEmpty) {
                  final int idx = ref.read(automixProvider).activeLyricIndex;
                  final int line = (idx >= 0 ? idx : 0).clamp(
                    0,
                    lyrics.length - 1,
                  );
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    if (armed) {
                      if (!_lyricPickArmed) return;
                      _followArmedList(line, animate: false);
                    } else {
                      if (_lyricPickArmed) return;
                      _followCylinder(line, animate: false);
                    }
                  });
                }
                if (Platform.isAndroid || Platform.isIOS) {
                  ref.read(automixSyncArmedProvider.notifier).state = armed;
                }
              },
              lyricsWidget: _lyricPickArmed
                  ? ListView.builder(
                      controller: _lyricsListController,
                      physics: const BouncingScrollPhysics(),
                      itemExtent: _lyricRowExtent(),
                      itemCount: lyrics.length,
                      itemBuilder: (context, index) {
                        return Consumer(
                          builder: (context, ref, _) {
                            final activeIdx = ref.watch(
                              automixProvider.select((s) => s.activeLyricIndex),
                            );
                            final isCurrent = index == activeIdx;
                            final bool previewFirst =
                                activeIdx < 0 && index == 0;
                            final isPassed = index < activeIdx;
                            final Color textColor = isCurrent
                                ? const Color(0xFF39FF14)
                                : (previewFirst
                                      ? Colors.white
                                      : (isPassed
                                            ? Colors.white38
                                            : Colors.white70));
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: compact ? 22 : 28,
                                    child: Text(
                                      '${index + 1}',
                                      textAlign: TextAlign.right,
                                      maxLines: 1,
                                      style: TextStyle(
                                        color: isCurrent
                                            ? const Color(0xFF00FFFF)
                                            : textColor,
                                        fontSize: compact ? 10 : 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      lyrics[index].text.toString(),
                                      style: TextStyle(
                                        color: textColor,
                                        fontSize: compact ? 11 : 13,
                                        fontWeight: isCurrent || previewFirst
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        fontStyle: isPassed
                                            ? FontStyle.italic
                                            : FontStyle.normal,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.visible,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    )
                  : ListWheelScrollView(
                      controller: _lyricsController,
                      itemExtent: compact ? 20.0 : 32.0,
                      diameterRatio: 10.0,
                      perspective: 0.0001,
                      physics: const NeverScrollableScrollPhysics(),
                      children: List.generate(lyrics.length, (index) {
                        return Consumer(
                          builder: (context, ref, _) {
                            final activeIdx = ref.watch(
                              automixProvider.select((s) => s.activeLyricIndex),
                            );
                            final highlightIdx = activeIdx;
                            final isCurrent = index == highlightIdx;
                            final isNext = index == highlightIdx + 1;
                            final isPassed = index < highlightIdx;

                            Color textColor;
                            double fontSize;
                            FontWeight fontWeight;

                            if (isCurrent) {
                              textColor = const Color(0xFF39FF14);
                              fontSize = compact ? 14 : 24;
                              fontWeight = FontWeight.bold;
                            } else if (highlightIdx < 0 && index == 0) {
                              textColor = Colors.white;
                              fontSize = compact ? 14 : 24;
                              fontWeight = FontWeight.bold;
                            } else if (isNext) {
                              textColor = Colors.white.withValues(alpha: 0.95);
                              fontSize = compact ? 11 : 14;
                              fontWeight = FontWeight.w600;
                            } else {
                              textColor = Colors.white38;
                              fontSize = compact ? 10 : 12;
                              fontWeight = FontWeight.normal;
                            }

                            return Center(
                              child: Text(
                                lyrics[index].text.toString(),
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: fontSize,
                                  fontWeight: fontWeight,
                                  fontStyle: isPassed
                                      ? FontStyle.italic
                                      : FontStyle.normal,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.visible,
                              ),
                            );
                          },
                        );
                      }),
                    ),
            ),
          ),
        );

        return Padding(
          padding: EdgeInsets.all(compact ? 4.0 : 20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: (compact && !syncExpand)
                ? MainAxisSize.min
                : MainAxisSize.max,
            children: [
              if (compact)
                syncExpand
                    ? Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GatoMixMobileModeBar(
                              title: 'Automix',
                              accent: GatoMixTheme.deckA,
                              open: menuOpen,
                              expand: false,
                              onTap: () =>
                                  ref
                                          .read(mobileNavOpenProvider.notifier)
                                          .state =
                                      !menuOpen,
                            ),
                            const SizedBox(width: 6),
                            Expanded(child: lyricsBox),
                          ],
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GatoMixMobileModeBar(
                            title: 'Automix',
                            accent: GatoMixTheme.deckA,
                            open: menuOpen,
                            expand: false,
                            onTap: () =>
                                ref.read(mobileNavOpenProvider.notifier).state =
                                    !menuOpen,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: SizedBox(height: 100, child: lyricsBox),
                          ),
                        ],
                      )
              else
                Expanded(child: lyricsBox),
              SizedBox(height: compact ? 2 : 8),
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 4 : 20,
                  vertical: compact ? 2 : 10,
                ),
                decoration: BoxDecoration(
                  color: GatoMixTheme.bgPanel,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: compact ? 92 : 110,
                      child: Flex(
                        direction: compact ? Axis.horizontal : Axis.vertical,
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            constraints: BoxConstraints.tightFor(
                              width: compact ? 32 : 52,
                              height: compact ? 32 : 52,
                            ),
                            icon: Container(
                              width: compact ? 28 : 48,
                              height: compact ? 28 : 48,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color:
                                    (mixStrategy == MixStrategy.random
                                            ? const Color(0xFFFF007F)
                                            : const Color(0xFF00FFFF))
                                        .withValues(alpha: 0.18),
                                border: Border.all(
                                  color: mixStrategy == MixStrategy.random
                                      ? const Color(0xFFFF007F)
                                      : const Color(0xFF00FFFF),
                                  width: 2,
                                ),
                              ),
                              child: Icon(
                                mixStrategy == MixStrategy.random
                                    ? Icons.shuffle
                                    : Icons.format_list_numbered,
                                size: compact ? 16 : 26,
                                color: mixStrategy == MixStrategy.random
                                    ? const Color(0xFFFF007F)
                                    : const Color(0xFF00FFFF),
                              ),
                            ),
                            tooltip: mixStrategy == MixStrategy.random
                                ? 'Modo: Aleatorio (Shuffle)'
                                : 'Modo: Secuencial',
                            onPressed: () {
                              automixNotifier.toggleMixStrategy();
                            },
                          ),
                          SizedBox(
                            width: compact ? 12 : 0,
                            height: compact ? 0 : 8,
                          ),
                          IconButton(
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            constraints: BoxConstraints.tightFor(
                              width: compact ? 48 : 48,
                              height: compact ? 48 : 48,
                            ),
                            icon: Icon(
                              isPlaying
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_fill,
                              color: const Color(0xFF39FF14),
                              size: compact ? 42 : 45,
                            ),
                            onPressed: () => automixNotifier.togglePlayPause(),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Consumer(
                        builder: (context, ref, _) {
                          final position = ref.watch(
                            automixProvider.select((s) => s.position),
                          );
                          final duration = ref.watch(
                            automixProvider.select((s) => s.duration),
                          );
                          final triggerRemainingMs = ref.watch(
                            automixProvider.select((s) => s.triggerRemainingMs),
                          );
                          final customCueInMs = ref.watch(
                            automixProvider.select((s) => s.customCueInMs),
                          );
                          final customMixOutMs = ref.watch(
                            automixProvider.select((s) => s.customMixOutMs),
                          );
                          final customMixDurationMs = ref.watch(
                            automixProvider.select(
                              (s) => s.customMixDurationMs,
                            ),
                          );
                          final nextTrackPath = ref.watch(
                            automixProvider.select((s) => s.nextTrackPath),
                          );

                          return Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "${position.inMinutes}:${(position.inSeconds % 60).toString().padLeft(2, '0')}",
                                    style: const TextStyle(
                                      color: Color(0xFF39FF14),
                                      fontFamily: 'Consolas',
                                      fontSize: 12,
                                    ),
                                  ),
                                  Row(
                                    children: [
                                      IconButton(
                                        onPressed: currentTrackPath == null
                                            ? null
                                            : () => automixNotifier
                                                  .toggleAutoMixBypass(),
                                        icon: Icon(
                                          autoMixArmed
                                              ? Icons.lock_outline
                                              : Icons.lock_open,
                                          color: autoMixArmed
                                              ? const Color(0xFF00FFFF)
                                              : Colors.white24,
                                          size: 18,
                                        ),
                                        tooltip: autoMixArmed
                                            ? "AutoMix ARMADO"
                                            : "AutoMix BYPASS (Navegación Libre)",
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 28,
                                              height: 28,
                                            ),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                        style: IconButton.styleFrom(
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                      ),
                                      ElevatedButton(
                                        onPressed:
                                            (currentTrackPath == null ||
                                                autoMixArmed)
                                            ? null
                                            : () => automixNotifier.setMixPoint(
                                                'IN',
                                              ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.white10,
                                          foregroundColor: const Color(
                                            0xFF39FF14,
                                          ),
                                          disabledForegroundColor:
                                              Colors.white24,
                                          disabledBackgroundColor:
                                              Colors.black12,
                                          minimumSize: const Size(60, 24),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                        ),
                                        child: const Text(
                                          "SET IN",
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 5),
                                      ElevatedButton(
                                        onPressed:
                                            (currentTrackPath == null ||
                                                autoMixArmed)
                                            ? null
                                            : () async {
                                                await automixNotifier
                                                    .setMixPoint('OUT');
                                                if (!ref
                                                    .read(automixProvider)
                                                    .autoMixArmed) {
                                                  automixNotifier
                                                      .toggleAutoMixBypass();
                                                }
                                              },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.white10,
                                          foregroundColor: const Color(
                                            0xFFFF007F,
                                          ),
                                          disabledForegroundColor:
                                              Colors.white24,
                                          disabledBackgroundColor:
                                              Colors.black12,
                                          minimumSize: const Size(60, 24),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                        ),
                                        child: const Text(
                                          "SET OUT",
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        onPressed:
                                            (currentTrackPath == null ||
                                                autoMixArmed)
                                            ? null
                                            : () => automixNotifier
                                                  .clearMixPoints(),
                                        icon: Icon(
                                          Icons.delete_sweep,
                                          color: autoMixArmed
                                              ? Colors.white12
                                              : Colors.white54,
                                          size: 18,
                                        ),
                                        tooltip:
                                            "Borrar Cues (Restaurar Letra de Internet)",
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 28,
                                              height: 28,
                                            ),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                        style: IconButton.styleFrom(
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    "-${(duration - position).inMinutes}:${((duration - position).inSeconds % 60).toString().padLeft(2, '0')}",
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontFamily: 'Consolas',
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: compact ? 2 : 8),
                              LayoutBuilder(
                                builder: (context, deckConstraints) {
                                  return GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapDown: (details) {
                                      if (duration.inMilliseconds == 0) return;
                                      final double percent =
                                          (details.localPosition.dx /
                                                  deckConstraints.maxWidth)
                                              .clamp(0.0, 1.0);
                                      final targetMs =
                                          (percent * duration.inMilliseconds)
                                              .toInt();
                                      automixNotifier.seek(
                                        Duration(milliseconds: targetMs),
                                      );
                                    },
                                    onHorizontalDragUpdate: (details) {
                                      if (duration.inMilliseconds == 0) return;
                                      final double percent =
                                          (details.localPosition.dx /
                                                  deckConstraints.maxWidth)
                                              .clamp(0.0, 1.0);
                                      final targetMs =
                                          (percent * duration.inMilliseconds)
                                              .toInt();
                                      automixNotifier.seek(
                                        Duration(milliseconds: targetMs),
                                      );
                                    },
                                    child: CustomPaint(
                                      size: Size(
                                        deckConstraints.maxWidth,
                                        compact ? 16 : 24,
                                      ),
                                      painter: SemanticDeckPainter(
                                        positionMs: position.inMilliseconds,
                                        durationMs: duration.inMilliseconds,
                                        triggerRemainingMs: triggerRemainingMs,
                                        lyrics: lyrics,
                                        nextTrackName: nextTrackPath
                                            ?.replaceAll('\\', '/')
                                            .split('/')
                                            .last,
                                        customCueInMs: customCueInMs,
                                        customMixOutMs: customMixOutMs,
                                        customMixDurationMs:
                                            customMixDurationMs,
                                        autoMixArmed: autoMixArmed,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 2),
                              SizedBox(
                                height: 12,
                                child: SliderTheme(
                                  data: SliderThemeData(
                                    trackHeight: 2,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 5,
                                    ),
                                    overlayShape: RoundSliderOverlayShape(
                                      overlayRadius: compact ? 0 : 10,
                                    ),
                                    activeTrackColor: Colors.white54,
                                    inactiveTrackColor: Colors.white10,
                                    thumbColor: Colors.white,
                                  ),
                                  child: Slider(
                                    value: duration.inMilliseconds > 0
                                        ? position.inMilliseconds
                                              .toDouble()
                                              .clamp(
                                                0.0,
                                                duration.inMilliseconds
                                                    .toDouble(),
                                              )
                                        : 0.0,
                                    min: 0.0,
                                    max: duration.inMilliseconds > 0
                                        ? duration.inMilliseconds.toDouble()
                                        : 1.0,
                                    onChanged: (val) {
                                      if (duration.inMilliseconds > 0) {
                                        automixNotifier.seek(
                                          Duration(milliseconds: val.toInt()),
                                        );
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    if (canRecord) ...[
                      const SizedBox(width: 20),
                      SizedBox(
                        width: 70,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              isRecording ? "REC" : "MASTER",
                              style: TextStyle(
                                color: isRecording
                                    ? Colors.redAccent
                                    : Colors.white38,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 5),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: Icon(
                                isRecording
                                    ? Icons.stop_circle
                                    : Icons.fiber_manual_record,
                                color: isRecording
                                    ? Colors.redAccent
                                    : Colors.white54,
                                size: 40,
                              ),
                              onPressed: () => ref
                                  .read(wasapiRecordProvider.notifier)
                                  .toggleRecording(context),
                            ),
                          ],
                        ),
                      ),
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
}

class LyricsSyncPanel extends ConsumerStatefulWidget {
  final String title;
  final bool hasLyrics;
  final Widget lyricsWidget;
  final Widget noLyricsWidget;
  final VoidCallback onSync;
  final ValueChanged<int> onSyncMed;
  final ValueChanged<int> onSyncSingle;
  final ValueChanged<bool>? onArmedChanged;
  final ValueChanged<int>? onAnchorMode;
  final bool syncArmed;
  final int anchorMode;
  final VoidCallback? onUndo;

  const LyricsSyncPanel({
    super.key,
    required this.title,
    required this.hasLyrics,
    required this.lyricsWidget,
    required this.noLyricsWidget,
    required this.onSync,
    required this.onSyncMed,
    required this.onSyncSingle,
    this.onArmedChanged,
    this.onAnchorMode,
    this.syncArmed = false,
    this.anchorMode = 1,
    this.onUndo,
  });

  @override
  ConsumerState<LyricsSyncPanel> createState() => _LyricsSyncPanelState();
}

class _LyricsSyncPanelState extends ConsumerState<LyricsSyncPanel> {
  bool isArmed = false;
  bool _labBusy = false;
  final TextEditingController _filaCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onUndoKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onUndoKey);
    _filaCtrl.dispose();
    super.dispose();
  }

  bool _onUndoKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!isArmed || _filaCtrl.text.isNotEmpty) return false;
    final bool ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!ctrl || event.logicalKey != LogicalKeyboardKey.keyZ) return false;
    widget.onUndo?.call();
    return true;
  }

  void _needLineNumber() {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('Indica primero el número de la línea'),
      ),
    );
  }

  @override
  void didUpdateWidget(LyricsSyncPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.syncArmed != isArmed) {
      isArmed = widget.syncArmed;
    }
  }

  void _stampNow() {
    if (!isArmed) return;
    if (widget.anchorMode == 1) {
      widget.onSync();
      return;
    }
    final int? n = int.tryParse(_filaCtrl.text.trim());
    if (n == null || n < 1) {
      _needLineNumber();
      return;
    }
    final int line = n - 1;
    if (widget.anchorMode == 2) {
      widget.onSyncMed(line);
    } else {
      widget.onSyncSingle(line);
    }
    _filaCtrl.clear();
    setState(() {});
  }

  Future<void> _sendCurrentTrackToLab(
    String trackPath,
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (trackPath.isEmpty || _labBusy) return;

    final file = File(trackPath);
    if (!file.existsSync()) return;

    _labBusy = true;
    try {
      final automixState = ref.read(automixProvider);
      final automixNotifier = ref.read(automixProvider.notifier);
      final bool wasPlaying = automixState.isPlaying;
      final bool hasNext = automixState.playlist.length > 1;

      await automixNotifier.mixOutForQuarantine(trackPath);

      String baseMusicPath;
      if (Platform.isIOS) {
        baseMusicPath = IphoneLibrary.musicRoot;
      } else if (Platform.isWindows) {
        final userProfile = Platform.environment['USERPROFILE'];
        baseMusicPath = userProfile != null
            ? '$userProfile\\Music'
            : 'C:\\Music';
      } else if (Platform.isMacOS || Platform.isLinux) {
        final home = Platform.environment['HOME'];
        baseMusicPath = home != null ? '$home/Music' : '/tmp';
      } else {
        baseMusicPath = '/storage/emulated/0/Music';
      }

      final labDir = Directory(labFolder(baseMusicPath));
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

      final fileName = file.uri.pathSegments.last;
      final newPath = '${labDir.path}${Platform.pathSeparator}$fileName';

      bool moved = false;
      int attempts = 0;

      await Future.delayed(const Duration(milliseconds: 500));

      while (!moved && attempts < 20) {
        try {
          file.renameSync(newPath);
          moved = true;
        } catch (e) {
          await Future.delayed(const Duration(milliseconds: 500));
          attempts++;
        }
      }

      if (!moved) {
        debugPrint("🔴 VETO TÉCNICO: libmpv no liberó el handle.");
        return;
      }

      registry[fileName] = trackPath;
      final lrcFile = File(
        trackPath.replaceAll(
          RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
          '.lrc',
        ),
      );
      if (lrcFile.existsSync()) {
        lrcFile.renameSync(
          '${labDir.path}${Platform.pathSeparator}${fileName.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
        );
      }
      registryFile.writeAsStringSync(jsonEncode(registry));

      ref.read(automixQueueProvider.notifier).removeTrack(trackPath);
      automixNotifier.removeTrack(trackPath);

      if (!wasPlaying && hasNext) {
        final newPlaylist = List<String>.from(automixState.playlist)
          ..remove(trackPath);
        int loadIndex = automixState.currentIndex;
        if (loadIndex >= newPlaylist.length) loadIndex = 0;

        if (newPlaylist.isNotEmpty) {
          await automixNotifier.loadContextAndPlay(newPlaylist, loadIndex);
          await automixNotifier.pause();
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "En laboratorio",
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            backgroundColor: GatoMixTheme.bgPanel,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint("🔴 Error de I/O consolidando el Laboratorio: $e");
    } finally {
      _labBusy = false;
    }
  }

  void _openFullscreenLyrics() {
    final automixState = ref.read(automixProvider);
    final lyrics = automixState.lyrics;
    final displayTitle = automixState.currentTrackPath != null
        ? automixState.currentTrackPath!.replaceAll('\\', '/').split('/').last
        : "Visor de Letras en Vivo";

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF121212),
        insetPadding: const EdgeInsets.all(15),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Color(0xFF39FF14), width: 1.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Container(
          width: MediaQuery.of(context).size.width,
          height: MediaQuery.of(context).size.height,
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      displayTitle,
                      style: const TextStyle(
                        color: Color(0xFF39FF14),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(color: Colors.white10),
              Expanded(
                child: lyrics.isEmpty
                    ? const Center(
                        child: Text(
                          "No hay letras sincronizadas en caché.",
                          style: TextStyle(color: Colors.white38),
                        ),
                      )
                    : Consumer(
                        builder: (context, ref, _) {
                          final activeIdx = ref.watch(
                            automixProvider.select((s) => s.activeLyricIndex),
                          );

                          return ListView.builder(
                            physics: const BouncingScrollPhysics(),
                            itemCount: lyrics.length,
                            itemBuilder: (context, index) {
                              final isCurrent = index == activeIdx;
                              final isPassed = index < activeIdx;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8.0,
                                ),
                                child: Text(
                                  lyrics[index].text,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: isCurrent
                                        ? const Color(0xFF39FF14)
                                        : (isPassed
                                              ? Colors.white38
                                              : Colors.white),
                                    fontSize: isCurrent ? 24 : 16,
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    fontStyle: isPassed
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _anchorNumBtn({
    required String n,
    required Color color,
    required bool selected,
    required bool isMobileLandscape,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    final double size = isMobileLandscape ? 22 : 26;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: size,
          height: size,
          child: Material(
            color: selected
                ? color.withValues(alpha: 0.28)
                : Colors.transparent,
            shape: CircleBorder(
              side: BorderSide(color: color, width: selected ? 2 : 1),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: Center(
                child: Text(
                  n,
                  style: TextStyle(
                    color: color,
                    fontSize: isMobileLandscape ? 11 : 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobileLandscape = MediaQuery.of(context).size.height < 500;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: isMobileLandscape ? 1 : 8,
          ),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.white10)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: isMobileLandscape ? 12 : 14,
                  ),
                ),
                const SizedBox(width: 15),
                IconButton(
                  icon: Icon(
                    Icons.fullscreen,
                    color: Colors.white,
                    size: isMobileLandscape ? 16 : 18,
                  ),
                  onPressed: _openFullscreenLyrics,
                  tooltip: "Modo Teatro (Letras en Pantalla Completa)",
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 10),
                Consumer(
                  builder: (context, ref, child) {
                    final currentPath = ref.watch(
                      automixProvider.select((p) => p.currentTrackPath),
                    );
                    return IconButton(
                      icon: Icon(
                        Icons.science,
                        color: Colors.orangeAccent,
                        size: isMobileLandscape ? 16 : 18,
                      ),
                      onPressed: currentPath == null
                          ? null
                          : () => _sendCurrentTrackToLab(
                              currentPath,
                              context,
                              ref,
                            ),
                      tooltip: "Mover Pista al Laboratorio (LAB)",
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    );
                  },
                ),
                if (widget.hasLyrics) ...[
                  const SizedBox(width: 15),
                  Text(
                    "Sync I/O",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: isMobileLandscape ? 10 : 11,
                    ),
                  ),
                  Theme(
                    data: ThemeData(unselectedWidgetColor: Colors.white38),
                    child: Checkbox(
                      value: isArmed,
                      activeColor: const Color(0xFFFF007F),
                      visualDensity: VisualDensity.compact,
                      onChanged: (val) {
                        final bool armed = val ?? false;
                        setState(() => isArmed = armed);
                        widget.onArmedChanged?.call(armed);
                      },
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: isArmed ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _anchorNumBtn(
                          n: '1',
                          color: const Color(0xFFFF007F),
                          selected: widget.anchorMode == 1,
                          isMobileLandscape: isMobileLandscape,
                          tooltip: 'Ancla 1: bloque entero',
                          onPressed: isArmed
                              ? () => widget.onAnchorMode?.call(1)
                              : null,
                        ),
                        _anchorNumBtn(
                          n: '2',
                          color: const Color(0xFF00FFFF),
                          selected: widget.anchorMode == 2,
                          isMobileLandscape: isMobileLandscape,
                          tooltip: 'Ancla 2: desde #Fila al final',
                          onPressed: isArmed
                              ? () => widget.onAnchorMode?.call(2)
                              : null,
                        ),
                        _anchorNumBtn(
                          n: '3',
                          color: GatoMixTheme.deckA,
                          selected: widget.anchorMode == 3,
                          isMobileLandscape: isMobileLandscape,
                          tooltip: 'Ancla 3: solo #Fila',
                          onPressed: isArmed
                              ? () => widget.onAnchorMode?.call(3)
                              : null,
                        ),
                        if (widget.anchorMode != 1) ...[
                          SizedBox(
                            width: isMobileLandscape ? 56 : 72,
                            height: isMobileLandscape ? 22 : 28,
                            child: TextField(
                              controller: _filaCtrl,
                              enabled: isArmed,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              onChanged: (_) => setState(() {}),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: isMobileLandscape ? 10 : 12,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '#Fila',
                                hintStyle: TextStyle(
                                  color: Colors.white38,
                                  fontSize: isMobileLandscape ? 9 : 10,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 4,
                                ),
                                border: const OutlineInputBorder(),
                                enabledBorder: const OutlineInputBorder(
                                  borderSide: BorderSide(color: Colors.white24),
                                ),
                                focusedBorder: const OutlineInputBorder(
                                  borderSide: BorderSide(
                                    color: Color(0xFF00FFFF),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'EMPATAR AHORA',
                          icon: Icon(
                            Icons.my_location,
                            size: isMobileLandscape ? 16 : 18,
                            color: const Color(0xFF00FFFF),
                          ),
                          onPressed: isArmed ? _stampNow : null,
                        ),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: isMobileLandscape ? 90 : 140,
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              widget.anchorMode == 3
                                  ? '3 solo fila ${_filaCtrl.text.isEmpty ? '#' : _filaCtrl.text}'
                                  : (widget.anchorMode == 2
                                        ? '2 desde fila ${_filaCtrl.text.isEmpty ? '#' : _filaCtrl.text}'
                                        : '1 bloque a AHORA'),
                              maxLines: 1,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: isMobileLandscape ? 9 : 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.all(isMobileLandscape ? 2.0 : 10.0),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: !widget.hasLyrics
                      ? widget.noLyricsWidget
                      : widget.lyricsWidget,
                ),
                const _VocalCountIn(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _VocalCountIn extends ConsumerWidget {
  const _VocalCountIn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(automixProvider.select((s) => s.lyrics));
    final idx = ref.watch(automixProvider.select((s) => s.activeLyricIndex));
    final pos = ref.watch(automixProvider.select((s) => s.position));
    if (idx >= 0 || lyrics.isEmpty) return const SizedBox.shrink();
    LyricLine? upcoming;
    for (final line in lyrics) {
      if (line.timestamp > pos) {
        upcoming = line;
        break;
      }
    }
    if (upcoming == null) return const SizedBox.shrink();
    final int leftMs = upcoming.timestamp.inMilliseconds - pos.inMilliseconds;
    if (leftMs <= 0 || leftMs > 3000) return const SizedBox.shrink();
    final int n = (leftMs / 1000).ceil().clamp(1, 3);
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, right: 8),
        child: Text(
          '$n',
          style: const TextStyle(
            color: Color(0xFF39FF14),
            fontSize: 28,
            fontWeight: FontWeight.bold,
            fontFamily: 'Consolas',
          ),
        ),
      ),
    );
  }
}

class SemanticDeckPainter extends CustomPainter {
  final int positionMs;
  final int durationMs;
  final int triggerRemainingMs;
  final List<dynamic> lyrics;
  final String? nextTrackName;
  final int customCueInMs;
  final int customMixOutMs;
  final int customMixDurationMs;
  final bool autoMixArmed;

  SemanticDeckPainter({
    required this.positionMs,
    required this.durationMs,
    required this.triggerRemainingMs,
    required this.lyrics,
    this.nextTrackName,
    required this.customCueInMs,
    required this.customMixOutMs,
    required this.customMixDurationMs,
    required this.autoMixArmed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (durationMs == 0) return;

    final double ratio = (positionMs / durationMs).clamp(0.0, 1.0);
    final double progressX = ratio * size.width;
    final double triggerX =
        size.width -
        ((triggerRemainingMs / durationMs) * size.width).clamp(0.0, size.width);

    final Rect deckA = Rect.fromLTWH(0, 0, size.width, 10);
    canvas.drawRect(deckA, Paint()..color = GatoMixTheme.bgPanel);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, progressX, 10),
      Paint()..color = const Color(0xFF39FF14).withValues(alpha: 0.5),
    );

    final Paint vocalPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8);
    for (var lyric in lyrics) {
      final double lX =
          ((lyric.timestamp.inMilliseconds / durationMs).clamp(0.0, 1.0)) *
          size.width;
      canvas.drawRect(Rect.fromLTWH(lX, 1, 2, 8), vocalPaint);
    }

    double visualMixStartX = triggerX;
    double visualMixEndX = size.width;
    double visualMixWidth = size.width - triggerX;
    if (customMixOutMs > 0) {
      // DAWN entra 5 s antes del SET OUT y se prolonga sobre la cola del outro.
      final mixStartMs = (customMixOutMs - kDawnLeadMs).clamp(0, durationMs);
      final mixEndMs = (mixStartMs + customMixDurationMs).clamp(0, durationMs);
      visualMixStartX = (mixStartMs / durationMs) * size.width;
      visualMixEndX = (mixEndMs / durationMs) * size.width;
      visualMixWidth = ((mixEndMs - mixStartMs) / durationMs) * size.width;
    }

    if (autoMixArmed) {
      canvas.drawRect(
        Rect.fromLTWH(visualMixStartX, 0, visualMixWidth, 10),
        Paint()..color = const Color(0xFFFF007F).withValues(alpha: 0.4),
      );
    }

    if (customCueInMs > 0) {
      final double inX =
          ((customCueInMs / durationMs).clamp(0.0, 1.0)) * size.width;

      canvas.drawRect(
        Rect.fromLTWH(0, 0, inX, 10),
        Paint()..color = const Color(0xFFFF007F).withValues(alpha: 0.4),
      );

      canvas.drawLine(
        Offset(inX, 0),
        Offset(inX, 10),
        Paint()
          ..color = const Color(0xFF39FF14)
          ..strokeWidth = 2,
      );
      canvas.drawCircle(
        Offset(inX, 0),
        3,
        Paint()..color = const Color(0xFF39FF14),
      );
    }

    if (customMixOutMs > 0) {
      final double outX =
          ((customMixOutMs / durationMs).clamp(0.0, 1.0)) * size.width;
      canvas.drawLine(
        Offset(outX, 0),
        Offset(outX, 10),
        Paint()
          ..color = const Color(0xFFFF007F)
          ..strokeWidth = 2,
      );
      canvas.drawCircle(
        Offset(outX, 10),
        3,
        Paint()..color = const Color(0xFFFF007F),
      );

      double deadX = visualMixEndX;
      if (deadX < size.width) {
        canvas.drawRect(
          Rect.fromLTWH(deadX, 0, size.width - deadX, 10),
          Paint()..color = Colors.black.withValues(alpha: 0.7),
        );
      }
    } else if (autoMixArmed) {
      canvas.drawLine(
        Offset(triggerX, 0),
        Offset(triggerX, 10),
        Paint()
          ..color = const Color(0xFFFF007F)
          ..strokeWidth = 2,
      );
    }

    final Rect deckB = Rect.fromLTWH(0, 18, size.width, 10);
    canvas.drawRect(deckB, Paint()..color = const Color(0xFF111111));

    if (autoMixArmed && nextTrackName != null) {
      canvas.drawRect(
        Rect.fromLTWH(visualMixStartX, 18, visualMixWidth, 10),
        Paint()..color = const Color(0xFF00FFFF).withValues(alpha: 0.3),
      );

      if (customMixOutMs > 0) {
        double deadX = visualMixEndX;
        if (deadX < size.width) {
          canvas.drawRect(
            Rect.fromLTWH(deadX, 18, size.width - deadX, 10),
            Paint()..color = Colors.black.withValues(alpha: 0.7),
          );
        }
      }

      final textPainter = TextPainter(
        text: TextSpan(
          text: nextTrackName,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 9,
            fontFamily: 'Consolas',
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: size.width - 10);
      textPainter.paint(canvas, const Offset(4, 16));
    }

    canvas.drawLine(
      Offset(progressX, -5),
      Offset(progressX, 35),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant SemanticDeckPainter oldDelegate) {
    if (positionMs != oldDelegate.positionMs ||
        durationMs != oldDelegate.durationMs ||
        customCueInMs != oldDelegate.customCueInMs ||
        customMixOutMs != oldDelegate.customMixOutMs ||
        customMixDurationMs != oldDelegate.customMixDurationMs ||
        autoMixArmed != oldDelegate.autoMixArmed ||
        lyrics.length != oldDelegate.lyrics.length) {
      return true;
    }
    for (var i = 0; i < lyrics.length; i++) {
      if (lyrics[i].timestamp != oldDelegate.lyrics[i].timestamp) return true;
    }
    return false;
  }
}
