import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Filtros `af` que el libmpv empaquetado SÍ trae.
///
/// Auditoría 2026-10-05: el libmpv de Windows (build "audio" de media_kit)
/// solo incluye `equalizer` entre los filtros de libavfilter. Si una cadena
/// `af` nombra un solo filtro ausente, mpv rechaza la cadena ENTERA y deja
/// la anterior (vacía): ni EQ, ni limitador, ni nada. Por eso toda cadena
/// pasa por [sanitize] y los filtros opcionales se prueban en tiempo de
/// ejecución con [probe].
class AfCaps {
  AfCaps._();

  /// Candidatos opcionales que se prueban (el resto no se usa).
  static const List<String> _optional = ['alimiter'];

  static final Set<String> _ok = {'equalizer'};
  static bool _probed = false;
  static Future<void>? _running;

  /// Cadena completa que el libmpv de Windows aceptó como limitador.
  /// Vacía si ninguna sonda pasó: no se inventa un filtro.
  static String windowsSafetyLimiter = '';

  /// Solo se prueban en Windows, y solo si `alimiter=level=disabled` falla.
  static const List<String> _windowsFallbacks = [
    'alimiter=limit=0.95:level=0',
    'acompressor=threshold=-1dB:ratio=20:attack=5:release=100:makeup=1:knee=1.5',
    'compand=attacks=0:decays=0.3:points=-80/-80|-12/-12|-1/-1|20/-1',
  ];

  static bool has(String name) => _ok.contains(name);

  /// Deja solo los filtros soportados de una cadena `a,b,c`.
  static String sanitize(String chain) {
    if (chain.isEmpty) return chain;
    final keep = <String>[];
    for (final part in chain.split(',')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final name = p.split('=').first.trim();
      if (_ok.contains(name)) keep.add(p);
    }
    return keep.join(',');
  }

  /// Prueba una sola vez qué filtros acepta este libmpv.
  static Future<void> probe() => _running ??= _doProbe();

  static Future<void> _doProbe() async {
    if (_probed) return;
    Player? p;
    try {
      p = Player();
      final dynamic pl = p.platform;
      await pl?.setProperty('vid', 'no');

      Future<bool> accepts(String chain, String name) async {
        try {
          await pl?.setProperty('af', '');
          await pl?.setProperty('af', chain);
          final dynamic v = await pl?.getProperty('af');
          final bool ok = v is String && v.contains(name);
          await pl?.setProperty('af', '');
          return ok;
        } catch (_) {
          return false;
        }
      }

      final eqOk = await accepts(
        'equalizer=f=1000:width_type=o:w=1:g=1.0',
        'equalizer',
      );
      if (eqOk) {
        _ok.add('equalizer');
      } else {
        _ok.remove('equalizer');
      }
      for (final f in _optional) {
        final String chain = '$f=limit=0.95:level=disabled';
        if (await accepts(chain, f)) {
          _ok.add(f);
          if (defaultTargetPlatform == TargetPlatform.windows) {
            windowsSafetyLimiter = chain;
          }
        }
      }
      if (defaultTargetPlatform == TargetPlatform.windows &&
          windowsSafetyLimiter.isEmpty) {
        for (final String chain in _windowsFallbacks) {
          final String name = chain.split('=').first.trim();
          if (await accepts(chain, name)) {
            _ok.add(name);
            windowsSafetyLimiter = chain;
            break;
          }
        }
      }
      _probed = true;
      debugPrint(
        '🎚️ [AF CAPS] soportados: $_ok'
        '${windowsSafetyLimiter.isEmpty ? '' : ' | windows=$windowsSafetyLimiter'}',
      );
    } catch (e) {
      debugPrint('🔴 [AF CAPS] sin sonda ($e), solo equalizer');
    } finally {
      try {
        await p?.dispose();
      } catch (_) {}
    }
  }
}
