import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// 🛠️ FIX: Requerido para leer el sello de agua y saltar I/O
import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;

import '../core/id3_names.dart';
import '../core/track_name_clean.dart';
import '../services/id3_title_artist.dart';

final metadataWorkerProvider = Provider((ref) => MetadataWorker());

class MetadataWorker {
  // Regex nivel 4 (Portado del Core Python original)
  final RegExp _garbageRegex = RegExp(
    r'\s*[\(\[\{][^\)\]\}]*(official|music video|video|audio|lyric|lyrics|letra|letras|hq|hd|4k|remastered|remaster)[^\)\]\}]*[\)\]\}]',
    caseSensitive: false,
  );
  final _spacesRegex = RegExp(r"\s{2,}");
  final _dashRegex = RegExp(r"\s*-\s*-+\s*");
  final _invalidCharsRegex = RegExp(r'[<>:"/\\|?*]');

  Future<void> processDirectory(
    String directoryPath,
    Function(int, int, String) onProgress, {
    Function(String)? onCorrupt,
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp3'))
        .toList();
    int total = files.length;

    for (int i = 0; i < total; i++) {
      // FRENO DE EMERGENCIA ATÓMICO
      if (isCancelled != null && isCancelled()) {
        debugPrint("🔴 [Metadata Worker] Proceso abortado por el usuario.");
        break;
      }
      final file = files[i];
      final filename = file.uri.pathSegments.last;

      onProgress(i + 1, total, filename);

      // 🛠️ FIX: BYPASS SI YA ESTÁ MASTERIZADO
      try {
        if (await rust_dsp.checkWatermark(inputPath: file.path)) {
          continue;
        }
      } catch (_) {}

      // ---------------------------------------------------------
      // AUTO-HEALING: Failsafe de Corrupción I/O
      // ---------------------------------------------------------
      try {
        // Heurística de daño estructural: Si pesa menos de 2KB, no tiene payload de audio real
        if (file.lengthSync() < 2048) {
          throw Exception("Corrupción estructural (Falta payload).");
        }
        // Prueba atómica de lectura de header para validar el I/O Lock
        final randomAccessFile = file.openSync(mode: FileMode.read);
        randomAccessFile.readByteSync();
        randomAccessFile.closeSync();
      } catch (e) {
        debugPrint(
          "🔴 [Auto-Healing] Pista corrupta interceptada: $filename - $e",
        );

        try {
          file.deleteSync(); // Purga física inmediata
        } catch (_) {}

        if (onCorrupt != null) {
          // Limpiamos el nombre para entregarle al Scraper de YouTube un query puro
          final cleanQuery = _cleanFilename(
            filename,
          ).replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '');
          onCorrupt(cleanQuery);
        }
        continue; // Bypass atómico: El bucle jamás se detiene
      }

      final cleanName = _uniqueName(
        file.parent,
        _cleanFilename(filename),
        file.path,
      );
      if (cleanName != filename) {
        final newPath =
            '${file.parent.path}${Platform.pathSeparator}$cleanName';
        if (!File(newPath).existsSync()) {
          try {
            await file.rename(newPath);
            await _syncAssociatedFile(file.path, newPath, '.lrc');
            await _syncKaraokeFile(file.path, newPath);
          } catch (e) {
            debugPrint("🔴 [I/O Lock]: No se pudo renombrar $filename - $e");
          }
        }
      }

      // Prevención de UI Stuttering
      await Future.delayed(const Duration(milliseconds: 5));
    }
  }

  String _cleanFilename(
    String filename, {
    String id3Artist = '',
    String id3Title = '',
  }) {
    var prepared = filename.replaceAll(_garbageRegex, ' ');
    prepared = prepared.replaceAll(_dashRegex, ' - ');
    prepared = prepared.replaceAll('_', ' ');
    prepared = prepared.replaceAll(_spacesRegex, ' ');
    final CleanTrackName cleaned = cleanTrackFileName(
      prepared,
      id3Artist: id3Artist,
      id3Title: id3Title,
    );
    final String stem;
    if (cleaned.artist.isNotEmpty && cleaned.title.isNotEmpty) {
      stem = '${_toTitleCase(cleaned.artist)} - ${_toTitleCase(cleaned.title)}';
    } else if (cleaned.title.isNotEmpty) {
      stem = _toTitleCase(cleaned.title);
    } else if (cleaned.artist.isNotEmpty) {
      stem = _toTitleCase(cleaned.artist);
    } else {
      stem = 'Pista';
    }
    return stem.replaceAll(_invalidCharsRegex, '');
  }

