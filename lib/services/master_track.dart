import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;

import '../core/lrc_timeline.dart';
import '../core/lyric_files.dart';
import '../core/lyric_match.dart';
import '../core/lyric_timing_check.dart';
import '../providers/db_provider.dart';
import '../providers/metadata_provider.dart';
import '../providers/nlp_provider.dart';

/// Una canción, en el orden de Gabriel: nombre, letra, inicio de la letra,
/// recorte real, desplazar .lrc y cues, BPM, −14 LUFS. Solo lo que falta.
class MasterOutcome {
  final String path;
  final int trimHeadMs;
  final LyricStatus? lyric;
  final String detail;
  final bool stopped;

  /// GMX_LYR_CHECK: 'OK', 'FIXED', 'REVIEW' o null (sin letra / megamix).
  final String? lyricCheck;
  final String lyricCheckReason;

  const MasterOutcome({
    required this.path,
    required this.trimHeadMs,
    required this.lyric,
    required this.detail,
    this.stopped = false,
    this.lyricCheck,
    this.lyricCheckReason = '',
  });
}

class MasterTrack {
  static const int megamixBytes = 16 * 1024 * 1024;

  static Future<MasterOutcome> run({
    required WidgetRef ref,
    required String path,
    required bool withLyrics,
    bool writeCues = true,
    void Function(String stage)? onStage,
    bool Function()? shouldStop,
  }) async {
    bool stop() => shouldStop?.call() == true;
    MasterOutcome abortedAt(String at) => MasterOutcome(
      path: at,
      trimHeadMs: 0,
      lyric: null,
      detail: '',
      stopped: true,
    );

    onStage?.call('METADATA_CLEANUP');
    final String oldPath = path;
    var current = await ref.read(metadataWorkerProvider).processSingleFile(path);
    if (current != oldPath) {
      await ref.read(dbServiceProvider).retargetTrackMetadata(oldPath, current);
      await _retargetBpmCache(oldPath, current);
    }

    await _ensureBackup(current);

    final bool mega = File(current).lengthSync() > megamixBytes;
    await _mark(current, 'GMX_NAME_OK', '1');
    await _mark(current, 'GMX_TYPE', mega ? 'MEGAMIX' : 'SONG');
    await _mark(current, 'GMX_BACKUP', '1');
    if (stop()) return abortedAt(current);

    LyricStatus? lyric;
    String detail = '';
    if (mega) {
      await _mark(current, 'GMX_LYR', 'NA');
    } else if (withLyrics) {
      onStage?.call('LYRICS');
      final worker = ref.read(nlpWorkerProvider);
      lyric = await worker.processSingleFile(current);
      detail = worker.lastDetail;
      final String? lyrMark = switch (lyric) {
        LyricStatus.ok => 'SYNC',
        LyricStatus.plain => 'PLAIN',
        LyricStatus.retry => 'RETRY',
        LyricStatus.noMatch => 'NONE',
        LyricStatus.failed => 'RETRY',
        LyricStatus.kept => null,
        LyricStatus.doubt => null,
      };
      if (lyric != LyricStatus.doubt && lyrMark != null) {
        await _mark(current, 'GMX_LYR', lyrMark);
      } else if (lyric != LyricStatus.doubt) {
        final marks = await rust_dsp.readGmxMarks(inputPath: current);
        if (marks.lyr.isEmpty) {
          final String lrcPath = _lrcPath(current);
          final bool manual = File(lrcPath).existsSync() && !_lrcIsAuto(lrcPath);
          await _mark(current, 'GMX_LYR', manual ? 'MANUAL' : 'SYNC');
        }
      }
      final File lrc = File(_lrcPath(current));
      if (lrc.existsSync()) {
        final int? start = firstVerseMs(await lrc.readAsString());
        if (start != null) await _mark(current, 'GMX_LYR_START_MS', '$start');
      }
    }
    if (stop()) return abortedAt(current);

    onStage?.call('DSP_ANALYSIS');
    final before = await rust_dsp.readGmxMarks(inputPath: current);
    final bool needTrim = before.trimMs < 0;
    final bool needLufs = !before.lufsDone;
    final bool needBpm = !before.bpmOk;
    var trimHead = 0;
    if (needTrim || needLufs || needBpm) {
      final rust_dsp.MasterRewrite rw;
      try {
        rw = await rust_dsp.masterRewrite(
          inputPath: current,
          doTrim: needTrim,
          doLufs: needLufs,
          introBpm: mega,
          forceHeadMs: -1,
          forceTailMs: -1,
        );
      } catch (e) {
        if (e.toString().contains('Cancelado')) return abortedAt(current);
        rethrow;
      }
      trimHead = rw.trimHeadMs;
      final int residual = rw.residualMs;
      // Solo el corte medido en esta pasada. Un GMX_TRIM de antes (Take On
      // Me, 1010 ms) no mueve una letra que ya coincide con el archivo.
      final int? shiftBy = measuredLyricShiftMs(
        audioCut: rw.rewritten && trimHead > 0,
        trimHeadMs: trimHead,
        residualMs: residual,
      );
      if (shiftBy != null) {
        await _shiftLyricsAndCues(
          ref,
          current,
          trimHead,
          extraDelayMs: residual,
        );
      }
      if (trimHead > 0) {
        await _trimKaraokeTwin(current, trimHead, rw.trimTailMs);
      }
    }
    if (stop()) return abortedAt(current);

    // Chequeo de tiempo de la letra contra el audio ya final. Corre también
    // en canciones ya masterizadas (el audio no se vuelve a procesar).
    ({String? mark, String reason}) check = (mark: null, reason: '');
    if (!mega && withLyrics) {
      onStage?.call('LYRIC_CHECK');
      try {
        check = await _checkLyricTiming(ref, current);
      } catch (e) {
        debugPrint('🔴 [GMX_LYR_CHECK] $e');
      }
    }
    if (stop()) return abortedAt(current);

    final String karaokeTwin = current.replaceAll(
      RegExp(r'\.mp3$', caseSensitive: false),
      '_K.mp3',
    );
    if (!mega && File(karaokeTwin).existsSync()) {
      await _mark(current, 'GMX_K', '1');
    }

    onStage?.call('WATERMARK_ID3');
    final after = await rust_dsp.readGmxMarks(inputPath: current);
    if (after.reason.isNotEmpty) {
      detail = detail.isEmpty ? after.reason : '$detail · ${after.reason}';
    }
    final bool lyricsOk = mega ||
        after.lyr == 'SYNC' ||
        after.lyr == 'PLAIN' ||
        after.lyr == 'MANUAL' ||
        after.lyr == 'NA' ||
        after.lyr == 'NONE';
    if (after.trimMs >= 0 && after.lufsDone && after.bpmOk && lyricsOk) {
      await rust_dsp.injectWatermark(inputPath: current);
    }
    if (stop()) return abortedAt(current);

    if (writeCues) {
      onStage?.call('DB_ISAR');
      await _assignCues(ref, current);
    }

    return MasterOutcome(
      path: current,
      trimHeadMs: trimHead,
      lyric: lyric,
      detail: detail,
      lyricCheck: check.mark,
      lyricCheckReason: check.reason,
    );
  }

