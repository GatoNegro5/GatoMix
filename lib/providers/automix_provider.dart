import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';

// 🛡️ FIX: Se cambió foundation.dart por material.dart para dar acceso al BuildContext
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;

import '../core/hal/platform_strategy.dart';
import '../core/session_store.dart';
import '../core/audio/af_caps.dart';
import '../core/audio/tempo_drift.dart';
import '../djiphone/iphone_library.dart';
import '../core/audio/dj_audio_handler.dart';

import '../core/audio_path.dart';
import '../core/gatomix_store.dart';
import '../core/livedj_order.dart';
import '../core/queue_bpm.dart';
import '../core/lyric_files.dart' hide sameAudioPath;
import '../core/session_restore.dart';
import '../core/lyric_match.dart';
import '../core/lyric_approx.dart';
import '../ui/widgets/approx_lyric_icon.dart' show approxLyricRevision;
import 'db_provider.dart';
import 'nlp_provider.dart';
import 'equalizer_provider.dart';

// 🛡️ FIX: Dependencia para dspWorkerProvider

enum MixStrategy { sequential, random }

/// Perfil acústico de la transición. Define si la mezcla permuta los graves
/// entre decks o se limita al crossfade DAWN puro.
enum AutomixMixProfile { smoothBassSwap, manualOverride }

// 🎚️ Corte de graves de la permuta de bajos: Butterworth de 2 polos a 140 Hz.
// Se inyecta en libmpv vía la propiedad 'af'; cero DSP por muestras en Dart.
// Corte de graves con `equalizer` (único filtro de libavfilter que trae el
// libmpv empaquetado; `highpass` no existe y tumbaba toda la cadena `af`).
const String _bassKillFilter =
    'equalizer=f=45:width_type=o:w=2.5:g=-24,equalizer=f=110:width_type=o:w=1.6:g=-14';

// ⏱️ Ventana DAWN automática: entra 5 s antes del SET OUT y se prolonga sobre
// la cola de energía que `silencedetect` encuentre después del punto — nunca
// menos de 2 s ni más de 5 s. El SET OUT deja de ser un final seco.
const int kDawnLeadMs = 5000;
const int _dawnTailMinMs = 2000;
const int _dawnTailMaxMs = 5000;

// 🎚️ Cambio manual: el fundido se dimensiona con la pista entrante, no con una
// constante. Fraseo 4/4 acotado a esta banda.
const int _manualMixMinMs = 8000;
const int _manualMixMaxMs = 18000;

class LyricLine {
  final Duration timestamp;
  final String text;
  LyricLine({required this.timestamp, required this.text});
}

class AutomixState {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final List<String> playlist;
  final int currentIndex;
  final String? currentTrackPath;
  final List<LyricLine> lyrics;
  final int activeLyricIndex;
  final String? nextTrackPath;
  final int triggerRemainingMs;
  final MixStrategy mixStrategy;
  final int customCueInMs;
  final int customMixOutMs;
  final int customMixDurationMs;
  final bool autoMixArmed;

  AutomixState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playlist = const [],
    this.currentIndex = -1,
    this.currentTrackPath,
    this.lyrics = const [],
    this.activeLyricIndex = -1,
    this.nextTrackPath,
    this.triggerRemainingMs = 4000,
    this.mixStrategy = MixStrategy.sequential,
    this.customCueInMs = -1,
    this.customMixOutMs = -1,
    this.customMixDurationMs = 18000,
    this.autoMixArmed = true,
  });

  AutomixState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    List<String>? playlist,
    int? currentIndex,
    String? currentTrackPath,
    bool clearCurrentTrackPath = false,
    List<LyricLine>? lyrics,
    int? activeLyricIndex,
    String? nextTrackPath,
    bool clearNextTrackPath = false,
    int? triggerRemainingMs,
    MixStrategy? mixStrategy,
    int? customCueInMs,
    int? customMixOutMs,
    int? customMixDurationMs,
    bool? autoMixArmed,
  }) {
    return AutomixState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playlist: playlist ?? this.playlist,
      currentIndex: currentIndex ?? this.currentIndex,
      currentTrackPath: clearCurrentTrackPath
          ? null
          : (currentTrackPath ?? this.currentTrackPath),
      lyrics: lyrics ?? this.lyrics,
      activeLyricIndex: activeLyricIndex ?? this.activeLyricIndex,
      nextTrackPath: clearNextTrackPath
          ? null
          : (nextTrackPath ?? this.nextTrackPath),
      triggerRemainingMs: triggerRemainingMs ?? this.triggerRemainingMs,
      mixStrategy: mixStrategy ?? this.mixStrategy,
      customCueInMs: customCueInMs ?? this.customCueInMs,
      customMixOutMs: customMixOutMs ?? this.customMixOutMs,
      customMixDurationMs: customMixDurationMs ?? this.customMixDurationMs,
      autoMixArmed: autoMixArmed ?? this.autoMixArmed,
    );
  }
}

class AutomixNotifier extends Notifier<AutomixState> {
  late final Player _playerA;
  late final Player _playerB;
  bool _usePlayerA = true;

  Player get _activeAutomix => _usePlayerA ? _playerA : _playerB;
  Player get _standbyPlayer => _usePlayerA ? _playerB : _playerA;
  List<Player> get deckPlayers => [_playerA, _playerB];
  bool get _deckHot => _activeAutomix.state.duration.inMilliseconds > 0;

  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;
  StreamSubscription? _completedSub;

  bool _isCrossfading = false;
  bool get nextTrackLocked => _isCrossfading;
  bool _parking = false;
  bool _isPrepModeBypass = false;
  int _lastSavedPositionMs = 0;
  int _sessionPositionMs = 0;
  bool _sessionWasPlaying = false;
  bool _freezePersist = false;
  bool _mixOutIsManual = false;
  bool _cueInIsManual = false;
  bool _mixPlanReady = false;
  int _autoMixAnchorMs = 0;
  String? _outroPlanToken;
  int _outroProbeGen = 0;
  bool _outroProbeBusy = false;
  String? _lastDurationPlanKey;
  int _lastUiPosMs = -1;
  final TempoDrift _drift = TempoDrift();
  int _lastLyricIndex = -2;
  String? _shownLyricsPath;
  List<LyricLine>? _lyricUndo;
  String? _lyricUndoPath;
  final Set<String> _shuffleKnown = <String>{};
  final Map<String, int> _outroEnergyEndCache = {};
  final Map<String, List<LyricLine>> _lyricPrime = {};

  late final PlatformMixStrategy _mixStrategy;

  @override
  AutomixState build() {
    _playerA = Player();
    _playerB = Player();

    _mixStrategy = MixStrategyFactory.getStrategy();

    for (final Player deck in deckPlayers) {
      final dynamic platform = deck.platform;
      platform?.setProperty('vid', 'no');
      platform?.setProperty('af', _mixStrategy.hifiFilter);
    }

    _attachListeners(_playerA);
    _initPersistence();

    globalAudioHandler.onPlayPause = () => togglePlayPause();
    globalAudioHandler.onNext = () => _osStep(1);
    globalAudioHandler.onPrevious = () => _osStep(-1);
    globalAudioHandler.onSeek = (pos) => seek(pos);

    final StreamSubscription<String> lrcSub = lrcChanges.listen(
      (String path) => unawaited(reloadLyrics(path)),
    );

    ref.onDispose(() {
      lrcSub.cancel();
      _cancelOutroProbe();
      _positionSub?.cancel();
      _durationSub?.cancel();
      _playingSub?.cancel();
      _completedSub?.cancel();
      _playerA.dispose();
      _playerB.dispose();
    });

    return AutomixState();
  }

  Future<void> setMixPoint(String type) async {
    if (state.currentTrackPath == null) return;
    final currentPosMs = state.position.inMilliseconds;
    final db = ref.read(dbServiceProvider);

    if (type == 'IN') {
      await db.saveTrackMetadata(
        path: state.currentTrackPath!,
        cueInMs: currentPosMs,
        isManualCue: true,
      );
      _cueInIsManual = true;
      state = state.copyWith(customCueInMs: currentPosMs);
    } else {
      await db.saveTrackMetadata(
        path: state.currentTrackPath!,
        mixOutMs: currentPosMs,
        isManualCue: true,
      );
      _mixOutIsManual = true;
      state = state.copyWith(
        customMixOutMs: currentPosMs,
        // Provisional hasta que el análisis del outro fije la cola real.
        customMixDurationMs: kDawnLeadMs + _dawnTailMinMs,
        autoMixArmed: true,
      );
      _recalculateMixWindow();
      if (!state.isPlaying) _isPrepModeBypass = true;
    }
  }

  String _getSessionFilePath() {
    return _mixStrategy.getSessionPath();
  }

  Future<void> persistSession() => _saveSnapshot();

  bool _pausedByInterruption = false;

  /// Llamada/alarma/otra app: pausa ambos decks (también a mitad de un cruce)
  /// sin tocar cola, posición ni sesión. Devuelve `true` si estaba sonando.
  Future<bool> pauseForInterruption() async {
    if (!state.isPlaying) return false;
    _pausedByInterruption = true;
    _cancelOutroProbe();
    try {
      await _playerA.pause();
    } catch (_) {}
    try {
      await _playerB.pause();
    } catch (_) {}
    _saveSnapshot();
    return true;
  }

  /// Reanuda exactamente donde quedó, solo si la pausa la causó el sistema.
  Future<void> resumeAfterInterruption() async {
    if (!_pausedByInterruption) return;
    _pausedByInterruption = false;
    try {
      await _activeAutomix.play();
    } catch (_) {}
    if (_isCrossfading) {
      try {
        await _standbyPlayer.play();
      } catch (_) {}
    }
    unawaited(_planVariableMixWindow());
  }

  int? _readSavedUiRoute() {
    try {
      final session = _mixStrategy.getSessionPath();
      final file = File(
        '${File(session).parent.path}${Platform.pathSeparator}_ui_route.json',
      );
      if (!file.existsSync()) return null;
      final data = jsonDecode(file.readAsStringSync());
      final route = data['route'];
      if (route is int && route >= 0 && route < 7) return route;
    } catch (_) {}
    return null;
  }

  Future<void> _saveSnapshot() async {
    try {
      final file = File(_getSessionFilePath());
      final pos = _freezePersist
          ? _sessionPositionMs
          : state.position.inMilliseconds;
      final data = {
        'playlist': state.playlist,
        'currentIndex': state.currentIndex,
        'positionMs': pos,
        'mixStrategy': state.mixStrategy.index,
        'autoMixArmed': state.autoMixArmed,
        'wasPlaying': _freezePersist ? _sessionWasPlaying : state.isPlaying,
      };
      // Atómico y en fila (ver SessionStore): sobrevive cierres y updates.
      await SessionStore.writeJson(file.path, data);
    } catch (_) {}
  }

