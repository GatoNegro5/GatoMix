import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/automix_provider.dart';
import '../providers/livedj_provider.dart';

/// Comportamiento de app profesional ante interrupciones del sistema
/// (llamada telefónica, alarma, otra app de audio, auriculares fuera).
///
/// * Al sonar pide el foco de audio (`setActive(true)`): sin él Android
///   mezcla la llamada con la música.
/// * Interrupción temporal (llamada) → pausa y, al terminar, reanuda sola
///   solo si la pausa la causó el sistema.
/// * Pérdida permanente (otra app de música) → pausa y NO reanuda.
/// * Auriculares/Bluetooth desconectados → pausa y NO reanuda.
/// * "Duck" (navegación hablando): lo atenúa el sistema; no se toca el volumen
///   para no pelear con el motor de mezcla.
///
/// Un solo guardián para Automix y Live DJ en Android e iPhone (en
/// Windows/macOS no hay llamadas ni foco que gestionar).
class AudioInterruptionGuard {
  AudioInterruptionGuard(this._ref);

  final WidgetRef _ref;
  AudioSession? _session;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _noisySub;
  final List<ProviderSubscription<dynamic>> _playingSubs = [];
  bool _resumeAutomix = false;
  bool _resumeLiveDj = false;
  // Pausa causada por el sistema: se conserva el foco para que Android nos
  // avise (GAIN) cuando termine la llamada y poder reanudar.
  bool _interrupted = false;
  bool _disposed = false;

  bool get _supported => Platform.isAndroid || Platform.isIOS;

  Future<void> start() async {
    if (!_supported) return;
    try {
      final session = await AudioSession.instance;
      if (_disposed) return;
      // Foco "transitorio": las otras apps (TikTok, Facebook…) lo reciben de
      // vuelta al pausar/cerrar; con foco permanente algunas quedan en mute.
      await session.configure(
        const AudioSessionConfiguration.music().copyWith(
          androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
        ),
      );
      _session = session;
      _interruptionSub = session.interruptionEventStream.listen(
        _onInterruption,
      );
      _noisySub = session.becomingNoisyEventStream.listen((_) {
        unawaited(_pauseAll(resumeLater: false));
      });
      _playingSubs.add(
        _ref.listenManual<bool>(
          automixProvider.select((s) => s.isPlaying),
          (prev, next) => _onPlayingChanged(next),
        ),
      );
      _playingSubs.add(
        _ref.listenManual<bool>(
          liveDjProvider.select((s) => s.isPlaying),
          (prev, next) => _onPlayingChanged(next),
        ),
      );
    } catch (e) {
      debugPrint('🔴 [AUDIO FOCUS] init $e');
    }
  }

  void dispose() {
    _disposed = true;
    _interruptionSub?.cancel();
    _noisySub?.cancel();
    for (final sub in _playingSubs) {
      sub.close();
    }
    _playingSubs.clear();
  }

  bool get _anyPlaying =>
      _ref.read(automixProvider).isPlaying ||
      _ref.read(liveDjProvider).isPlaying;

  void _onPlayingChanged(bool playing) {
    final session = _session;
    if (session == null) return;
    if (playing) {
      unawaited(_requestFocus(session));
    } else if (!_anyPlaying && !_interrupted) {
      // Pausa o parada del usuario: soltar el foco para que otras apps
      // (llamada, navegación, otro reproductor) funcionen con normalidad.
      unawaited(session.setActive(false).catchError((_) => false));
    }
  }

  Future<void> _requestFocus(AudioSession session) async {
    try {
      final granted = await session.setActive(true);
      if (!granted && _anyPlaying) {
        // El sistema nos niega el foco (p. ej. llamada en curso): no sonar encima.
        await _pauseAll(resumeLater: false);
      }
    } catch (e) {
      debugPrint('🔴 [AUDIO FOCUS] request $e');
    }
  }

  void _onInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          return;
        case AudioInterruptionType.pause:
          unawaited(_pauseAll(resumeLater: true));
          return;
        case AudioInterruptionType.unknown:
          unawaited(_pauseAll(resumeLater: false));
          return;
      }
    } else {
      switch (event.type) {
        case AudioInterruptionType.duck:
          return;
        case AudioInterruptionType.pause:
          unawaited(_resumeAll());
          return;
        case AudioInterruptionType.unknown:
          _resumeAutomix = false;
          _resumeLiveDj = false;
          _interrupted = false;
          return;
      }
    }
  }

  Future<void> _pauseAll({required bool resumeLater}) async {
    if (resumeLater) _interrupted = true;
    try {
      final automix = _ref.read(automixProvider.notifier);
      final paused = await automix.pauseForInterruption();
      if (paused && resumeLater) _resumeAutomix = true;
    } catch (e) {
      debugPrint('🔴 [AUDIO FOCUS] pause automix $e');
    }
    try {
      final live = _ref.read(liveDjProvider.notifier);
      final paused = await live.pauseForInterruption();
      if (paused && resumeLater) _resumeLiveDj = true;
    } catch (e) {
      debugPrint('🔴 [AUDIO FOCUS] pause livedj $e');
    }
    if (!resumeLater) {
      _resumeAutomix = false;
      _resumeLiveDj = false;
      _interrupted = false;
    } else if (!_resumeAutomix && !_resumeLiveDj) {
      // Nada sonaba: no hay nada que reanudar ni foco que retener.
      _interrupted = false;
    }
  }

  Future<void> _resumeAll() async {
    final wantAutomix = _resumeAutomix;
    final wantLive = _resumeLiveDj;
    _resumeAutomix = false;
    _resumeLiveDj = false;
    _interrupted = false;
    if (!wantAutomix && !wantLive) return;
    final session = _session;
    if (session != null) {
      try {
        final granted = await session.setActive(true);
        if (!granted) return;
      } catch (_) {}
    }
    if (wantAutomix) {
      try {
        await _ref.read(automixProvider.notifier).resumeAfterInterruption();
      } catch (e) {
        debugPrint('🔴 [AUDIO FOCUS] resume automix $e');
      }
    }
    if (wantLive) {
      try {
        await _ref.read(liveDjProvider.notifier).resumeAfterInterruption();
      } catch (e) {
        debugPrint('🔴 [AUDIO FOCUS] resume livedj $e');
      }
    }
  }
}