  /// OK / FIXED / REVIEW. Nunca toca una letra manual ([gmx_manual]): si
  /// falla, queda en REVIEW. Al reemplazar guarda `.lrc.bak` una sola vez.
  static Future<({String? mark, String reason})> _checkLyricTiming(
    WidgetRef ref,
    String path,
  ) async {
    final File lrc = File(_lrcPath(path));
    if (!lrc.existsSync()) return (mark: null, reason: '');
    final String text = await lrc.readAsString();
    if (lrcIsPlain(text)) return (mark: null, reason: '');
    final int durationMs =
        (await rust_dsp.getAudioDurationMs(inputPath: path)).toInt();
    final worker = ref.read(nlpWorkerProvider);
    final int? voice = await worker.probeVoiceOnsetMs(path);
    final LyricTimingVerdict v = checkLyricTiming(
      lrc: text,
      durationMs: durationMs,
      voiceOnsetMs: voice,
    );
    if (v.ok) {
      await _mark(path, 'GMX_LYR_CHECK', 'OK');
      return (mark: 'OK', reason: '');
    }
    if (!lrcIsManual(text)) {
      final marks = await rust_dsp.readGmxMarks(inputPath: path);
      // 1) La búsqueda de Automix y luego TODOS los candidatos (con respaldos
      //    sin año / intercambiado). LRCLIB trae tiempos del audio original:
      //    se aplica el mismo recorte que ya tiene el archivo.
      final List<String> candidates = <String>[];
      final choice = await worker.lookupSafeLyric(path);
      if (choice.hasText && choice.kind != LyricKind.plain) {
        candidates.add(choice.fileText);
      }
      candidates.addAll(await worker.syncedLyricCandidates(path));
      String? fixed = firstPassingLyric(
        candidates: candidates,
        current: text,
        trimMs: marks.trimMs,
        durationMs: durationMs,
        voiceOnsetMs: voice,
      );
      // 2) Letra completa pero corrida: se mueve entera a donde entra la voz.
      fixed ??= realignLrcToVoice(
        lrc: text,
        durationMs: durationMs,
        voiceOnsetMs: voice,
      );
      if (fixed != null && fixed.trim() != text.trim()) {
        keepOriginalLrcBakSync(lrc.path);
        await lrc.writeAsString(fixed);
        await _syncKaraokeLrc(path, fixed);
        final int? start = firstVerseMs(fixed);
        if (start != null) await _mark(path, 'GMX_LYR_START_MS', '$start');
        await _mark(path, 'GMX_LYR_CHECK', 'FIXED');
        return (mark: 'FIXED', reason: v.reason);
      }
    }
    await _mark(path, 'GMX_LYR_CHECK', 'REVIEW');
    return (mark: 'REVIEW', reason: v.reason);
  }

