import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/lyric_match.dart';
import '../providers/nlp_provider.dart';

/// Aviso breve cuando una letra pendiente llega en segundo plano.
final GlobalKey<ScaffoldMessengerState> lyricRetryMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// El mismo desplazamiento que usaba `_offsetLrcTimeline` en la ingesta YT.
Future<void> offsetLrcTimeline(String lrcPath, int trimmedMs) async {
  final File file = File(lrcPath);
  if (!file.existsSync() || trimmedMs <= 0) return;

  try {
    final List<String> lines = await file.readAsLines();
    final RegExp regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
    final List<String> next = <String>[];

    for (final String line in lines) {
      final Match? match = regex.firstMatch(line);
      if (match == null) {
        next.add(line);
        continue;
      }
      final int min = int.parse(match.group(1)!);
      final int sec = int.parse(match.group(2)!);
      int ms = int.parse(match.group(3)!);
      if (match.group(3)!.length == 2) ms *= 10;

      int totalMs = (min * 60000) + (sec * 1000) + ms - trimmedMs;
      if (totalMs < 0) totalMs = 0;

      final String newMin = (totalMs ~/ 60000).toString().padLeft(2, '0');
      final String newSec = ((totalMs % 60000) ~/ 1000).toString().padLeft(
        2,
        '0',
      );
      final String newMs = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
      next.add('[$newMin:$newSec.$newMs]${match.group(4)!}');
    }
    await file.writeAsString(next.join('\n'));
  } catch (_) {}
}

class LyricRetryEntry {
  final String mp3Path;
  final int trimmedMs;
  final DateTime addedAt;

  const LyricRetryEntry({
    required this.mp3Path,
    required this.trimmedMs,
    required this.addedAt,
  });

  LyricRetryEntry copyWith({int? trimmedMs}) {
    return LyricRetryEntry(
      mp3Path: mp3Path,
      trimmedMs: trimmedMs ?? this.trimmedMs,
      addedAt: addedAt,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'mp3Path': mp3Path,
    'trimmedMs': trimmedMs,
    'addedAt': addedAt.toUtc().toIso8601String(),
  };

  static LyricRetryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? path = raw['mp3Path'];
    final Object? trim = raw['trimmedMs'];
    final Object? at = raw['addedAt'];
    if (path is! String || path.isEmpty) return null;
    final int ms = trim is int ? trim : int.tryParse('$trim') ?? 0;
    final DateTime added = DateTime.tryParse('$at')?.toUtc() ?? DateTime.now().toUtc();
    return LyricRetryEntry(mp3Path: path, trimmedMs: ms, addedAt: added);
  }
}

class LyricRetryQueue {
  LyricRetryQueue({
    required this.fetch,
    this.storeFile,
    this.storeFileLoader,
    this.offsetLrc = offsetLrcTimeline,
    this.exists,
    this.onFound,
    this.clock,
    this.period = const Duration(minutes: 1),
  });

  final Future<LyricFetchOutcome> Function(String mp3Path) fetch;
  final File? storeFile;
  final Future<File> Function()? storeFileLoader;
  final Future<void> Function(String lrcPath, int trimmedMs) offsetLrc;
  final bool Function(String path)? exists;
  final void Function(String fileName)? onFound;
  final DateTime Function()? clock;
  final Duration period;

  final List<LyricRetryEntry> entries = <LyricRetryEntry>[];
  bool _busy = false;
  bool _loaded = false;
  Timer? _timer;
  File? _resolved;

  bool get isTicking => _busy;

  bool fileExists(String path) => exists?.call(path) ?? File(path).existsSync();

  Future<File> _file() async {
    if (storeFile != null) return storeFile!;
    if (_resolved != null) return _resolved!;
    final Future<File> Function()? loader = storeFileLoader;
    if (loader == null) {
      throw StateError('Cola de letras sin archivo');
    }
    _resolved = await loader();
    return _resolved!;
  }

  Future<void> load() async {
    final File file = await _file();
    entries.clear();
    if (file.existsSync()) {
      try {
        final Object? raw = jsonDecode(await file.readAsString());
        if (raw is List) {
          for (final Object? item in raw) {
            final LyricRetryEntry? entry = LyricRetryEntry.fromJson(item);
            if (entry != null) entries.add(entry);
          }
        }
      } catch (_) {}
    }
    _loaded = true;
  }

  Future<void> _save() async {
    final File file = await _file();
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsString(
      jsonEncode(<Object>[for (final LyricRetryEntry e in entries) e.toJson()]),
    );
  }

  Future<void> enqueue({
    required String mp3Path,
    required int trimmedMs,
  }) async {
    if (!_loaded) await load();
    final int i = entries.indexWhere((LyricRetryEntry e) => e.mp3Path == mp3Path);
    if (i >= 0) {
      entries[i] = entries[i].copyWith(trimmedMs: trimmedMs);
    } else {
      entries.add(
        LyricRetryEntry(
          mp3Path: mp3Path,
          trimmedMs: trimmedMs,
          addedAt: (clock ?? DateTime.now)().toUtc(),
        ),
      );
    }
    await _save();
  }

  /// Reloj de un minuto. El primer pase no bloquea el arranque.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(period, (_) {
      unawaited(tick());
    });
    unawaited(tick());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> tick() async {
    if (_busy) return;
    _busy = true;
    try {
      if (!_loaded) await load();
      final List<LyricRetryEntry> pending = List<LyricRetryEntry>.from(entries);
      for (final LyricRetryEntry entry in pending) {
        if (!entries.any((LyricRetryEntry e) => e.mp3Path == entry.mp3Path)) {
          continue;
        }
        if (!fileExists(entry.mp3Path)) {
          entries.removeWhere((LyricRetryEntry e) => e.mp3Path == entry.mp3Path);
          continue;
        }
        final LyricFetchOutcome outcome = await fetch(entry.mp3Path);
        if (outcome == LyricFetchOutcome.serverDown) continue;
        entries.removeWhere((LyricRetryEntry e) => e.mp3Path == entry.mp3Path);
        if (outcome == LyricFetchOutcome.found) {
          final String lrcPath = entry.mp3Path.replaceAll(
            RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
            '.lrc',
          );
          if (entry.trimmedMs > 50) {
            await offsetLrc(lrcPath, entry.trimmedMs);
          }
          final String name = entry.mp3Path.replaceAll('\\', '/').split('/').last;
          onFound?.call(name);
        }
      }
      await _save();
    } catch (_) {
    } finally {
      _busy = false;
    }
  }
}

final lyricRetryQueueProvider = Provider<LyricRetryQueue>((Ref ref) {
  final LyricRetryQueue queue = LyricRetryQueue(
    fetch: (String path) => ref.read(nlpWorkerProvider).processSingleFile(path),
    storeFileLoader: () async {
      final Directory dir = await getApplicationSupportDirectory();
      return File(
        '${dir.path}${Platform.pathSeparator}lyric_retry_queue.json',
      );
    },
    onFound: (String name) {
      lyricRetryMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('$kLyricAddedNoticePrefix$name'),
          duration: const Duration(seconds: 3),
        ),
      );
    },
  );
  ref.onDispose(queue.dispose);
  return queue;
});