  Future<void> _initPersistence() async {
    try {
      final data = SessionStore.readJson(_getSessionFilePath());
      if (data is! Map) return;

      final rawList = ((data['playlist'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      // Pistas renombradas por Masterizar se reencuentran. Rutas equivalentes
      // (mayúsculas, separadores, junctions) cuentan como una sola.
      final AutomixSessionRestore restored = restoreAutomixSession(
        data,
        strategyCount: MixStrategy.values.length,
      );
      final List<String> playlist = <String>[];
      final Map<String, int> at = <String, int>{};
      int? index;
      for (var i = 0; i < restored.playlist.length; i++) {
        final String c = canonicalAudioPath(restored.playlist[i]);
        final String key = audioPathKey(c);
        final int? prev = at[key];
        if (prev != null) {
          if (i == restored.index) index = prev;
          continue;
        }
        if (i == restored.index) index = playlist.length;
        at[key] = playlist.length;
        playlist.add(c);
      }
      if (index == null && playlist.isNotEmpty && restored.index != null) {
        index = restored.index!.clamp(0, playlist.length - 1);
      }
      final bool sameTrack = restored.positionMs != null && index != null;
      final positionMs = sameTrack ? restored.positionMs : null;
      final mixStrategyIdx = restored.mixStrategyIndex;
      // El modo (Shuffle/Secuencial) se respeta aunque no haya pista actual.
      state = state.copyWith(mixStrategy: MixStrategy.values[mixStrategyIdx]);
      final autoMixArmed = restored.autoMixArmed;
      final wasPlaying = restored.wasPlaying;

      if (playlist.isNotEmpty && index != null && index >= 0) {
        state = state.copyWith(
          playlist: playlist,
          currentIndex: index,
          currentTrackPath: playlist[index],
          mixStrategy: MixStrategy.values[mixStrategyIdx],
          autoMixArmed: autoMixArmed,
        );
        if (rawList.length != playlist.length ||
            rawList.join('\n') != playlist.join('\n')) {
          _sessionPositionMs = positionMs ?? 0;
          _sessionWasPlaying = wasPlaying;
          _freezePersist = true;
          unawaited(_saveSnapshot());
          _freezePersist = false;
        }

        await _loadLyrics(playlist[index]);
        await _loadTrackMetadata(playlist[index]);
        await Future.delayed(const Duration(milliseconds: 150));

        final int seekMs = (positionMs != null && positionMs > 0)
            ? positionMs
            : (state.customCueInMs > 0 ? state.customCueInMs : 0);
        if (positionMs != null && positionMs > 0) {
          _sessionPositionMs = positionMs;
        }

        if (wasPlaying) {
          _freezePersist = false;
          await _forceOpenAndPlay(playlist[index], seekMs: seekMs);
        } else {
          await _activeAutomix.open(Media(playlist[index]), play: false);
          ref
              .read(automixEqualizerProvider.notifier)
              .adapt(_activeAutomix, playlist[index]);
          try {
            await _activeAutomix.stream.duration
                .firstWhere((d) => d.inMilliseconds > 0)
                .timeout(const Duration(seconds: 2));
          } catch (_) {}
          if (seekMs > 0) {
            await _activeAutomix.seek(Duration(milliseconds: seekMs));
          }
        }
        if (state.mixStrategy == MixStrategy.random) {
          _applyShuffleBank(advance: false);
        }
      }
    } catch (_) {}
  }

  void setMixStrategy(MixStrategy strategy) {
    state = state.copyWith(mixStrategy: strategy);
    _saveSnapshot();
    _recalculateMixWindow();
  }

  void shufflePlaylist() {
    unawaited(_shufflePlaylistAsync());
  }

  Future<void> _shufflePlaylistAsync() async {
    final List<String> paths = state.playlist
        .where((p) => !isKaraokeAudioPath(p))
        .toList();
    await preloadQueueBpm(paths);
    _applyShuffleBank(advance: true);
  }

  void _applyShuffleBank({required bool advance}) {
    // Al reabrir, el orden guardado es la verdad: no se vuelve a armar.
    if (!advance) return;
    final paths = dedupeAudioPaths(
      state.playlist.where((p) => !isKaraokeAudioPath(p)).toList(),
    );
    if (paths.length <= 2) {
      state = state.copyWith(
        playlist: paths,
        mixStrategy: MixStrategy.random,
        currentIndex: paths.isEmpty
            ? -1
            : (state.currentTrackPath == null
                  ? state.currentIndex
                  : paths.indexWhere(
                      (p) => sameAudioPath(p, state.currentTrackPath),
                    )),
      );
      _saveSnapshot();
      return;
    }
    _shuffleKnown.addAll(paths);
    GatomixStore.migrate(File(_getSessionFilePath()).parent.path);
    preloadQueueBpmSync(paths);
    final String? playing = state.currentTrackPath;
    final ShuffleMemory mem = GatomixStore.loadShuffleMemory(<String>[
      ...paths,
      if (playing != null) playing,
    ]);
    final HarmonicOrder built = buildHarmonicShuffle(
      paths,
      _extractBpm,
      keyOf: camelotFromPath,
      usedPairs: mem.pairs,
      recentAge: mem.age,
      playing: playing,
      continueFrom: playing,
    );
    String? head;
    if (playing != null) {
      for (final String path in paths) {
        if (sameAudioPath(path, playing)) {
          head = path;
          break;
        }
      }
    }
    final List<String> rest = List<String>.from(built.tracks);
    for (final path in paths) {
      if (head != null && sameAudioPath(path, head)) continue;
      if (!rest.any((r) => sameAudioPath(r, path))) rest.add(path);
    }
    final List<String> playlist = <String>[
      if (head != null) head,
      ...rest.where((p) => head == null || !sameAudioPath(p, head)),
    ];
    GatomixStore.commitShuffleMemory(rest, anchor: head ?? playing);

    state = state.copyWith(
      playlist: playlist,
      currentIndex: 0,
      mixStrategy: MixStrategy.random,
    );

    _saveSnapshot();
    _recalculateMixWindow();

    debugPrint("🔀 [DSP] Shuffle armónico. ${rest.length} pistas.");
  }

  void toggleMixStrategy() {
    if (state.mixStrategy == MixStrategy.sequential) {
      shufflePlaylist();
    } else {
      state = state.copyWith(mixStrategy: MixStrategy.sequential);
      _saveSnapshot();
      debugPrint("➡️ [DSP] Modo SECUENCIAL activado.");
    }
  }

  void toggleAutoMixBypass() {
    state = state.copyWith(autoMixArmed: !state.autoMixArmed);
    _saveSnapshot();
  }

  void syncDynamicPlaylist(List<String> newPlaylistOrdered) {
    newPlaylistOrdered = dedupeAudioPaths(
      newPlaylistOrdered.where((p) => !isKaraokeAudioPath(p)).toList(),
    );
    bool hasPath(Iterable<String> xs, String p) =>
        xs.any((e) => sameAudioPath(e, p));
    final added = <String>[
      for (final path in newPlaylistOrdered)
        if (!hasPath(state.playlist, path) && !hasPath(_shuffleKnown, path))
          path,
    ];
    // Cola estable en secuencial. Con Shuffle, lo nuevo entra en el hueco
    // armónico de lo que aún no suena. El banco solo se arma con lista vacía.
    if (added.isNotEmpty &&
        state.playlist.isEmpty &&
        state.mixStrategy == MixStrategy.random &&
        newPlaylistOrdered.length > 2 &&
        !_isCrossfading) {
      state = state.copyWith(
        playlist: List<String>.from(newPlaylistOrdered),
        mixStrategy: MixStrategy.random,
      );
      _applyShuffleBank(advance: true);
      return;
    }
    var ordered = newPlaylistOrdered;
    if (state.mixStrategy == MixStrategy.random) {
      final kept = <String>[
        for (final path in state.playlist)
          if (hasPath(newPlaylistOrdered, path)) path,
      ];
      final added = <String>[
        for (final path in newPlaylistOrdered)
          if (!hasPath(kept, path)) path,
      ];
      if (added.isNotEmpty) {
        preloadQueueBpmSync(added);
        for (final String path in added) {
          saveTrackMusic(
            path,
            bpm: _extractBpm(path),
            camelot: harmonicKeyOf(path),
          );
        }
        var lock = 0;
        if (state.currentTrackPath != null) {
          final int i = kept.indexWhere(
            (String p) => sameAudioPath(p, state.currentTrackPath),
          );
          if (i >= 0) lock = i + 1;
        }
        if (_isCrossfading && state.nextTrackPath != null) {
          final int i = kept.indexWhere(
            (String p) => sameAudioPath(p, state.nextTrackPath),
          );
          if (i >= 0 && i + 1 > lock) lock = i + 1;
        }
        final List<String> merged = insertHarmonicTracks(
          queue: kept,
          incoming: added,
          bpmOf: _extractBpm,
          keyOf: harmonicKeyOf,
          lockedPrefix: lock,
          playing: state.currentTrackPath,
          pinned: _isCrossfading ? state.nextTrackPath : null,
        );
        ordered = dedupeAudioPaths(merged);
      } else {
        ordered = dedupeAudioPaths(kept);
      }
    }
    ordered = dedupeAudioPaths(ordered);
    if (listEquals(state.playlist, ordered)) return;
    int newCurrentIndex = -1;
    if (state.currentTrackPath != null) {
      newCurrentIndex = ordered.indexWhere(
        (p) => sameAudioPath(p, state.currentTrackPath),
      );
    }
    state = state.copyWith(playlist: ordered, currentIndex: newCurrentIndex);
    _saveSnapshot();
    _recalculateMixWindow();
  }

  Future<List<Map<String, dynamic>>> searchLyrics(String query) async {
    List<Map<String, dynamic>> allResults = [];
    try {
      final uriGlobal = Uri.parse(
        'https://lrclib.net/api/search?q=${Uri.encodeComponent(query.trim())}',
      );
      final resGlobal = await http
          .get(uriGlobal)
          .timeout(const Duration(seconds: 5));
      if (resGlobal.statusCode == 200) {
        allResults.addAll(
          List<Map<String, dynamic>>.from(jsonDecode(resGlobal.body)),
        );
      }

      if (!query.contains('-')) {
        final uriArtist = Uri.parse(
          'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(query.trim())}',
        );
        final resArtist = await http
            .get(uriArtist)
            .timeout(const Duration(seconds: 5));
        if (resArtist.statusCode == 200) {
          allResults.addAll(
            List<Map<String, dynamic>>.from(jsonDecode(resArtist.body)),
          );
        }
      } else {
        final parts = query.split('-');
        final uriAdvanced = Uri.parse(
          'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(parts[0].trim())}&track_name=${Uri.encodeComponent(parts.sublist(1).join(' ').trim())}',
        );
        final resAdvanced = await http
            .get(uriAdvanced)
            .timeout(const Duration(seconds: 5));
        if (resAdvanced.statusCode == 200) {
          allResults.addAll(
            List<Map<String, dynamic>>.from(jsonDecode(resAdvanced.body)),
          );
        }
      }

      final uniqueById = <int, Map<String, dynamic>>{};
      for (var item in allResults) {
        if (item['id'] != null) uniqueById[item['id']] = item;
      }
      return uniqueById.values.toList();
    } catch (_) {}
    return [];
  }

  Future<void> applyManualLyrics(String audioPath, String syncedLyrics) async {
    try {
      final lrcPath = audioPath.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );
      await File(lrcPath).writeAsString(syncedLyrics);
      if (state.currentTrackPath == audioPath) await _loadLyrics(audioPath);
    } catch (_) {}
  }

  Future<void> _loadTrackMetadata(String audioPath) async {
    final metadata = await ref
        .read(dbServiceProvider)
        .getTrackMetadata(audioPath);

    final bool manual = metadata?.isManualCue ?? false;
    _cueInIsManual = manual && (metadata?.cueInMs ?? 0) > 0;
    _mixOutIsManual = manual && (metadata?.mixOutMs ?? 0) > 0;
    state = state.copyWith(
      customCueInMs: metadata?.cueInMs ?? -1,
      customMixOutMs: metadata?.mixOutMs ?? -1,
      autoMixArmed: true,
    );
    _recalculateMixWindow();
  }

  Future<void> seek(Duration position) async {
    if (state.currentTrackPath == null || _isCrossfading) return;
    _isPrepModeBypass = false;
    await _activeAutomix.seek(position);
  }

  double _extractBpm(String? path) => knownBpm(path);

  Future<int> _calculateSmartCueIn(String path, Player player) async {
    final meta = await ref.read(dbServiceProvider).getTrackMetadata(path);

    if (meta != null &&
        meta.isManualCue &&
        meta.cueInMs != null &&
        meta.cueInMs! > 0) {
      return meta.cueInMs!;
    }

    final int durMs = player.state.duration.inMilliseconds;
    if (durMs > 30000) return 10000;
    return 0;
  }

  Future<void> _recalculateMixWindow() async {
    if (state.duration.inMilliseconds == 0) return;
    final nextIdx = _calculateNextIndex();
    final nextPath = nextIdx != -1 ? state.playlist[nextIdx] : null;

    int safeMixOutMs = _mixOutIsManual ? state.customMixOutMs : -1;
    int safeCueInMs = state.customCueInMs;

    // SET IN / SET OUT mandan. Letra y ADN solo rellenan huecos.
    if (!_mixOutIsManual && safeMixOutMs <= 0) {
      final trackPathLower = state.currentTrackPath?.toLowerCase() ?? '';
      final isRemix = trackPathLower.contains('remix');
      final isEdm =
          trackPathLower.contains('electronica') ||
          trackPathLower.contains('house');
      final isTropical =
          trackPathLower.contains('salsa') ||
          trackPathLower.contains('cumbia') ||
          trackPathLower.contains('merengue');

      if (state.lyrics.isNotEmpty) {
        final lastLyricMs = state.lyrics.last.timestamp.inMilliseconds;
        safeMixOutMs = lastLyricMs + 1500;
      } else if (isRemix || isEdm) {
        safeMixOutMs = (state.duration.inMilliseconds * 0.65).toInt();
      } else if (isTropical) {
        safeMixOutMs = (state.duration.inMilliseconds * 0.80).toInt();
      } else {
        safeMixOutMs = (state.duration.inMilliseconds * 0.75).toInt();
      }
    }

    if (!_mixOutIsManual &&
        safeMixOutMs > 0 &&
        safeMixOutMs >= state.duration.inMilliseconds - 4000) {
      safeMixOutMs = state.duration.inMilliseconds - 4000;
    }
    if (!_cueInIsManual &&
        safeCueInMs > 0 &&
        safeCueInMs > state.duration.inMilliseconds ~/ 2) {
      safeCueInMs = 0;
    }

    int triggerMs = 0;
    if (safeMixOutMs > 0) {
      triggerMs = state.duration.inMilliseconds - safeMixOutMs;
    } else {
      triggerMs = 8000;
    }

    _autoMixAnchorMs = safeMixOutMs;
    _mixPlanReady = _mixOutIsManual;
    state = state.copyWith(
      nextTrackPath: nextPath,
      clearNextTrackPath: nextPath == null,
      triggerRemainingMs: triggerMs,
      customMixOutMs: safeMixOutMs,
      customCueInMs: safeCueInMs,
    );
    if (nextPath != null) unawaited(_primeLyrics(nextPath));

    // En pausa no se lanza FFmpeg. Si la pista ya está medida, el plan sale de caché.
    final String? planPath = state.currentTrackPath;
    final bool outroWarm =
        planPath != null && _outroEnergyEndCache.containsKey(planPath);
    if (state.isPlaying || outroWarm) {
      unawaited(_planVariableMixWindow());
    }
  }

  void _cancelOutroProbe() {
    // La sonda corre en Rust (no hay proceso que matar): invalidar la
    // generación descarta cualquier resultado en vuelo.
    _outroProbeGen++;
  }

  /// Detecta dónde muere la energía del outro (Rust, en proceso, todas las
  /// plataformas). Resultado cacheado por ruta.
  Future<int> _probeOutroEnergyEndMs(String path, int durationMs) async {
    final cached = _outroEnergyEndCache[path];
    if (cached != null) return cached;
    if (durationMs <= 0) return 0;

    if (_outroEnergyEndCache.length >= 48) {
      _outroEnergyEndCache.remove(_outroEnergyEndCache.keys.first);
    }

    if (_outroProbeBusy) return -1;
    _outroProbeBusy = true;

    final int gen = _outroProbeGen;

    try {
      final int energyEnd = (await rust_dsp.outroEnergyEndMs(
        inputPath: path,
        durationMs: BigInt.from(durationMs),
      )).toInt();
      if (gen != _outroProbeGen) return durationMs;
      if (energyEnd > 0) {
        final clamped = energyEnd.clamp(
          (durationMs * 0.55).toInt(),
          durationMs,
        );
        _outroEnergyEndCache[path] = clamped;
        debugPrint(
          '🎛️ [TRACKER OUTRO] $path energyEnd=${clamped}ms / dur=$durationMs',
        );
        return clamped;
      }
    } catch (e) {
      debugPrint('🔴 [TRACKER OUTRO] sonda de outro falló: $e');
      if (gen != _outroProbeGen) return durationMs;
    } finally {
      _outroProbeBusy = false;
    }

    if (gen != _outroProbeGen) return durationMs;
    _outroEnergyEndCache[path] = durationMs;
    return durationMs;
  }

  /// Dimensiona un cambio manual con la pista que entra: compases 4/4 sobre su
  /// BPM, acotados a 8–18 s. Sin BPM legible en el nombre cae al largo relativo
  /// de la pista. Jamás una constante fija.
  int _planManualMixDurationMs(String? incomingPath, int incomingDurationMs) {
    final double bpm = _extractBpm(incomingPath);
    if (bpm >= 60 && bpm <= 200) {
      final double barMs = (60000.0 / bpm) * 4;
      for (final int bars in const [16, 8, 4, 2]) {
        final int span = (barMs * bars).round();
        if (span >= _manualMixMinMs && span <= _manualMixMaxMs) return span;
      }
    }
    if (incomingDurationMs > 0) {
      return (incomingDurationMs * 0.06).round().clamp(
        _manualMixMinMs,
        _manualMixMaxMs,
      );
    }
    return 12000;
  }

  Future<void> _planVariableMixWindow() async {
    final path = state.currentTrackPath;
    final durationMs = state.duration.inMilliseconds;
    if (path == null || durationMs <= 0) return;

    final token = '$path|$durationMs|${state.lyrics.length}';
    _outroPlanToken = token;
    final int gen = _outroProbeGen;

    // El análisis del outro decide cuánta cola real queda después del SET OUT.
    // Sonda ocupada (-1) = otro plan sigue en vuelo (p. ej. al corregir la
    // duración real): esperar y reintentar; abortar dejaba el plan sin listo
    // y la mezcla nunca disparaba en la línea roja.
    int energyEnd = await _probeOutroEnergyEndMs(path, durationMs);
    for (
      int retry = 0;
      energyEnd < 0 &&
          retry < 100 &&
          gen == _outroProbeGen &&
          _outroPlanToken == token &&
          state.currentTrackPath == path;
      retry++
    ) {
      await Future.delayed(const Duration(milliseconds: 150));
      energyEnd = await _probeOutroEnergyEndMs(path, durationMs);
    }
    if (energyEnd < 0 ||
        gen != _outroProbeGen ||
        _outroPlanToken != token ||
        state.currentTrackPath != path) {
      return;
    }

    int mixOut = _mixOutIsManual
        ? state.customMixOutMs
        : (_autoMixAnchorMs > 0
              ? _autoMixAnchorMs
              : (durationMs * 0.75).toInt());
    mixOut = mixOut.clamp(0, durationMs);

    // La cola no puede rebasar ni la energía del outro ni el final del archivo.
    final int physicalTail = (durationMs - mixOut).clamp(0, _dawnTailMaxMs);
    final int energyTail = (energyEnd - mixOut).clamp(0, _dawnTailMaxMs);
    final int tailMs = min(
      energyTail >= _dawnTailMinMs ? energyTail : _dawnTailMinMs,
      physicalTail,
    );

    int fadeMs = kDawnLeadMs + tailMs;
    if (mixOut - kDawnLeadMs < 0) {
      fadeMs = mixOut + tailMs;
    }

    debugPrint(
      '🎛️ [TRACKER MIX PLAN] out=${mixOut}ms lead=${kDawnLeadMs}ms '
      'cola=${tailMs}ms fade=${fadeMs}ms energyEnd=$energyEnd',
    );

    _mixPlanReady = true;
    state = state.copyWith(customMixOutMs: mixOut, customMixDurationMs: fadeMs);
  }

  Future<void> _prefetchNextOutro(String nextPath) async {
    final int gen = _outroProbeGen;
    try {
      final dur = await rust_dsp.getAudioDurationMs(inputPath: nextPath);
      if (gen != _outroProbeGen || !state.isPlaying) return;
      await _probeOutroEnergyEndMs(nextPath, dur.toInt());
    } catch (e) {
      debugPrint('🔴 [TRACKER OUTRO] prefetch $nextPath: $e');
    }
  }

  /// Siguiente/anterior desde el icono exterior (notificación, bloqueo):
  /// da la vuelta a la lista como una app profesional.
  Future<void> _osStep(int delta) async {
    final int n = state.playlist.length;
    if (n < 2 || state.currentIndex < 0) return;
    await forceTransition((state.currentIndex + delta) % n);
  }

  Future<void> forceTransition(int index) async {
    await jumpToTrack(index);
  }

  /// LAB: fundido a la siguiente con el motor de mezcla; el archivo sale
  /// cuando el deck saliente ya soltó el handle.
  Future<void> mixOutForQuarantine(String outgoingPath) async {
    if (outgoingPath.isEmpty) return;

    Future<void> waitIdle() async {
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 25));
      while (_isCrossfading && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    if (state.isPlaying && state.playlist.length > 1) {
      await waitIdle();
      if (state.currentTrackPath == outgoingPath) {
        final int next = _calculateNextIndex();
        if (next >= 0 && state.playlist[next] != outgoingPath) {
          await jumpToTrack(next);
        }
      }
      await waitIdle();
    } else {
      await stopAndRelease();
    }
    await Future.delayed(const Duration(milliseconds: 400));
  }

  int _calculateNextIndex() {
    return nextDifferentAudioIndex(
      state.playlist,
      state.currentIndex,
      state.currentTrackPath,
    );
  }

  Future<void> _stopWhenNoNext() async {
    _isCrossfading = false;
    try {
      await _playerA.pause();
    } catch (_) {}
    try {
      await _playerB.pause();
    } catch (_) {}
    try {
      await _playerA.stop();
    } catch (_) {}
    try {
      await _playerB.stop();
    } catch (_) {}

    if (state.autoMixArmed && _calculateNextIndex() < 0) {
      // Fin de cola en automático: no queda pista residual en memoria.
      // Con el candado manual (autoMixArmed=false) la pista se conserva
      // para seguir marcando SET IN / SET OUT.
      _cancelOutroProbe();
      _isPrepModeBypass = false;
      _sessionPositionMs = 0;
      _sessionWasPlaying = false;
      _lastSavedPositionMs = 0;
      state = state.copyWith(
        isPlaying: false,
        clearNextTrackPath: true,
        clearCurrentTrackPath: true,
        playlist: const <String>[],
        currentIndex: -1,
        position: Duration.zero,
        duration: Duration.zero,
        lyrics: const <LyricLine>[],
        activeLyricIndex: -1,
        customCueInMs: -1,
        customMixOutMs: -1,
      );
    } else {
      state = state.copyWith(isPlaying: false, clearNextTrackPath: true);
    }
    _saveSnapshot();
  }

  Future<void> loadContextAndPlay(
    List<String> newPlaylist,
    int startIndex,
  ) async {
    // Las pistas _K de Karaoke nunca suenan en Automix (solo TV).
    // Dos grafías de la misma ruta cuentan como una.
    if (startIndex >= 0 && startIndex < newPlaylist.length) {
      final String picked = newPlaylist[startIndex];
      final List<String> clean = dedupeAudioPaths(
        newPlaylist.where((t) => !isKaraokeAudioPath(t)).toList(),
      );
      var idx = -1;
      for (var i = 0; i < clean.length; i++) {
        if (sameAudioPath(clean[i], picked)) {
          idx = i;
          break;
        }
      }
      if (idx < 0) {
        final int before = newPlaylist
            .take(startIndex)
            .where((t) => !isKaraokeAudioPath(t))
            .length;
        idx = before < clean.length ? before : 0;
      }
      newPlaylist = clean;
      startIndex = idx;
    }
    if (startIndex < 0 || startIndex >= newPlaylist.length) return;
    _freezePersist = false;

    final String nextTrack = newPlaylist[startIndex];
    if (_isCrossfading && !_deckHot) _isCrossfading = false;

    if (!_deckHot || state.currentTrackPath == null) {
      state = state.copyWith(
        playlist: newPlaylist,
        currentIndex: startIndex,
        currentTrackPath: nextTrack,
        position: Duration.zero,
        lyrics: [],
        activeLyricIndex: -1,
      );

      await _forceOpenAndPlay(nextTrack);

      await _loadLyrics(nextTrack);
      await _loadTrackMetadata(nextTrack);
      try {
        _recalculateMixWindow();
      } catch (_) {}
      _saveSnapshot();
      return;
    }

    if (sameAudioPath(state.currentTrackPath, nextTrack)) {
      state = state.copyWith(playlist: newPlaylist, currentIndex: startIndex);
      if (!state.isPlaying) {
        await _activeAutomix.setVolume(100.0);
        await _activeAutomix.play();
      }
      _saveSnapshot();
      return;
    }

    if (!_isCrossfading) {
      _isCrossfading = true;
      _isPrepModeBypass = false;

      final Player fadingPlayer = _activeAutomix;
      final Player incomingPlayer = _standbyPlayer;

      try {
        await incomingPlayer.setVolume(0.0);
        await incomingPlayer.open(Media(nextTrack), play: false);
        ref
            .read(automixEqualizerProvider.notifier)
            .adapt(incomingPlayer, nextTrack);
      } catch (e) {
        _isCrossfading = false;
        return;
      }

      int cueInMs = 0;
      try {
        cueInMs = await _calculateSmartCueIn(nextTrack, incomingPlayer);
        if (cueInMs > 0) {
          await incomingPlayer.seek(Duration(milliseconds: cueInMs));
        }
      } catch (_) {}

      final fadingBpm = _extractBpm(state.currentTrackPath);
      final incomingBpm = _extractBpm(nextTrack);
      double incomingRate = 1.0;
      if (fadingBpm > 60 && incomingBpm > 60) {
        final ratio = (fadingBpm * fadingPlayer.state.rate) / incomingBpm;
        if (ratio >= 0.88 && ratio <= 1.12) incomingRate = ratio;
      }

      try {
        await incomingPlayer.setRate(incomingRate);
        await incomingPlayer.play();
      } catch (e) {
        _isCrossfading = false;
        return;
      }

      _usePlayerA = !_usePlayerA;
      _attachListeners(_activeAutomix);

      List<String> updatedPlaylist = List.from(newPlaylist);
      updatedPlaylist.remove(nextTrack);
      updatedPlaylist.insert(0, nextTrack);

      state = state.copyWith(
        playlist: updatedPlaylist,
        currentIndex: 0,
        currentTrackPath: nextTrack,
        position: Duration(milliseconds: cueInMs),
        duration: await _trueDuration(nextTrack, incomingPlayer.state.duration),
        lyrics: _lyricPrime[nextTrack] ?? const <LyricLine>[],
        activeLyricIndex: -1,
      );

      await _loadLyrics(nextTrack);
      await _loadTrackMetadata(nextTrack);
      try {
        _recalculateMixWindow();
      } catch (_) {}
      _saveSnapshot();

      await _executeMixEngine(
        fadingPlayer: fadingPlayer,
        incomingPlayer: incomingPlayer,
        mixDurationMs: _planManualMixDurationMs(
          nextTrack,
          incomingPlayer.state.duration.inMilliseconds,
        ),
        mixProfile: AutomixMixProfile.manualOverride,
        incomingRate: incomingRate,
        isManualSkip: true,
      );
    }
  }

  Future<void> jumpToTrack(int index) async {
    if (index < 0 || index >= state.playlist.length) return;
    if (_isCrossfading && _deckHot) return;
    if (state.currentIndex == index && state.isPlaying && _deckHot) return;

    if (!_deckHot) {
      final String coldTrack = state.playlist[index];
      _isCrossfading = false;
      state = state.copyWith(
        currentIndex: index,
        currentTrackPath: coldTrack,
        position: Duration.zero,
        lyrics: [],
        activeLyricIndex: -1,
      );
      await _forceOpenAndPlay(coldTrack);
      await _loadLyrics(coldTrack);
      await _loadTrackMetadata(coldTrack);
      try {
        _recalculateMixWindow();
      } catch (_) {}
      _saveSnapshot();
      return;
    }

    _isCrossfading = true;
    _isPrepModeBypass = false;

    final String nextTrack = state.playlist[index];
    final Player fadingPlayer = _activeAutomix;
    final Player incomingPlayer = _standbyPlayer;

    try {
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.open(Media(nextTrack), play: false);
      ref
          .read(automixEqualizerProvider.notifier)
          .adapt(incomingPlayer, nextTrack);
    } catch (e) {
      _isCrossfading = false;
      return;
    }

    int cueInMs = 0;
    try {
      cueInMs = await _calculateSmartCueIn(nextTrack, incomingPlayer);
      if (cueInMs > 0) {
        await incomingPlayer.seek(Duration(milliseconds: cueInMs));
        await Future.delayed(const Duration(milliseconds: 150));
      }
    } catch (_) {}

    final fadingBpm = _extractBpm(state.currentTrackPath);
    final incomingBpm = _extractBpm(nextTrack);
    double incomingRate = 1.0;

    if (fadingBpm > 60 && incomingBpm > 60) {
      final ratio = (fadingBpm * fadingPlayer.state.rate) / incomingBpm;
      if (ratio >= 0.88 && ratio <= 1.12) {
        incomingRate = ratio;
      }
    }

    try {
      await incomingPlayer.setRate(incomingRate);
      await incomingPlayer.play();
    } catch (e) {
      _isCrossfading = false;
      return;
    }

    _usePlayerA = !_usePlayerA;
    _attachListeners(_activeAutomix);

    List<String> newPlaylist = List.from(state.playlist);
    if (state.currentTrackPath != null) {
      newPlaylist.remove(state.currentTrackPath);
    }
    newPlaylist.remove(nextTrack);
    newPlaylist.insert(0, nextTrack);

    state = state.copyWith(
      playlist: newPlaylist,
      currentIndex: 0,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
      duration: await _trueDuration(nextTrack, incomingPlayer.state.duration),
      lyrics: _lyricPrime[nextTrack] ?? const <LyricLine>[],
      activeLyricIndex: -1,
    );

    await _loadLyrics(nextTrack);
    await _loadTrackMetadata(nextTrack);
    try {
      _recalculateMixWindow();
    } catch (_) {}
    _saveSnapshot();

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixDurationMs: _planManualMixDurationMs(
        nextTrack,
        incomingPlayer.state.duration.inMilliseconds,
      ),
      mixProfile: AutomixMixProfile.manualOverride,
      incomingRate: incomingRate,
      isManualSkip: true,
    );
  }

  Future<void> _triggerCrossfade() async {
    if (_isCrossfading || state.nextTrackPath == null) return;
    _isCrossfading = true;

    final String nextTrack = state.nextTrackPath!;
    await _primeLyrics(nextTrack);
    final int outgoingMixDuration = state.customMixDurationMs.clamp(
      kDawnLeadMs,
      kDawnLeadMs + _dawnTailMaxMs,
    );
    final Player fadingPlayer = _activeAutomix;
    final Player incomingPlayer = _standbyPlayer;

    try {
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.open(Media(nextTrack), play: false);
      ref
          .read(automixEqualizerProvider.notifier)
          .adapt(incomingPlayer, nextTrack);
    } catch (e) {
      _isCrossfading = false;
      return;
    }

    int cueInMs = 0;
    try {
      cueInMs = await _calculateSmartCueIn(nextTrack, incomingPlayer);
      if (cueInMs > 0) {
        await incomingPlayer.seek(Duration(milliseconds: cueInMs));
        await Future.delayed(const Duration(milliseconds: 150));
      }
    } catch (_) {}

    final fadingBpm = _extractBpm(state.currentTrackPath);
    final incomingBpm = _extractBpm(nextTrack);
    double incomingRate = 1.0;

    if (fadingBpm > 60 && incomingBpm > 60) {
      final ratio = (fadingBpm * fadingPlayer.state.rate) / incomingBpm;
      if (ratio >= 0.88 && ratio <= 1.12) {
        incomingRate = ratio;
      }
    }

    try {
      await incomingPlayer.setRate(incomingRate);
      await incomingPlayer.play();
    } catch (e) {
      _isCrossfading = false;
      return;
    }

    _usePlayerA = !_usePlayerA;
    _attachListeners(_activeAutomix);

    List<String> newPlaylist = List.from(state.playlist);
    if (state.currentTrackPath != null) {
      newPlaylist.remove(state.currentTrackPath);
    }
    newPlaylist.remove(nextTrack);
    newPlaylist.insert(0, nextTrack);

    state = state.copyWith(
      playlist: newPlaylist,
      currentIndex: 0,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
      duration: await _trueDuration(nextTrack, incomingPlayer.state.duration),
      lyrics: _lyricPrime[nextTrack] ?? const <LyricLine>[],
      activeLyricIndex: -1,
    );

    await _loadLyrics(nextTrack);
    await _loadTrackMetadata(nextTrack);
    try {
      _recalculateMixWindow();
    } catch (_) {}
    _saveSnapshot();

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixDurationMs: outgoingMixDuration,
      mixProfile: AutomixMixProfile.smoothBassSwap,
      incomingRate: incomingRate,
      isManualSkip: false,
    );
  }