  String _uniqueName(Directory parent, String stem, String currentPath) {
    final String sep = Platform.pathSeparator;
    return uniqueMp3Name(stem, (String fileName) {
      final String p = '${parent.path}$sep$fileName';
      return p.toLowerCase() != currentPath.toLowerCase() &&
          File(p).existsSync();
    });
  }

  String _toTitleCase(String text) {
    if (text.isEmpty) return text;
    return text
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join(' ');
  }

  Future<String> processSingleFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return filePath;

    final filename = file.uri.pathSegments.last;
    final Id3Names id3 = await loadId3TitleArtist(filePath);
    final cleanName = _uniqueName(
      file.parent,
      _cleanFilename(filename, id3Artist: id3.artist, id3Title: id3.title),
      filePath,
    );

    if (cleanName != filename) {
      final targetPath =
          '${file.parent.path}${Platform.pathSeparator}$cleanName';

      try {
        if (targetPath.toLowerCase() == filePath.toLowerCase()) {
          final tempPath =
              '${file.parent.path}${Platform.pathSeparator}TEMP_$cleanName';
          // Usamos Copy/Delete atómico. Evade el Spinlock de MoveFileW
          await file.copy(tempPath);
          await file.delete();
          await File(tempPath).copy(targetPath);
          await File(tempPath).delete();
        } else {
          if (!File(targetPath).existsSync()) {
            await file.copy(targetPath);
            await file.delete();
          }
        }

        // Letra, texto y pista _K siguen al MP3 renombrado.
        await _syncAssociatedFile(filePath, targetPath, '.lrc');
        await _retargetAutoLyric(filePath, targetPath);
        await _syncAssociatedFile(filePath, targetPath, '.txt');
        await _syncKaraokeFile(filePath, targetPath);

        return targetPath;
      } catch (e) {
        debugPrint("🔴 [I/O Lock Evadido]: $e");
        return filePath;
      }
    }

    return filePath;
  }

  Future<void> _retargetAutoLyric(String oldMp3, String newMp3) async {
    final RegExp ext = RegExp(r'\.mp3$', caseSensitive: false);
    final String oldBase = File(
      oldMp3.replaceAll(ext, '.lrc'),
    ).uri.pathSegments.last;
    final String newBase = File(
      newMp3.replaceAll(ext, '.lrc'),
    ).uri.pathSegments.last;
    if (oldBase == newBase) return;
    final File reg = File(
      '${File(newMp3).parent.path}${Platform.pathSeparator}_lyrics_auto.json',
    );
    if (!reg.existsSync()) return;
    try {
      final dynamic decoded = jsonDecode(reg.readAsStringSync());
      if (decoded is! Map || !decoded.containsKey(oldBase)) return;
      final Map<String, dynamic> map = Map<String, dynamic>.from(decoded);
      map[newBase] = map.remove(oldBase);
      await reg.writeAsString(jsonEncode(map));
    } catch (_) {}
  }

  // Motor para evitar dejar archivos .lrc o .txt huérfanos al renombrar el MP3
  Future<void> _syncAssociatedFile(
    String oldMp3,
    String newMp3,
    String ext,
  ) async {
    final oldFile = File(
      oldMp3.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), ext),
    );
    if (!oldFile.existsSync()) return;

    final newFile = File(
      newMp3.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), ext),
    );
    try {
      if (oldFile.path.toLowerCase() == newFile.path.toLowerCase()) {
        final temp = File(
          '${oldFile.parent.path}${Platform.pathSeparator}TEMP_${oldFile.uri.pathSegments.last}',
        );
        await oldFile.copy(temp.path);
        await oldFile.delete();
        await temp.copy(newFile.path);
        await temp.delete();
      } else if (!newFile.existsSync()) {
        await oldFile.copy(newFile.path);
        await oldFile.delete();
      }
    } catch (_) {}
  }

  Future<void> _syncKaraokeFile(String oldMp3, String newMp3) async {
    final RegExp ext = RegExp(r'\.mp3$', caseSensitive: false);
    final File oldFile = File(oldMp3.replaceAll(ext, '_K.mp3'));
    final File newFile = File(newMp3.replaceAll(ext, '_K.mp3'));
    if (!oldFile.existsSync()) return;
    if (oldFile.path.toLowerCase() == newFile.path.toLowerCase()) return;
    if (newFile.existsSync()) return;
    try {
      await oldFile.copy(newFile.path);
      await oldFile.delete();
    } catch (_) {}
  }
}
