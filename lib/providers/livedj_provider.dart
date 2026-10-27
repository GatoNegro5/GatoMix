import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';

import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;
import '../core/hal/platform_strategy.dart';
import '../core/livedj_order.dart';
import '../core/session_store.dart';
import '../core/audio/af_caps.dart';
import '../core/audio/tempo_drift.dart';
import '../services/track_tags.dart';
import '../core/audio/dj_audio_handler.dart';
import 'equalizer_provider.dart';
import 'mix_formula.dart';
import 'directory_provider.dart';
import '../djiphone/iphone_library.dart';

enum LiveDjMixStrategy { sequential, random }

/// Bitácora de decisiones del mezclador (solo diagnóstico, no toca el audio).
/// Archivo: <temp>/gatomix_livedj_trace.txt (se recorta solo al pasar 300 KB).
void _djTrace(String msg) {
  try {
    final f = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}gatomix_livedj_trace.txt',
    );
    if (f.existsSync() && f.lengthSync() > 300000) f.writeAsStringSync('');
    f.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $msg\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

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
  double _incomingNatBpm = 0.0;

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

  double _extractBpm(String? path) {
    if (path == null) return 0.0;
    final fileName = path.replaceAll('\\', '/').split('/').last;
    final match = RegExp(
      r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
      caseSensitive: false,
    ).firstMatch(fileName);
    if (match != null) return double.parse(match.group(1)!);
    // Sin BPM en el nombre: el que midió/guardó el masterizado (etiqueta TBPM).
    return TrackTags.peek(path)?.bpm ?? 0.0;
  }

  Future<int> _calculateSmartCueIn(String path, Player player) async {
    if (_isMixTrack(player.state.duration.inMilliseconds)) return 0;
    final int durMs = player.state.duration.inMilliseconds;
    if (ref.read(mixFormulaProvider) == MixFormula.stealthGap) {
      return stealthCueInMs(durMs, const []);
    }
    // El silencio inicial medido por el masterizado nunca queda dentro del cue.
    final int leadMs = TrackTags.peek(path)?.leadMs ?? 0;
    if (durMs > 30000) return leadMs > 10000 ? leadMs : 10000;
    return leadMs < durMs ~/ 3 ? leadMs : 0;
  }

  // 🎛️ INYECCIÓN ADN DJ: Ahora el Cartridge aplica la regla 65%-80%
  // Se consulta en CADA tick de posición: se memoriza por pista/fórmula para
  // no repetir regex + búsquedas de texto decenas de veces por segundo (CPU).
  String? _mixOutCacheKey;
  int _mixOutCacheVal = 0;

  int _calculateRadioMixOut(int durationMs, String? path) {
    final String key =
        '$durationMs|$path|${ref.read(mixFormulaProvider)}|'
        '${TrackTags.peek(path)?.tailMs ?? 0}|${TrackTags.peek(path)?.bpm ?? 0}';
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

    if (safeMixOutMs >= effDurMs - 4000) {
      safeMixOutMs = effDurMs - 4000;
    }

    if (ref.read(mixFormulaProvider) == MixFormula.stealthGap) {
      return stealthMixOutMs(
        durationMs: effDurMs,
        lyricMs: const [],
        bpm: _extractBpm(path),
      );
    }
    if (ref.read(mixFormulaProvider) == MixFormula.phraseGrid) {
      return snapPhraseGridMixOut(
        durationMs: effDurMs,
        dnaMixOutMs: safeMixOutMs,
        bpm: _extractBpm(path),
      );
    }
    return safeMixOutMs;
  }

  Future<void> persistSession() => _saveSnapshot();

  bool _pausedByInterruption = false;

  /// Llamada/alarma/otra app: pausa ambos decks (también a mitad de un cruce)
  /// sin tocar cola, posición ni sesión. Devuelve `true` si estaba sonando.
  Future<bool> pauseForInterruption() async {
    if (!state.isPlaying) return false;
    _pausedByInterruption = true;
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
      await _activePlayer.play();
    } catch (_) {}
    if (_isCrossfading) {
      try {
        await _standbyPlayer.play();
      } catch (_) {}
    }
  }

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

  String _sessionFilePath() {
    final shared = _liveStrategy.getSessionPath();
    return '${File(shared).parent.path}${Platform.pathSeparator}_livedj_session.json';
  }

  File _resolveSessionFile() {
    return File(_sessionFilePath());
  }

  Future<void> _saveSnapshot() async {
    try {
      final path = _sessionFilePath();
      final pos = _freezePersist
          ? _sessionPositionMs
          : state.position.inMilliseconds;
      final data = {
        'schema': 2,
        'queue': state.queue.map((f) => f.path).toList(),
        'currentTrackPath': state.currentTrackPath,
        'positionMs': pos,
        'mixMode': state.currentMixMode.index,
        'mixStrategy': state.mixStrategy.index,
        'mixFormula': ref.read(mixFormulaProvider).index,
        'wasPlaying': _freezePersist ? _sessionWasPlaying : state.isPlaying,
        'radioOn': state.radioOn,
        'radioGenres': state.radioGenres.toList(),
        'sortMode': state.sortMode.name,
      };
      // Atómico y en fila: un cierre o una actualización a mitad de guardado
      // ya no deja la sesión dañada (antes: cola vacía y modo Secuencial).
      await SessionStore.writeJson(path, data);
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
    try {
      _applyLiveShuffleBank(advance: true);
    } catch (e, stack) {
      debugPrint("🔴 [TRACKER ERROR FATAL] El Shuffle explotó: $e\n$stack");
    }
  }

  String _liveShuffleBanksPath() {
    final session = File(_sessionFilePath());
    return '${session.parent.path}${Platform.pathSeparator}_livedj_shuffle_banks.json';
  }

  Map<String, dynamic> _readLiveShuffleBankFile() {
    try {
      final data = SessionStore.readJson(_liveShuffleBanksPath());
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (_) {}
    return <String, dynamic>{};
  }

  void _writeLiveShuffleBankFile(Map<String, dynamic> data) {
    try {
      SessionStore.writeJsonSync(_liveShuffleBanksPath(), data);
    } catch (_) {}
  }

  // Grupos de 20 vecinos en BPM: el 1º sube, el 2º baja, el 3º sube…
  // Sin BPM van al final, una vez. Ver lib/core/livedj_order.dart.
  List<String> _bpmGroupOrder(List<String> paths, int salt) {
    return buildShuffleGroups(
      paths,
      _extractBpm,
      salt,
    ).expand((g) => g).toList();
  }

  // Firmas de grupos ya usados (persisten en _livedj_shuffle_banks.json):
  // cada Shuffle arma grupos con composición nueva.
  static const int _shuffleHistoryCap = 3000;

  void _applyLiveShuffleBank({required bool advance}) {
    if (state.queue.length <= 1) {
      debugPrint("⚠️ [TRACKER] Cola muy pequeña. Forzando solo UI.");
      state = state.copyWith(mixStrategy: LiveDjMixStrategy.random);
      _saveSnapshot();
      return;
    }

    final paths = state.queue.map((f) => f.path).toList();
    final all = _readLiveShuffleBankFile();
    final List<String> hist = ((all['history'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final picked = pickFreshShuffle(paths, _extractBpm, hist.toSet(), Random());
    final queued = <File>[
      for (final g in picked.groups)
        for (final p in g) File(p),
    ];
    for (final g in picked.groups) {
      if (g.length > 1) hist.add(groupSignature(g));
    }
    final int over = hist.length - _shuffleHistoryCap;
    all['history'] = over > 0 ? hist.sublist(over) : hist;
    all['algo'] = 4;
    all['lastSeed'] = picked.seed;
    all.remove(
      'lists',
    ); // bancos fijos de la versión anterior (se repetían cada 10)
    _writeLiveShuffleBankFile(all);

    state = state.copyWith(
      queue: queued,
      mixStrategy: LiveDjMixStrategy.random,
    );
    _saveSnapshot();
    debugPrint(
      "🔀 [TRACKER] Shuffle: ${picked.groups.length} grupos, ${queued.length} pistas.",
    );
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
      // Pistas renombradas por Masterizar se reencuentran en su carpeta.
      final queueFiles = resolvePlayableSessionPaths(
        queuePaths,
      ).map((p) => File(p)).toList();
      String? currentTrackPath = data['currentTrackPath'] as String?;
      if (currentTrackPath != null) {
        final hit = resolvePlayableSessionPaths([currentTrackPath]);
        currentTrackPath = hit.isEmpty ? null : hit.first;
      }
      if (currentTrackPath != null) {
        queueFiles.removeWhere((f) => f.path == currentTrackPath);
      }
      final LiveDjSortMode savedSort = LiveDjSortMode.values.firstWhere(
        (m) => m.name == data['sortMode'],
        orElse: () => LiveDjSortMode.manual,
      );
      bool currentFromQueue = false;
      if (currentTrackPath == null && queueFiles.isNotEmpty) {
        // La pista que pasa a "actual" sale de la cola (cartridge destructiva);
        // si no, volvería a sonar al terminar.
        currentTrackPath = queueFiles.removeAt(0).path;
        currentFromQueue = true;
      }
      // La posición guardada era de otra pista: no se aplica a la nueva.
      final int? positionMs = currentFromQueue
          ? null
          : data['positionMs'] as int?;

      final mixModeIdx = (data['mixMode'] as int? ?? 0).clamp(
        0,
        LiveDjMixMode.values.length - 1,
      );
      final mixStrategyIdx = (data['mixStrategy'] as int? ?? 0).clamp(
        0,
        LiveDjMixStrategy.values.length - 1,
      );
      final mixFormulaIdx = data['mixFormula'] as int? ?? 0;
      if (mixFormulaIdx >= 0 && mixFormulaIdx < MixFormula.values.length) {
        ref.read(mixFormulaProvider.notifier).state =
            MixFormula.values[mixFormulaIdx];
      }

      // Radio: estado y géneros persisten; el historial vive en su propio archivo.
      final bool savedRadioOn = data['radioOn'] as bool? ?? false;
      final Set<String> savedGenres = ((data['radioGenres'] as List?) ?? [])
          .map((e) => e.toString())
          .where(kRadioGenreIds.contains)
          .toSet();
      _loadRadioHistory();

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
      if (savedRadioOn) unawaited(_radioEnsureIndex());

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
    }
  }

  void addTrack(File file) {
    if (!state.queue.any((f) => f.path == file.path)) {
      // Cola estable: la pista nueva va al final; lo ya cargado no se mueve
      // ni cambia de modo (secuencial/shuffle solo lo cambia el botón).
      state = state.copyWith(queue: [...state.queue, file]);
      if (state.mixStrategy == LiveDjMixStrategy.sequential) _applySort();
      _saveSnapshot();
    }
  }

  void addAllTracks(List<File> files) {
    final currentPaths = state.queue.map((f) => f.path).toSet();
    final newFiles = files
        .where((f) => !currentPaths.contains(f.path))
        .toList();
    if (newFiles.isNotEmpty) {
      // Cola estable: solo se mezcla el lote nuevo (y solo en modo shuffle);
      // lo ya cargado conserva su orden.
      if (state.mixStrategy == LiveDjMixStrategy.random) {
        final ordered = _bpmGroupOrder(
          newFiles.map((f) => f.path).toList(),
          Random().nextInt(1 << 30),
        );
        final byPath = {for (final f in newFiles) f.path: f};
        newFiles
          ..clear()
          ..addAll(ordered.map((p) => byPath[p]!));
      }
      final bool wasEmpty = state.queue.isEmpty;
      state = state.copyWith(queue: [...state.queue, ...newFiles]);
      if (state.mixStrategy == LiveDjMixStrategy.sequential) _applySort();
      _saveSnapshot();
      // Cola vacía (p. ej. fin de cola) + shuffle activo: la carga nueva usa
      // el mismo banco de shuffle del botón, así no arranca secuencial.
      if (wasEmpty &&
          state.mixStrategy == LiveDjMixStrategy.random &&
          state.queue.length > 1) {
        _applyLiveShuffleBank(advance: true);
      }
    }
  }

  void removeTrack(String path) {
    final newQueue = state.queue.where((f) => f.path != path).toList();
    state = state.copyWith(queue: newQueue);
    _saveSnapshot();
  }

  void clearQueue() {
    state = state.copyWith(queue: []);
    _saveSnapshot();
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
        final List<File> newFiles = paths
            .map((p) => File(p.toString()))
            .where((f) => f.existsSync())
            .toList();

        if (newFiles.isNotEmpty) {
          final currentPaths = state.queue.map((f) => f.path).toSet();
          final fresh = newFiles
              .where((f) => !currentPaths.contains(f.path))
              .toList();
          if (state.mixStrategy == LiveDjMixStrategy.random) {
            final ordered = _bpmGroupOrder(
              fresh.map((f) => f.path).toList(),
              Random().nextInt(1 << 30),
            );
            final byPath = {for (final f in fresh) f.path: f};
            fresh
              ..clear()
              ..addAll(ordered.map((p) => byPath[p]!));
          }
          if (fresh.isNotEmpty) {
            final bool wasEmpty = state.queue.isEmpty;
            state = state.copyWith(queue: [...state.queue, ...fresh]);
            if (state.mixStrategy == LiveDjMixStrategy.sequential) {
              _applySort();
            }
            _saveSnapshot();
            if (wasEmpty &&
                state.mixStrategy == LiveDjMixStrategy.random &&
                state.queue.length > 1) {
              _applyLiveShuffleBank(advance: true);
            }
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

  /// Duración real del archivo (Rust/symphonia). Si difiere de la estimada por
  /// libmpv en más de 1.5 s, manda la real. Sin dato: la de libmpv.
  Future<Duration> _trueDuration(String path, Duration mpv) async {
    // Etiquetas del masterizado (silencios, BPM) listas antes de calcular la mezcla.
    await TrackTags.load(path);
    try {
      int? ms = _exactDurCache[path];
      if (ms == null) {
        ms = (await rust_dsp.exactDurationMs(inputPath: path)).toInt();
        _exactDurCache[path] = ms;
      }
      if (ms > 0 && (ms - mpv.inMilliseconds).abs() > 1500) {
        debugPrint(
          '⏱️ [LIVEDJ] Duración corregida ${mpv.inSeconds}s → ${ms ~/ 1000}s: $path',
        );
        return Duration(milliseconds: ms);
      }
    } catch (_) {}
    return mpv;
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

      if ((posMs - _lastUiPosMs).abs() >= 250) {
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

      if ((posMs - _lastSavedPositionMs).abs() > 15000) {
        _lastSavedPositionMs = posMs;
        _saveSnapshot();
      }

      if (durMs > 0 &&
          state.currentTrackPath != null &&
          (state.queue.isNotEmpty || state.radioOn)) {
        final int barMixOut = state.customMixOutMs > 10000
            ? state.customMixOutMs
            : _calculateRadioMixOut(durMs, state.currentTrackPath);

        if (!_isCrossfading) {
          final double curRate = player.state.rate;
          final double? tgt = _drift.tick(
            posMs: posMs,
            durMs: durMs,
            mixOutMs: barMixOut,
            rate: curRate,
            nextBpm: _extractBpm(_standbyArmedPath),
          );
          if (tgt != null) unawaited(_drift.ramp(player, curRate, tgt));
        }

        // No se arma durante un cruce: el deck "standby" es el que aún suena
        // (saliendo); recargarlo mete pistas fantasma y deja el armado huérfano.
        if (!_isStandbyArmed &&
            !_isCrossfading &&
            posMs >= (barMixOut - 10000) &&
            barMixOut > 10000) {
          _isStandbyArmed = true;
          _standbyArmedPath = null;
          // Radio encendida: la pista sale del universo de géneros, no de la cola.
          final String? armPathOrNull = state.radioOn
              ? await _radioNextPath()
              : (state.queue.isNotEmpty
                    ? state.queue[_nextQueueIndex()].path
                    : null);
          if (armPathOrNull == null) return;
          final String armPath = armPathOrNull;
          if (!state.radioOn && armPath == tickPath) {
            _isStandbyArmed = false;
            return;
          }
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
          ref
              .read(liveDjEqualizerProvider.notifier)
              .adapt(_standbyPlayer, armPath);
        }

        if (state.currentTrackPath != tickPath || player != _activePlayer) {
          return;
        }
        // Red de seguridad: si el deck va a acabar antes que la duración de la
        // barra (cabecera larga), se mezcla ~25 s antes de ese final real.
        // Una estimación corta de arranque (menor que la mitad) no cuenta.
        int endMs = durMs;
        final int deckDur = player.state.duration.inMilliseconds;
        if (deckDur > 45000 && deckDur + 1500 < durMs && deckDur > durMs ~/ 2) {
          endMs = deckDur;
        }
        final bool nearEnd =
            endMs > 60000 && posMs >= endMs - 25000 && posMs > 20000;
        if ((posMs >= barMixOut && barMixOut > 10000) || nearEnd) {
          if (!_isCrossfading && !_isPrepModeBypass) {
            _djTrace(
              'TRIGGER pos=$posMs dur=$durMs end=$endMs bar=$barMixOut nearEnd=$nearEnd '
              'cur=${state.currentTrackPath} armed=$_standbyArmedPath q0=${state.queue.isNotEmpty ? state.queue.first.path : null}',
            );
            _triggerCrossfade();
          }
        }
      }
    });

    _durationSub = player.stream.duration.listen((mpvDur) async {
      // No publicar la estimación corta de libmpv antes de la duración real:
      // si no, el punto de mezcla cae a los pocos segundos y el cruce arranca.
      final String? durPath = state.currentTrackPath;
      Duration dur = mpvDur;
      if (durPath != null && mpvDur.inMilliseconds > 0) {
        dur = await _trueDuration(durPath, mpvDur);
        if (state.currentTrackPath != durPath) return;
      }
      if (dur.inMilliseconds <= 0 || state.currentTrackPath == null) return;
      // Una estimación posterior más corta no achica la duración ya corregida.
      if (state.currentTrackPath == durPath &&
          state.duration.inMilliseconds > dur.inMilliseconds + 1500) {
        dur = state.duration;
      }
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
        'COMPLETED SIN MEZCLA pos=${state.position.inMilliseconds} '
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

    await _activePlayer.playOrPause();
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
  // La radio NO toca la cola (congelada). Solo decide qué pista sigue:
  // universo = carpetas de género dentro de Música (sin _K), salto de carpeta
  // cada 2 temas, BPM cercano, sin artista seguido y sin repetir (historial).
  Map<String, List<String>>? _radioIndex; // carpeta → pistas
  final Map<String, String> _radioFolderGenre = <String, String>{};
  Future<void>? _radioIndexing;
  final Set<String> _radioHistory = <String>{};
  String? _radioPending;
  String? _radioPendingFolder;
  String? _radioLastFolder;
  String _radioLastArtist = '';
  int _radioStreak = 0;
  final Random _radioRng = Random();

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

  String _radioMusicRoot() {
    String base;
    if (Platform.isIOS) {
      base = IphoneLibrary.musicRoot;
    } else if (Platform.isAndroid) {
      base = '/storage/emulated/0/Music';
    } else if (Platform.isWindows) {
      final up = Platform.environment['USERPROFILE'];
      base = up != null ? '$up\\Music' : 'C:\\Music';
    } else {
      final home = Platform.environment['HOME'];
      base = home != null ? '$home/Music' : '/';
    }
    // Las carpetas de género viven en Música/ReGenial; si no existe, en Música.
    final regenial = Directory('$base${Platform.pathSeparator}ReGenial');
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

  String _radioArtist(String path) {
    var name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    final i = name.indexOf(' - ');
    if (i <= 0) return '';
    return _radioFold(name.substring(0, i)).trim();
  }

  String _radioHistoryPath() =>
      '${File(_sessionFilePath()).parent.path}${Platform.pathSeparator}_livedj_radio.json';

  void _loadRadioHistory() {
    try {
      final f = File(_radioHistoryPath());
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync());
      final list = (data['history'] as List?) ?? const [];
      _radioHistory
        ..clear()
        ..addAll(list.map((e) => e.toString()));
    } catch (_) {}
  }

  void _saveRadioHistory() {
    try {
      File(
        _radioHistoryPath(),
      ).writeAsStringSync(jsonEncode({'history': _radioHistory.toList()}));
    } catch (_) {}
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

  /// BPM más cercano al actual (±12 %); sin BPM, sorteo simple.
  String _radioPickByBpm(List<String> list) {
    final double cur = _extractBpm(state.currentTrackPath);
    if (cur > 60) {
      final sample = List<String>.from(list)..shuffle(_radioRng);
      String? best;
      double bestDiff = double.infinity;
      for (final p in sample.take(80)) {
        final b = _extractBpm(p);
        if (b <= 60) continue;
        final ratio = cur / b;
        if (ratio < 0.88 || ratio > 1.12) continue;
        final d = (cur - b).abs();
        if (d < bestDiff) {
          bestDiff = d;
          best = p;
        }
      }
      if (best != null) return best;
    }
    return list[_radioRng.nextInt(list.length)];
  }

  /// Siguiente pista de la radio (se fija hasta consumirse o cambiar géneros).
  Future<String?> _radioNextPath() async {
    final pending = _radioPending;
    if (pending != null && File(pending).existsSync()) return pending;
    _radioPending = null;
    await _radioEnsureIndex();
    // Otra llamada pudo elegir mientras se esperaba el índice.
    final already = _radioPending;
    if (already != null && File(already).existsSync()) return already;
    final idx = _radioIndex;
    if (idx == null || idx.isEmpty) return _radioQueueFallback();

    final genres = state.radioGenres;
    var folders = <String>[
      for (final e in idx.entries)
        if (genres.isEmpty || genres.contains(_radioFolderGenre[e.key])) e.key,
    ];
    // Géneros elegidos que no existen en esta biblioteca: suena todo, no se para.
    if (folders.isEmpty) folders = idx.keys.toList();
    if (folders.isEmpty) return _radioQueueFallback();

    // La carpeta seleccionada en el Explorador queda fuera de la radio.
    String selPrefix = '';
    try {
      final sel = ref.read(liveDjDirectoryProvider).currentPath;
      if (sel.isNotEmpty) {
        selPrefix = sel + Platform.pathSeparator;
        if (Platform.isWindows) selPrefix = selPrefix.toLowerCase();
      }
    } catch (_) {}
    bool relaxSel = false; // nivel 3: la carpeta del Explorador también vale
    bool outsideSel(String p) {
      if (relaxSel || selPrefix.isEmpty) return true;
      return !(Platform.isWindows ? p.toLowerCase() : p).startsWith(selPrefix);
    }

    // nivel 0: estricto · 1: sin regla de artista · 2: historial reiniciado
    for (int level = 0; level < 4; level++) {
      if (level == 3) relaxSel = true;
      if (level == 2) {
        _radioHistory.clear();
        _saveRadioHistory();
      }
      final cand = <String, List<String>>{};
      for (final f in folders) {
        final list = idx[f]!.where((p) {
          if (!outsideSel(p)) return false;
          if (level < 2 && _radioHistory.contains(p)) return false;
          if (level < 1 &&
              _radioLastArtist.isNotEmpty &&
              _radioArtist(p) == _radioLastArtist) {
            return false;
          }
          return true;
        }).toList();
        if (list.isNotEmpty) cand[f] = list;
      }
      if (cand.isEmpty) continue;

      String folder;
      final last = _radioLastFolder;
      if (last != null && _radioStreak < 2 && cand.containsKey(last)) {
        folder = last; // 2 temas por carpeta
      } else {
        final others = cand.keys.where((k) => k != last).toList();
        final pool = others.isNotEmpty ? others : cand.keys.toList();
        folder = pool[_radioRng.nextInt(pool.length)];
      }

      final pick = _radioPickByBpm(cand[folder]!);
      if (!File(pick).existsSync()) {
        idx[folder]!.remove(pick);
        return _radioNextPath();
      }
      _radioPending = pick;
      _radioPendingFolder = folder;
      state = state.copyWith(radioNextPath: pick);
      return pick;
    }
    return _radioQueueFallback();
  }

  /// Último recurso: la radio nunca se para; suena una pista de la cola.
  String? _radioQueueFallback() {
    final cur = state.currentTrackPath;
    for (final f in state.queue) {
      if (f.path != cur && File(f.path).existsSync()) return f.path;
    }
    return null;
  }

  void _radioConsumed(String path) {
    _radioHistory.add(path);
    final folder = _radioPendingFolder;
    if (folder != null) {
      if (folder == _radioLastFolder) {
        _radioStreak++;
      } else {
        _radioLastFolder = folder;
        _radioStreak = 1;
      }
    }
    _radioLastArtist = _radioArtist(path);
    _radioPending = null;
    _radioPendingFolder = null;
    state = state.copyWith(clearRadioNextPath: true);
    _saveRadioHistory();
  }

  Future<void> toggleRadio() async {
    final bool on = !state.radioOn;
    state = state.copyWith(radioOn: on, clearRadioNextPath: true);
    _radioPending = null;
    _radioPendingFolder = null;
    _saveSnapshot();
    if (on) {
      unawaited(_radioEnsureIndex());
      if (state.currentTrackPath == null && !_isCrossfading) {
        _isPrepModeBypass = false;
        await forceNext();
      } else {
        unawaited(_radioNextPath()); // que el "siguiente" salga de inmediato
      }
    }
  }

  void clearRadioGenres() {
    state = state.copyWith(radioGenres: <String>{}, clearRadioNextPath: true);
    _radioPending = null;
    _radioPendingFolder = null;
    _saveSnapshot();
    if (state.radioOn) unawaited(_radioNextPath());
  }

  void toggleRadioGenre(String genre) {
    if (!kRadioGenreIds.contains(genre)) return;
    final next = Set<String>.from(state.radioGenres);
    if (!next.remove(genre)) next.add(genre);
    state = state.copyWith(radioGenres: next, clearRadioNextPath: true);
    _radioPending = null;
    _radioPendingFolder = null;
    _saveSnapshot();
    if (state.radioOn) unawaited(_radioNextPath());
  }

  int _nextQueueIndex() {
    if (state.queue.isEmpty) return -1;
    if (ref.read(mixFormulaProvider) != MixFormula.stealthGap ||
        state.currentTrackPath == null) {
      return 0;
    }
    final int picked = pickStealthNextIndex(
      remaining: state.queue.map((f) => f.path).toList(),
      currentPath: state.currentTrackPath,
      bpmOf: _extractBpm,
    );
    return picked < 0 ? 0 : picked;
  }

  Future<void> _triggerCrossfade({
    bool forceJit = false,
    bool isManualSkip = false,
    int? queueIndex,
  }) async {
    if (_isCrossfading || (state.queue.isEmpty && !state.radioOn)) return;
    _isCrossfading = true;

    // Radio encendida y sin pista elegida a mano: la sigue la radio (la cola
    // queda congelada). Un toque explícito a una fila (queueIndex) sí suena.
    final bool radioPick = state.radioOn && queueIndex == null;
    final String nextTrack;
    if (radioPick) {
      final String? picked = await _radioNextPath();
      if (picked == null) {
        _isCrossfading = false;
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
          (f) => f.path == _standbyArmedPath,
        );
        if (ai >= 0) nextIdx = ai;
      }
      _nextFromCompletion = false;
      _djTrace(
        'NEXT elegido idx=$nextIdx de ${state.queue.length} jit=$forceJit',
      );
      if (nextIdx < 0 || nextIdx >= state.queue.length) {
        _isCrossfading = false;
        await _stopWhenNoNext();
        return;
      }
      nextTrack = state.queue[nextIdx].path;
    }
    if (!radioPick &&
        state.currentTrackPath != null &&
        nextTrack == state.currentTrackPath) {
      _djTrace('ABORT mezcla contra la misma pista $nextTrack');
      _isCrossfading = false;
      _isStandbyArmed = false;
      _standbyArmedPath = null;
      return;
    }
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

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
        _isCrossfading = false;
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
          final res = await Future.wait([
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
    // BPM con el que SUENA ahora el saliente (puede ir regulado, ver TempoDrift).
    final double outRate = fadingPlayer.state.rate;
    if (fadingBpm > 60 && incomingBpm > 60) {
      final ratio = (fadingBpm * outRate) / incomingBpm;
      if (ratio >= 0.88 && ratio <= 1.12) {
        incomingRate = ratio;
      }
    }

    try {
      // Punto de arranque del entrante: su golpe más cercano a partir del cue.
      int startMs = cueInMs;
      if (gridIn != null) {
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
      _prepareIncomingDeck(incomingPlayer, nextMode);
      await incomingPlayer.setRate(incomingRate);
      await incomingPlayer.setVolume(0.0);
      if (gridOut != null && gridIn != null) {
        // Espera al próximo golpe del saliente (≤ 1 compás de pulso) y arranca ahí.
        final Duration fresh = await fadingPlayer.stream.position.first.timeout(
          const Duration(seconds: 1),
        );
        final Stopwatch sw = Stopwatch()..start();
        final double pOut = 60000.0 / gridOut.bpm;
        final double nowOut = fresh.inMilliseconds.toDouble();
        final double kOut = ((nowOut + 60 - gridOut.beatMs) / pOut)
            .ceilToDouble();
        final double nextBeat = gridOut.beatMs + kOut * pOut;
        // 20 ms: latencia de arranque del deck entrante.
        // El saliente avanza `outRate` ms de pista por cada ms real.
        final int waitMs = ((nextBeat - nowOut) / outRate).round() - 20;
        final int left = waitMs - sw.elapsedMilliseconds;
        if (left > 0 && left < 1500) {
          await Future.delayed(Duration(milliseconds: left));
        }
      }
      await incomingPlayer.play();
    } catch (e) {
      _isCrossfading = false;
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
    if (autoRadio) unawaited(_radioEnsureIndex());
    if (radioPick) _radioConsumed(nextTrack);

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
    );
  }

  /// Deja el deck entrante listo ANTES de `play()`: corrección de tono y cadena
  /// `af` (con corte de graves en modo activeSync). Mismos valores que antes
  /// ponía el motor de mezcla ya con el deck sonando.
  void _prepareIncomingDeck(Player incoming, LiveDjMixMode mode) {
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
        mode == LiveDjMixMode.activeSync ? lowCut : base,
      );
    } catch (_) {}
  }

  Future<void> _executeMixEngine({
    required Player fadingPlayer,
    required Player incomingPlayer,
    required LiveDjMixMode mixProfile,
    double incomingRate = 1.0,
    bool isManualSkip = false,
    int? manualMixDurationMs,
  }) async {
    final eqN = ref.read(liveDjEqualizerProvider.notifier);
    String inBase() => eqN.filterFor(incomingPlayer);
    String outBase() => eqN.filterFor(fadingPlayer);
    final platformOut = fadingPlayer.platform as dynamic;
    final platformIn = incomingPlayer.platform as dynamic;

    final bool useBassSwap = mixProfile == LiveDjMixMode.activeSync;
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
      platformOut?.setProperty('af', outBase());

      await incomingPlayer.setVolume(0.0);

      final fadeStopwatch = Stopwatch()..start();
      final fadeOutDurationMs = isManualSkip
          ? (manualMixDurationMs ?? 12000)
          : (mixProfile == LiveDjMixMode.longBypass
                ? 4000
                : (ref.read(mixFormulaProvider) == MixFormula.phraseGrid ||
                          ref.read(mixFormulaProvider) == MixFormula.stealthGap
                      ? phraseFadeMs(
                          incomingBpm: _extractBpm(state.currentTrackPath),
                          incomingDurationMs: state.duration.inMilliseconds,
                        )
                      : 18000));

      while (fadeStopwatch.elapsedMilliseconds < fadeOutDurationMs) {
        final progress = (fadeStopwatch.elapsedMilliseconds / fadeOutDurationMs)
            .clamp(0.0, 1.0);

        // 🎛️ SUPER MEZCLA DAWN (Alta Energía / Cero Huecos Acústicos)
        final rateIn = (progress * 1.8).clamp(0.0, 1.0);
        final rateOut = ((1.0 - progress) * 1.8).clamp(0.0, 1.0);

        final smoothRateIn = pow(rateIn, 1.2).toDouble();
        final smoothRateOut = pow(rateOut, 1.2).toDouble();

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
      debugPrint("🔴 [ERROR DSP]: $e");
    } finally {
      // La diferencia entre el BPM de entrada y el real se reparte en 5
      // (10 %–50 %). Al 50 % la canción va en su BPM. Vale para Stealth.
      _drift.begin(_incomingNatBpm, incomingRate);
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
      // El deck saliente quedó vacío: ningún armado previo sigue siendo válido.
      _standbyArmedPath = null;

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

  Future<void> parkIdleDecks({bool force = false}) async {
    if (_parking) return;
    if (!force && (state.isPlaying || _isCrossfading)) return;
    _parking = true;
    try {
      if (force) _isCrossfading = false;
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