  // 🛡️ FIX: INYECCIÓN DE LA SUPER MEZCLA DAWN Y PARÁMETROS CORREGIDOS
  Future<void> _executeMixEngine({
    required Player fadingPlayer,
    required Player incomingPlayer,
    required int mixDurationMs,
    required AutomixMixProfile mixProfile,
    double incomingRate = 1.0,
    bool isManualSkip = false,
  }) async {
    final eqN = ref.read(automixEqualizerProvider.notifier);
    String inBase() => eqN.filterFor(incomingPlayer);
    String outBase() => eqN.filterFor(fadingPlayer);
    final platformOut = fadingPlayer.platform as dynamic;
    final platformIn = incomingPlayer.platform as dynamic;

    // Un skip manual de 4,5 s no da margen musical para permutar graves.
    final bool useBassSwap = mixProfile == AutomixMixProfile.smoothBassSwap;
    final String lowCutIn = AfCaps.sanitize(
      [inBase(), _bassKillFilter].where((s) => s.isNotEmpty).join(','),
    );
    final String lowCutOut = AfCaps.sanitize(
      [outBase(), _bassKillFilter].where((s) => s.isNotEmpty).join(','),
    );
    bool bassSwapped = false;

    try {
      platformIn?.setProperty('audio-pitch-correction', 'yes');
      platformOut?.setProperty('audio-pitch-correction', 'yes');
      // La entrante nace sin graves para que nunca convivan dos líneas de bajo
      // sumando energía en el cruce. Inaudible: su volumen todavía es 0.
      platformIn?.setProperty('af', useBassSwap ? lowCutIn : inBase());
      platformOut?.setProperty('af', outBase());

      await incomingPlayer.setVolume(0.0);

      final fadeStopwatch = Stopwatch()..start();
      final actualDuration = mixDurationMs;

      while (fadeStopwatch.elapsedMilliseconds < actualDuration) {
        final progress = (fadeStopwatch.elapsedMilliseconds / actualDuration)
            .clamp(0.0, 1.0);

        // 🎛️ SUPER MEZCLA DAWN (Alta Energía / Cero Huecos Acústicos)
        final rateIn = (progress * 1.8).clamp(0.0, 1.0);
        final rateOut = ((1.0 - progress) * 1.8).clamp(0.0, 1.0);

        final smoothRateIn = pow(rateIn, 1.2).toDouble();
        final smoothRateOut = pow(rateOut, 1.2).toDouble();

        // 🔀 PERMUTA DE GRAVES en el cruce, donde ambas rondan el 0.9: la
        // saliente cede el bajo y la entrante lo recupera. Una única
        // reconstrucción de la cadena af por deck, enmascarada por el nivel
        // máximo de la mezcla.
        if (useBassSwap && !bassSwapped && progress >= 0.5) {
          bassSwapped = true;
          platformOut?.setProperty('af', lowCutOut);
          platformIn?.setProperty('af', inBase());
        }

        await incomingPlayer.setVolume(
          (smoothRateIn * 100.0).clamp(0.0, 100.0),
        );
        await fadingPlayer.setVolume((smoothRateOut * 100.0).clamp(0.0, 100.0));

        await Future.delayed(const Duration(milliseconds: 32));
      }
    } catch (e) {
      debugPrint("🔴 [ERROR DSP AUTOMIX]: $e");
    } finally {
      // 🛡️ FIX: el glide de tempo arranca en incomingRate. Fijar aquí el rate a
      // 1.0 provocaba un salto de velocidad hacia atrás al iniciar la rampa.
      // Mucha corrección: se queda en el BPM de entrada y TempoDrift reparte
      // la diferencia en 5 pasos (10 %–50 %) hasta su BPM real.
      _drift.begin(_extractBpm(state.currentTrackPath), incomingRate);
      final bool keepRate = _drift.active && incomingRate != 1.0;
      final bool willGlideRate = incomingRate != 1.0 && !keepRate;

      try {
        await incomingPlayer.setVolume(100.0);
        if (!willGlideRate && !keepRate) await incomingPlayer.setRate(1.0);
        platformIn?.setProperty('af', inBase());
        platformOut?.setProperty('af', outBase());
        await fadingPlayer.setVolume(0.0);
        await fadingPlayer.setRate(1.0);
        await fadingPlayer.stop();
      } catch (_) {}

      if (willGlideRate) {
        try {
          final pitchStopwatch = Stopwatch()..start();
          final double rateDiff = 1.0 - incomingRate;
          while (pitchStopwatch.elapsedMilliseconds < 3000) {
            final double p = (pitchStopwatch.elapsedMilliseconds / 3000).clamp(
              0.0,
              1.0,
            );
            final double curve = sin(p * (pi / 2));
            await incomingPlayer.setRate(incomingRate + (rateDiff * curve));
            await Future.delayed(const Duration(milliseconds: 50));
          }
        } catch (_) {}
        try {
          await incomingPlayer.setRate(1.0);
        } catch (_) {}
      }

      _isCrossfading = false;
    }
  }

