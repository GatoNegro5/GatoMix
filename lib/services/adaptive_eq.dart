import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;
import '../core/audio/af_caps.dart';
import '../core/hal/platform_strategy.dart';

/// Perfil medido de una canción.
class AdaptiveProfile {
  /// Corrección espectral (dB) en las 10 bandas octava.
  final List<double> gains;

  /// Ganancia de sonoridad (dB) para igualar el volumen entre canciones.
  final double levelDb;
  const AdaptiveProfile(this.gains, this.levelDb);

  Map<String, dynamic> toJson() => {'g': gains, 'l': levelDb};

  static AdaptiveProfile? fromJson(dynamic j) {
    if (j is! Map) return null;
    final g = j['g'];
    final l = j['l'];
    if (g is! List || g.length != 10 || l is! num) return null;
    return AdaptiveProfile(
      g.map((e) => (e as num).toDouble()).toList(),
      l.toDouble(),
    );
  }
}

/// Audio profesional automático por canción, compartido por Automix y Live DJ
/// (cada uno lo aplica solo a sus propios decks):
///
///  * EQ adaptativa: mide 30 s del tema en 10 bandas octava y corrige hacia
///    una curva típica de música comercial (máx ±3 dB; no realza bandas que
///    el archivo no tiene).
///  * Sonoridad igual: mide la sonoridad (K-weighting + compuertas, estilo
///    BS.1770) y fija la ganancia como desplazamiento de la cadena
///    `equalizer` (ver `eqChain`). El libmpv empaquetado solo trae
///    `equalizer` (ver `AfCaps`); `replaygain-fallback` no cambia en vivo.
class AdaptiveEq {
  AdaptiveEq._();

  /// Interruptor global (por defecto activo).
  static bool enabled = true;

  /// 1.0.19 tipo Sound Check: sonoridad integrada BS.1770, objetivo −14 LUFS
  /// (el mismo de Masterizar). Antes: −16 LUFS medido solo en 30 s.
  static const double targetLufs = -14.0;

  /// Arranques (s) de las ventanas de sonoridad. Vacío si la pista ya trae
  /// `GMX_LUFS_DONE`: la ganancia de sonoridad queda en 0 y no se decodifica
  /// el resto del archivo mientras suena.
  @visibleForTesting
  static List<int> integratedLoudnessStarts({required bool lufsDone}) {
    if (lufsDone) return const <int>[];
    return const <int>[0, 60, 120, 180];
  }

  /// Ganancia (dB) hacia [targetLufs] sin clipping: nunca más arriba que
  /// pico −1,5 dB (no hay limitador en todos los reproductores), tope
  /// +9 / −12. Con GMX_LUFS_DONE y medida dentro de ±1 LU: 0 (ya está).
  @visibleForTesting
  static double soundCheckGainDb({
    required double lufs,
    required double peakDb,
    bool lufsDone = false,
  }) {
    double level = targetLufs - lufs;
    if (lufsDone && level.abs() <= 1.0) return 0;
    final double maxUp = -peakDb - 1.5;
    if (level > maxUp) level = maxUp;
    return level.clamp(-12.0, 9.0).toDouble();
  }

  static const List<int> bands = [
    31,
    62,
    125,
    250,
    500,
    1000,
    2000,
    4000,
    8000,
    16000,
  ];
  static const int _sr = 44100;

  static final Expando<List<double>> _gains = Expando<List<double>>('aeqGains');
  static final Expando<double> _levels = Expando<double>('aeqLevel');
  static final Expando<String> _token = Expando<String>('aeqToken');

  static Map<String, dynamic>? _disk;
  static final Map<String, AdaptiveProfile?> _mem = {};
  static final Map<String, Future<AdaptiveProfile?>> _pending = {};
  static Future<void> _queue = Future.value();

  /// Corrección espectral del [player] (10 ceros si no hay perfil o está
  /// desactivada).
  static List<double> gainsFor(Player player) {
    if (!enabled) return List<double>.filled(10, 0);
    return _gains[player] ?? List<double>.filled(10, 0);
  }

