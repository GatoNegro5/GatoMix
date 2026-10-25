import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import '../core/audio/af_caps.dart';
import '../core/hal/platform_strategy.dart';
import 'adaptive_eq.dart';
import '../providers/automix_provider.dart';
import '../providers/livedj_provider.dart';

class EqualizerPreset {
  final String name;
  final double preamp;
  final List<double> gains;

  const EqualizerPreset({
    required this.name,
    required this.preamp,
    required this.gains,
  });

  static const List<EqualizerPreset> defaultPresets = [
    EqualizerPreset(
      name: 'Spotify Signature',
      preamp: -1.5,
      gains: [3.5, 2.5, 1.0, -0.5, -1.0, 0.0, 1.5, 2.5, 3.5, 4.0],
    ),
    EqualizerPreset(
      name: 'Flat / Studio',
      preamp: 0.0,
      gains: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    ),
    EqualizerPreset(
      name: 'Club DJ Punch',
      preamp: -2.0,
      gains: [5.0, 4.0, 2.0, 0.0, -1.0, -1.0, 0.0, 2.0, 3.5, 4.5],
    ),
    EqualizerPreset(
      name: 'Bass Master',
      preamp: -3.0,
      gains: [6.5, 5.5, 3.5, 1.0, 0.0, -1.5, -1.0, 0.0, 1.0, 1.5],
    ),
    EqualizerPreset(
      name: 'Vocal & Acoustic',
      preamp: -1.0,
      gains: [-2.0, -1.0, 0.0, 1.5, 3.0, 3.5, 2.5, 1.0, 0.5, 0.0],
    ),
  ];
}

/// Motor dueño de un ecualizador. Cada uno escribe `af` solo en sus decks.
enum EqualizerTarget { automix, liveDj }

class AudioEqualizerService {
  final Ref ref;
  final EqualizerTarget target;

  /// Cadena base (EQ del usuario, sin corrección adaptativa de canción).
  String currentBaseFilter = '';
  static const List<int> bandFrequencies = AdaptiveEq.bands;

  double _preamp = 0.0;
  List<double> _gains = List.filled(10, 0.0);
  bool _enabled = true;

  AudioEqualizerService(this.ref, this.target) {
    _rebuild();
    // El libmpv empaquetado solo acepta algunos filtros: se sondea una vez
    // y se reconstruye la cadena (p. ej. para sumar el limitador si existe).
    AfCaps.probe().then((_) => _applyAll());
  }

  Future<void> applyEqualizer({
    required double preamp,
    required List<double> gains,
    required bool enabled,
  }) async {
    if (gains.length != 10) return;
    _preamp = preamp;
    _gains = List<double>.from(gains);
    _enabled = enabled;
    _rebuild();
    await _applyAll();
  }

  void _rebuild() {
    currentBaseFilter = _compose(List.filled(10, 0.0));
  }

  /// Cadena `af`: color de plataforma -> EQ (usuario + canción, con margen
  /// automático) -> limitador (si el libmpv lo trae). Todo pasa por
  /// `AfCaps.sanitize`: un filtro ausente invalidaría la cadena entera.
  String _compose(List<double> adaptive, [double level = 0.0]) {
    final strategy = MixStrategyFactory.getStrategy();
    final String hal = strategy.colorFilter;
    final merged = List<double>.generate(
      10,
      (i) => (_enabled ? _gains[i] : 0.0) + adaptive[i],
    );
    final eq = AdaptiveEq.eqChain(
      merged,
      preamp: _enabled ? _preamp : 0.0,
      levelDb: level,
    );
    final chain = [
      if (hal.isNotEmpty) hal,
      ...eq,
      strategy.levelerFilter,
      strategy.limiterFilter,
    ].where((s) => s.isNotEmpty).join(',');
    return AfCaps.sanitize(chain);
  }

  List<Player> get _players => target == EqualizerTarget.automix
      ? ref.read(automixProvider.notifier).deckPlayers
      : ref.read(liveDjProvider.notifier).deckPlayers;

  Future<void> _applyAll() async {
    // Aplicación a los decks del motor dueño, cada uno con la curva de SU
    // canción.
    for (final player in _players) {
      try {
        await (player.platform as dynamic)?.setProperty(
          'af',
          filterFor(player),
        );
      } catch (_) {}
    }
  }

  /// Cadena completa del [player]: EQ del usuario + corrección adaptativa de
  /// SU canción.
  String filterFor(Player player) =>
      _compose(AdaptiveEq.gainsFor(player), AdaptiveEq.levelFor(player));

  /// Llamar tras `open()` en un deck: mide la canción, fija su sonoridad y
  /// aplica su curva.
  void adapt(Player player, String path) {
    AdaptiveEq.attach(
      player,
      path,
      onReady: () {
        try {
          (player.platform as dynamic)?.setProperty('af', filterFor(player));
        } catch (_) {}
      },
    );
  }
}
