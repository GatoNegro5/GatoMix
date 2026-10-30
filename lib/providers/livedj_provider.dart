import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';

import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;

import '../core/audio_path.dart';
import '../core/gatomix_radio.dart';
import '../core/gatomix_store.dart';
import '../core/hal/platform_strategy.dart';
import '../core/mode_session.dart';
import '../core/livedj_next.dart';
import '../core/livedj_order.dart';
import '../core/dna_mix.dart';
import '../core/phrase_grid.dart';
import '../core/queue_bpm.dart';
import '../core/stored_grid.dart';
import '../core/session_restore.dart';
import '../core/session_store.dart';
import '../core/audio/af_caps.dart';
import '../core/audio/mix_pause.dart';
import '../core/audio/phase_lock.dart';
import '../core/audio/tempo_drift.dart';
import '../core/dj_trace.dart';
import '../core/exact_mix.dart';
import '../services/track_tags.dart';
import '../core/audio/dj_audio_handler.dart';
import 'equalizer_provider.dart';
import 'mix_formula.dart';
import '../djiphone/iphone_library.dart';

enum LiveDjMixStrategy { sequential, random }

/// Bitácora de decisiones del mezclador (solo diagnóstico, no toca el audio).
void _djTrace(String msg) => djTrace(msg);

enum LiveDjMixMode { activeSync, longBypass }

// 🎚️ Corte de graves de la permuta de bajos: Butterworth de 2 polos a 140 Hz.
// Idéntico al de Automix. Se inyecta en libmpv vía 'af'; cero DSP por muestras.
// Corte de graves con `equalizer` (único filtro de libavfilter que trae el
// libmpv empaquetado; `highpass` no existe y tumbaba toda la cadena `af`).
const String _bassKillFilter =
    'equalizer=f=45:width_type=o:w=2.5:g=-24,equalizer=f=110:width_type=o:w=1.6:g=-14';

// 🎚️ Banda del fundido en cambios manuales; la pista entrante elige el punto.
const int _manualMixMinMs = 8000;
const int _manualMixMaxMs = 18000;

class LiveDjState {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final List<File> queue;
  final String? currentTrackPath;
  final LiveDjMixMode currentMixMode;
  final int customCueInMs;
  final int customMixOutMs;
  final LiveDjMixStrategy mixStrategy;
  // Orden de la cola en Secuencial (A-Z, BPM ↑, BPM ↓ o como se cargó).
  final LiveDjSortMode sortMode;
  // ON AIR Radio: con la radio encendida la cola queda congelada y el motor
  // toma pistas del universo de Música filtrado por géneros.
  final bool radioOn;
  final Set<String> radioGenres;
  // Pista que la Radio ya eligió para sonar a continuación (null = sin elegir).
  final String? radioNextPath;
  // Cola de la opción de radio ya armada, desde la posición actual.
  // Vacía con la radio apagada. No se relee el JSON en cada build.
  final List<String> radioUpcoming;
  // Géneros que SÍ tienen carpeta con pistas (el resto de chips se apaga).
  final Set<String> radioGenresAvailable;

  LiveDjState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.queue = const [],
    this.currentTrackPath,
    this.currentMixMode = LiveDjMixMode.activeSync,
    this.customCueInMs = -1,
    this.customMixOutMs = -1,
    this.mixStrategy = LiveDjMixStrategy.sequential,
    this.sortMode = LiveDjSortMode.manual,
    this.radioOn = false,
    this.radioGenres = const <String>{},
    this.radioNextPath,
    this.radioUpcoming = const <String>[],
    this.radioGenresAvailable = const <String>{},
  });

  LiveDjState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    List<File>? queue,
    String? currentTrackPath,
    bool clearCurrentTrackPath = false,
    LiveDjMixMode? currentMixMode,
    int? customCueInMs,
    int? customMixOutMs,
    LiveDjMixStrategy? mixStrategy,
    LiveDjSortMode? sortMode,
    bool? radioOn,
    Set<String>? radioGenres,
    String? radioNextPath,
    bool clearRadioNextPath = false,
    List<String>? radioUpcoming,
    Set<String>? radioGenresAvailable,
  }) {
    return LiveDjState(
      radioGenresAvailable: radioGenresAvailable ?? this.radioGenresAvailable,
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      queue: queue ?? this.queue,
      currentTrackPath: clearCurrentTrackPath
          ? null
          : (currentTrackPath ?? this.currentTrackPath),
      currentMixMode: currentMixMode ?? this.currentMixMode,
      customCueInMs: customCueInMs ?? this.customCueInMs,
      customMixOutMs: customMixOutMs ?? this.customMixOutMs,
      mixStrategy: mixStrategy ?? this.mixStrategy,
      sortMode: sortMode ?? this.sortMode,
      radioOn: radioOn ?? this.radioOn,
      radioGenres: radioGenres ?? this.radioGenres,
      radioNextPath: clearRadioNextPath
          ? null
          : (radioNextPath ?? this.radioNextPath),
      radioUpcoming: radioUpcoming ?? this.radioUpcoming,
    );
  }
}

/// Géneros de la Radio (id → carpetas de Música que lo componen, por nombre).
const List<String> kRadioGenreIds = [
  'actuales',
  'bailable',
  'romanticas',
  'ochenteras',
  'rock',
];

const Map<String, String> kRadioGenreLabels = {
  'actuales': 'Actuales',
  'bailable': 'Bailable',
  'romanticas': 'Románticas',
  'ochenteras': 'Ochenteras',
  'rock': 'Rock',
};

class LiveDjNotifier extends Notifier<LiveDjState> {
  late final Player _playerA;
  late final Player _playerB;
  bool _usePlayerA = true;

  Player get _activePlayer => _usePlayerA ? _playerA : _playerB;
  Player get _standbyPlayer => _usePlayerA ? _playerB : _playerA;

  List<Player> get deckPlayers => [_playerA, _playerB];

  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;
  StreamSubscription? _completedSub;

  bool _isCrossfading = false;
  bool _parking = false;
  bool _isStandbyArmed = false;
  bool _nextFromCompletion = false;
  // Pista realmente precargada en el deck standby. Si la cola cambia
  // (quitar, shuffle, otra pista) antes del cruce, se vuelve a cargar.
  String? _standbyArmedPath;
  // Pista elegida para el relevo, antes de que el deck termine de abrirla.
  // La rampa de tempo la usa; no espera al throttle de la UI.
  String? _driftNextPath;
  int _radioSaveSerial = 0;
  Future<void> _radioSaveChain = Future<void>.value();
  String? _radioRootOverride;
  // La pista que sonaba antes de la que entra. El fallback no puede elegirla.
  String? _radioPrevious;
  Future<void> _queueAddChain = Future<void>.value();
  final Set<String> _queueAddPending = <String>{};
  int _addEpoch = 0;
  bool _queueHold = false;
  bool _queueRestart = false;
  RadioMemory? _radioMem;
  LiveQueueFreeze? _radioFreeze;
  bool _radioOffAfterFade = false;
  bool _isPrepModeBypass = false;
  int _lastSavedPositionMs = 0;
  int _lastUiPosMs = -1;
  int _sessionPositionMs = 0;
  bool _sessionWasPlaying = false;
  bool _freezePersist = false;
  bool _sessionHydrated = false;
  int _lastOsSecond = -1;
  // Regulación sutil de tempo (ver tempo_drift.dart) y BPM real de la pista
  // entrante (etiqueta/nombre o medido por beat_grid).
  final TempoDrift _drift = TempoDrift();
  final MixPause _mix = MixPause();
  PhaseLockSession? _phaseLock;
  bool _deckAWasOn = false;
  bool _deckBWasOn = false;
  // Deck entrante entre arm y su play. Una pausa en esa ventana no lo
  // reanuda: al soltar suena el saliente y el fundido lo sube desde 0.
  Player? _incomingQuiet;
  double _incomingNatBpm = 0.0;
  // Análisis de Phrase 8, una pista por vez, fuera del tick.
  Future<void> _phraseJobs = Future<void>.value();
  final Set<String> _phrasePending = <String>{};
  int _publishedFadeMs = 0;

  late final PlatformMixStrategy _liveStrategy;

  @override
  LiveDjState build() {
    _playerA = Player();
    _playerB = Player();

    _liveStrategy = MixStrategyFactory.getStrategy();

    for (final Player deck in deckPlayers) {
      final dynamic platform = deck.platform;
      platform?.setProperty('vid', 'no');
      platform?.setProperty('af', _liveStrategy.hifiFilter);
    }

    _attachListeners(_playerA);
    _initPersistence();

    // TIPO DE MEZCLA persistente: cada cambio de fórmula baja a disco.
    ref.listen<MixFormula>(mixFormulaProvider, (previous, next) {
      if (previous == next || !_sessionHydrated) return;
      _saveSnapshot();
      if (next == MixFormula.phraseGrid || next == MixFormula.dnaEnergy) {
        _schedulePhraseNeighbors();
      }
    });

    ref.onDispose(() {
      _positionSub?.cancel();
      _durationSub?.cancel();
      _playingSub?.cancel();
      _completedSub?.cancel();
    });

    return LiveDjState();
  }

  bool _isMixTrack(int durationMs) => durationMs > 600000;

  /// Cambio manual: el fundido lo dicta la pista entrante — compases 4/4 sobre
  /// su BPM acotados a 8–18 s. Idéntico criterio que Automix.
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

  double _extractBpm(String? path) => knownBpm(path);

  /// Lo que usa el relevo visual. Phrase 8 y DNA publican el fundido real.
  int get publishedFadeMs => _publishedFadeMs;

  bool _wantsPhraseProfile() {
    final MixFormula formula = ref.read(mixFormulaProvider);
    return formula == MixFormula.phraseGrid || formula == MixFormula.dnaEnergy;
  }

  int _phraseFallbackCue(String? path, int durMs) {
    final int leadMs = TrackTags.peek(path)?.leadMs ?? 0;
    if (durMs > 30000) return leadMs > 10000 ? leadMs : 10000;
    return leadMs < durMs ~/ 3 ? leadMs : 0;
  }

  String? _phrasePeerPath() {
    if (!_wantsPhraseProfile()) return null;
    if (state.radioOn) {
      final String? drift = _driftNextPath;
      if (drift != null && drift.isNotEmpty) return drift;
      return null;
    }
    return _queueHeadPath();
  }

  void _schedulePhraseNeighbors() {
    if (!_sessionHydrated) return;
    if (!_wantsPhraseProfile()) return;
    _schedulePhraseGrid(state.currentTrackPath);
    _schedulePhraseGrid(_phrasePeerPath());
  }

  void _schedulePhraseGrid(String? path) {
    if (path == null || path.isEmpty) return;
    if (!_wantsPhraseProfile()) return;
    if (!_sessionHydrated) return;
    if (PhraseGridMemory.peek(path) != null || PhraseGridMemory.gaveUp(path)) {
      return;
    }
    final String key = audioPathKey(path);
    if (!_phrasePending.add(key)) return;
    if (!File(path).existsSync()) {
      PhraseGridMemory.giveUp(path);
      _phrasePending.remove(key);
      return;
    }
    _phraseJobs = _phraseJobs.then((_) async {
      try {
        await _buildPhraseGrid(path);
      } finally {
        _phrasePending.remove(key);
      }
    });
  }

  Future<void> _buildPhraseGrid(String path) async {
    if (PhraseGridMemory.peek(path) != null || PhraseGridMemory.gaveUp(path)) {
      return;
    }
    try {
      PhraseGridMemory.absorbDir(File(path).parent.path);
    } catch (_) {}
    if (PhraseGridMemory.peek(path) != null) {
      _refreshPhraseMixOut();
      return;
    }
    try {
      double bpm = _extractBpm(path);
      var beatMs = 0;
      try {
        final rust_dsp.BeatGrid grid =
            beatFromTag(path, 0) ??
            await rust_dsp.beatGrid(
              inputPath: path,
              fromMs: BigInt.zero,
              spanSecs: 24,
            );
        if (grid.ok && grid.bpm >= 60 && grid.bpm <= 200) {
          if (bpm < 60 || bpm > 200) bpm = grid.bpm;
          beatMs = grid.beatMs.round();
        }
      } catch (_) {}
      if (bpm < 60 || bpm > 200) {
        PhraseGridMemory.giveUp(path);
        return;
      }
      final Uint8List pcm = await rust_dsp.decodeMonoPcm(
        inputPath: path,
        startSecs: 0,
        lengthSecs: 900,
        targetRate: 22050,
      );
      final PhraseTrack? track = await Isolate.run(
        () => analyzePhrasePcm(
          pcm: pcm,
          sampleRate: 22050,
          bpm: bpm,
          beatMs: beatMs,
        ),
      );
      if (track == null) {
        PhraseGridMemory.giveUp(path);
        return;
      }
      PhraseGridMemory.save(path, track);
      _refreshPhraseMixOut();
    } catch (_) {
      PhraseGridMemory.giveUp(path);
    }
  }

  void _refreshPhraseMixOut() {
    try {
      if (!_wantsPhraseProfile()) return;
      final String? path = state.currentTrackPath;
      if (path == null || path.isEmpty) return;
      final int dur = state.duration.inMilliseconds;
      if (dur <= 0) return;
      _mixOutCacheKey = null;
      final int mix = _calculateRadioMixOut(dur, path);
      if (mix <= 10000) return;
      if (mix <= state.position.inMilliseconds + 1500) return;
      if (mix == state.customMixOutMs) return;
      state = state.copyWith(customMixOutMs: mix);
    } catch (_) {}
  }