  final Map<String, int> _exactDurCache = {};

  /// Duración real del archivo (Rust). Si difiere de la de libmpv en más de
  /// 1.5 s manda la real: evita la barra que termina al 70-80 % y daña la mezcla.
  Future<Duration> _trueDuration(String? path, Duration mpv) async {
    if (path == null) return mpv;
    try {
      int? ms = _exactDurCache[path];
      if (ms == null) {
        ms = (await rust_dsp.exactDurationMs(inputPath: path)).toInt();
        _exactDurCache[path] = ms;
      }
      if (ms > 0 && (ms - mpv.inMilliseconds).abs() > 1500) {
        debugPrint(
          '⏱️ [AUTOMIX] Duración corregida ${mpv.inSeconds}s → ${ms ~/ 1000}s: $path',
        );
        return Duration(milliseconds: ms);
      }
    } catch (_) {}
    return mpv;
  }

  /// Aplica la duración real a la pista actual y recalcula la ventana de mezcla.
  Future<void> _applyTrueDuration(String? path, Duration mpv) async {
    if (path == null || mpv.inMilliseconds <= 0) return;
    final Duration real = await _trueDuration(path, mpv);
    if (real == mpv || state.currentTrackPath != path) return;
    if (state.duration == real) return;
    _lastDurationPlanKey = '$path|${real.inMilliseconds}';
    state = state.copyWith(duration: real);
    try {
      _recalculateMixWindow();
    } catch (_) {}
  }

