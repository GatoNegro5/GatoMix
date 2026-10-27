import 'dart:io';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

// 🛠️ INYECCIÓN: Uso estricto de la capa HAL
import '../core/audio_path.dart';
import '../core/hal/platform_strategy.dart';

class DirectoryState {
  final String currentPath;
  final List<File> files;
  final bool isProcessing;
  final Set<String> expandedPaths;

  DirectoryState({
    this.currentPath = '',
    this.files = const [],
    this.isProcessing = false,
    this.expandedPaths = const {},
  });

  DirectoryState copyWith({
    String? currentPath,
    List<File>? files,
    bool? isProcessing,
    Set<String>? expandedPaths,
  }) {
    return DirectoryState(
      currentPath: currentPath ?? this.currentPath,
      files: files ?? this.files,
      isProcessing: isProcessing ?? this.isProcessing,
      expandedPaths: expandedPaths ?? this.expandedPaths,
    );
  }
}

class DirectoryNotifier extends Notifier<DirectoryState> {
  /// Cada motor persiste su explorador en su propio JSON.
  final String sessionFileName;

  DirectoryNotifier({this.sessionFileName = '_explorer_session.json'});

  late final PlatformMixStrategy _halStrategy;

  @override
  DirectoryState build() {
    _halStrategy = MixStrategyFactory.getStrategy();
    _initPersistence();
    return DirectoryState();
  }

  // 🛠️ DELEGACIÓN AL HAL: Cero "if(Platform.isWindows)"
  String _getSessionFilePath() {
    // Tomamos la ruta base de la estrategia y le adjuntamos el JSON específico del explorador
    final baseDir = File(_halStrategy.getSessionPath()).parent;
    if (!baseDir.existsSync()) baseDir.createSync(recursive: true);
    return '${baseDir.path}${Platform.pathSeparator}$sessionFileName';
  }

  Future<void> _initPersistence() async {
    try {
      final file = File(_getSessionFilePath());
      if (file.existsSync()) {
        final content = await file.readAsString();
        final data = jsonDecode(content);

        final lastDir = data['currentPath'] as String?;
        final savedExpanded =
            (data['expandedPaths'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toSet() ??
            {};

        state = state.copyWith(expandedPaths: savedExpanded);

        if (lastDir != null && Directory(lastDir).existsSync()) {
          await scanPath(lastDir);
        }
      }
    } catch (_) {}
  }

  Future<void> _saveSnapshot() async {
    try {
      final file = File(_getSessionFilePath());
      final data = {
        'currentPath': state.currentPath,
        'expandedPaths': state.expandedPaths.toList(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  void toggleNode(String path, bool isExpanded) {
    final newExpanded = Set<String>.from(state.expandedPaths);
    if (isExpanded) {
      newExpanded.add(path);
    } else {
      newExpanded.remove(path);
    }
    state = state.copyWith(expandedPaths: newExpanded);
    _saveSnapshot();
  }

  Future<void> loadDirectory() async {
    if (state.isProcessing) return;
    final String? selectedDirectory = await getDirectoryPath();
    if (selectedDirectory != null) {
      await scanPath(selectedDirectory);
    }
  }

  Future<void> refreshCurrentPath() async {
    if (state.currentPath.isNotEmpty) {
      await scanPath(state.currentPath);
    }
  }

  Future<void> scanPath(String path) async {
    state = state.copyWith(isProcessing: true, currentPath: path);
    await _saveSnapshot();

    try {
      final dir = Directory(path);
      final List<File> targetFiles = [];
      final Set<String> validAudioBases = {};
      final List<File> lrcFiles = [];

      final stream = dir.list(recursive: true, followLinks: false).handleError((
        e,
      ) {
        debugPrint("⚠️ [I/O Ignorado en Scoped Storage]: $e");
      });

      await for (final entity in stream) {
        if (entity is File) {
          final lowerPath = entity.path.toLowerCase();
          if (lowerPath.endsWith('.mp3') ||
              lowerPath.endsWith('.webm') ||
              lowerPath.endsWith('.m4a') ||
              lowerPath.endsWith('.wav')) {
            targetFiles.add(entity);
            validAudioBases.add(
              entity.path.replaceAll(
                RegExp(r'\.mp3$|\.webm$|\.m4a$|\.wav$', caseSensitive: false),
                '',
              ),
            );
          } else if (lowerPath.endsWith('.lrc')) {
            lrcFiles.add(entity);
          }
        }
      }

      for (final lrc in lrcFiles) {
        final baseName = lrc.path.replaceAll(
          RegExp(r'\.lrc$', caseSensitive: false),
          '',
        );
        if (!validAudioBases.contains(baseName)) {
          try {
            await lrc.delete();
          } catch (_) {}
        }
      }

      // Una sola fila por archivo: junctions, mayúsculas y separadores
      // distintos colapsan a la ruta real. El .lrc (icono tomate) queda
      // junto a esa ruta. Los _K siguen en el explorador.
      final Map<String, File> uniq = <String, File>{};
      for (final File f in targetFiles) {
        final String canon = canonicalAudioPath(f.path);
        uniq.putIfAbsent(audioPathKey(canon), () => File(canon));
      }
      final List<File> uniqueFiles = uniq.values.toList();
      uniqueFiles.sort(
        (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
      );
      state = state.copyWith(files: uniqueFiles, isProcessing: false);
    } catch (e) {
      debugPrint("🔴 [SCAN FATAL ERROR]: $e");
      state = state.copyWith(isProcessing: false, files: []);
    }
  }
}

final directoryProvider = NotifierProvider<DirectoryNotifier, DirectoryState>(
  DirectoryNotifier.new,
);

/// Explorador propio de Live DJ: carpeta, árbol expandido y archivos
/// independientes de Automix / Lab / Masterizar.
final liveDjDirectoryProvider =
    NotifierProvider<DirectoryNotifier, DirectoryState>(
      () => DirectoryNotifier(sessionFileName: '_livedj_explorer_session.json'),
    );