  /// Cadena `equalizer` de 10 bandas con margen automático: el realce neto
  /// máximo se compensa bajando todas las bandas (no hay filtro `volume` ni
  /// limitador en el libmpv empaquetado), así nada pasa de 0 dBFS.
  ///
  /// [levelDb] es la ganancia de sonoridad de la canción. El libmpv no
  /// permite cambiar `replaygain-fallback` con la canción ya abierta (medido:
  /// solo se lee al cargar el archivo), así que la sonoridad se aplica como
  /// desplazamiento común de las bandas. Como las 10 bandas se solapan, las
  /// ganancias se resuelven para que la respuesta real de la cascada en cada
  /// frecuencia central sea la pedida (cálculo de coeficientes, no DSP).
  static List<String> eqChain(
    List<double> gains, {
    double preamp = 0,
    double levelDb = 0,
  }) {
    if (gains.length != 10) return const [];
    double maxBoost = 0;
    final g = gains.map((v) => v.clamp(-12.0, 12.0).toDouble()).toList();
    for (final v in g) {
      if (v > maxBoost) maxBoost = v;
    }
    final double shift = (preamp < -maxBoost ? preamp : -maxBoost) + levelDb;
    final target = List<double>.generate(10, (i) => g[i] + shift);
    final solved = _solveCascade(target);
    final out = <String>[];
    for (int i = 0; i < 10; i++) {
      final v = solved[i];
      if (v.abs() >= 0.1) {
        out.add(
          'equalizer=f=${bands[i]}:width_type=o:w=1:g=${v.toStringAsFixed(1)}',
        );
      }
    }
    return out;
  }

  /// Respuesta (dB) en [f] Hz de un filtro peaking RBJ (octavas [w]).
  static double _peakDb(double f0, double gDb, double f) {
    const double bw = 1.0;
    final w0 = 2 * pi * f0 / _sr;
    final alpha =
        sin(w0) *
        (exp(ln2 / 2 * bw * w0 / sin(w0)) - exp(-ln2 / 2 * bw * w0 / sin(w0))) /
        2;
    final a = pow(10, gDb / 40).toDouble();
    final c = cos(w0);
    final b0 = 1 + alpha * a, b1 = -2 * c, b2 = 1 - alpha * a;
    final a0 = 1 + alpha / a, a1 = -2 * c, a2 = 1 - alpha / a;
    final w = 2 * pi * f / _sr;
    final cw = cos(w), sw = sin(w), c2 = cos(2 * w), s2 = sin(2 * w);
    final nr = b0 + b1 * cw + b2 * c2, ni = -(b1 * sw + b2 * s2);
    final dr = a0 + a1 * cw + a2 * c2, di = -(a1 * sw + a2 * s2);
    final m = (nr * nr + ni * ni) / (dr * dr + di * di);
    return 10 * log(m) / ln10;
  }

  /// Ajusta las ganancias de las 10 bandas para que la respuesta total de la
  /// cascada en cada frecuencia central valga [target] (iteración de punto
  /// fijo sobre el solape entre bandas).
  static List<double> _solveCascade(List<double> target) {
    final g = List<double>.from(target);
    for (int it = 0; it < 12; it++) {
      double err = 0;
      for (int i = 0; i < 10; i++) {
        double h = 0;
        for (int j = 0; j < 10; j++) {
          if (g[j].abs() < 0.01) continue;
          h += _peakDb(bands[j].toDouble(), g[j], bands[i].toDouble());
        }
        final e = target[i] - h;
        err = max(err, e.abs());
        g[i] = (g[i] + e * 0.8).clamp(-24.0, 24.0).toDouble();
      }
      if (err < 0.05) break;
    }
    return g;
  }

  /// Ganancia de sonoridad (dB) de la canción del [player].
  static double levelFor(Player player) =>
      enabled ? (_levels[player] ?? 0.0) : 0.0;

  /// Registra la canción [path] en el [player]: limpia lo anterior, mide la
  /// canción (o toma la caché) y aplica sonoridad + notifica a [onReady] para
  /// que el motor reconstruya el `af` del deck con la nueva EQ.
  static void attach(
    Player player,
    String path, {
    required VoidCallback onReady,
  }) {
    _gains[player] = null;
    _levels[player] = null;
    _token[player] = path;
    if (!enabled) return;
    () async {
      await AfCaps.probe();
      final prof = await profile(path);
      if (prof == null) return;
      if (_token[player] != path) return; // el deck ya cambió de canción
      _gains[player] = prof.gains;
      _levels[player] = prof.levelDb;
      onReady();
    }();
  }