  void _attachListeners(Player player) {
    _lastUiPosMs = -1;
    _lastLyricIndex = -2;
    _lastDurationPlanKey = null;
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();

    // media_kit no re-emite duration/playing si el evento ya pasó (1ª pista).
    final Duration liveDur = player.state.duration;
    final Duration livePos = player.state.position;
    final bool livePlaying = player.state.playing;
    if (liveDur.inMilliseconds > 0) {
      _lastDurationPlanKey =
          '${state.currentTrackPath}|${liveDur.inMilliseconds}';
      state = state.copyWith(
        duration: liveDur,
        position: livePos,
        isPlaying: livePlaying,
      );
      try {
        _recalculateMixWindow();
      } catch (_) {}
      unawaited(_applyTrueDuration(state.currentTrackPath, liveDur));
    } else if (livePlaying || livePos.inMilliseconds > 0) {
      state = state.copyWith(isPlaying: livePlaying, position: livePos);
    }

    _positionSub = player.stream.position.listen((Duration pos) {
      final posMs = pos.inMilliseconds;

      if (!_isCrossfading && state.duration.inMilliseconds > 0) {
        final double curRate = player.state.rate;
        final double? tgt = _drift.tick(
          posMs: posMs,
          durMs: state.duration.inMilliseconds,
          mixOutMs: state.customMixOutMs,
          rate: curRate,
          nextBpm: _extractBpm(state.nextTrackPath),
        );
        if (tgt != null) unawaited(_drift.ramp(player, curRate, tgt));
      }

      if (state.customCueInMs > 0 &&
          posMs < state.customCueInMs &&
          posMs < 1000) {
        player.seek(Duration(milliseconds: state.customCueInMs));
        return;
      }

      // Red de seguridad: si el plan no quedó listo, igual se mezcla al pasar
      // el punto de salida (nunca antes), en vez de llegar al final de la pista.
      if (state.autoMixArmed &&
          (_mixPlanReady ||
              (state.customMixOutMs > 0 && posMs >= state.customMixOutMs)) &&
          state.customMixOutMs > 0 &&
          state.nextTrackPath != null) {
        // DAWN arranca 5 s antes del SET OUT; la cola se consume después de él.
        final triggerMs = (state.customMixOutMs - kDawnLeadMs).clamp(
          0,
          state.customMixOutMs,
        );
        if (posMs >= (triggerMs - 150)) {
          if (!_isCrossfading && !_isPrepModeBypass) {
            _triggerCrossfade();
          }
        }
      }

      int newLyricIndex = _lastLyricIndex;
      if (state.lyrics.isEmpty) {
        newLyricIndex = -1;
      } else {
        final lyrics = state.lyrics;
        int i = newLyricIndex;
        if (i < 0) i = 0;
        if (i >= lyrics.length) i = lyrics.length - 1;
        while (i + 1 < lyrics.length && pos >= lyrics[i + 1].timestamp) {
          i++;
        }
        while (i >= 0 && pos < lyrics[i].timestamp) {
          i--;
        }
        newLyricIndex = i;
      }

      final bool uiTick = (posMs - _lastUiPosMs).abs() >= 250;
      final bool lyricTick = newLyricIndex != _lastLyricIndex;
      if (uiTick || lyricTick) {
        _lastUiPosMs = posMs;
        _lastLyricIndex = newLyricIndex;
        state = state.copyWith(position: pos, activeLyricIndex: newLyricIndex);
      }

      if (!_freezePersist) {
        _sessionPositionMs = posMs;
        _sessionWasPlaying = state.isPlaying;
      }

      if ((posMs - _lastSavedPositionMs).abs() > 15000) {
        _lastSavedPositionMs = posMs;
        _saveSnapshot();
      }

      if (uiTick) {
        globalAudioHandler.syncOs(
          owner: 'automix',
          path: state.currentTrackPath,
          duration: state.duration,
          playing: state.isPlaying,
          position: pos,
        );
      }

      if (state.autoMixArmed &&
          state.customMixOutMs <= 0 &&
          state.duration.inMilliseconds > 0 &&
          state.nextTrackPath != null) {
        int timeRemaining = state.duration.inMilliseconds - pos.inMilliseconds;

        if (timeRemaining > state.triggerRemainingMs) _isPrepModeBypass = false;
        if (timeRemaining <= state.triggerRemainingMs && !_isCrossfading) {
          if (!_isPrepModeBypass) _triggerCrossfade();
        }
      }
    });

    _durationSub = player.stream.duration.listen((dur) {
      final key = '${state.currentTrackPath}|${dur.inMilliseconds}';
      if (key == _lastDurationPlanKey) return;
      _lastDurationPlanKey = key;
      state = state.copyWith(duration: dur);
      _recalculateMixWindow();
      unawaited(_applyTrueDuration(state.currentTrackPath, dur));

      if (state.currentTrackPath != null) {
        globalAudioHandler.syncOs(
          owner: 'automix',
          path: state.currentTrackPath,
          duration: dur,
          playing: state.isPlaying,
          position: state.position,
        );
      }
    });

    _playingSub = player.stream.playing.listen((playing) {
      if (_parking) return;
      if (playing == state.isPlaying) return;
      state = state.copyWith(isPlaying: playing);
      if (playing) {
        // Controles de notificación/auriculares: el que suena es el dueño.
        globalAudioHandler.claim(
          'automix',
          onPlayPause: () => togglePlayPause(),
          onPause: () => pause(),
          onNext: () => _osStep(1),
          onPrevious: () => _osStep(-1),
          onSeek: (pos) => seek(pos),
          isPlaying: () => state.isPlaying,
        );
      }
      globalAudioHandler.syncOs(
        owner: 'automix',
        path: state.currentTrackPath,
        duration: state.duration,
        playing: playing,
        position: state.position,
      );
    });

    _completedSub = player.stream.completed.listen((completed) {
      if (!completed || _isCrossfading) return;
      _isPrepModeBypass = false;
      if (state.autoMixArmed && state.nextTrackPath != null) {
        _triggerCrossfade();
      } else {
        unawaited(_stopWhenNoNext());
      }
    });
  }