  /// Si el `_K` tiene su propio `.lrc`, recibe la misma letra (con su `.bak`).
  static Future<void> _syncKaraokeLrc(String path, String text) async {
    final String kLrc = path.replaceAll(
      RegExp(r'\.mp3$', caseSensitive: false),
      '_K.lrc',
    );
    final File f = File(kLrc);
    if (!f.existsSync()) return;
    if (lrcIsManual(f.readAsStringSync())) return;
    keepOriginalLrcBakSync(kLrc);
    await f.writeAsString(text);
  }

  static Future<List<File>> backupsIn(String folder) async {
    final Directory dir = Directory(
      '$folder${Platform.pathSeparator}.gatomix_original',
    );
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.toLowerCase().endsWith('.mp3'))
        .toList();
  }

  /// Devuelve el audio original y deshace el desplazamiento de letra y cues.
  static Future<void> restore(WidgetRef ref, String mp3Path) async {
    final File live = File(mp3Path);
    final File backup = File(
      '${live.parent.path}${Platform.pathSeparator}.gatomix_original${Platform.pathSeparator}${live.uri.pathSegments.last}',
    );
    if (!backup.existsSync()) {
      throw Exception('No hay original en .gatomix_original/');
    }
    final marks = await rust_dsp.readGmxMarks(inputPath: mp3Path);
    final int trim = marks.trimMs < 0 ? 0 : marks.trimMs;
    final File lrc = File(_lrcPath(mp3Path));
    var undo = trim;
    if (lrc.existsSync()) {
      final String content = await lrc.readAsString();
      final int? stored = lrcShiftMs(content);
      if (stored != null) undo = stored;
      if (!lrcIsManual(content) && stored != null && stored != 0) {
        await lrc.writeAsString(unshiftLrcText(content, stored));
      } else if (trim > 0 && !lrcIsManual(content) && stored == null) {
        await lrc.writeAsString(unshiftLrcText(content, trim));
      }
    }
    if (undo != 0) {
      final db = ref.read(dbServiceProvider);
      final meta = await db.getTrackMetadata(mp3Path);
      if (meta != null) {
        int? cue = meta.cueInMs;
        int? mix = meta.mixOutMs;
        if (cue != null) {
          final int next = cue + undo;
          cue = next < 0 ? 0 : next;
        }
        if (mix != null) {
          final int next = mix + undo;
          mix = next < 0 ? 0 : next;
        }
        await db.saveTrackMetadata(
          path: mp3Path,
          mixProfile: meta.mixProfile,
          durationMs: meta.mixDurationMs,
          genre: meta.genreAssigned,
          cueInMs: cue,
          mixOutMs: mix,
          hasLyrics: meta.hasLyrics,
          hasBpm: meta.hasBpm,
          hasCurve: meta.hasCurve,
          isManualCue: meta.isManualCue,
        );
      }
    }
    await backup.copy(mp3Path);
  }

  static Future<void> _mark(String path, String key, String value) async {
    try {
      await rust_dsp.setGmxMark(inputPath: path, key: key, value: value);
    } catch (e) {
      debugPrint('🔴 [GMX $key] $e');
    }
  }

  static String _lrcPath(String mp3) =>
      mp3.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '.lrc');

  static bool _lrcIsAuto(String lrcPath) {
    final File f = File(lrcPath);
    final File reg = File(
      '${f.parent.path}${Platform.pathSeparator}_lyrics_auto.json',
    );
    if (!reg.existsSync()) return false;
    try {
      final dynamic decoded = jsonDecode(reg.readAsStringSync());
      return decoded is Map && decoded.containsKey(f.uri.pathSegments.last);
    } catch (_) {
      return false;
    }
  }

  static Future<void> _ensureBackup(String path) async {
    final File src = File(path);
    if (!src.existsSync()) return;
    final Directory dir = Directory(
      '${src.parent.path}${Platform.pathSeparator}.gatomix_original',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final File dest = File(
      '${dir.path}${Platform.pathSeparator}${src.uri.pathSegments.last}',
    );
    if (dest.existsSync()) return;
    await src.copy(dest.path);
  }

  static Future<void> _shiftLyricsAndCues(
    WidgetRef ref,
    String path,
    int trimMs, {
    int extraDelayMs = 0,
  }) async {
    final int net = trimMs - extraDelayMs;
    final File lrc = File(_lrcPath(path));
    if (lrc.existsSync()) {
      final String text = await lrc.readAsString();
      final bool manual = lrcIsManual(text) || !_lrcIsAuto(lrc.path);
      if (!manual) {
        final LrcShift shifted = shiftLrcText(
          text,
          trimMs,
          extraDelayMs: extraDelayMs,
        );
        if (shifted.changed) {
          await lrc.writeAsString(shifted.text);
          await _mark(path, 'GMX_LRC_SHIFT', '1');
        }
      }
    }
    final db = ref.read(dbServiceProvider);
    final meta = await db.getTrackMetadata(path);
    if (meta == null) return;
    int? cue = meta.cueInMs;
    int? mix = meta.mixOutMs;
    if (cue != null) {
      final int next = cue - net;
      cue = next < 0 ? 0 : next;
    }
    if (mix != null) {
      final int next = mix - net;
      mix = next < 0 ? 0 : mix;
    }
    await db.saveTrackMetadata(
      path: path,
      mixProfile: meta.mixProfile,
      durationMs: meta.mixDurationMs,
      genre: meta.genreAssigned,
      cueInMs: cue,
      mixOutMs: mix,
      hasLyrics: meta.hasLyrics,
      hasBpm: meta.hasBpm,
      hasCurve: meta.hasCurve,
      isManualCue: meta.isManualCue,
    );
  }

  static Future<void> _trimKaraokeTwin(String path, int headMs, int tailMs) async {
    final String k = path.replaceAll(
      RegExp(r'\.mp3$', caseSensitive: false),
      '_K.mp3',
    );
    if (!File(k).existsSync()) return;
    try {
      final marks = await rust_dsp.readGmxMarks(inputPath: k);
      if (marks.trimMs >= 0) return;
      await rust_dsp.masterRewrite(
        inputPath: k,
        doTrim: true,
        doLufs: false,
        introBpm: false,
        forceHeadMs: headMs,
        forceTailMs: tailMs,
      );
    } catch (e) {
      debugPrint('🔴 [_K trim] $e');
    }
  }

  static Future<void> _retargetBpmCache(String oldPath, String newPath) async {
    final Directory parent = File(newPath).parent;
    final File cache = File(
      '${parent.path}${Platform.pathSeparator}_dj_metadata.json',
    );
    if (!cache.existsSync()) return;
    try {
      final dynamic decoded = jsonDecode(await cache.readAsString());
      if (decoded is! Map) return;
      final Map<String, dynamic> map = Map<String, dynamic>.from(decoded);
      if (!map.containsKey(oldPath)) return;
      map[newPath] = map[oldPath];
      map[File(newPath).uri.pathSegments.last] = map[oldPath];
      map.remove(oldPath);
      await cache.writeAsString(jsonEncode(map));
    } catch (_) {}
  }

  static const Map<String, Map<String, dynamic>> _mixProfiles = {
    'salsa': {'curve': 'echo_out', 'durationMs': 0},
    'merengue': {'curve': 'echo_out', 'durationMs': 0},
    'cumbia': {'curve': 'brake_stop', 'durationMs': 1000},
    'nacional': {'curve': 'brake_stop', 'durationMs': 500},
    'vallenato': {'curve': 'echo_out', 'durationMs': 0},
    'guaracha': {'curve': 'brake_stop', 'durationMs': 1000},
    '80s': {'curve': 'quick_fade', 'durationMs': 2500},
    'rock': {'curve': 'eq_kill', 'durationMs': 2000},
    'balada': {'curve': 'quick_fade', 'durationMs': 3000},
    'española': {'curve': 'quick_fade', 'durationMs': 2500},
    'bachata': {'curve': 'constant_power', 'durationMs': 4000},
    'actualidad': {'curve': 'bass_swap', 'durationMs': 6000},
    'fiesta': {'curve': 'bass_swap', 'durationMs': 6000},
    'descargas': {'curve': 'constant_power', 'durationMs': 5000},
  };

  /// Género y cues. Un cue que ya existía (manual o no) se conserva: si el
  /// recorte lo movió, [_shiftLyricsAndCues] ya lo hizo.
  static Future<void> _assignCues(WidgetRef ref, String path) async {
    final String rawGenre = await rust_dsp.readAudioGenre(inputPath: path);
    String assignedProfile = 'constant_power';
    int assignedDuration = 6000;
    if (rawGenre.isNotEmpty && rawGenre != 'desconocido') {
      for (final key in _mixProfiles.keys) {
        if (rawGenre.contains(key)) {
          assignedProfile = _mixProfiles[key]!['curve'] as String;
          assignedDuration = _mixProfiles[key]!['durationMs'] as int;
          break;
        }
      }
    }
    final db = ref.read(dbServiceProvider);
    final existing = await db.getTrackMetadata(path);
    final bool isManual = existing?.isManualCue ?? false;
    final int physical = (await rust_dsp.getAudioDurationMs(inputPath: path)).toInt();
    int leadMs = 0;
    int tailMs = 0;
    try {
      final mt = await rust_dsp.readMasterTags(inputPath: path);
      if (mt.analyzed) {
        leadMs = mt.leadMs.toInt();
        tailMs = mt.tailMs.toInt();
      }
    } catch (_) {}
    int calculatedCueIn =
        (rawGenre.contains('electro') || rawGenre.contains('rock')) ? 100 : 350;
    if (leadMs > 0) calculatedCueIn = (leadMs - 50).clamp(0, 15000);
    final int usableMs = physical - tailMs;
    int calculatedMixOut = usableMs > assignedDuration
        ? usableMs - assignedDuration
        : usableMs - 2000;
    if (calculatedMixOut < 0) calculatedMixOut = 0;
    final int finalCueIn = existing != null &&
            (isManual || (existing.cueInMs != null && existing.cueInMs! > 0))
        ? existing.cueInMs!
        : calculatedCueIn;
    final int finalMixOut = existing != null &&
            (isManual || (existing.mixOutMs != null && existing.mixOutMs! > 0))
        ? existing.mixOutMs!
        : calculatedMixOut;
    await db.saveTrackMetadata(
      path: path,
      mixProfile: assignedProfile,
      durationMs: assignedDuration,
      genre: rawGenre,
      cueInMs: finalCueIn,
      mixOutMs: finalMixOut,
      isManualCue: isManual,
    );
  }
}