  // ------------------------------------------------------------------ caché
  static File _cacheFile() {
    final base = File(MixStrategyFactory.getStrategy().getSessionPath()).parent;
    return File('${base.path}${Platform.pathSeparator}_adaptive_audio.json');
  }

  static String _key(String path) {
    try {
      final f = File(path);
      return 'v2|$path|${f.lengthSync()}|${f.lastModifiedSync().millisecondsSinceEpoch}';
    } catch (_) {
      return path;
    }
  }

  static void _loadDisk() {
    if (_disk != null) return;
    try {
      final f = _cacheFile();
      if (f.existsSync()) {
        final d = jsonDecode(f.readAsStringSync());
        if (d is Map<String, dynamic>) {
          _disk = d;
          return;
        }
      }
    } catch (_) {}
    _disk = <String, dynamic>{};
  }

  static void _saveDisk() {
    try {
      _cacheFile().writeAsStringSync(jsonEncode(_disk));
    } catch (_) {}
  }

  /// Perfil de la canción desde caché o midiéndola (en cola, de a una).
  static Future<AdaptiveProfile?> profile(String path) {
    final k = _key(path);
    if (_mem.containsKey(k)) return Future.value(_mem[k]);
    _loadDisk();
    final c = AdaptiveProfile.fromJson(_disk![k]);
    if (c != null) {
      _mem[k] = c;
      return Future.value(c);
    }
    return _pending[k] ??= _enqueue(
      () => _measure(path, k),
    ).whenComplete(() => _pending.remove(k));
  }