  Future<List<LyricLine>> _parseLyricsFile(String audioPath) async {
    final lrcPath = audioPath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final lrcFile = File(lrcPath);
    if (!lrcFile.existsSync()) return const [];
    try {
      final lines = await lrcFile.readAsLines();
      final List<LyricLine> parsedLyrics = [];
      final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
      for (var line in lines) {
        final match = regex.firstMatch(line);
        if (match == null) continue;
        final min = int.parse(match.group(1)!);
        final sec = int.parse(match.group(2)!);
        int ms = int.parse(match.group(3)!);
        if (match.group(3)!.length == 2) ms *= 10;
        final text = match.group(4)!.trim();
        if (text.isEmpty) continue;
        parsedLyrics.add(
          LyricLine(
            timestamp: Duration(minutes: min, seconds: sec, milliseconds: ms),
            text: text,
          ),
        );
      }
      return parsedLyrics;
    } catch (_) {
      return const [];
    }
  }

  /// El `.lrc` de [audioPath] cambió fuera de Automix: olvida la letra en
  /// memoria y la relee si es la pista actual o la siguiente.
  Future<void> reloadLyrics(String audioPath) async {
    _lyricPrime.removeWhere((String k, _) => sameAudioPath(k, audioPath));
    final String? current = state.currentTrackPath;
    final String? next = state.nextTrackPath;
    // Sin _fetchLyricsAsync: un Deshacer que borra la letra no la vuelve a bajar.
    if (sameAudioPath(current, audioPath)) {
      final List<LyricLine> parsed = await _parseLyricsFile(current!);
      _lyricPrime[current] = parsed;
      if (state.currentTrackPath != current) return;
      _shownLyricsPath = current;
      state = state.copyWith(lyrics: parsed, activeLyricIndex: -1);
      _lastLyricIndex = -2;
    } else if (sameAudioPath(next, audioPath)) {
      _lyricPrime[next!] = await _parseLyricsFile(next);
    }
  }