  Future<int> _calculateSmartCueIn(String path, Player player) async {
    // La duración la mide Rust. El deck no decide el cue.
    final int durMs = _exactDurCache[path] ?? 0;
    if (durMs <= 0) {
      return 0;
    }
    if (_isMixTrack(durMs)) return 0;
    if (ref.read(mixFormulaProvider) == MixFormula.stealthGap) {
      return stealthCueInMs(durMs, const []);
    }
    // El silencio inicial medido por el masterizado nunca queda dentro del cue.
    final int leadMs = TrackTags.peek(path)?.leadMs ?? 0;
    final int fallback = durMs > 30000
        ? (leadMs > 10000 ? leadMs : 10000)
        : (leadMs < durMs ~/ 3 ? leadMs : 0);
    if (ref.read(mixFormulaProvider) == MixFormula.dnaEnergy) {
      final String? outPath = state.currentTrackPath;
      final bool other = outPath != null && !sameAudioPath(outPath, path);
      final bool locked = other && state.customMixOutMs > 10000;
      return _dnaPair(
        outDurationMs: other ? state.duration.inMilliseconds : durMs,
        outPath: other ? outPath : null,
        genreMixOutMs: locked ? state.customMixOutMs : 0,
        exitLocked: locked,
        inDurationMs: durMs,
        inPath: path,
        fallbackCueMs: fallback,
        outRate: 1,
      ).cueInMs;
    }
    if (ref.read(mixFormulaProvider) != MixFormula.phraseGrid) return fallback;
    final String? outPath = state.currentTrackPath;
    final bool other = outPath != null && !sameAudioPath(outPath, path);
    final PhraseTrack? incoming = PhraseGridMemory.peek(path);
    final double bpm = _extractBpm(path);
    return planPhrase8(
      outDurationMs: other ? state.duration.inMilliseconds : durMs,
      inDurationMs: durMs,
      fallbackMixOutMs: other ? state.customMixOutMs : 0,
      fallbackCueMs: fallback,
      incomingBpm: bpm >= 60 ? bpm : (incoming?.bpm ?? 0),
      incomingRate: 1,
      outgoing: other ? PhraseGridMemory.peek(outPath) : null,
      incoming: incoming,
      lockExit: other,
    ).cueInMs;
  }

  // 🎛️ INYECCIÓN ADN DJ: Ahora el Cartridge aplica la regla 65%-80%
  // Se consulta en CADA tick de posición: se memoriza por pista/fórmula para
  // no repetir regex + búsquedas de texto decenas de veces por segundo (CPU).
  String? _mixOutCacheKey;
  int _mixOutCacheVal = 0;

  int _calculateRadioMixOut(int durationMs, String? path) {
    final MixFormula formula = ref.read(mixFormulaProvider);
    String key =
        '$durationMs|$path|$formula|'
        '${TrackTags.peek(path)?.tailMs ?? 0}|${TrackTags.peek(path)?.bpm ?? 0}';
    if (formula == MixFormula.phraseGrid || formula == MixFormula.dnaEnergy) {
      final String? peer = _phrasePeerPath();
      key =
          '$key|${PhraseGridMemory.stamp(path)}|${PhraseGridMemory.stamp(peer)}|$peer';
    }
    if (key == _mixOutCacheKey) return _mixOutCacheVal;
    final int v = _calculateRadioMixOutRaw(durationMs, path);
    _mixOutCacheKey = key;
    _mixOutCacheVal = v;
    return v;
  }

  int _calculateRadioMixOutRaw(int durationMs, String? path) {
    if (_isMixTrack(durationMs)) {
      // Un Mix ya no se escucha hasta el final: la mezcla sale 30 s antes del
      // fin (sin el silencio final medido por el masterizado).
      final int mixTail = TrackTags.peek(path)?.tailMs ?? 0;
      final int mixEff = (mixTail > 0 && mixTail < durationMs ~/ 3)
          ? durationMs - mixTail
          : durationMs;
      return mixEff - 30000;
    }
    if (durationMs <= 0) return 0;

    final trackPathLower = path?.toLowerCase() ?? '';
    final isRemix = trackPathLower.contains('remix');
    final isEdm =
        trackPathLower.contains('electronica') ||
        trackPathLower.contains('house');
    final isTropical =
        trackPathLower.contains('salsa') ||
        trackPathLower.contains('cumbia') ||
        trackPathLower.contains('merengue');

    int safeMixOutMs = 0;
    if (isRemix || isEdm) {
      safeMixOutMs = (durationMs * 0.65).toInt();
    } else if (isTropical) {
      safeMixOutMs = (durationMs * 0.80).toInt();
    } else {
      safeMixOutMs = (durationMs * 0.75).toInt();
    }

    // El silencio final medido por el masterizado no cuenta como canción: el
    // cruce sale antes de que empiece (la pista ya no se recorta en disco).
    final int tailMs = TrackTags.peek(path)?.tailMs ?? 0;
    final int effDurMs = (tailMs > 0 && tailMs < durationMs ~/ 3)
        ? durationMs - tailMs
        : durationMs;
    if (effDurMs != durationMs) {
      safeMixOutMs = (safeMixOutMs * effDurMs / durationMs).toInt();
    }

    if (ref.read(mixFormulaProvider) == MixFormula.stealthGap) {
      return stealthMixOutMs(
        durationMs: effDurMs,
        lyricMs: const [],
        bpm: _extractBpm(path),
      );
    }
    if (ref.read(mixFormulaProvider) == MixFormula.phraseGrid) {
      final int snapped = snapPhraseGridMixOut(
        durationMs: effDurMs,
        dnaMixOutMs: safeMixOutMs,
        bpm: _extractBpm(path),
      );
      final String? peer = _phrasePeerPath();
      final PhraseTrack? incoming = PhraseGridMemory.peek(peer);
      final double peerBpm = _extractBpm(peer);
      final int peerDur = incoming?.durationMs ?? 0;
      return planPhrase8(
        outDurationMs: effDurMs,
        inDurationMs: peerDur,
        fallbackMixOutMs: snapped,
        fallbackCueMs: _phraseFallbackCue(peer, peerDur),
        incomingBpm: peerBpm >= 60 ? peerBpm : (incoming?.bpm ?? 0),
        incomingRate: 1,
        outgoing: PhraseGridMemory.peek(path),
        incoming: incoming,
      ).mixOutMs;
    }
    final String? peer = _phrasePeerPath();
    final PhraseTrack? incoming = PhraseGridMemory.peek(peer);
    final int peerDur = incoming?.durationMs ?? 0;
    final DnaDecision dna = _dnaPair(
      outDurationMs: effDurMs,
      outPath: path,
      genreMixOutMs: safeMixOutMs,
      exitLocked: false,
      inDurationMs: peerDur,
      inPath: peer,
      fallbackCueMs: _phraseFallbackCue(peer, peerDur),
      outRate: 1,
    );
    if (effDurMs > 0) {
      final double pct = dna.mixOutMs * 100.0 / effDurMs;
      debugPrint(
        'DNA mixOut=${dna.mixOutMs} (${pct.toStringAsFixed(1)}%) '
        'fuente=${dna.mixSource} fadeFin=${dna.mixOutMs + dna.fadeMs}',
      );
    }
    return dna.mixOutMs;
  }

  DnaDecision _dnaPair({
    required int outDurationMs,
    required String? outPath,
    required int genreMixOutMs,
    required bool exitLocked,
    required int inDurationMs,
    required String? inPath,
    required int fallbackCueMs,
    required double outRate,
  }) {
    return decideDna(
      outDurationMs: outDurationMs,
      inDurationMs: inDurationMs,
      genreMixOutMs: genreMixOutMs,
      fallbackCueMs: fallbackCueMs,
      outBpm: _extractBpm(outPath),
      inBpm: _extractBpm(inPath),
      outRate: outRate,
      outKey: outPath == null || outPath.isEmpty ? null : harmonicKeyOf(outPath),
      inKey: inPath == null || inPath.isEmpty ? null : harmonicKeyOf(inPath),
      outgoing: PhraseGridMemory.peek(outPath),
      incoming: PhraseGridMemory.peek(inPath),
      echoSupported: AfCaps.has('aecho'),
      eqSupported: AfCaps.has('equalizer'),
      exitLocked: exitLocked,
    );
  }

  Future<void> persistSession() => _saveSnapshot();

  bool _pausedByInterruption = false;

  /// Llamada/alarma/otra app: pausa ambos decks (también a mitad de un cruce)
  /// sin tocar cola, posición ni sesión. Devuelve `true` si estaba sonando.
  Future<bool> pauseForInterruption() async {
    if (!state.isPlaying) return false;
    _pausedByInterruption = true;
    if (_mix.armed) _captureDecks();
    final String? line = _mix.pauseAll();
    if (line != null) _djTrace(line);
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
    if (_mix.armed) {
      await _playDecksHeld();
      final String? line = _mix.resumeAll();
      if (line != null) _djTrace(line);
      return;
    }
    _mix.resumeAll();
    try {
      await _activePlayer.play();
    } catch (_) {}
    if (_isCrossfading) {
      try {
        await _standbyPlayer.play();
      } catch (_) {}
    }
  }

  void _releaseMix() {
    _isCrossfading = false;
    _incomingQuiet = null;
    _mix.end();
  }

  Future<void> _dropPhase() async {
    final PhaseLockSession? phase = _phaseLock;
    _phaseLock = null;
    if (phase == null) return;
    await phase.finish();
    phase.logLater(_djTrace);
  }

  bool _deckPlaying(Player Function() read) {
    try {
      return read().state.playing;
    } catch (_) {
      return false;
    }
  }

  void _captureDecks() {
    _deckAWasOn = _deckPlaying(() => _playerA);
    _deckBWasOn = _deckPlaying(() => _playerB);
    final Player? quiet = _incomingQuiet;
    if (quiet != null && _mix.fadeClock == null) {
      if (identical(quiet, _playerA)) _deckAWasOn = false;
      if (identical(quiet, _playerB)) _deckBWasOn = false;
    }
  }

  Future<void> _playDecksHeld() async {
    if (_deckAWasOn) {
      try {
        await _playerA.play();
      } catch (_) {}
    }
    if (_deckBWasOn) {
      try {
        await _playerB.play();
      } catch (_) {}
    }
  }

  /// Pausa o reanuda la mezcla en el acto: relojes primero, decks después.
  Future<void> _toggleMixHold() async {
    if (_mix.paused) {
      await _playDecksHeld();
      final String? line = _mix.resumeAll();
      if (line != null) _djTrace(line);
      return;
    }
    _captureDecks();
    final String? line = _mix.pauseAll();
    if (line != null) _djTrace(line);
    try {
      await _playerA.pause();
    } catch (_) {}
    try {
      await _playerB.pause();
    } catch (_) {}
    await _saveSnapshot();
  }

  @visibleForTesting
  void armMixForTest({
    required int fadeMs,
    required double rampBpm,
    int elapsedMs = 0,
  }) {
    _isCrossfading = true;
    _mix.arm();
    _mix.setRampBpm(rampBpm);
    _mix.beginFade(fadeMs, elapsedMs: elapsedMs);
  }

  @visibleForTesting
  void armMixPreFadeForTest({required double rampBpm}) {
    _isCrossfading = true;
    _mix.arm();
    _mix.setRampBpm(rampBpm);
  }

  @visibleForTesting
  int get mixEpoch => _mix.epoch;

  /// Pausa entre [MixPause.arm] y el play del entrante: no arranca hasta que
  /// la mezcla vuelve a correr. false = epoch distinto o mezcla suelta.
  @visibleForTesting
  Future<bool> holdIncomingBeforePlay(int epoch) async {
    if (_mix.paused) await _mix.untilRunning();
    if (_mix.epoch != epoch || !_mix.armed) {
      await _dropPhase();
      return false;
    }
    return true;
  }

  @visibleForTesting
  Future<void> runFadeForTest({required int fadeMs}) async {
    final int epoch = _mix.epoch;
    final MixRunClock fadeClock = _mix.beginFade(fadeMs);
    while (fadeClock.elapsedMilliseconds < fadeMs && _mix.epoch == epoch) {
      if (_mix.paused) {
        await _mix.untilRunning();
        continue;
      }
      await _mix.slice(16, fadeClock);
    }
    _releaseMix();
  }

  @visibleForTesting
  bool get mixPaused => _mix.paused;

  @visibleForTesting
  bool get crossfadeHeld => _isCrossfading;

  @visibleForTesting
  String? get lastMixHoldLine => _mix.lastLine;