  static Future<AdaptiveProfile?> _enqueue(
    Future<AdaptiveProfile?> Function() job,
  ) {
    final done = Completer<AdaptiveProfile?>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await job());
      } catch (_) {
        done.complete(null);
      }
    });
    return done.future;
  }

  static Future<AdaptiveProfile?> _measure(String path, String k) async {
    try {
      // REGLA (CONTEXTO): solo existen 2 decks. Se decodifica en proceso con
      // Rust/symphonia: sin reproductor, sin FFmpeg, igual en las 4 plataformas.
      Uint8List? bytes;
      bool lufsDone = false;
      try {
        lufsDone = (await rust_dsp.readGmxMarks(inputPath: path)).lufsDone;
      } catch (_) {}
      for (final start in const [30, 0]) {
        try {
          final b = await rust_dsp.decodeMonoPcm(
            inputPath: path,
            startSecs: start,
            lengthSecs: 30,
            targetRate: _sr,
          );
          if (b.length > _sr * 2 * 5) {
            bytes = b;
            break;
          }
        } catch (_) {}
      }
      if (bytes == null) return null;
      final Uint8List data = bytes;
      AdaptiveProfile? p = await Isolate.run(
        () => _analyze(data, lufsDone: lufsDone),
      );
      // Sonoridad. Una pista con GMX_LUFS_DONE ya está en −14: no se
      // decodifica entera (eso calentaba el CPU en cada canción de Live DJ).
      // Sin esa marca, cuatro ventanas y se corta al acabar el archivo.
      // Antes: cada 30 s hasta 20 min; si el seek fallaba, 40 veces el
      // mismo tramo inicial.
      if (p != null && lufsDone) {
        p = AdaptiveProfile(p.gains, 0);
      } else if (p != null) {
        final List<double> blocks = <double>[];
        double peak = 0;
        for (final int start in integratedLoudnessStarts(lufsDone: false)) {
          Uint8List chunk;
          try {
            chunk = await rust_dsp.decodeMonoPcm(
              inputPath: path,
              startSecs: start,
              lengthSecs: 30,
              targetRate: _sr,
            );
          } catch (_) {
            break;
          }
          if (chunk.length < _sr * 2) break;
          final (List<double>, double) r = await Isolate.run(
            () => loudnessBlocks(chunk),
          );
          blocks.addAll(r.$1);
          if (r.$2 > peak) peak = r.$2;
          if (chunk.length < _sr * 2 * 29) break;
        }
        final double? lufs = gatedLufs(blocks);
        if (lufs != null && peak > 1e-4) {
          p = AdaptiveProfile(
            p.gains,
            soundCheckGainDb(
              lufs: lufs,
              peakDb: 20 * log(peak) / ln10,
              lufsDone: lufsDone,
            ),
          );
        }
      }
      _mem[k] = p;
      if (p != null) {
        _loadDisk();
        _disk![k] = p.toJson();
        _saveDisk();
      }
      return p;
    } catch (e) {
      debugPrint('🔴 [ADAPTIVE AUDIO] $path: $e');
      return null;
    }
  }

  /// Energías K-weighted de bloques de 400 ms (75 % solape) y pico de un
  /// tramo PCM16 mono a [_sr].
  @visibleForTesting
  static (List<double>, double) loudnessBlocks(Uint8List b) {
    final int n = b.length ~/ 2;
    final ByteData bd = ByteData.sublistView(b);
    final Float64List k = Float64List(n);
    double peak = 0;
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0, u1 = 0, u2 = 0, v1 = 0, v2 = 0;
    const b0 = 1.53512485958697, b1 = -2.69169618940638, b2 = 1.19839281085285;
    const a1 = -1.69065929318241, a2 = 0.73248077421585;
    const c1 = -1.99004745483398, c2 = 0.99007225036621;
    for (int i = 0; i < n; i++) {
      final double x = bd.getInt16(i * 2, Endian.little) / 32768.0;
      if (x.abs() > peak) peak = x.abs();
      final double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1;
      x1 = x;
      y2 = y1;
      y1 = y;
      final double z = y - 2 * u1 + u2 - c1 * v1 - c2 * v2;
      u2 = u1;
      u1 = y;
      v2 = v1;
      v1 = z;
      k[i] = z;
    }
    final int blk = (_sr * 0.4).round();
    final List<double> out = <double>[];
    for (int s = 0; s + blk <= n; s += blk ~/ 4) {
      double e = 0;
      for (int i = s; i < s + blk; i++) {
        e += k[i] * k[i];
      }
      out.add(e / blk);
    }
    return (out, peak);
  }

  /// BS.1770: compuerta absoluta −70 LUFS y relativa −10 LU. Null si no hay.
  @visibleForTesting
  static double? gatedLufs(List<double> blocks) {
    final List<double> abs = blocks.where((e) => e > 1.2e-7).toList();
    if (abs.isEmpty) return null;
    final double m1 = abs.reduce((a, c) => a + c) / abs.length;
    final List<double> rel = abs.where((e) => e > m1 * 0.1).toList();
    final List<double> g = rel.isEmpty ? abs : rel;
    return -0.691 + 10 * log(g.reduce((a, c) => a + c) / g.length) / ln10;
  }

  // -------------------------------------------------------------- análisis
  // Nivel típico de música comercial por banda octava (dB, relativo a 1 kHz).
  static const List<double> _target = [-1, 4, 6, 3, 1, 0, -3, -6, -11, -18];

  static AdaptiveProfile? _analyze(Uint8List b, {bool lufsDone = false}) {
    final n = b.length ~/ 2;
    const int fft = 4096;
    if (n < fft * 8) return null;
    final bd = ByteData.sublistView(b);
    final samples = Float64List(n);
    double peak = 0;
    for (int i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      samples[i] = v;
      final a = v.abs();
      if (a > peak) peak = a;
    }
    if (peak < 1e-4) return AdaptiveProfile(List<double>.filled(10, 0), 0);

    // ---- Sonoridad: K-weighting (coef. BS.1770 a 48 kHz, aprox. a 44.1)
    // y bloques de 400 ms con compuerta absoluta y relativa.
    final k = Float64List(n);
    {
      double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
      const b0 = 1.53512485958697,
          b1 = -2.69169618940638,
          b2 = 1.19839281085285;
      const a1 = -1.69065929318241, a2 = 0.73248077421585;
      double u1 = 0, u2 = 0, v1 = 0, v2 = 0;
      const c1 = -1.99004745483398, c2 = 0.99007225036621;
      for (int i = 0; i < n; i++) {
        final x = samples[i];
        final y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = x;
        y2 = y1;
        y1 = y;
        final z = y - 2 * u1 + u2 - c1 * v1 - c2 * v2;
        u2 = u1;
        u1 = y;
        v2 = v1;
        v1 = z;
        k[i] = z;
      }
    }
    final blk = (_sr * 0.4).round();
    final blocks = <double>[];
    for (int s = 0; s + blk <= n; s += blk ~/ 4) {
      double e = 0;
      for (int i = s; i < s + blk; i++) {
        e += k[i] * k[i];
      }
      blocks.add(e / blk);
    }
    final abs = blocks.where((e) => e > 1.2e-7).toList(); // ~ -70 LUFS
    if (abs.isEmpty) return AdaptiveProfile(List<double>.filled(10, 0), 0);
    final m1 = abs.reduce((a, c) => a + c) / abs.length;
    final rel = abs.where((e) => e > m1 * 0.1).toList(); // -10 LU
    final m2 =
        (rel.isEmpty ? abs : rel).reduce((a, c) => a + c) /
        (rel.isEmpty ? abs.length : rel.length);
    final lufs = -0.691 + 10 * log(m2) / ln10;
    final peakDb = 20 * log(peak) / ln10;
    // Sube/baja hacia el objetivo, nunca más allá del pico medido (-1.5 dB
    // de margen: no hay limitador) ni más de +9 / -12 dB.
    final double level = soundCheckGainDb(
      lufs: lufs,
      peakDb: peakDb,
      lufsDone: lufsDone,
    );

    // ---- Espectro por bandas octava (FFT 4096, Hann, ~1 trama/0.5 s)
    final win = List<double>.generate(
      fft,
      (i) => 0.5 - 0.5 * cos(2 * pi * i / (fft - 1)),
    );
    final acc = Float64List(fft ~/ 2);
    int frames = 0;
    final re = Float64List(fft);
    final im = Float64List(fft);
    for (int s = 0; s + fft <= n; s += 22050) {
      for (int i = 0; i < fft; i++) {
        re[i] = samples[s + i] * win[i];
        im[i] = 0;
      }
      _fft(re, im);
      for (int i = 1; i < fft ~/ 2; i++) {
        acc[i] += re[i] * re[i] + im[i] * im[i];
      }
      frames++;
    }
    if (frames == 0) return AdaptiveProfile(List<double>.filled(10, 0), level);
    final binHz = _sr / fft;
    final lv = List<double>.filled(10, -120);
    for (int bI = 0; bI < 10; bI++) {
      final int lo = (bands[bI] / sqrt2 / binHz)
          .floor()
          .clamp(1, fft ~/ 2 - 1)
          .toInt();
      final int hi = (bands[bI] * sqrt2 / binHz)
          .ceil()
          .clamp(lo + 1, fft ~/ 2)
          .toInt();
      double e = 0;
      for (int i = lo; i < hi; i++) {
        e += acc[i];
      }
      e /= frames;
      lv[bI] = 10 * log(e + 1e-12) / ln10;
    }
    double m = 0;
    for (int i = 2; i <= 7; i++) {
      m += lv[i] - _target[i];
    }
    m /= 6;
    final out = List<double>.filled(10, 0);
    for (int i = 0; i < 10; i++) {
      final d = lv[i] - _target[i] - m;
      double c = -0.5 * d;
      if ((i >= 8 || i == 0) && d < -12) c = 0; // banda vacía: no se realza
      double hiLim = 3.0;
      if (i == 0) hiLim = 1.0;
      if (i == 8) hiLim = 2.0;
      if (i == 9) hiLim = 0.0;
      c = c.clamp(-3.0, hiLim).toDouble();
      out[i] = (c * 10).round() / 10;
    }
    return AdaptiveProfile(out, (level * 100).round() / 100);
  }

  static void _fft(Float64List re, Float64List im) {
    final n = re.length;
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (int len = 2; len <= n; len <<= 1) {
      final ang = -2 * pi / len;
      final wr = cos(ang);
      final wi = sin(ang);
      for (int i = 0; i < n; i += len) {
        double cr = 1, ci = 0;
        for (int k = 0; k < len ~/ 2; k++) {
          final ur = re[i + k];
          final ui = im[i + k];
          final vr = re[i + k + len ~/ 2] * cr - im[i + k + len ~/ 2] * ci;
          final vi = re[i + k + len ~/ 2] * ci + im[i + k + len ~/ 2] * cr;
          re[i + k] = ur + vr;
          im[i + k] = ui + vi;
          re[i + k + len ~/ 2] = ur - vr;
          im[i + k + len ~/ 2] = ui - vi;
          final ncr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = ncr;
        }
      }
    }
  }
}