  Future<void> _primeLyrics(String audioPath) async {
    if (_lyricPrime.containsKey(audioPath)) return;
    final parsed = await _parseLyricsFile(audioPath);
    _lyricPrime[audioPath] = parsed;
    if (parsed.isEmpty) {
      final lrcPath = audioPath.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );
      if (!File(lrcPath).existsSync()) _fetchLyricsAsync(audioPath, lrcPath);
    }
  }

  Future<void> _loadLyrics(String audioPath) async {
    var parsed = _lyricPrime[audioPath];
    if (parsed == null || parsed.isEmpty) {
      _lyricPrime.remove(audioPath);
      parsed = await _parseLyricsFile(audioPath);
      _lyricPrime[audioPath] = parsed;
    }
    if (state.currentTrackPath != audioPath) return;
    _refreshApproxFlag(audioPath);
    if (parsed.isNotEmpty) {
      _shownLyricsPath = audioPath;
      state = state.copyWith(lyrics: parsed, activeLyricIndex: -1);
    } else {
      final lrcPath = audioPath.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );
      _shownLyricsPath = audioPath;
      state = state.copyWith(lyrics: [], activeLyricIndex: -1);
      if (!File(lrcPath).existsSync()) _fetchLyricsAsync(audioPath, lrcPath);
    }
    try {
      await _recalculateMixWindow();
    } catch (_) {}
  }

  void _refreshApproxFlag(String audioPath) {
    var approx = false;
    try {
      final File f = File(
        audioPath.replaceAll(
          RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
          '.lrc',
        ),
      );
      if (f.existsSync()) approx = lrcIsApprox(f.readAsStringSync());
    } catch (_) {}
    ref.read(automixLyricApproxProvider.notifier).state = approx;
  }

  Future<void> _fetchLyricsAsync(String audioPath, String lrcPath) async {
    if (!lyricMayDownload(lrcExists: File(lrcPath).existsSync())) return;
    try {
      final LyricChoice choice = await ref
          .read(nlpWorkerProvider)
          .lookupSafeLyric(audioPath);
      if (!choice.hasText) return;
      if (!lyricMayDownload(lrcExists: File(lrcPath).existsSync())) return;
      await File(lrcPath).writeAsString(choice.fileText);
      _lyricPrime.remove(audioPath);
      if (state.currentTrackPath == audioPath) {
        await _loadLyrics(audioPath);
      }
    } catch (_) {}
  }

  Future<void> togglePlayPause() async {
    if (state.currentTrackPath == null) return;
    _isPrepModeBypass = false;
    _freezePersist = false;
    _isCrossfading = false;

    final String path = state.currentTrackPath!;
    final bool deckEmpty = _activeAutomix.state.duration.inMilliseconds <= 0;
    if (deckEmpty) {
      if (!File(path).existsSync()) return;
      try {
        final int resumeMs = _sessionPositionMs > 0
            ? _sessionPositionMs
            : (state.position.inMilliseconds > 0
                  ? state.position.inMilliseconds
                  : (state.customCueInMs > 0 ? state.customCueInMs : 0));
        await _forceOpenAndPlay(path, seekMs: resumeMs);
      } catch (e) {
        debugPrint("🔴 [AUTOMIX OPEN]: $e");
      }
      _saveSnapshot();
      return;
    }

    if (state.isPlaying) {
      _cancelOutroProbe();
      await _activeAutomix.pause();
      _saveSnapshot();
      return;
    }

    if (state.customCueInMs > 0 &&
        state.position.inMilliseconds < state.customCueInMs) {
      await _activeAutomix.seek(Duration(milliseconds: state.customCueInMs));
    }
    await _activeAutomix.play();
    unawaited(_planVariableMixWindow());
    await Future.delayed(const Duration(milliseconds: 80));
    if (!_activeAutomix.state.playing) {
      final int resumeMs = _sessionPositionMs > 0
          ? _sessionPositionMs
          : (state.position.inMilliseconds > 0
                ? state.position.inMilliseconds
                : 0);
      await _forceOpenAndPlay(path, seekMs: resumeMs);
    }
    if (!state.isPlaying) _saveSnapshot();
  }

  Future<void> pause() async {
    if (state.isPlaying) {
      _cancelOutroProbe();
      await _activeAutomix.pause();
      _saveSnapshot();
    }
  }

  Future<void> updateCurrentTrackAndPlay(String newPath) async {
    if (state.currentIndex < 0 || _isCrossfading) return;
    _isPrepModeBypass = false;

    final currentList = List<String>.from(state.playlist);
    currentList[state.currentIndex] = newPath;

    final bool wasPlaying = state.isPlaying;
    _mixOutIsManual = false;
    _cueInIsManual = false;
    _mixPlanReady = false;

    state = state.copyWith(
      playlist: currentList,
      currentTrackPath: newPath,
      clearNextTrackPath: true,
      customCueInMs: -1,
      customMixOutMs: -1,
      autoMixArmed: true,
    );
    _saveSnapshot();
    await _loadLyrics(newPath);
    await _loadTrackMetadata(newPath);

    final Player fadingPlayer = _activeAutomix;
    final Player incomingPlayer = _standbyPlayer;

    // Sustitución en frío: sin audio saliente no hay nada que fundir.
    if (!wasPlaying) {
      _drift.begin(_extractBpm(newPath), 1.0);
      await incomingPlayer.setRate(1.0);
      await incomingPlayer.setVolume(100.0);
      await incomingPlayer.open(Media(newPath), play: true);
      ref
          .read(automixEqualizerProvider.notifier)
          .adapt(incomingPlayer, newPath);
      _usePlayerA = !_usePlayerA;
      _attachListeners(_activeAutomix);
      return;
    }

    _isCrossfading = true;
    try {
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.open(Media(newPath), play: false);
      ref
          .read(automixEqualizerProvider.notifier)
          .adapt(incomingPlayer, newPath);
      if (state.customCueInMs > 0) {
        await incomingPlayer.seek(Duration(milliseconds: state.customCueInMs));
      }
      await incomingPlayer.setRate(1.0);
      await incomingPlayer.play();
    } catch (e) {
      _isCrossfading = false;
      debugPrint('🔴 [AUTOMIX SWAP] $e');
      return;
    }

    _usePlayerA = !_usePlayerA;
    _attachListeners(_activeAutomix);

    // Reemplazo de pista en caliente: mezcla DAWN, jamás corte.
    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixDurationMs: _planManualMixDurationMs(
        newPath,
        incomingPlayer.state.duration.inMilliseconds,
      ),
      mixProfile: AutomixMixProfile.manualOverride,
      incomingRate: 1.0,
      isManualSkip: true,
    );
  }

  Future<void> stopAndRelease() async {
    try {
      await _playerA.stop();
    } catch (_) {}
    try {
      await _playerB.stop();
    } catch (_) {}
    _isCrossfading = false;
    await Future.delayed(const Duration(milliseconds: 600));
  }

  /// El deck activo a veces queda vacío (restore / park). La 2ª pista suena
  /// porque abre el standby; la 1ª reutilizaba el muerto. Siempre el otro.
  Future<void> _forceOpenAndPlay(String path, {int seekMs = 0}) async {
    _isCrossfading = false;
    final Player incoming = _standbyPlayer;
    _drift.begin(_extractBpm(path), 1.0);
    try {
      await incoming.setRate(1.0);
    } catch (_) {}
    await incoming.setVolume(100.0);
    await incoming.open(Media(path), play: true);
    ref.read(automixEqualizerProvider.notifier).adapt(incoming, path);
    try {
      await incoming.stream.duration
          .firstWhere((d) => d.inMilliseconds > 0)
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
    if (seekMs > 0) {
      await incoming.seek(Duration(milliseconds: seekMs));
    }
    _usePlayerA = !_usePlayerA;
    _attachListeners(_activeAutomix);
    try {
      await _standbyPlayer.setVolume(0.0);
      await _standbyPlayer.stop();
    } catch (_) {}
    final Duration d = await _trueDuration(path, _activeAutomix.state.duration);
    if (d.inMilliseconds > 0) {
      state = state.copyWith(
        duration: d,
        isPlaying: true,
        position: seekMs > 0
            ? Duration(milliseconds: seekMs)
            : _activeAutomix.state.position,
      );
    }
  }

  /// Apaga ambos decks si este módulo no está sonando. Evita 4× libmpv en idle.
  /// `force: true` libera el dispositivo (Android: un solo motor de audio).
  Future<void> parkIdleDecks({bool force = false}) async {
    if (_parking) return;
    if (!force && (state.isPlaying || _isCrossfading)) return;
    _parking = true;
    try {
      if (force) _isCrossfading = false;
      _cancelOutroProbe();
      _sessionWasPlaying = state.isPlaying;
      if (state.position.inMilliseconds > 0) {
        _sessionPositionMs = state.position.inMilliseconds;
      }
      _freezePersist = true;
      await _saveSnapshot();
      try {
        await _playerA.pause();
      } catch (_) {}
      try {
        await _playerB.pause();
      } catch (_) {}
      try {
        await _playerA.stop();
      } catch (_) {}
      try {
        await _playerB.stop();
      } catch (_) {}
      state = state.copyWith(isPlaying: false);
    } finally {
      _parking = false;
    }
  }

  Future<void> clearMixPoints() async {
    if (state.currentTrackPath == null) return;
    final path = state.currentTrackPath!;

    _cueInIsManual = false;
    _mixOutIsManual = false;
    state = state.copyWith(customCueInMs: 0, customMixOutMs: 0);

    final lrcPath = path.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final lrcFile = File(lrcPath);
    if (lrcFile.existsSync()) {
      lrcFile.deleteSync();
    }

    await ref
        .read(dbServiceProvider)
        .saveTrackMetadata(
          path: path,
          mixProfile: state.mixStrategy == MixStrategy.sequential
              ? 'constant_power'
              : 'eq_kill',
          durationMs: 6000,
          genre: 'desconocido',
          cueInMs: 0,
          mixOutMs: 0,
          isManualCue: false,
        );

    try {
      await ref.read(nlpWorkerProvider).processSingleFile(path);
    } catch (_) {}

    state = state.copyWith(lyrics: [], activeLyricIndex: -1);
    debugPrint(
      "🗑️ [PAPELERA] Cues y archivo NLP destruidos y reseteados para: $path",
    );
  }

  void removeTrack(String path) {
    final newPlaylist = List<String>.from(state.playlist)..remove(path);
    int newIndex = state.currentIndex;
    if (state.currentTrackPath != null && state.currentTrackPath != path) {
      newIndex = newPlaylist.indexOf(state.currentTrackPath!);
    }
    state = state.copyWith(playlist: newPlaylist, currentIndex: newIndex);
    _saveSnapshot();
  }

  Future<void> autoSyncFirstLyric() async {
    if (state.currentTrackPath == null || state.lyrics.isEmpty) return;
    if (_shownLyricsPath != state.currentTrackPath) return;
    _rememberLyricUndo();

    final posMs = state.position.inMilliseconds;
    final targetLine = state.lyrics.first;

    final deltaMs = posMs - targetLine.timestamp.inMilliseconds;

    final List<LyricLine> newLyrics = [];

    for (var line in state.lyrics) {
      int newMs = line.timestamp.inMilliseconds + deltaMs;
      if (newMs < 0) newMs = 0;

      newLyrics.add(
        LyricLine(
          timestamp: Duration(milliseconds: newMs),
          text: line.text,
        ),
      );
    }

    await _saveLyricsToFile(state.currentTrackPath!, newLyrics);
    state = state.copyWith(lyrics: newLyrics);
    debugPrint("✅ [SYNC GLOBAL] Matriz reconstruida por Delta: ${deltaMs}ms");
  }

  Future<void> autoSyncFromCurrentLyric({required int lineIndex}) async {
    if (state.currentTrackPath == null || state.lyrics.isEmpty) return;
    if (_shownLyricsPath != state.currentTrackPath) return;
    _rememberLyricUndo();

    int idx = lineIndex;
    if (idx < 0) idx = 0;
    if (idx >= state.lyrics.length) idx = state.lyrics.length - 1;

    final int deltaMs =
        state.position.inMilliseconds -
        state.lyrics[idx].timestamp.inMilliseconds;

    final List<LyricLine> newLyrics = [
      for (int i = 0; i < state.lyrics.length; i++)
        i < idx
            ? state.lyrics[i]
            : LyricLine(
                timestamp: Duration(
                  milliseconds: max(
                    0,
                    state.lyrics[i].timestamp.inMilliseconds + deltaMs,
                  ),
                ),
                text: state.lyrics[i].text,
              ),
    ];

    await _saveLyricsToFile(state.currentTrackPath!, newLyrics);
    state = state.copyWith(lyrics: newLyrics, activeLyricIndex: idx);
    debugPrint("✅ [SYNC MED] linea ${idx + 1} al playhead, delta ${deltaMs}ms");
  }

  Future<void> autoSyncSingleLyric({required int lineIndex}) async {
    if (state.currentTrackPath == null || state.lyrics.isEmpty) return;
    if (_shownLyricsPath != state.currentTrackPath) return;
    _rememberLyricUndo();

    int idx = lineIndex;
    if (idx < 0) idx = 0;
    if (idx >= state.lyrics.length) idx = state.lyrics.length - 1;

    final int newMs = max(0, state.position.inMilliseconds);
    final List<LyricLine> newLyrics = [
      for (int i = 0; i < state.lyrics.length; i++)
        i == idx
            ? LyricLine(
                timestamp: Duration(milliseconds: newMs),
                text: state.lyrics[i].text,
              )
            : state.lyrics[i],
    ];

    await _saveLyricsToFile(state.currentTrackPath!, newLyrics);
    state = state.copyWith(lyrics: newLyrics, activeLyricIndex: idx);
    debugPrint("✅ [SYNC SOLO] linea ${idx + 1} a ${newMs}ms");
  }

  void _rememberLyricUndo() {
    _lyricUndoPath = state.currentTrackPath;
    _lyricUndo = List<LyricLine>.from(state.lyrics);
  }

  Future<void> undoLastLyricSync() async {
    final saved = _lyricUndo;
    final path = _lyricUndoPath;
    if (saved == null || path == null) return;
    if (path != state.currentTrackPath) return;
    _lyricUndo = null;
    _lyricUndoPath = null;
    await _saveLyricsToFile(path, saved);
    _shownLyricsPath = path;
    state = state.copyWith(lyrics: saved);
  }

  Future<void> _saveLyricsToFile(
    String audioPath,
    List<dynamic> currentLyrics,
  ) async {
    final lrcPath = audioPath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final file = File(lrcPath);
    final buffer = StringBuffer();

    for (dynamic line in currentLyrics) {
      final totalMs = line.timestamp.inMilliseconds as int;
      final min = (totalMs ~/ 60000).toString().padLeft(2, '0');
      final sec = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
      final ms = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
      buffer.writeln('[$min:$sec.$ms]${line.text}');
    }

    await file.writeAsString(buffer.toString());
    _lyricPrime.remove(audioPath);
    if (ref.read(automixLyricApproxProvider)) {
      // El ajuste del usuario convierte la letra aproximada en MANUAL.
      ref.read(automixLyricApproxProvider.notifier).state = false;
      approxLyricRevision.value++;
      try {
        await rust_dsp.setGmxMark(
          inputPath: audioPath,
          key: 'GMX_LYR',
          value: 'MANUAL',
        );
      } catch (_) {}
    }
  }

  Future<void> shiftLyrics(int offsetMs) async {
    if (state.currentTrackPath == null) return;
    final lrcPath = state.currentTrackPath!.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final file = File(lrcPath);
    if (!file.existsSync()) return;

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

          int totalMs = (min * 60000) + (sec * 1000) + ms + offsetMs;
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
      await _loadLyrics(state.currentTrackPath!);
    } catch (_) {}
  }

  Future<void> shiftLyricsPartial(int offsetMs, int thresholdMs) async {
    if (state.currentTrackPath == null) return;
    final lrcPath = state.currentTrackPath!.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final file = File(lrcPath);
    if (!file.existsSync()) return;

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

          int originalMs = (min * 60000) + (sec * 1000) + ms;
          int totalMs = originalMs;

          if (originalMs >= thresholdMs - 100) {
            totalMs += offsetMs;
            if (totalMs < 0) totalMs = 0;
          }

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
      await _loadLyrics(state.currentTrackPath!);
    } catch (_) {}
  }
}

class PlayedTracksNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    _loadSession();
    return {};
  }

  String _getSessionFilePath() {
    if (Platform.isIOS) {
      final dir = Directory(IphoneLibrary.playlistsDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return '${dir.path}${Platform.pathSeparator}_played_tracks_session.json';
    }
    String baseDir;
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      baseDir = userProfile != null
          ? '$userProfile\\Music\\DjPlaylists'
          : 'C:\\Music\\DjPlaylists';
    } else if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      baseDir = home != null ? '$home/Music/DjPlaylists' : '/tmp/DjPlaylists';
    } else {
      baseDir = '/storage/emulated/0/Music/DjPlaylists';
    }
    final dir = Directory(baseDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}${Platform.pathSeparator}_played_tracks_session.json';
  }

  Future<void> _loadSession() async {
    try {
      final data = SessionStore.readJson(_getSessionFilePath());
      if (data is List) {
        state = {...data.map((e) => e.toString()), ...state};
      }
    } catch (_) {}
  }

  Future<void> _saveSession(Set<String> currentPlayed) async {
    try {
      await SessionStore.writeJson(
        _getSessionFilePath(),
        currentPlayed.toList(),
      );
    } catch (_) {}
  }

  void addTrack(String track) {
    if (!state.any((p) => sameAudioPath(p, track))) {
      final newState = {...state, track};
      state = newState;
      _saveSession(newState);
    }
  }

  void removeTrack(String track) {
    final newState = state.where((p) => !sameAudioPath(p, track)).toSet();
    if (newState.length != state.length) {
      state = newState;
      _saveSession(newState);
    }
  }
}