  int? _readSavedUiRoute() {
    try {
      final session = _liveStrategy.getSessionPath();
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

  String _sessionFilePath() => liveDjStatePath();

  File _resolveSessionFile() {
    return File(_sessionFilePath());
  }

  Future<void> _saveSnapshot() async {
    try {
      final path = _sessionFilePath();
      if (_queueHold && state.queue.isNotEmpty) {
        _queueHold = false;
      }
      if (_queueHold && !state.radioOn) {
        clearModeQueueSync(path);
        return;
      }
      final bool restart = _queueRestart;
      if (restart) {
        _queueRestart = false;
        _sessionPositionMs = 0;
      }
      final pos = restart
          ? 0
          : (_freezePersist
                ? _sessionPositionMs
                : state.position.inMilliseconds);
      final data = <String, dynamic>{
        'schema': 2,
        'queue': state.queue.map((f) => f.path).toList(),
        'currentTrackPath': restart ? null : state.currentTrackPath,
        'positionMs': pos,
        'mixMode': state.currentMixMode.index,
        'mixStrategy': state.mixStrategy.index,
        'mixFormula': ref.read(mixFormulaProvider).index,
        'wasPlaying': restart
            ? false
            : (_freezePersist ? _sessionWasPlaying : state.isPlaying),
        'radioOn': state.radioOn,
        'radioGenres': state.radioGenres.toList(),
        'sortMode': state.sortMode.name,
        if (_radioFreeze != null) 'radioFreeze': _radioFreeze!.toJson(),
      };
      // Atómico y en fila: un cierre o una actualización a mitad de guardado
      // ya no deja la sesión dañada (antes: cola vacía y modo Secuencial).
      // No pisa parejas ni ola: el parche deja el resto del archivo.
      await patchModeDoc(path, data);
      debugPrint("✅ [TRACKER] Snapshot guardado en disco correctamente.");
    } catch (e, stack) {
      debugPrint(
        "🔴 [TRACKER ERROR FATAL] Fallo al guardar Snapshot: $e\n$stack",
      );
    }
  }

  void shuffleQueue() {
    debugPrint(
      "🛠️ [TRACKER] shuffleQueue() INICIADO. Elementos en cola: ${state.queue.length}",
    );
    unawaited(_shuffleQueueAsync());
  }

  Future<void> _shuffleQueueAsync() async {
    try {
      final List<String> paths = state.queue
          .map((f) => f.path)
          .where((p) => !isKaraokeAudioPath(p))
          .toList();
      await preloadQueueBpm(paths);
      _applyLiveShuffleBank(advance: true);
    } catch (e, stack) {
      debugPrint("🔴 [TRACKER ERROR FATAL] El Shuffle explotó: $e\n$stack");
    }
  }

  void _applyLiveShuffleBank({required bool advance}) {
    if (!advance) return;
    final List<String> paths = dedupeAudioPaths(
      state.queue
          .map((f) => f.path)
          .where((p) => !isKaraokeAudioPath(p))
          .toList(),
    );
    if (paths.length <= 1) {
      debugPrint("⚠️ [TRACKER] Cola muy pequeña. Forzando solo UI.");
      state = state.copyWith(
        queue: paths.map(File.new).toList(),
        mixStrategy: LiveDjMixStrategy.random,
      );
      _saveSnapshot();
      return;
    }
    final String sessionPath = _sessionFilePath();
    GatomixStore.migrate(File(sessionPath).parent.path);
    preloadQueueBpmSync(paths);
    final String? playing = state.currentTrackPath;
    final ModeWave wave = loadModeWave(sessionPath, <String>[
      ...paths,
      ?playing,
    ]);
    final HarmonicOrder order = buildHarmonicShuffle(
      paths,
      _extractBpm,
      keyOf: camelotFromPath,
      usedPairs: wave.pairs,
      recentAge: wave.age,
      playing: playing,
      continueFrom: playing,
      startWaveUp: wave.waveUp,
      startInWave: wave.inWave,
    );
    GatomixStore.commitShuffleMemory(order.tracks, anchor: playing);
    unawaited(
      patchModeDoc(
        sessionPath,
        queueWavePatch(
          doc: readModeDoc(sessionPath),
          order: order.tracks,
          anchor: playing,
          waveUp: order.waveUp,
          inWave: order.inWave,
          previousBpm: order.tracks.isEmpty
              ? 0
              : _extractBpm(order.tracks.last),
        ),
      ),
    );
    state = state.copyWith(
      queue: order.tracks.map(File.new).toList(),
      mixStrategy: LiveDjMixStrategy.random,
    );
    _saveSnapshot();
    debugPrint("🔀 [TRACKER] Shuffle armónico: ${order.tracks.length} pistas.");
  }

  /// Orden de la cola en Secuencial. Se guarda y se vuelve a aplicar a lo
  /// que se cargue después. No cambia la mezcla.
  void setSortMode(LiveDjSortMode mode) {
    state = state.copyWith(sortMode: mode);
    if (state.mixStrategy == LiveDjMixStrategy.sequential) _applySort();
    _saveSnapshot();
  }

  void _applySort() {
    if (state.sortMode == LiveDjSortMode.manual || state.queue.length < 2) {
      return;
    }
    final ordered = sortLiveDjPaths(
      state.queue.map((f) => f.path).toList(),
      state.sortMode,
      _extractBpm,
    );
    state = state.copyWith(queue: ordered.map((p) => File(p)).toList());
  }

  void toggleMixStrategy() {
    debugPrint(
      "🖱️ [TRACKER] Clic recibido en toggleMixStrategy(). Estrategia actual: ${state.mixStrategy.name}",
    );
    try {
      if (state.mixStrategy == LiveDjMixStrategy.sequential) {
        shuffleQueue();
      } else {
        state = state.copyWith(mixStrategy: LiveDjMixStrategy.sequential);
        _applySort();
        debugPrint(
          "➡️ [TRACKER] Estado Mutado a SECUENCIAL. Mandando señal a la UI...",
        );
        _saveSnapshot();
      }
    } catch (e, stack) {
      debugPrint("🔴 [TRACKER ERROR FATAL] El Toggle explotó: $e\n$stack");
    }
  }

  Future<void> _initPersistence() async {
    try {
      final data = SessionStore.readJson(_resolveSessionFile().path);
      if (data is! Map) return;

      final queuePaths = ((data['queue'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      // Pistas renombradas por Masterizar se reencuentran. Duplicados de
      // la misma ruta (mayúsculas, separadores) y las _K se quitan al abrir.
      final LiveDjSessionRestore restored = restoreLiveDjSession(
        data,
        strategyCount: LiveDjMixStrategy.values.length,
        modeCount: LiveDjMixMode.values.length,
      );
      final List<File> queueFiles = dedupeAudioFiles(
        restored.queue.map(File.new).toList(),
      );
      String? currentTrackPath = restored.currentTrackPath == null
          ? null
          : canonicalAudioPath(restored.currentTrackPath!);
      if (currentTrackPath != null) {
        queueFiles.removeWhere((f) => sameAudioPath(f.path, currentTrackPath));
      }
      final LiveDjSortMode savedSort = LiveDjSortMode.values.firstWhere(
        (m) => m.name == data['sortMode'],
        orElse: () => LiveDjSortMode.manual,
      );
      var currentFromQueue = restored.currentFromQueue;
      if (currentTrackPath == null && queueFiles.isNotEmpty) {
        // La pista que pasa a "actual" sale de la cola (cartridge destructiva);
        // si no, volvería a sonar al terminar.
        currentTrackPath = queueFiles.removeAt(0).path;
        currentFromQueue = true;
      }
      // La posición guardada era de otra pista: no se aplica a la nueva.
      final int? positionMs = currentFromQueue ? null : restored.positionMs;

      final mixModeIdx = restored.mixModeIndex;
      final mixStrategyIdx = restored.mixStrategyIndex;
      final mixFormulaIdx = data['mixFormula'] as int? ?? 0;
      if (mixFormulaIdx >= 0 && mixFormulaIdx < MixFormula.values.length) {
        ref.read(mixFormulaProvider.notifier).state =
            MixFormula.values[mixFormulaIdx];
      }

      // Radio: géneros en la sesión. La lista de cada opción vive en
      // `LiveDj_Radio.json`, en la raíz de Música.
      final bool savedRadioOn = data['radioOn'] as bool? ?? false;
      final Set<String> savedGenres = ((data['radioGenres'] as List?) ?? [])
          .map((e) => e.toString())
          .where(kRadioGenreIds.contains)
          .toSet();
      _radioFreeze = LiveQueueFreeze.tryParse(data['radioFreeze']);
      _radioMem = GatomixRadio.load(
        _musicRoot(),
        legacyPaths: <String>[_radioHistoryPath()],
      );

      if (state.queue.isNotEmpty || state.currentTrackPath != null) {
        return;
      }

      state = state.copyWith(
        radioOn: savedRadioOn,
        radioGenres: savedGenres,
        queue: queueFiles,
        currentTrackPath: currentTrackPath,
        currentMixMode: LiveDjMixMode.values[mixModeIdx],
        mixStrategy: LiveDjMixStrategy.values[mixStrategyIdx],
        sortMode: savedSort,
      );
      final bool queueDirty =
          queuePaths.length != queueFiles.length ||
          queuePaths.join('\n') != queueFiles.map((f) => f.path).join('\n') ||
          (data['currentTrackPath'] as String?) != currentTrackPath;
      if (queueDirty) {
        _sessionPositionMs = positionMs ?? 0;
        _sessionWasPlaying = data['wasPlaying'] as bool? ?? false;
        _freezePersist = true;
        unawaited(_saveSnapshot());
        _freezePersist = false;
      }
      if (savedRadioOn) {
        _publishRadioUpcoming();
        unawaited(_radioEnsureIndex());
      }

      _freezePersist = false;
      if (currentTrackPath != null && _readSavedUiRoute() == 5) {
        _drift.begin(_extractBpm(currentTrackPath), 1.0);
        try {
          await _activePlayer.setRate(1.0);
        } catch (_) {}
        await _activePlayer.open(Media(currentTrackPath), play: false);
        ref
            .read(liveDjEqualizerProvider.notifier)
            .adapt(_activePlayer, currentTrackPath);
        try {
          await _activePlayer.stream.duration
              .firstWhere((d) => d.inMilliseconds > 0)
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
        if (positionMs != null && positionMs > 0) {
          await _activePlayer.seek(Duration(milliseconds: positionMs));
          _sessionPositionMs = positionMs;
        }
        final wasPlaying = data['wasPlaying'] as bool? ?? false;
        if (wasPlaying) {
          await _activePlayer.play();
        }
      }
      // El orden guardado de la cola es la verdad: no se re-mezcla al reabrir.
    } catch (_) {
    } finally {
      _sessionHydrated = true;
      _schedulePhraseNeighbors();
    }
  }

  void addTrack(File file) {
    if (isKaraokeAudioPath(file.path)) return;
    final File kept = File(canonicalAudioPath(file.path));
    if (state.queue.any((File f) => sameAudioPath(f.path, kept.path))) return;
    if (state.mixStrategy != LiveDjMixStrategy.random) {
      // Secuencial: la pista nueva va al final. El modo no cambia.
      state = state.copyWith(queue: <File>[...state.queue, kept]);
      _applySort();
      _saveSnapshot();
      return;
    }
    final String key = audioPathKey(kept.path);
    if (!_queueAddPending.add(key)) return;
    final int epoch = _addEpoch;
    _queueAddChain = _queueAddChain.then(
      (_) => _insertLiveRandom(<File>[kept], epoch),
    );
  }

  void addAllTracks(List<File> files) {
    final Set<String> currentPaths = <String>{
      for (final File f in state.queue) audioPathKey(f.path),
      ..._queueAddPending,
    };
    final List<File> newFiles = <File>[];
    for (final File f in files) {
      if (isKaraokeAudioPath(f.path)) continue;
      final File kept = File(canonicalAudioPath(f.path));
      if (currentPaths.add(audioPathKey(kept.path))) newFiles.add(kept);
    }
    if (newFiles.isEmpty) return;
    if (state.mixStrategy != LiveDjMixStrategy.random) {
      state = state.copyWith(queue: <File>[...state.queue, ...newFiles]);
      _applySort();
      _saveSnapshot();
      return;
    }
    for (final File f in newFiles) {
      _queueAddPending.add(audioPathKey(f.path));
    }
    final int epoch = _addEpoch;
    _queueAddChain = _queueAddChain.then(
      (_) => _insertLiveRandom(newFiles, epoch),
    );
  }

  int _liveLockedPrefix() {
    if (state.queue.isEmpty) return 0;
    if (_isCrossfading) return 1;
    if (_standbyArmedPath == null) return 0;
    final int i = state.queue.indexWhere(
      (File f) => sameAudioPath(f.path, _standbyArmedPath),
    );
    if (i >= 0) return i + 1;
    return 0;
  }

  Future<void> _insertLiveRandom(List<File> files, int epoch) async {
    if (epoch != _addEpoch) {
      for (final File f in files) {
        _queueAddPending.remove(audioPathKey(f.path));
      }
      return;
    }
    final List<File> fresh = <File>[];
    for (final File f in files) {
      _queueAddPending.remove(audioPathKey(f.path));
      if (isKaraokeAudioPath(f.path)) continue;
      if (state.queue.any((File e) => sameAudioPath(e.path, f.path))) continue;
      if (state.currentTrackPath != null &&
          sameAudioPath(state.currentTrackPath, f.path)) {
        continue;
      }
      fresh.add(f);
    }
    if (fresh.isEmpty) return;
    final List<String> paths = fresh.map((File f) => f.path).toList();
    try {
      await preloadQueueBpm(paths);
    } catch (_) {}
    if (epoch != _addEpoch) return;
    for (final String p in paths) {
      saveTrackMusic(p, bpm: _extractBpm(p), camelot: harmonicKeyOf(p));
    }
    if (epoch != _addEpoch) return;
    if (state.mixStrategy != LiveDjMixStrategy.random) {
      state = state.copyWith(queue: <File>[...state.queue, ...fresh]);
      _applySort();
      _saveSnapshot();
      return;
    }
    if (state.queue.isEmpty && fresh.length > 1) {
      state = state.copyWith(queue: fresh);
      _applyLiveShuffleBank(advance: true);
      return;
    }
    if (epoch != _addEpoch) return;
    final List<String> next = insertHarmonicTracks(
      queue: state.queue.map((File f) => f.path).toList(),
      incoming: paths,
      bpmOf: _extractBpm,
      keyOf: harmonicKeyOf,
      lockedPrefix: _liveLockedPrefix(),
      playing: state.currentTrackPath,
      pinned: _standbyArmedPath,
    );
    final Map<String, File> byKey = <String, File>{
      for (final File f in <File>[...state.queue, ...fresh])
        audioPathKey(f.path): f,
    };
    state = state.copyWith(
      queue: <File>[
        for (final String p in next) byKey[audioPathKey(p)] ?? File(p),
      ],
    );
    _saveSnapshot();
  }

  void removeTrack(String path) {
    final newQueue = state.queue
        .where((f) => !sameAudioPath(f.path, path))
        .toList();
    state = state.copyWith(queue: newQueue);
    _saveSnapshot();
  }

  void clearQueue() {
    _addEpoch++;
    _queueAddPending.clear();
    _queueAddChain = Future<void>.value();
    if (state.radioOn) {
      // Fuera de este arreglo: la radio y su archivo no se vacían.
      state = state.copyWith(queue: <File>[]);
      _saveSnapshot();
      return;
    }
    _queueHold = true;
    _queueRestart = true;
    _radioFreeze = null;
    _sessionPositionMs = 0;
    _lastSavedPositionMs = 0;
    _sessionWasPlaying = false;
    state = state.copyWith(
      queue: <File>[],
      position: Duration.zero,
      clearCurrentTrackPath: true,
    );
    clearModeQueueSync(_sessionFilePath());
  }

  Future<void> savePlaylist() async {
    if (state.queue.isEmpty) return;
    try {
      final FileSaveLocation? result = await getSaveLocation(
        suggestedName: 'LiveDj_playlist.json',
        acceptedTypeGroups: [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (result != null) {
        final file = File(result.path);
        final data = state.queue.map((f) => f.path).toList();
        await file.writeAsString(jsonEncode(data));
      }
    } catch (e) {
      debugPrint("🔴 [ERROR] Guardando playlist: $e");
    }
  }

  Future<void> loadPlaylist() async {
    try {
      final XFile? result = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (result != null) {
        final file = File(result.path);
        final content = await file.readAsString();
        final List<dynamic> paths = jsonDecode(content);
        final List<File> newFiles = dedupeAudioFiles(
          paths
              .map((p) => File(p.toString()))
              .where((f) => f.existsSync())
              .toList(),
        );

        if (newFiles.isNotEmpty) {
          final Set<String> currentPaths = <String>{
            for (final File f in state.queue) audioPathKey(f.path),
          };
          final List<File> fresh = newFiles
              .where((f) => currentPaths.add(audioPathKey(f.path)))
              .toList();
          if (fresh.isEmpty) return;
          if (state.mixStrategy == LiveDjMixStrategy.random) {
            for (final File f in fresh) {
              _queueAddPending.add(audioPathKey(f.path));
            }
            final int epoch = _addEpoch;
            _queueAddChain = _queueAddChain.then(
              (_) => _insertLiveRandom(fresh, epoch),
            );
            await _queueAddChain;
          } else {
            state = state.copyWith(queue: <File>[...state.queue, ...fresh]);
            _applySort();
            _saveSnapshot();
          }
        }
      }
    } catch (e) {
      debugPrint("🔴 [ERROR] Cargando playlist: $e");
    }
  }

  Future<void> playTrackFromQueue(int index) async {
    if (index < 0 || index >= state.queue.length || _isCrossfading) return;

    // La pista tocada suena tal cual; el resto de la cola NO se reordena.
    _isPrepModeBypass = false;
    await forceNext(queueIndex: index);
  }

  final Map<String, int> _exactDurCache = {};

  /// Duración decodificada (`exact_duration_ms`). Ni TLEN ni la estimación
  /// de libmpv deciden la barra ni el disparo. Sin medición, duración 0.
  Future<Duration> _trueDuration(String path, Duration mpv) async {
    await TrackTags.load(path);
    try {
      int? ms = _exactDurCache[path];
      if (ms == null || ms <= 0) {
        ms = (await rust_dsp.exactDurationMs(inputPath: path)).toInt();
        if (ms > 0) _exactDurCache[path] = ms;
      }
      if (ms > 0) {
        if (ms != mpv.inMilliseconds) {
          debugPrint(
            '⏱️ [LIVEDJ] Duración decodificada ${ms ~/ 1000}s '
            '(libmpv ${mpv.inSeconds}s): $path',
          );
        }
        return Duration(milliseconds: ms);
      }
    } catch (e) {
      _djTrace('DURACION FALLO $path $e');
    }
    _djTrace('DURACION SIN MEDIR $path mpv=${mpv.inMilliseconds}');
    return Duration.zero;
  }

  void _rememberDriftNext() {
    if (_isCrossfading) return;
    final String? next = state.radioOn
        ? ((state.radioNextPath != null && state.radioNextPath!.isNotEmpty)
              ? state.radioNextPath
              : _radioPending)
        : _queueHeadPath();
    if (next != null && next.isNotEmpty) _driftNextPath = next;
  }

  void _attachListeners(Player player) {
    _lastUiPosMs = -1;
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();

    _positionSub = player.stream.position.listen((Duration pos) async {
      final posMs = pos.inMilliseconds;
      final String? tickPath = state.currentTrackPath;
      final durMs = state.duration.inMilliseconds;

      if (uiPositionShouldPublish(posMs, _lastUiPosMs)) {
        _lastUiPosMs = posMs;
        state = state.copyWith(position: pos);
      }

      // Servicio en primer plano (Android): sin esto el SO mata el proceso
      // en segundo plano / pantalla apagada. Un latido por segundo.
      final int osSecond = posMs ~/ 1000;
      if (osSecond != _lastOsSecond) {
        _lastOsSecond = osSecond;
        globalAudioHandler.syncOs(
          owner: 'livedj',
          path: state.currentTrackPath,
          duration: state.duration,
          playing: state.isPlaying,
          position: pos,
        );
      }

      if (!_freezePersist) {
        _sessionPositionMs = posMs;
        _sessionWasPlaying = state.isPlaying;
      }

      if (sessionPositionShouldSave(posMs, _lastSavedPositionMs)) {
        _lastSavedPositionMs = posMs;
        _saveSnapshot();
      }

      if (durMs > 0 &&
          state.currentTrackPath != null &&
          (state.queue.isNotEmpty || state.radioOn)) {
        final int barMixOut = state.customMixOutMs > 10000
            ? state.customMixOutMs
            : _calculateRadioMixOut(durMs, state.currentTrackPath);

        if (!_isCrossfading && !_mix.paused) {
          final double curRate = player.state.rate;
          final String? blocked = _drift.takeBlockedReport();
          if (blocked != null) _djTrace('MIDPOINT FUERA $blocked');
          final double? tgt = _drift.tick(
            posMs: posMs,
            durMs: durMs,
            mixOutMs: barMixOut,
            rate: curRate,
            nextBpm: _extractBpm(_driftNextPath ?? _standbyArmedPath),
          );
          final String? blockedAfter = _drift.takeBlockedReport();
          if (blockedAfter != null) _djTrace('MIDPOINT FUERA $blockedAfter');
          if (tgt != null) {
            unawaited(
              _drift.ramp(player, curRate, tgt, ms: _drift.rampMs, hold: _mix),
            );
          }
        }

        // No se arma durante un cruce: el deck "standby" es el que aún suena
        // (saliendo); recargarlo mete pistas fantasma y deja el armado huérfano.
        if (!_isStandbyArmed &&
            !_isCrossfading &&
            !_mix.paused &&
            posMs >= (barMixOut - 10000) &&
            barMixOut > 10000) {
          _isStandbyArmed = true;
          _standbyArmedPath = null;
          final bool armingRadio = state.radioOn;
          final int armEpoch = _radioEpoch;
          // Radio encendida: la pista sale del universo de géneros, no de la cola.
          // Apagada: la misma que muestra la barra (cabeza, o BPM en Stealth).
          final String? armPathOrNull = armingRadio
              ? (_radioPendingReady() ?? await _radioNextPath())
              : (state.queue.isNotEmpty
                    ? state.queue[_nextQueueIndex()].path
                    : null);
          if (armingRadio &&
              !radioArmStillValid(
                radioOn: state.radioOn,
                epoch: _radioEpoch,
                armEpoch: armEpoch,
              )) {
            // La radio se apagó mientras elegía: no se precarga esa pista.
            // El tick siguiente arma la cabeza de la cola, una sola vez.
            _isStandbyArmed = false;
            _driftNextPath = _queueHeadPath();
            return;
          }
          if (armPathOrNull == null) return;
          final String armPath = armPathOrNull;
          // Ni la que suena ni la anterior: el relevo no puede reabrirlas.
          if (sameAudioPath(armPath, tickPath) ||
              (_radioPrevious != null &&
                  sameAudioPath(armPath, _radioPrevious))) {
            _isStandbyArmed = false;
            _radioPending = null;
            return;
          }
          // La rampa ve el BPM de la entrante mientras el deck abre el archivo.
          _driftNextPath = armPath;
          await _standbyPlayer.setVolume(0.0);
          await _standbyPlayer.open(Media(armPath), play: false);
          // Si durante la carga cambió la pista o empezó un cruce, este armado
          // ya no vale: si no, se recarga el deck que está sonando.
          if (state.currentTrackPath != tickPath ||
              _isCrossfading ||
              player != _activePlayer) {
            return;
          }
          // Solo se da por precargada cuando la carga terminó de verdad.
          _standbyArmedPath = armPath;
          _schedulePhraseNeighbors();
          ref
              .read(liveDjEqualizerProvider.notifier)
              .adapt(_standbyPlayer, armPath);
        }

        if (state.currentTrackPath != tickPath || player != _activePlayer) {
          return;
        }
        if (mixTriggerDue(
          posMs: posMs,
          exactMs: durMs,
          mixOutMs: barMixOut,
        )) {
          if (!_isCrossfading && !_isPrepModeBypass && !_mix.paused) {
            _djTrace(
              'TRIGGER pos=$posMs dur=$durMs bar=$barMixOut '
              'cur=${state.currentTrackPath} armed=$_standbyArmedPath q0=${state.queue.isNotEmpty ? state.queue.first.path : null}',
            );
            _triggerCrossfade();
          }
        }
      }
    });

    _durationSub = player.stream.duration.listen((mpvDur) async {
      // La barra y el punto de mezcla esperan la duración decodificada.
      // La estimación de libmpv no se publica.
      final String? durPath = state.currentTrackPath;
      if (durPath == null) return;
      final Duration dur = await _trueDuration(durPath, mpvDur);
      if (state.currentTrackPath != durPath) return;
      if (dur.inMilliseconds <= 0 || state.currentTrackPath == null) return;
      state = state.copyWith(duration: dur);
      globalAudioHandler.syncOs(
        owner: 'livedj',
        path: state.currentTrackPath,
        duration: dur,
        playing: state.isPlaying,
        position: state.position,
      );
      final triggerMs = _calculateRadioMixOut(
        dur.inMilliseconds,
        state.currentTrackPath,
      );
      final cueInMs = await _calculateSmartCueIn(
        state.currentTrackPath!,
        player,
      );
      final mode = _isMixTrack(dur.inMilliseconds)
          ? LiveDjMixMode.longBypass
          : LiveDjMixMode.activeSync;

      state = state.copyWith(
        customCueInMs: cueInMs,
        customMixOutMs: triggerMs,
        currentMixMode: mode,
      );
      _rememberDriftNext();
    });

    _playingSub = player.stream.playing.listen((playing) {
      if (_parking) return;
      if (playing == state.isPlaying) return;
      state = state.copyWith(isPlaying: playing);
      if (playing) {
        // Controles de notificación/auriculares: el que suena es el dueño.
        globalAudioHandler.claim(
          'livedj',
          onPlayPause: () => togglePlayPause(),
          onPause: () async {
            if (state.isPlaying) await togglePlayPause();
          },
          onNext: () => forceNext(),
          // Anterior: reinicia la canción (la cola Live DJ es FIFO destructiva).
          onPrevious: () => seek(Duration.zero),
          onSeek: (pos) => seek(pos),
          isPlaying: () => state.isPlaying,
        );
      }
      globalAudioHandler.syncOs(
        owner: 'livedj',
        path: state.currentTrackPath,
        duration: state.duration,
        playing: playing,
        position: state.position,
      );
    });

    _completedSub = player.stream.completed.listen((completed) {
      if (!completed || !_sessionHydrated) return;
      // El deck que sale también puede marcar fin durante un cruce. Si se
      // anula el cruce y se pide otra pista, la que suena se mezcla consigo.
      if (_isCrossfading) return;
      _isPrepModeBypass = false;
      _djTrace(
        'NO DISPARO pos=${state.position.inMilliseconds} '
        'dur=${state.duration.inMilliseconds} trigger=${state.customMixOutMs} '
        'cur=${state.currentTrackPath} armed=$_standbyArmedPath radio=${state.radioOn}',
      );
      if (state.queue.isNotEmpty || state.radioOn) {
        _nextFromCompletion = true;
        forceNext();
      } else {
        unawaited(_stopWhenNoNext());
      }
    });
  }

  Future<void> togglePlayPause() async {
    if (_mix.armed) {
      await _toggleMixHold();
      return;
    }
    if (state.queue.isEmpty &&
        state.currentTrackPath == null &&
        !state.radioOn) {
      return;
    }

    _isPrepModeBypass = false;
    _freezePersist = false;

    if (state.currentTrackPath == null &&
        (state.queue.isNotEmpty || state.radioOn)) {
      await forceNext();
      return;
    }

    final path = state.currentTrackPath;
    final deckEmpty = _activePlayer.state.duration.inMilliseconds <= 0;
    if (path != null && deckEmpty) {
      if (!File(path).existsSync()) {
        if (state.queue.isNotEmpty) {
          await forceNext();
        }
        return;
      }
      try {
        _drift.begin(_extractBpm(path), 1.0);
        try {
          await _activePlayer.setRate(1.0);
        } catch (_) {}
        await _activePlayer.open(Media(path), play: true);
        ref.read(liveDjEqualizerProvider.notifier).adapt(_activePlayer, path);
        _attachListeners(_activePlayer);
      } catch (e) {
        debugPrint("🔴 [LIVEDJ OPEN]: $e");
        if (state.queue.isNotEmpty) await forceNext();
      }
      _saveSnapshot();
      return;
    }

    final bool playingNow = _deckPlaying(() => _activePlayer);
    if (playingNow) _mix.pauseAll();
    await _activePlayer.playOrPause();
    if (!playingNow) _mix.resumeAll();
    if (!state.isPlaying) _saveSnapshot();
  }

  Future<void> seek(Duration position) async {
    if (state.currentTrackPath == null || _isCrossfading) return;
    _isPrepModeBypass = false;
    await _activePlayer.seek(position);
  }

  Future<void> forceNext({int? queueIndex}) async {
    if (_isCrossfading) return;
    if (state.queue.isEmpty && !state.radioOn) {
      await _stopWhenNoNext();
      return;
    }
    await _triggerCrossfade(
      forceJit: true,
      isManualSkip: true,
      queueIndex: queueIndex,
    );
  }

  Future<void> _stopWhenNoNext() async {
    _releaseMix();
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
    // Fin de cola: no queda nada en memoria. Sin pista residual, la próxima
    // carga arranca desde la primera canción de la cola nueva.
    _isStandbyArmed = false;
    _isPrepModeBypass = false;
    _sessionPositionMs = 0;
    _sessionWasPlaying = false;
    _lastSavedPositionMs = 0;
    state = state.copyWith(
      isPlaying: false,
      clearCurrentTrackPath: true,
      position: Duration.zero,
      duration: Duration.zero,
      customCueInMs: -1,
      customMixOutMs: -1,
    );
    _saveSnapshot();
  }

  /// `true` si el deck tiene cargada (y con duración) exactamente `path`.
  bool _deckHolds(Player deck, String path) {
    try {
      if (deck.state.duration.inMilliseconds <= 0) return false;
      final medias = deck.state.playlist.medias;
      final idx = deck.state.playlist.index;
      if (idx < 0 || idx >= medias.length) return false;
      String norm(String s) {
        var t = s;
        try {
          t = Uri.decodeFull(s);
        } catch (_) {}
        return t
            .replaceAll('\\', '/')
            .replaceFirst('file:///', '')
            .toLowerCase();
      }

      final loaded = norm(medias[idx].uri);
      final want = norm(path);
      return loaded == want || loaded.endsWith(want) || want.endsWith(loaded);
    } catch (_) {
      return false;
    }
  }

  // ───────────────────────── ON AIR Radio ─────────────────────────
  // La cola de Live DJ se congela al encender. Cada opción de géneros tiene
  // una lista ya armada en `LiveDj_Radio.json` y sigue desde su posición.
  Map<String, List<String>>? _radioIndex; // carpeta → pistas
  final Map<String, String> _radioFolderGenre = <String, String>{};
  Future<void>? _radioIndexing;
  String? _radioPending;
  // Próximas de radio ya elegidas (hasta kRadioAheadCount). Valen solo en la
  // época en que se calcularon; el relleno corre en segundo plano.
  List<String> _radioAhead = const <String>[];
  int _radioAheadEpoch = -1;
  Future<void>? _radioRefillRun;
  bool _radioRefillAgain = false;
  final Random _radioRng = Random();
  int _radioEpoch = 0;
  int _radioAssembleEpoch = -1;
  Future<void>? _radioAssemble;

  static const Set<String> _radioExt = {
    'mp3',
    'm4a',
    'flac',
    'wav',
    'aac',
    'ogg',
    'opus',
    'wma',
  };

  String _radioFold(String s) {
    const from = 'áàäâéèëêíìïîóòöôúùüûñ';
    const to = 'aaaaeeeeiiiioooouuuun';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return b.toString();
  }

  String _musicBase() {
    if (Platform.isIOS) {
      if (IphoneLibrary.musicRoot.isNotEmpty) return IphoneLibrary.musicRoot;
    } else if (Platform.isAndroid) {
      return '/storage/emulated/0/Music';
    } else if (Platform.isWindows) {
      final String? up = Platform.environment['USERPROFILE'];
      return up != null ? '$up\\Music' : 'C:\\Music';
    } else {
      final String? home = Platform.environment['HOME'];
      return home != null ? '$home/Music' : '/tmp/Music';
    }
    return File(_sessionFilePath()).parent.path;
  }

  /// Raíz de Música, donde vive `LiveDj_Radio.json`.
  String _musicRoot() {
    final String base = _musicBase();
    if (base.isEmpty || base == '/')
      return File(_sessionFilePath()).parent.path;
    return base;
  }

  String _radioMusicRoot() {
    final String base = _musicBase();
    // Las carpetas de género viven en Música/ReGenial; si no existe, en Música.
    final Directory regenial = Directory(
      '$base${Platform.pathSeparator}ReGenial',
    );
    return regenial.existsSync() ? regenial.path : base;
  }

  /// Género de una carpeta de Música por su nombre; null = fuera de la radio.
  String? _radioGenreOfFolder(String name) {
    final n = _radioFold(name);
    if (n.contains('_k')) return null; // Karaoke
    if (n.startsWith('actualidad')) return 'actuales';
    for (final k in const [
      'salsa',
      'merengue',
      'cumbia',
      'guaracha',
      'bachata',
      'fiesta',
      'nacional',
    ]) {
      if (n.contains(k)) return 'bailable';
    }
    if (n.contains('balada')) return 'romanticas';
    if (n.contains('80s') || n.contains('ochent')) return 'ochenteras';
    if (n.contains('rock')) return 'rock';
    return null;
  }

  String _radioHistoryPath() =>
      '${File(_sessionFilePath()).parent.path}${Platform.pathSeparator}_livedj_radio.json';

  RadioMemory _radioMemory() => _radioMem ??= GatomixRadio.load(
    _musicRoot(),
    legacyPaths: <String>[_radioHistoryPath()],
  );

  void _saveRadio(RadioMemory mem, {String? activeKey}) {
    _radioMem = mem;
    _publishRadioUpcoming();
    final int serial = ++_radioSaveSerial;
    final String root = _radioRootOverride ?? _musicRoot();
    final Map<String, dynamic> doc = mem.toJson(activeKey: activeKey);
    // Una sola escritura a la vez. Una posición ya superada no pisa a la nueva.
    _radioSaveChain = _radioSaveChain.then((_) async {
      if (serial != _radioSaveSerial) return;
      await GatomixRadio.saveAsync(root, doc);
    });
  }

  bool _radioBanned(String path) {
    return radioRepeatsRecent(
      path,
      playing: state.currentTrackPath,
      previous: _radioPrevious,
      recent: radioRecent(_radioMemory().history),
    );
  }

  void _publishRadioUpcoming() {
    final List<String> next = state.radioOn
        ? radioUpcomingPaths(
            plan: _radioMem?.planOf(radioGenreKey(state.radioGenres)),
            nextPath: state.radioNextPath,
            ahead: _radioAheadEpoch == _radioEpoch
                ? _radioAhead
                : const <String>[],
          )
        : const <String>[];
    if (listEquals(state.radioUpcoming, next)) return;
    state = state.copyWith(radioUpcoming: next);
  }

  /// La siguiente ya elegida, sin esperar ni tocar disco. null = no hay.
  String? _radioPendingReady() {
    final String? p = _radioPending;
    if (p == null || p.isEmpty || _radioBanned(p)) return null;
    return p;
  }

  /// Rellena en segundo plano hasta [kRadioAheadCount] próximas. Nunca corre
  /// desde el tick; durante un cruce solo asegura la primera (sin disco).
  Future<void> _radioRefill() {
    if (!state.radioOn) return Future<void>.value();
    final Future<void>? run = _radioRefillRun;
    if (run != null) {
      _radioRefillAgain = true;
      return run;
    }
    return _radioRefillRun = _radioRefillLoop().whenComplete(() {
      _radioRefillRun = null;
    });
  }

  Future<void> _radioRefillLoop() async {
    do {
      _radioRefillAgain = false;
      try {
        await _radioRefillOnce();
      } catch (e, st) {
        debugPrint('🔴 [RADIO] relleno: $e\n$st');
      }
    } while (_radioRefillAgain && state.radioOn);
  }

  Future<void> _radioRefillOnce() async {
    final int epoch = _radioEpoch;
    bool live() => radioArmStillValid(
      radioOn: state.radioOn,
      epoch: _radioEpoch,
      armEpoch: epoch,
    );
    // Tras consumir la primera, la segunda ya elegida pasa a ser la siguiente.
    if (_radioPending == null && _radioAheadEpoch == epoch) {
      for (final String p in _radioAhead) {
        if (_radioBanned(p)) continue;
        if (!_isCrossfading && !File(p).existsSync()) continue;
        _radioPending = p;
        _driftNextPath = p;
        state = state.copyWith(radioNextPath: p);
        break;
      }
    }
    final String? first = await _radioNextPath();
    if (!live() || first == null || first.isEmpty) return;
    // Los extras tocan disco (existsSync): esperan al final de la mezcla.
    if (_isCrossfading) return;
    final List<String> out = <String>[first];
    final RadioPlan? plan = _radioMemory().planOf(
      radioGenreKey(state.radioGenres),
    );
    if (plan != null && !plan.finished) {
      for (
        var i = plan.position;
        i < plan.order.length && out.length < kRadioAheadCount;
        i++
      ) {
        final String p = plan.order[i];
        if (out.any((String o) => sameAudioPath(o, p))) continue;
        if (sameAudioPath(p, state.currentTrackPath)) continue;
        if (_radioBanned(p)) continue;
        if (!File(p).existsSync()) continue;
        out.add(p);
      }
    }
    if (!live()) return;
    _radioAhead = out;
    _radioAheadEpoch = epoch;
    _publishRadioUpcoming();
  }

  bool _radioAccept(String path) {
    if (isKaraokeAudioPath(path)) return false;
    final String fname = path.replaceAll('\\', '/').split('/').last;
    final int dot = fname.lastIndexOf('.');
    if (dot < 0) return false;
    return _radioExt.contains(fname.substring(dot + 1).toLowerCase());
  }

  List<String> _radioPoolNow() {
    final Map<String, List<String>>? idx = _radioIndex;
    if (idx == null || idx.isEmpty) return const <String>[];
    List<String> from(bool Function(String folder) take) {
      final List<String> out = <String>[];
      final Set<String> seen = <String>{};
      for (final MapEntry<String, List<String>> e in idx.entries) {
        if (!take(e.key)) continue;
        for (final String path in e.value) {
          if (!_radioAccept(path)) continue;
          if (seen.add(audioPathKey(path))) out.add(path);
        }
      }
      return out;
    }

    final Set<String> genres = state.radioGenres;
    final List<String> filtered = from((String folder) {
      final String? g = _radioFolderGenre[folder];
      return genres.isEmpty || (g != null && genres.contains(g));
    });
    if (filtered.isNotEmpty || genres.isEmpty) return filtered;
    return from((String _) => true);
  }

  Future<void> _radioEnsureIndex() {
    if (_radioIndex != null && _radioIndex!.isNotEmpty) return Future.value();
    return _radioIndexing ??= _radioBuildIndex().whenComplete(() {
      _radioIndexing = null;
    });
  }

  Future<void> _radioBuildIndex() async {
    final Map<String, List<String>> index = <String, List<String>>{};
    try {
      final root = Directory(_radioMusicRoot());
      if (root.existsSync()) {
        final kFile = RegExp(r'_k\.[a-z0-9]+$', caseSensitive: false);
        await for (final e in root.list(followLinks: false)) {
          if (e is! Directory) continue;
          final name = e.path.replaceAll('\\', '/').split('/').last;
          final genre = _radioGenreOfFolder(name);
          if (genre == null) continue;
          final files = <String>[];
          try {
            await for (final f in e.list(recursive: true, followLinks: false)) {
              if (f is! File) continue;
              final fname = f.path.replaceAll('\\', '/').split('/').last;
              final dot = fname.lastIndexOf('.');
              if (dot < 0) continue;
              if (!_radioExt.contains(fname.substring(dot + 1).toLowerCase())) {
                continue;
              }
              if (kFile.hasMatch(fname)) continue; // pista _K de Karaoke
              files.add(f.path);
            }
          } catch (_) {}
          if (files.isNotEmpty) {
            index[e.path] = files;
            _radioFolderGenre[e.path] = genre;
          }
        }
      }
    } catch (e) {
      debugPrint("🔴 [RADIO] Índice: $e");
    }
    // Sin carpetas con nombre de género (p. ej. una sola carpeta con todo):
    // todo el contenido de Música es el universo "Todo" y la radio no se para.
    if (index.isEmpty) {
      try {
        final root = Directory(_radioMusicRoot());
        if (root.existsSync()) {
          final kFile = RegExp(r'_k\.[a-z0-9]+$', caseSensitive: false);
          final Map<String, List<String>> byDir = <String, List<String>>{};
          await for (final f in root.list(
            recursive: true,
            followLinks: false,
          )) {
            if (f is! File) continue;
            final fname = f.path.replaceAll('\\', '/').split('/').last;
            final dot = fname.lastIndexOf('.');
            if (dot < 0) continue;
            if (!_radioExt.contains(fname.substring(dot + 1).toLowerCase())) {
              continue;
            }
            if (kFile.hasMatch(fname)) continue;
            byDir.putIfAbsent(f.parent.path, () => <String>[]).add(f.path);
          }
          byDir.forEach((dir, files) {
            index[dir] = files;
            _radioFolderGenre[dir] = 'todo';
          });
        }
      } catch (e) {
        debugPrint("🔴 [RADIO] Índice (respaldo): $e");
      }
    }
    _radioIndex = index;
    final Set<String> avail = <String>{
      for (final id in index.keys)
        if (_radioFolderGenre[id] != null) _radioFolderGenre[id]!,
    }..remove('todo');
    state = state.copyWith(radioGenresAvailable: avail);
    debugPrint(
      "📻 [RADIO] Índice: ${index.length} carpetas, "
      "${index.values.fold<int>(0, (a, b) => a + b.length)} pistas.",
    );
  }

  /// Siguiente de la lista ya armada. Si hay que armarla, el trabajo pesado
  /// (BPM de todas las carpetas + Shuffle) va a otro isolate. Esta función
  /// devuelve enseguida una pista compatible para que la mezcla no espere
  /// y la ventana no se congele.
  Future<String?> _radioNextPath({int depth = 0}) async {
    final int epoch = _radioEpoch;
    bool live() => radioArmStillValid(
      radioOn: state.radioOn,
      epoch: _radioEpoch,
      armEpoch: epoch,
    );
    if (!live()) return null;
    try {
      final String? pending = _radioPending;
      if (pending != null && pending.isNotEmpty && !_radioBanned(pending)) {
        return pending;
      }
      _radioPending = null;
      await _radioEnsureIndex();
      if (!live()) return null;
      final String? already = _radioPending;
      if (already != null && already.isNotEmpty && !_radioBanned(already)) {
        return already;
      }
      final List<String> pool = _radioPoolNow();
      if (pool.isEmpty) return _radioQueueFallback();
      final String key = radioGenreKey(state.radioGenres);
      final RadioMemory mem = _radioMemory();
      final RadioResolve resolve = radioResolveNext(
        memory: mem,
        key: key,
        pool: pool,
        playing: state.currentTrackPath,
        previous: _radioPrevious,
        bpmOf: memoryBpm,
        keyOf: camelotFromPath,
        rng: _radioRng,
        allowRebuild: false,
      );
      if (!live()) return null;
      final RadioPlan? saved = mem.planOf(key);
      if (resolve.followedPlan || resolve.rebuilt) {
        _radioMem = resolve.memory;
      }
      final String? next = resolve.next;
      if (next != null &&
          depth < 8 &&
          next.isNotEmpty &&
          !File(next).existsSync()) {
        _radioMem = _radioMemory().rememberMix(key: key, played: next);
        _radioPending = null;
        return await _radioNextPath(depth: depth + 1);
      }
      if (!live()) return null;
      if (next != null && next.isNotEmpty && !_radioBanned(next)) {
        _radioPending = next;
        _driftNextPath = next;
        state = state.copyWith(radioNextPath: next);
        _publishRadioUpcoming();
        if (resolve.needsAssemble) {
          _ensureRadioAssemble(
            epoch: epoch,
            key: key,
            pool: pool,
            mem: resolve.memory,
            saved: saved,
            pinned: next,
          );
        }
        return next;
      }
      if (resolve.needsAssemble) {
        _ensureRadioAssemble(
          epoch: epoch,
          key: key,
          pool: pool,
          mem: resolve.memory,
          saved: saved,
          pinned: null,
        );
      }
      return _radioQueueFallback();
    } catch (e, st) {
      debugPrint('🔴 [RADIO] $e\n$st');
      return _radioQueueFallback();
    }
  }

  void _ensureRadioAssemble({
    required int epoch,
    required String key,
    required List<String> pool,
    required RadioMemory mem,
    required RadioPlan? saved,
    required String? pinned,
  }) {
    if (!state.radioOn || epoch != _radioEpoch) {
      _djTrace(
        'RADIO ASSEMBLE DROP antes de arrancar epoch=$epoch ahora=$_radioEpoch '
        'on=${state.radioOn} pool=${pool.length}',
      );
      return;
    }
    // Solo se salta si la lista guardada todavía cubre este pool. Un plan
    // corto (o ninguno) no puede dejar el panel en una sola canción.
    if (!radioAssembleShouldStart(
      inFlight: _radioAssemble != null && _radioAssembleEpoch == epoch,
      planOpen: saved != null &&
          !saved.finished &&
          radioPlanIsOpen(saved, pool),
    )) {
      _djTrace(
        'RADIO ASSEMBLE DROP en curso o lista abierta pool=${pool.length} '
        'hist=${mem.history.length}',
      );
      return;
    }
    _radioAssembleEpoch = epoch;
    final Map<String, Object?> msg = <String, Object?>{
      'pool': List<String>.from(pool),
      'seed': _radioRng.nextInt(1 << 31),
      'pinned': pinned,
      'playing': state.currentTrackPath,
      'hasSaved': saved != null,
      'order': saved?.order ?? const <String>[],
      'position': saved?.position ?? 0,
      'pairs': saved?.pairs ?? const <String>[],
      'previousPairs': saved?.previousPairs ?? const <String>[],
      'readTags': false,
    };
    final Stopwatch sw = Stopwatch()..start();
    _djTrace(
      'RADIO ASSEMBLE START pool=${pool.length} key=$key epoch=$epoch '
      'hist=${mem.history.length}',
    );
    _radioAssemble = compute(assembleRadioOffUi, msg)
        .then((Map<String, Object?> raw) async {
          sw.stop();
          final bool applied = _applyRadioPlan(
            raw: raw,
            epoch: epoch,
            key: key,
            pool: pool,
            replace: false,
            elapsedMs: sw.elapsedMilliseconds,
          );
          if (!applied) return;
          final List<String> untagged = <String>[
            for (final Object? p in (raw['untagged'] as List?) ?? const <Object>[])
              p.toString(),
          ];
          if (untagged.isEmpty || epoch != _radioEpoch || !state.radioOn) {
            return;
          }
          final Stopwatch sw2 = Stopwatch()..start();
          _djTrace(
            'RADIO REFINE START pool=${pool.length} sinBpm=${untagged.length} key=$key',
          );
          final Map<String, Object?> tagged = Map<String, Object?>.from(msg);
          tagged['readTags'] = true;
          final Map<String, Object?> raw2 = await compute(
            assembleRadioOffUi,
            tagged,
          );
          sw2.stop();
          _applyRadioPlan(
            raw: raw2,
            epoch: epoch,
            key: key,
            pool: pool,
            replace: true,
            elapsedMs: sw2.elapsedMilliseconds,
          );
        })
        .catchError((Object e, StackTrace st) {
          _djTrace(
            'RADIO ASSEMBLE FALLO pool=${pool.length} ${sw.elapsedMilliseconds}ms $e',
          );
          debugPrint('🔴 [RADIO] $e\n$st');
        })
        .whenComplete(() {
          if (_radioAssembleEpoch == epoch) _radioAssemble = null;
        });
  }

  bool _applyRadioPlan({
    required Map<String, Object?> raw,
    required int epoch,
    required String key,
    required List<String> pool,
    required bool replace,
    required int elapsedMs,
  }) {
    if (epoch != _radioEpoch || !state.radioOn) {
      _djTrace(
        'RADIO ASSEMBLE DROP epoca epoch=$epoch ahora=$_radioEpoch '
        'on=${state.radioOn} pool=${pool.length} ${elapsedMs}ms',
      );
      return false;
    }
    if (raw['ok'] != true) {
      _djTrace(
        'RADIO ASSEMBLE FALLO pool=${pool.length} ${elapsedMs}ms ${raw['error']}',
      );
      return false;
    }
    RadioPlan plan = RadioPlan(
      order: <String>[
        for (final Object? p in (raw['order'] as List?) ?? const <Object>[])
          p.toString(),
      ],
      position: raw['position'] is int ? raw['position'] as int : 0,
      pairs: <String>[
        for (final Object? p in (raw['pairs'] as List?) ?? const <Object>[])
          p.toString(),
      ],
      previousPairs: <String>[
        for (final Object? p
            in (raw['previousPairs'] as List?) ?? const <Object>[])
          p.toString(),
      ],
    );
    if (plan.order.isEmpty) {
      _djTrace(
        'RADIO ASSEMBLE FALLO pool=${pool.length} orden vacía ${elapsedMs}ms',
      );
      return false;
    }
    final RadioPlan? have = _radioMemory().planOf(key);
    if (!replace &&
        have != null &&
        !have.finished &&
        radioPlanIsOpen(have, pool)) {
      _djTrace(
        'RADIO ASSEMBLE DROP plan ya abierto lista=${have.order.length} '
        'pool=${pool.length} ${elapsedMs}ms',
      );
      return false;
    }
    final String? onAir = state.currentTrackPath;
    if (onAir != null &&
        !plan.finished &&
        plan.position < plan.order.length &&
        sameAudioPath(plan.order[plan.position], onAir)) {
      plan = advanceRadioPlan(plan, onAir);
    }
    if (_radioPrevious != null &&
        !plan.finished &&
        plan.position < plan.order.length &&
        sameAudioPath(plan.order[plan.position], _radioPrevious!)) {
      plan = advanceRadioPlan(plan, _radioPrevious!);
    }
    _djTrace(
      'RADIO ASSEMBLE FIN pool=${pool.length} lista=${plan.order.length} '
      '${elapsedMs}ms key=$key',
    );
    _saveRadio(_radioMemory().putPlan(key, plan), activeKey: key);
    if (state.radioOn && epoch == _radioEpoch && !_isCrossfading) {
      unawaited(_radioRefill());
    }
    if (_isStandbyArmed) return true;
    if (plan.finished || plan.order.isEmpty) return true;
    if (plan.position < 0 || plan.position >= plan.order.length) return true;
    final String next = plan.order[plan.position];
    if (_radioPending != null && !sameAudioPath(_radioPending, next)) {
      return true;
    }
    if (!state.radioOn || epoch != _radioEpoch) return true;
    if (!File(next).existsSync()) return true;
    _radioPending = next;
    _driftNextPath = next;
    state = state.copyWith(radioNextPath: next);
    _publishRadioUpcoming();
    return true;
  }

  /// Último recurso: la radio nunca se para; suena una pista de la cola.
  String? _radioQueueFallback() {
    for (final File f in state.queue) {
      if (_radioBanned(f.path)) continue;
      if (File(f.path).existsSync()) return f.path;
    }
    return null;
  }

  void _radioConsumed(String path) {
    final String key = radioGenreKey(state.radioGenres);
    _radioPrevious = state.currentTrackPath;
    _saveRadio(
      _radioMemory().rememberMix(key: key, played: path),
      activeKey: key,
    );
    final double bpm = _extractBpm(path);
    if (bpm > 0) {
      saveTrackMusic(path, bpm: bpm, camelot: harmonicKeyOf(path));
    }
    _radioPending = null;
    if (_radioAhead.isNotEmpty) {
      _radioAhead = <String>[
        for (final String p in _radioAhead)
          if (!sameAudioPath(p, path)) p,
      ];
    }
    state = state.copyWith(clearRadioNextPath: true);
    if (_radioAhead.isNotEmpty) _publishRadioUpcoming();
  }

  @visibleForTesting
  void useRadioLibrary(String root) {
    _radioRootOverride = root;
  }

  @visibleForTesting
  void seedRadioIndex({required String genre, required List<String> files}) {
    _radioIndex = <String, List<String>>{'/seed': files};
    _radioFolderGenre['/seed'] = genre;
  }

  @visibleForTesting
  Future<void> refillRadioAhead() => _radioRefill();

  @visibleForTesting
  String? get radioPendingReadyNow => _radioPendingReady();

  @visibleForTesting
  RadioMemory get radioMemoryNow => _radioMem ?? RadioMemory.empty;

  @visibleForTesting
  Future<void> flushRadioSave() => _radioSaveChain;

  @visibleForTesting
  void seedOffAirQueue({
    required List<String> queue,
    String? playing,
    bool radioOn = false,
    String? radioNextPath,
    List<String> radioUpcoming = const <String>[],
  }) {
    state = state.copyWith(
      queue: <File>[for (final String p in queue) File(p)],
      currentTrackPath: playing,
      clearCurrentTrackPath: playing == null || playing.isEmpty,
      radioOn: radioOn,
      radioNextPath: radioNextPath,
      clearRadioNextPath: radioNextPath == null || radioNextPath.isEmpty,
      radioUpcoming: radioUpcoming,
    );
  }

  @visibleForTesting
  int debugNextQueueIndex() => _nextQueueIndex();

  @visibleForTesting
  void seedRadio({
    required RadioMemory memory,
    required String genre,
    String? playing,
    String? previous,
  }) {
    _radioMem = memory;
    _radioPrevious = previous;
    _radioPending = null;
    _radioEpoch++;
    state = state.copyWith(
      radioOn: true,
      radioGenres: <String>{genre},
      currentTrackPath: playing,
      clearCurrentTrackPath: playing == null || playing.isEmpty,
      clearRadioNextPath: true,
      isPlaying: playing != null && playing.isNotEmpty,
    );
    _publishRadioUpcoming();
  }

  @visibleForTesting
  void showRadioGenre(String genre) {
    _radioEpoch++;
    _radioPending = null;
    if (!_isCrossfading) {
      _isStandbyArmed = false;
      _standbyArmedPath = null;
      _driftNextPath = null;
    }
    state = state.copyWith(
      radioOn: true,
      radioGenres: <String>{genre},
      clearRadioNextPath: true,
    );
    _publishRadioUpcoming();
  }

  @visibleForTesting
  String? followRadioNext(
    List<String> pool, {
    double Function(String path)? bpmOf,
  }) {
    final String key = radioGenreKey(state.radioGenres);
    final RadioResolve resolve = radioResolveNext(
      memory: _radioMemory(),
      key: key,
      pool: pool,
      playing: state.currentTrackPath,
      previous: _radioPrevious,
      bpmOf: bpmOf ?? memoryBpm,
      keyOf: camelotFromPath,
      rng: _radioRng,
      allowRebuild: false,
    );
    if (resolve.rebuilt) {
      _saveRadio(resolve.memory, activeKey: key);
    } else {
      _radioMem = resolve.memory;
    }
    final String? next = resolve.next;
    if (next == null || _radioBanned(next)) return null;
    _radioPending = next;
    state = state.copyWith(radioNextPath: next);
    _publishRadioUpcoming();
    return next;
  }

  @visibleForTesting
  void finishRadioMix(String played) {
    _radioConsumed(played);
    state = state.copyWith(
      currentTrackPath: played,
      isPlaying: true,
      position: Duration.zero,
    );
  }

  void _captureRadioFreeze() {
    if (_radioFreeze != null) return;
    _radioFreeze = LiveQueueFreeze(
      queue: state.queue.map((File f) => f.path).toList(),
      current: state.currentTrackPath,
      positionMs: state.position.inMilliseconds,
      wasPlaying: state.isPlaying,
    );
  }

  /// Apaga la radio sin tocar el deck que suena: ni pausa, ni open, ni seek,
  /// ni setRate. La cola congelada vuelve de memoria. El relevo de radio se
  /// cancela y la siguiente vuelve a salir de esa cola (cabeza, o BPM si Stealth).
  void _turnRadioOff() {
    _radioEpoch++;
    _radioPending = null;
    _radioAssemble = null;
    _radioOffAfterFade = false;
    final List<String> live = <String>[
      for (final File f in state.queue) f.path,
    ];
    final RadioOffEffect effect = effectOfRadioOff(
      queue: live,
      frozenQueue: _radioFreeze?.queue,
      playing: state.currentTrackPath,
    );
    _radioFreeze = null;
    final bool sameQueue =
        live.length == effect.queue.length &&
        listEquals(live, effect.queue);
    state = state.copyWith(
      radioOn: false,
      clearRadioNextPath: true,
      radioUpcoming: const <String>[],
      queue: sameQueue ? null : effect.queue.map(File.new).toList(),
    );
    if (!_isCrossfading) {
      final String? head = _queueHeadPath();
      if (_standbyArmedPath == null ||
          head == null ||
          !sameAudioPath(_standbyArmedPath, head)) {
        _isStandbyArmed = false;
        _standbyArmedPath = null;
      }
      _driftNextPath = head;
    }
    unawaited(_saveSnapshot());
  }

  Future<void> toggleRadio() async {
    final bool on = !state.radioOn;
    if (!on) {
      _turnRadioOff();
      return;
    }
    _captureRadioFreeze();
    _radioEpoch++;
    _radioPending = null;
    state = state.copyWith(radioOn: true, clearRadioNextPath: true);
    _publishRadioUpcoming();
    unawaited(_saveSnapshot());
    unawaited(_radioEnsureIndex());
    if (state.currentTrackPath == null && !_isCrossfading) {
      _isPrepModeBypass = false;
      await forceNext();
    } else {
      unawaited(_radioRefill());
    }
  }

  void clearRadioGenres() {
    _radioEpoch++;
    _radioPending = null;
    if (state.radioOn && !_isCrossfading) {
      _isStandbyArmed = false;
      _standbyArmedPath = null;
      _driftNextPath = null;
    }
    state = state.copyWith(radioGenres: <String>{}, clearRadioNextPath: true);
    _publishRadioUpcoming();
    unawaited(_saveSnapshot());
    if (state.radioOn) unawaited(_radioRefill());
  }

  void toggleRadioGenre(String genre) {
    if (!kRadioGenreIds.contains(genre)) return;
    final Set<String> next = Set<String>.from(state.radioGenres);
    if (!next.remove(genre)) next.add(genre);
    _radioEpoch++;
    _radioPending = null;
    if (state.radioOn && !_isCrossfading) {
      _isStandbyArmed = false;
      _standbyArmedPath = null;
      _driftNextPath = null;
    }
    state = state.copyWith(radioGenres: next, clearRadioNextPath: true);
    _publishRadioUpcoming();
    unawaited(_saveSnapshot());
    if (state.radioOn) unawaited(_radioRefill());
  }

  int _nextQueueIndex() {
    return offAirNextIndex(
      paths: <String>[for (final File f in state.queue) f.path],
      currentPath: state.currentTrackPath,
      stealth: ref.read(mixFormulaProvider) == MixFormula.stealthGap,
      bpmOf: (String path) => _extractBpm(path),
    );
  }

  String? _queueHeadPath() {
    final int i = _nextQueueIndex();
    if (i < 0 || i >= state.queue.length) return null;
    return state.queue[i].path;
  }

  Future<void> _triggerCrossfade({
    bool forceJit = false,
    bool isManualSkip = false,
    int? queueIndex,
  }) async {
    if (_isCrossfading || (state.queue.isEmpty && !state.radioOn)) return;
    _isCrossfading = true;
    _mix.arm();
    final int armEpoch = _mix.epoch;

    // Radio encendida y sin pista elegida a mano: la sigue la radio (la cola
    // queda congelada). Un toque explícito a una fila (queueIndex) sí suena.
    final bool radioPick = state.radioOn && queueIndex == null;
    final String nextTrack;
    if (radioPick) {
      String? picked;
      try {
        picked = await _radioNextPath();
      } catch (e, st) {
        debugPrint('🔴 [RADIO] siguiente: $e\n$st');
      }
      picked ??= _radioQueueFallback();
      if (picked == null) {
        await _stopWhenNoNext();
        return;
      }
      nextTrack = picked;
    } else {
      int nextIdx = queueIndex ?? _nextQueueIndex();
      // Fin natural sin mezcla: suena la pista que ya estaba precargada (la que
      // la pantalla mostraba como "siguiente"), no una recalculada.
      if (queueIndex == null &&
          _nextFromCompletion &&
          _standbyArmedPath != null) {
        final int ai = state.queue.indexWhere(
          (f) => sameAudioPath(f.path, _standbyArmedPath),
        );
        if (ai >= 0) nextIdx = ai;
      }
      _nextFromCompletion = false;
      _djTrace(
        'NEXT elegido idx=$nextIdx de ${state.queue.length} jit=$forceJit',
      );
      if (nextIdx < 0 || nextIdx >= state.queue.length) {
        await _stopWhenNoNext();
        return;
      }
      nextTrack = state.queue[nextIdx].path;
    }
    final bool sameNow =
        state.currentTrackPath != null &&
        sameAudioPath(nextTrack, state.currentTrackPath);
    final bool samePrev =
        radioPick &&
        _radioPrevious != null &&
        sameAudioPath(nextTrack, _radioPrevious);
    if (sameNow || samePrev) {
      _djTrace('ABORT mezcla contra la misma pista $nextTrack');
      if (radioPick) {
        _radioPending = null;
        final String key = radioGenreKey(state.radioGenres);
        if (_radioMemory().planOf(key) != null) {
          _saveRadio(
            _radioMemory().rememberMix(key: key, played: nextTrack),
            activeKey: key,
          );
        }
      }
      _releaseMix();
      _isStandbyArmed = false;
      _standbyArmedPath = null;
      return;
    }
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;
    _incomingQuiet = incomingPlayer;

    if (!_isStandbyArmed || forceJit || _standbyArmedPath != nextTrack) {
      try {
        await incomingPlayer.setVolume(0.0);
        await incomingPlayer.open(Media(nextTrack), play: false);
        ref
            .read(liveDjEqualizerProvider.notifier)
            .adapt(incomingPlayer, nextTrack);
        try {
          await incomingPlayer.stream.duration
              .firstWhere((d) => d.inMilliseconds > 0)
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      } catch (e) {
        debugPrint("🔴 [LIVEDJ OPEN]: $e");
      }
    }

    // Verificación anti-fantasma (Android): si el deck entrante no tiene
    // cargada la pista pedida (carga lenta/fallida), se recarga una vez; si
    // sigue mal, se aborta el cruce en vez de reproducir lo que quedó en el deck.
    if (!_deckHolds(incomingPlayer, nextTrack)) {
      try {
        await incomingPlayer.setVolume(0.0);
        await incomingPlayer.open(Media(nextTrack), play: false);
        ref
            .read(liveDjEqualizerProvider.notifier)
            .adapt(incomingPlayer, nextTrack);
        try {
          await incomingPlayer.stream.duration
              .firstWhere((d) => d.inMilliseconds > 0)
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      } catch (e) {
        debugPrint("🔴 [LIVEDJ OPEN RETRY]: $e");
      }
      if (!_deckHolds(incomingPlayer, nextTrack)) {
        debugPrint(
          "🔴 [LIVEDJ] Deck entrante sin la pista pedida. Cruce abortado.",
        );
        _isStandbyArmed = false;
        _standbyArmedPath = null;
        _releaseMix();
        return;
      }
    }

    Duration trackDur = Duration.zero;
    try {
      trackDur = incomingPlayer.state.duration;
    } catch (_) {}
    trackDur = await _trueDuration(nextTrack, trackDur);

    final int cueInMs = await _calculateSmartCueIn(nextTrack, incomingPlayer);
    final int triggerMs = _calculateRadioMixOut(
      trackDur.inMilliseconds,
      nextTrack,
    );
    final LiveDjMixMode nextMode = _isMixTrack(trackDur.inMilliseconds)
        ? LiveDjMixMode.longBypass
        : LiveDjMixMode.activeSync;

    double fadingBpm = _extractBpm(state.currentTrackPath);
    double incomingBpm = _extractBpm(nextTrack);
    double incomingRate = 1.0;

    // Rejilla de golpes de ambas pistas (Rust): BPM medido si no hay etiqueta y
    // fase del golpe, para que el entrante arranque EN el golpe del saliente.
    rust_dsp.BeatGrid? gridOut;
    rust_dsp.BeatGrid? gridIn;
    if (!isManualSkip && nextMode != LiveDjMixMode.longBypass) {
      try {
        final String? outPath = state.currentTrackPath;
        if (outPath != null) {
          final int outPos = fadingPlayer.state.position.inMilliseconds;
          final rust_dsp.BeatGrid? tagOut = beatFromTag(outPath, outPos + 1000);
          final rust_dsp.BeatGrid? tagIn = beatFromTag(nextTrack, cueInMs);
          final List<rust_dsp.BeatGrid> res = tagOut != null && tagIn != null
              ? <rust_dsp.BeatGrid>[tagOut, tagIn]
              : await Future.wait([
                  rust_dsp.beatGrid(
                    inputPath: outPath,
                    fromMs: BigInt.from(outPos + 1000),
                    spanSecs: 12,
                  ),
                  rust_dsp.beatGrid(
                    inputPath: nextTrack,
                    fromMs: BigInt.from(cueInMs),
                    spanSecs: 12,
                  ),
                ]).timeout(const Duration(seconds: 5));
          if (res[0].ok && res[1].ok) {
            gridOut = res[0];
            gridIn = res[1];
            if (fadingBpm <= 60) fadingBpm = gridOut.bpm;
            if (incomingBpm <= 60) incomingBpm = gridIn.bpm;
          }
        }
      } catch (_) {}
    }

    _incomingNatBpm = incomingBpm;
    // En el cruce las dos suenan en el punto medio. Vale también para eco y filtro.
    final double outRate = fadingPlayer.state.rate;
    final MidpointEntry entry = midpointEntry(fadingBpm, incomingBpm);
    if (entry.blocked) {
      _djTrace('MIDPOINT FUERA ${entry.note}');
    } else {
      incomingRate = entry.incomingRate;
    }
    _mix.setRampBpm(
      _incomingNatBpm > 0 && incomingRate > 0
          ? _incomingNatBpm * incomingRate
          : 0,
    );

    DnaDecision? dnaPlan;
    if (!isManualSkip &&
        nextMode != LiveDjMixMode.longBypass &&
        ref.read(mixFormulaProvider) == MixFormula.dnaEnergy) {
      final int lockedOut = state.customMixOutMs;
      dnaPlan = _dnaPair(
        outDurationMs: state.duration.inMilliseconds,
        outPath: state.currentTrackPath,
        genreMixOutMs: lockedOut > 10000 ? lockedOut : 0,
        exitLocked: lockedOut > 10000,
        inDurationMs: trackDur.inMilliseconds,
        inPath: nextTrack,
        fallbackCueMs: _phraseFallbackCue(nextTrack, trackDur.inMilliseconds),
        outRate: outRate,
      );
    }

    try {
      // Punto de arranque del entrante: su golpe más cercano a partir del cue.
      // Phrase 8, si ya hay perfil, entra en el downbeat de la frase.
      int startMs = cueInMs;
      final PhraseTrack? phraseIn = PhraseGridMemory.peek(nextTrack);
      final MixFormula downbeatFormula = ref.read(mixFormulaProvider);
      final bool onPhraseDownbeat =
          (downbeatFormula == MixFormula.phraseGrid ||
              downbeatFormula == MixFormula.dnaEnergy) &&
          phraseIn != null &&
          phraseIn.hitsDownbeat(cueInMs);
      if (gridIn != null && !onPhraseDownbeat) {
        final double pIn = 60000.0 / gridIn.bpm;
        final double ki = ((cueInMs - gridIn.beatMs) / pIn).ceilToDouble();
        startMs = (gridIn.beatMs + ki * pIn).round();
      }
      if (startMs > 0) {
        await incomingPlayer.seek(Duration(milliseconds: startMs));
        await Future.delayed(const Duration(milliseconds: 150));
      }
      // Filtros y corrección de tono ANTES de sonar: cambiarlos con el deck ya
      // andando reinicia la cadena de audio y el tempo tarda 2-3 s en asentarse.
      _prepareIncomingDeck(
        incomingPlayer,
        nextMode,
        afOverride: dnaPlan == null || dnaPlan.legacy
            ? null
            : _dnaIncomingAf(dnaPlan, incomingPlayer),
      );
      await incomingPlayer.setRate(incomingRate);
      await incomingPlayer.setVolume(0.0);
      if (_mix.paused) {
        try {
          await incomingPlayer.pause();
        } catch (_) {}
      }
      if (!await holdIncomingBeforePlay(armEpoch)) {
        _incomingQuiet = null;
        _releaseMix();
        return;
      }
      _incomingQuiet = null;
      if (gridOut != null &&
          gridIn != null &&
          gridOut.bpm > 0 &&
          gridIn.bpm > 0 &&
          incomingRate > 0) {
        final double liveOut = fadingPlayer.state.rate;
        _phaseLock = await engageBeatLock(
          outgoing: fadingPlayer,
          incoming: incomingPlayer,
          outBeatMs: gridOut.beatMs,
          outBpm: gridOut.bpm,
          outRate: liveOut > 0 ? liveOut : outRate,
          inBeatMs: gridIn.beatMs,
          inBpm: gridIn.bpm,
          cueMs: startMs.toDouble(),
          inRate: incomingRate,
          rampRate: incomingRate,
          incomingOnBeat: true,
          hold: _mix,
        );
      } else {
        await incomingPlayer.play();
      }
      if (!_mix.armed) {
        await _dropPhase();
        return;
      }
    } catch (e) {
      await _dropPhase();
      _releaseMix();
      return;
    }

    _usePlayerA = !_usePlayerA;
    _isStandbyArmed = false;
    _attachListeners(_activePlayer);

    // Se quita por ruta (no por índice): la cola pudo cambiar durante la
    // carga (quitar, añadir, shuffle) y un índice viejo borraría otra pista.
    List<File> newQueue = List.from(state.queue);
    if (!radioPick) {
      final int removeAt = newQueue.indexWhere((f) => f.path == nextTrack);
      if (removeAt >= 0) newQueue.removeAt(removeAt);
    }
    // Empieza la última canción de la cola: la Radio se enciende sola.
    final bool autoRadio = !radioPick && !state.radioOn && newQueue.isEmpty;
    if (autoRadio) {
      unawaited(_radioEnsureIndex());
      _radioFreeze ??= LiveQueueFreeze(
        queue: newQueue.map((File f) => f.path).toList(),
        current: nextTrack,
        positionMs: cueInMs,
        wasPlaying: true,
      );
    }
    if (radioPick) _radioConsumed(nextTrack);

    final String? fadingPath = state.currentTrackPath;
    final int fadingMixOut = state.customMixOutMs;
    final int fadingDurMs = state.duration.inMilliseconds;
    int? phraseFadeOverride;
    if (!isManualSkip &&
        nextMode != LiveDjMixMode.longBypass &&
        ref.read(mixFormulaProvider) == MixFormula.phraseGrid) {
      phraseFadeOverride = phraseGridFadeMs(
        bpm: phraseSoundingBpm(
          incomingBpm: incomingBpm,
          incomingRate: incomingRate,
        ),
        instrumental: phraseCrossIsInstrumental(
          outgoing: PhraseGridMemory.peek(fadingPath),
          incoming: PhraseGridMemory.peek(nextTrack),
          outMs: fadingMixOut,
          inMs: cueInMs,
        ),
        durationMs: trackDur.inMilliseconds,
      );
    }
    _publishedFadeMs = phraseFadeOverride ??
        (dnaPlan != null && !dnaPlan.legacy ? dnaPlan.fadeMs : 0);

    state = state.copyWith(
      radioOn: autoRadio ? true : null,
      queue: newQueue,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
      duration: trackDur,
      customCueInMs: cueInMs,
      customMixOutMs: triggerMs,
      currentMixMode: nextMode,
    );

    _saveSnapshot();
    _schedulePhraseNeighbors();
    // Con la Radio encendida el siguiente se elige apenas empieza esta pista.
    if (state.radioOn) unawaited(_radioNextPath());

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixProfile: nextMode,
      incomingRate: incomingRate,
      isManualSkip: isManualSkip,
      manualMixDurationMs: isManualSkip
          ? _planManualMixDurationMs(nextTrack, trackDur.inMilliseconds)
          : null,
      phraseFadeOverride: phraseFadeOverride,
      dnaKind: dnaPlan == null || dnaPlan.legacy ? null : dnaPlan.kind,
      dnaFadeMs: dnaPlan == null || dnaPlan.legacy ? null : dnaPlan.fadeMs,
      dnaBassSwap: dnaPlan == null || dnaPlan.legacy ? null : dnaPlan.bassSwap,
      dnaEchoDelayMs: dnaPlan?.echoDelayMs ?? 0,
      dnaEchoFeedback: dnaPlan?.echoFeedback ?? 0,
      outgoingDurationMs: fadingDurMs,
      outgoingMixOutMs: fadingMixOut,
    );
  }

  /// Deja el deck entrante listo ANTES de `play()`: corrección de tono y cadena
  /// `af` (con corte de graves en modo activeSync). Mismos valores que antes
  /// ponía el motor de mezcla ya con el deck sonando.
  void _prepareIncomingDeck(
    Player incoming,
    LiveDjMixMode mode, {
    String? afOverride,
  }) {
    try {
      final eqN = ref.read(liveDjEqualizerProvider.notifier);
      final String base = eqN.filterFor(incoming);
      final String lowCut = AfCaps.sanitize(
        [base, _bassKillFilter].where((s) => s.isNotEmpty).join(','),
      );
      final dynamic platform = incoming.platform;
      platform?.setProperty('audio-pitch-correction', 'yes');
      platform?.setProperty(
        'af',
        afOverride ?? (mode == LiveDjMixMode.activeSync ? lowCut : base),
      );
    } catch (_) {}
  }

  String _dnaIncomingAf(DnaDecision plan, Player incoming) {
    final String base = ref
        .read(liveDjEqualizerProvider.notifier)
        .filterFor(incoming);
    if (plan.kind == DnaKind.longBlend) {
      return AfCaps.sanitize(
        [base, _bassKillFilter, dnaHighShelfCut]
            .where((String s) => s.isNotEmpty)
            .join(','),
      );
    }
    return AfCaps.sanitize(base);
  }

  Future<void> _executeMixEngine({
    required Player fadingPlayer,
    required Player incomingPlayer,
    required LiveDjMixMode mixProfile,
    double incomingRate = 1.0,
    bool isManualSkip = false,
    int? manualMixDurationMs,
    int? phraseFadeOverride,
    DnaKind? dnaKind,
    int? dnaFadeMs,
    bool? dnaBassSwap,
    int dnaEchoDelayMs = 0,
    double dnaEchoFeedback = 0,
    int outgoingDurationMs = 0,
    int outgoingMixOutMs = 0,
  }) async {
    final eqN = ref.read(liveDjEqualizerProvider.notifier);
    String inBase() => eqN.filterFor(incomingPlayer);
    String outBase() => eqN.filterFor(fadingPlayer);
    final platformOut = fadingPlayer.platform as dynamic;
    final platformIn = incomingPlayer.platform as dynamic;

    final bool useBassSwap =
        mixProfile == LiveDjMixMode.activeSync && (dnaBassSwap ?? true);
    final String? dnaOutExtra = dnaKind == DnaKind.longBlend
        ? dnaHighShelfCut
        : (dnaKind == DnaKind.filterSweep
              ? dnaHighpassMild
              : (dnaKind == DnaKind.echoOut && AfCaps.has('aecho')
                    ? dnaEchoChain(dnaEchoDelayMs, dnaEchoFeedback)
                    : null));
    final String? dnaOutMid = dnaKind == DnaKind.filterSweep
        ? dnaHighpassHard
        : null;
    final String lowCutIn = AfCaps.sanitize(
      [inBase(), _bassKillFilter].where((s) => s.isNotEmpty).join(','),
    );
    final String lowCutOut = AfCaps.sanitize(
      [outBase(), _bassKillFilter].where((s) => s.isNotEmpty).join(','),
    );
    bool bassSwapped = false;

    try {
      // El deck entrante ya quedó preparado antes de sonar (_prepareIncomingDeck).
      platformOut?.setProperty('audio-pitch-correction', 'yes');
      platformOut?.setProperty(
        'af',
        dnaOutExtra == null
            ? outBase()
            : AfCaps.sanitize(
                [outBase(), dnaOutExtra].where((String s) => s.isNotEmpty).join(','),
              ),
      );

      await incomingPlayer.setVolume(0.0);

      final bool phraseNow =
          ref.read(mixFormulaProvider) == MixFormula.phraseGrid;
      final bool stealthNow =
          ref.read(mixFormulaProvider) == MixFormula.stealthGap;
      final fadeOutDurationMs = isManualSkip
          ? (manualMixDurationMs ?? 12000)
          : (mixProfile == LiveDjMixMode.longBypass
                ? 4000
                : (dnaFadeMs ??
                      (phraseNow && phraseFadeOverride != null
                          ? phraseFadeOverride
                          : (phraseNow || stealthNow
                                ? phraseFadeMs(
                                    incomingBpm: _extractBpm(
                                      state.currentTrackPath,
                                    ),
                                    incomingDurationMs:
                                        state.duration.inMilliseconds,
                                  )
                                : 18000))));
      final FittedFade fitted = fitMixFade(
        exactDurationMs: outgoingDurationMs,
        mixOutMs: outgoingMixOutMs,
        wantedFadeMs: fadeOutDurationMs,
      );
      if (fitted.shortened) _djTrace(fitted.note);
      final int fadeMs = fitted.fadeMs;
      final int mixEpoch = _mix.epoch;
      final MixRunClock fadeClock = _mix.beginFade(fadeMs);

      while (fadeClock.elapsedMilliseconds < fadeMs && _mix.epoch == mixEpoch) {
        if (_mix.paused) {
          await _mix.untilRunning();
          continue;
        }
        final progress = (fadeClock.elapsedMilliseconds / fadeMs).clamp(
          0.0,
          1.0,
        );

        // 🎛️ SUPER MEZCLA DAWN (Alta Energía / Cero Huecos Acústicos)
        final smoothRateIn = dawnCrossfadeGain(progress);
        final smoothRateOut = dawnCrossfadeGain(1.0 - progress);

        if (useBassSwap && !bassSwapped && progress >= 0.5) {
          bassSwapped = true;
          platformOut?.setProperty(
            'af',
            dnaOutExtra == null
                ? lowCutOut
                : AfCaps.sanitize(
                    [lowCutOut, dnaOutExtra]
                        .where((String s) => s.isNotEmpty)
                        .join(','),
                  ),
          );
          platformIn?.setProperty('af', inBase());
        } else if (dnaOutMid != null && !bassSwapped && progress >= 0.5) {
          bassSwapped = true;
          platformOut?.setProperty(
            'af',
            AfCaps.sanitize(
              [outBase(), dnaOutMid].where((String s) => s.isNotEmpty).join(','),
            ),
          );
        }

        await incomingPlayer.setVolume(
          (smoothRateIn * 100.0).clamp(0.0, 100.0),
        );
        await fadingPlayer.setVolume((smoothRateOut * 100.0).clamp(0.0, 100.0));

        await _mix.slice(32, fadeClock);
      }
    } catch (e) {
      debugPrint("🔴 [ERROR DSP]: $e");
    } finally {
      await _dropPhase();
      // B arrancó en el punto medio. Los pasos de vuelta los aplica TempoDrift.
      _drift.begin(_incomingNatBpm, incomingRate);
      final String? blocked = _drift.takeBlockedReport();
      if (blocked != null) _djTrace('MIDPOINT FUERA $blocked');

      try {
        await incomingPlayer.setVolume(100.0);
        platformIn?.setProperty('af', inBase());
        platformOut?.setProperty('af', outBase());
        await fadingPlayer.setVolume(0.0);
        await fadingPlayer.setRate(1.0);
        await fadingPlayer.stop();
      } catch (_) {}
      // El deck saliente quedó vacío: ningún armado previo sigue siendo válido.
      _standbyArmedPath = null;
      _driftNextPath = null;

      _releaseMix();
      if (_radioOffAfterFade) {
        _radioOffAfterFade = false;
        if (state.radioOn || _radioFreeze != null) _turnRadioOff();
      }
      // Terminada la mezcla: se reponen las próximas en segundo plano.
      if (state.radioOn) unawaited(_radioRefill());
    }
  }

  Future<void> parkIdleDecks({bool force = false}) async {
    if (_parking) return;
    if (!force && (state.isPlaying || _isCrossfading)) return;
    _parking = true;
    try {
      if (force) _releaseMix();
      _sessionWasPlaying = state.isPlaying;
      if (state.position.inMilliseconds > 0) {
        _sessionPositionMs = state.position.inMilliseconds;
      }
      _freezePersist = true;
      if (state.currentTrackPath != null || state.queue.isNotEmpty) {
        await _saveSnapshot();
      }
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
      if (state.isPlaying) state = state.copyWith(isPlaying: false);
    } finally {
      _parking = false;
    }
  }
}

final liveDjProvider = NotifierProvider<LiveDjNotifier, LiveDjState>(
  LiveDjNotifier.new,
);
