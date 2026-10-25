import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

/// Pre-escucha (CUE) de Live DJ, solo Windows.
///
/// Es un reproductor APARTE: no es un deck, no pasa por `liveDjProvider` ni
/// por ningún motor de mezcla. Su salida es SOLO el audífono: si Windows no
/// reporta un audífono (o no se puede fijar como salida), no suena nada y
/// nunca cae a los parlantes.
class CueState {
  /// Hay un audífono conectado y la pre-escucha puede usarse.
  final bool available;

  /// Nombre del dispositivo de audio (audífono) elegido.
  final String? deviceName;

  /// Canción que está sonando en pre-escucha (null = parada).
  final String? playingPath;

  const CueState({this.available = false, this.deviceName, this.playingPath});

  CueState copyWith({
    bool? available,
    String? deviceName,
    bool clearDevice = false,
    String? playingPath,
    bool clearPlaying = false,
  }) => CueState(
    available: available ?? this.available,
    deviceName: clearDevice ? null : (deviceName ?? this.deviceName),
    playingPath: clearPlaying ? null : (playingPath ?? this.playingPath),
  );
}

/// Dispositivos que cuentan como audífono (Windows los nombra así).
final RegExp _headphoneRe = RegExp(
  r'headphone|headset|earphone|earbud|buds|airpods|auricular|audifon|audífon|'
  r'cascos|hands-free|manos libres',
  caseSensitive: false,
);

/// Nunca son audífono aunque el nombre se parezca.
final RegExp _notHeadphoneRe = RegExp(
  r'speaker|altavo|parlante|hdmi|displayport|monitor|spdif|digital|tv\b|'
  r'line out|salida de l[ií]nea|microphone|micr[oó]fono|input|entrada',
  caseSensitive: false,
);

class CuePreviewNotifier extends StateNotifier<CueState> {
  CuePreviewNotifier() : super(const CueState()) {
    if (Platform.isWindows) {
      _init();
    }
  }

  Player? _player;
  Timer? _poll;
  StreamSubscription<List<AudioDevice>>? _devSub;
  StreamSubscription<bool>? _doneSub;
  bool _disposed = false;

  static bool get supported => Platform.isWindows;

  Future<void> _init() async {
    try {
      final p = Player(
        configuration: const PlayerConfiguration(title: 'GatoMix CUE'),
      );
      _player = p;
      try {
        final dynamic platform = p.platform;
        platform?.setProperty('vid', 'no');
      } catch (_) {}
      await p.setVolume(100.0);
      _doneSub = p.stream.completed.listen((done) {
        if (done && !_disposed && state.playingPath != null) {
          state = state.copyWith(clearPlaying: true);
        }
      });
      _devSub = p.stream.audioDevices.listen(_onDevices);
      _onDevices(p.state.audioDevices);
      // Windows puede tardar en reportar altas/bajas: se revisa cada 3 s.
      _poll = Timer.periodic(const Duration(seconds: 3), (_) {
        final pl = _player;
        if (pl != null) _onDevices(pl.state.audioDevices);
      });
    } catch (e) {
      debugPrint('🔴 [CUE] init: $e');
    }
  }

  AudioDevice? _pickHeadphones(List<AudioDevice> devices) {
    for (final d in devices) {
      if (d.name == 'auto') continue;
      final text = '${d.description} ${d.name}';
      if (_notHeadphoneRe.hasMatch(d.description)) continue;
      if (_headphoneRe.hasMatch(text)) return d;
    }
    return null;
  }

  void _onDevices(List<AudioDevice> devices) {
    if (_disposed) return;
    final pick = _pickHeadphones(devices);
    if (pick == null) {
      if (state.available || state.playingPath != null) {
        // Se desconectó el audífono: pre-escucha apagada y cortada.
        unawaited(_stopInternal());
        state = const CueState();
      }
      return;
    }
    if (!state.available || state.deviceName != pick.name) {
      state = state.copyWith(available: true, deviceName: pick.name);
    }
  }

  /// Play en la flecha roja de [path]. Si ya suena esa, la para.
  Future<void> toggle(String path) async {
    if (!supported || !state.available) return;
    if (state.playingPath == path) {
      await stop();
      return;
    }
    await play(path);
  }

  Future<void> play(String path) async {
    final p = _player;
    final dev = state.deviceName;
    if (p == null || !state.available || dev == null) return;
    try {
      AudioDevice? target;
      for (final d in p.state.audioDevices) {
        if (d.name == dev) {
          target = d;
          break;
        }
      }
      if (target == null) return;
      await p.setAudioDevice(target);
      // Seguridad: si no quedó fijado el audífono, NO suena.
      if (p.state.audioDevice.name != dev) return;
      await p.open(Media(path), play: true);
      state = state.copyWith(playingPath: path);
    } catch (e) {
      debugPrint('🔴 [CUE] play: $e');
      await _stopInternal();
      state = state.copyWith(clearPlaying: true);
    }
  }

  Future<void> _stopInternal() async {
    try {
      await _player?.stop();
    } catch (_) {}
  }

  /// Para la pre-escucha (también al dar Play verde a una canción).
  Future<void> stop() async {
    await _stopInternal();
    if (!_disposed && state.playingPath != null) {
      state = state.copyWith(clearPlaying: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _devSub?.cancel();
    _doneSub?.cancel();
    final p = _player;
    _player = null;
    if (p != null) {
      unawaited(p.dispose());
    }
    super.dispose();
  }
}

final cuePreviewProvider = StateNotifierProvider<CuePreviewNotifier, CueState>(
  (ref) => CuePreviewNotifier(),
);