class AutomixQueueNotifier extends Notifier<List<File>> {
  Future<void> _addChain = Future<void>.value();

  bool _shuffleOn() {
    try {
      return ref.read(automixProvider).mixStrategy == MixStrategy.random;
    } catch (_) {
      return false;
    }
  }

  int _locked(List<String> paths) {
    final AutomixState auto = ref.read(automixProvider);
    var lock = 0;
    if (auto.currentTrackPath != null) {
      final int i = paths.indexWhere(
        (String p) => sameAudioPath(p, auto.currentTrackPath),
      );
      if (i >= 0) lock = i + 1;
    }
    if (ref.read(automixProvider.notifier).nextTrackLocked &&
        auto.nextTrackPath != null) {
      final int i = paths.indexWhere(
        (String p) => sameAudioPath(p, auto.nextTrackPath),
      );
      if (i >= 0 && i + 1 > lock) lock = i + 1;
    }
    return lock;
  }

  Future<void> _insertShuffle(List<File> files) async {
    final List<File> fresh = <File>[];
    for (final File f in files) {
      if (isKaraokeAudioPath(f.path)) continue;
      if (state.any((File e) => sameAudioPath(e.path, f.path))) continue;
      fresh.add(f);
    }
    if (fresh.isEmpty) return;
    final List<String> paths = fresh.map((File f) => f.path).toList();
    try {
      await preloadQueueBpm(paths);
    } catch (_) {}
    for (final String p in paths) {
      saveTrackMusic(p, bpm: cachedBpm(p), camelot: harmonicKeyOf(p));
    }
    if (!_shuffleOn()) {
      final List<File> next = <File>[...state, ...fresh];
      state = next;
      await _saveSession(next);
      return;
    }
    final List<String> base = state.map((File f) => f.path).toList();
    final AutomixState auto = ref.read(automixProvider);
    final List<String> merged = insertHarmonicTracks(
      queue: base,
      incoming: paths,
      bpmOf: cachedBpm,
      keyOf: harmonicKeyOf,
      lockedPrefix: _locked(base),
      playing: auto.currentTrackPath,
      pinned: ref.read(automixProvider.notifier).nextTrackLocked
          ? auto.nextTrackPath
          : null,
    );
    final Map<String, File> byKey = <String, File>{
      for (final File f in <File>[...state, ...fresh]) audioPathKey(f.path): f,
    };
    final List<File> next = <File>[
      for (final String p in merged) byKey[audioPathKey(p)] ?? File(p),
    ];
    state = next;
    await _saveSession(next);
  }

  @override
  List<File> build() {
    _loadSession();
    return [];
  }

  String _getSessionFilePath() {
    if (Platform.isIOS) {
      final dir = Directory(IphoneLibrary.playlistsDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return '${dir.path}${Platform.pathSeparator}_automix_session.json';
    }
    String baseDir;
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      baseDir = userProfile != null
          ? '$userProfile\\Music\\DjPlaylists'
          : 'C:\\Music\\DjPlaylists';
    } else if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      baseDir = home != null ? '$home/Music/DjPlaylists' : '/tmp/DjPlaylists';
    } else {
      baseDir = '/storage/emulated/0/Music/DjPlaylists';
    }
    final dir = Directory(baseDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}${Platform.pathSeparator}_automix_session.json';
  }

  Future<void> _loadSession() async {
    try {
      final data = SessionStore.readJson(_getSessionFilePath());
      if (data is List && state.isEmpty) {
        // Pistas renombradas por Masterizar se reencuentran en su carpeta.
        // Duplicados guardados (otra grafía de la misma ruta) se limpian.
        final List<String> raw = data.map((e) => e.toString()).toList();
        final List<File> files = dedupeAudioFiles(
          resolvePlayableSessionPaths(raw).map(File.new).toList(),
        );
        state = files;
        if (raw.length != files.length ||
            raw.join('\n') != files.map((f) => f.path).join('\n')) {
          unawaited(_saveSession(files));
        }
      }
    } catch (_) {}
  }

  Future<void> _saveSession(List<File> currentQueue) async {
    try {
      final paths = currentQueue.map((f) => f.path).toList();
      await SessionStore.writeJson(_getSessionFilePath(), paths);
    } catch (_) {}
  }

  void addTrack(File file) {
    if (isKaraokeAudioPath(file.path)) return;
    final File kept = File(canonicalAudioPath(file.path));
    if (_shuffleOn()) {
      _addChain = _addChain.then((_) => _insertShuffle(<File>[kept]));
      return;
    }
    final newState = state
        .where((f) => !sameAudioPath(f.path, kept.path))
        .toList();
    newState.add(kept);
    state = newState;
    _saveSession(newState);
  }

  void addAll(List<File> files) {
    if (_shuffleOn()) {
      final List<File> kept = <File>[
        for (final File f in files)
          if (!isKaraokeAudioPath(f.path)) File(canonicalAudioPath(f.path)),
      ];
      _addChain = _addChain.then((_) => _insertShuffle(kept));
      return;
    }
    var newState = List<File>.from(state);
    for (final File f in files) {
      if (isKaraokeAudioPath(f.path)) continue;
      final File kept = File(canonicalAudioPath(f.path));
      newState.removeWhere(
        (existing) => sameAudioPath(existing.path, kept.path),
      );
      newState.add(kept);
    }
    state = newState;
    _saveSession(newState);
  }

  void removeTrack(String path) {
    final newState = state.where((f) => !sameAudioPath(f.path, path)).toList();
    state = newState;
    _saveSession(newState);
  }

  void clearQueue() {
    state = [];
    _saveSession([]);
  }

  void restoreQueue(List<String> paths) {
    final List<File> files = dedupeAudioFiles(
      paths
          .where((p) => !isKaraokeAudioPath(p) && File(p).existsSync())
          .map(File.new)
          .toList(),
    );
    state = files;
    _saveSession(files);
  }
}

enum TrackSortMode { alphabetical, bpmDesc, bpmAsc }

class TrackSortNotifier extends Notifier<TrackSortMode> {
  @override
  TrackSortMode build() {
    // El orden elegido se guarda junto a la sesión y sobrevive updates.
    try {
      final data = SessionStore.readJson(_path());
      if (data is Map) {
        return TrackSortMode.values.firstWhere(
          (m) => m.name == data['sortMode'],
          orElse: () => TrackSortMode.alphabetical,
        );
      }
    } catch (_) {}
    return TrackSortMode.alphabetical;
  }

  String _path() {
    final session = MixStrategyFactory.getStrategy().getSessionPath();
    return '${File(session).parent.path}${Platform.pathSeparator}_automix_sort.json';
  }

  void updateMode(TrackSortMode mode) {
    state = mode;
    try {
      SessionStore.writeJson(_path(), {'sortMode': mode.name});
    } catch (_) {}
  }
}

class BpmCacheNotifier extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => {};

  Future<void> loadCache(String directoryPath) async {
    if (directoryPath.isEmpty) {
      state = {};
      return;
    }

    try {
      final Map<String, dynamic> decoded = readDjMetadata(directoryPath);
      if (decoded.isEmpty) {
        state = {};
        return;
      }
      final Map<String, double> newCache = {};

      decoded.forEach((key, value) {
        if (value is num) {
          newCache[key] = value.toDouble();
        } else if (value is Map && value['bpm'] != null) {
          newCache[key] = (value['bpm'] as num).toDouble();
        }
      });
      state = newCache;
    } catch (e) {
      state = {};
    }
  }
}

class WasapiRecordNotifier extends Notifier<bool> {
  String? _currentOutputPath;
  @override
  bool build() => false;

  Future<void> toggleRecording(
    BuildContext context, {
    String filePrefix = 'LiveMix',
  }) async {
    if (state) {
      await stopRecording(context);
    } else {
      await startRecording(context, filePrefix: filePrefix);
    }
  }

  Future<void> startRecording(
    BuildContext context, {
    String filePrefix = 'LiveMix',
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      if (context.mounted) {
        _showErrorDialog(
          context,
          "VETO TÉCNICO: Sandbox Restringido",
          "La captura del Master Out en Android/iOS está bloqueada a nivel de Kernel por políticas de privacidad. Se requiere migrar a APIs nativas (MediaProjection/ReplayKit).",
        );
      }
      return;
    }

    final userProfile =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    final baseDir = Platform.isWindows
        ? '$userProfile\\Music\\GrabacionesDj'
        : '$userProfile/Music/GrabacionesDj';

    final dir = Directory(baseDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final dateStr = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    _currentOutputPath =
        '${dir.path}${Platform.pathSeparator}${filePrefix}_$dateStr.mp3';

    try {
      await rust_dsp.startMasterRecording(
        outputPath: _currentOutputPath!,
        bitrateKbps: 320,
      );
      state = true;
      debugPrint("🟢 [Hardware Tracker] Grabando bus maestro (Rust/LAME 320k)");

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🔴 GRABANDO MASTER OUT: ${filePrefix}_$dateStr.mp3',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint("🔴 [RECORD FATAL]: $e");
      state = false;
      if (context.mounted) {
        _showErrorDialog(context, "🔴 VETO TÉCNICO: Grabador", '$e');
      }
    }
  }

  Future<void> stopRecording(BuildContext context) async {
    try {
      await rust_dsp.stopMasterRecording();
    } catch (e) {
      debugPrint('🔴 [RECORD STOP]: $e');
    }
    state = false;

    final file = File(_currentOutputPath ?? '');
    final fileExists = file.existsSync() && file.lengthSync() > 0;

    if (context.mounted) {
      if (fileExists) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ Mezcla renderizada en: $_currentOutputPath',
              style: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: const Color(0xFF39FF14),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '❌ ERROR: Archivo vacío o I/O bloqueado.',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: Colors.redAccent,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _showErrorDialog(BuildContext context, String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Colors.redAccent),
          borderRadius: BorderRadius.circular(8),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.redAccent,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SizedBox(
          width: 600,
          height: 400,
          child: SingleChildScrollView(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white70,
                fontFamily: 'Consolas',
                fontSize: 11,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              "Cerrar",
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }
}

// 🛡️ DECLARACIÓN DE LOS PROVIDERS SEPARADOS:
/// La letra en pantalla es aproximada ([gmx_approx] / GMX_LYR=APPROX).
final automixLyricApproxProvider = StateProvider<bool>((ref) => false);

final automixProvider = NotifierProvider<AutomixNotifier, AutomixState>(
  AutomixNotifier.new,
);

final automixQueueProvider = NotifierProvider<AutomixQueueNotifier, List<File>>(
  AutomixQueueNotifier.new,
);

final playedTracksProvider =
    NotifierProvider<PlayedTracksNotifier, Set<String>>(
      PlayedTracksNotifier.new,
    );

final trackSortProvider = NotifierProvider<TrackSortNotifier, TrackSortMode>(
  TrackSortNotifier.new,
);

final bpmCacheProvider =
    NotifierProvider<BpmCacheNotifier, Map<String, double>>(
      BpmCacheNotifier.new,
    );

final wasapiRecordProvider = NotifierProvider<WasapiRecordNotifier, bool>(
  WasapiRecordNotifier.new,
);
