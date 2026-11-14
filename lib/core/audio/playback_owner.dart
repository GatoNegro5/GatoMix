import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 3.1.28: los dos motores de reproduccion de GatoMix.
enum PlaybackEngine { automix, liveDj }

/// Pausa el motor (tambien a mitad de un cruce). `true` si estaba sonando.
typedef PlaybackYield = Future<bool> Function();

/// Exclusion mutua entre Automix y Live DJ sin acoplarlos: cada motor se
/// registra y, al dar Play, reclama; el coordinador pide ceder al otro.
/// No importa ningun provider (sin dependencia circular). Cambiar de
/// pestana no reclama nada, asi que no corta la musica.
class PlaybackOwner {
  final Map<PlaybackEngine, PlaybackYield> _engines =
      <PlaybackEngine, PlaybackYield>{};
  PlaybackEngine? _owner;

  PlaybackEngine? get owner => _owner;

  void register(PlaybackEngine engine, PlaybackYield onYield) {
    _engines[engine] = onYield;
  }

  void unregister(PlaybackEngine engine, PlaybackYield onYield) {
    if (_engines[engine] == onYield) _engines.remove(engine);
  }

  /// Devuelve cuantos motores pausados cedieron la reproduccion.
  Future<int> claim(PlaybackEngine engine) async {
    _owner = engine;
    int paused = 0;
    for (final MapEntry<PlaybackEngine, PlaybackYield> e
        in _engines.entries.toList()) {
      if (e.key == engine) continue;
      try {
        if (await e.value()) paused++;
      } catch (_) {}
    }
    return paused;
  }
}

final Provider<PlaybackOwner> playbackOwnerProvider = Provider<PlaybackOwner>(
  (Ref ref) => PlaybackOwner(),
);
