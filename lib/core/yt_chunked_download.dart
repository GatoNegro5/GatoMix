// Descarga por trozos (Range) en paralelo para Descargas YT en móvil.
//
// Motivo (1.0.14): youtube_explode_dart pide el audio en UNA sola petición
// (hasta ~10 MB) y YouTube estrangula esas peticiones largas a velocidad de
// reproducción o peor; además el stream no tiene timeout ni progreso, así
// que en Android se quedaba >10 min en "Descargando stream crudo...".
// yt-dlp (Windows/macOS) baja por trozos pequeños, por eso allí es rápido.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Rangos [inicio, fin] inclusivos de tamaño [chunk] para [total] bytes.
List<List<int>> ytChunkRanges(int total, int chunk) {
  final out = <List<int>>[];
  for (var s = 0; s < total; s += chunk) {
    final e = (s + chunk > total ? total : s + chunk) - 1;
    out.add([s, e]);
  }
  return out;
}

/// Pide un rango igual que yt-dlp: cabecera Range para clientes ANDROID,
/// parámetro `range=` para el resto.
const _ytAndroidUa =
    'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
const _ytWebUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/96.0.4664.18 Safari/537.36';

http.Request ytRangeRequest(Uri url, int from, int to) {
  final android =
      url.queryParameters['c']?.toUpperCase().startsWith('ANDROID') ?? false;
  final http.Request req;
  if (android) {
    req = http.Request('GET', url)..headers['Range'] = 'bytes=$from-$to';
  } else {
    final q = Map<String, String>.from(url.queryParameters)
      ..['range'] = '$from-$to';
    req = http.Request('GET', url.replace(queryParameters: q));
  }
  req.headers['User-Agent'] = android ? _ytAndroidUa : _ytWebUa;
  return req;
}

class YtDownloadStalled implements Exception {
  final String msg;
  YtDownloadStalled(this.msg);
  @override
  String toString() => msg;
}

/// Baja [totalBytes] de [url] a [outPath] en trozos de [chunkSize] con
/// [parallel] conexiones, timeout por trozo y reintentos. [refreshUrl] se
/// llama tras un 403/410 para pedir una URL nueva al manifiesto.
Future<void> ytChunkedDownload({
  required Uri url,
  required int totalBytes,
  required String outPath,
  int chunkSize = 1024 * 1024,
  int parallel = 2,
  int retries = 3,
  int maxRefreshes = 4,
  Duration chunkTimeout = const Duration(seconds: 25),
  Future<Uri?> Function()? refreshUrl,
  void Function(int done, int total)? onProgress,
  http.Client? client,
  Duration deadline = const Duration(minutes: 3),
}) async {
  final clock = Stopwatch()..start();
  final c = client ?? http.Client();
  var current = url;
  final ranges = ytChunkRanges(totalBytes, chunkSize);
  final parts = List<Uint8List?>.filled(ranges.length, null);
  var next = 0;
  var done = 0;
  var refreshes = 0;
  Future<Uri?>? pendingRefresh;

  Future<Uint8List> fetch(int from, int to) async {
    Object? last;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (clock.elapsed > deadline) {
        throw YtDownloadStalled(
            'YouTube no entrega el audio en móvil (tiempo agotado). Prueba otro resultado.');
      }
      try {
        final resp = await c
            .send(ytRangeRequest(current, from, to))
            .timeout(chunkTimeout);
        if (resp.statusCode == 403 || resp.statusCode == 410) {
          await resp.stream.drain<void>();
          if (refreshUrl == null || refreshes >= maxRefreshes) {
            throw YtDownloadStalled(
                'YouTube rechazó la descarga en móvil (HTTP ${resp.statusCode}). Reintenta en unos minutos.');
          }
          final mine = current;
          // Un solo refresco compartido entre conexiones paralelas.
          pendingRefresh ??= (() async {
            refreshes++;
            try {
              return await refreshUrl();
            } finally {
              pendingRefresh = null;
            }
          })();
          final u = await pendingRefresh;
          if (u != null && identical(mine, current)) current = u;
          throw HttpException('HTTP ${resp.statusCode}');
        }
        if (resp.statusCode != 200 && resp.statusCode != 206) {
          await resp.stream.drain<void>();
          throw HttpException('HTTP ${resp.statusCode}');
        }
        final b = BytesBuilder(copy: false);
        await for (final d in resp.stream.timeout(chunkTimeout)) {
          b.add(d);
        }
        final bytes = b.takeBytes();
        if (bytes.length != to - from + 1) {
          throw HttpException(
              'trozo incompleto ${bytes.length}/${to - from + 1}');
        }
        return bytes;
      } on YtDownloadStalled {
        rethrow;
      } catch (e) {
        if (ytIsRateLimit(e)) throw YtDownloadStalled(ytRateLimitMsg);
        last = e;
        // Backoff exponencial: 1 s, 2 s, 4 s...
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
    throw YtDownloadStalled('No se pudo bajar el trozo $from-$to: $last');
  }

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= ranges.length) return;
      parts[i] = await fetch(ranges[i][0], ranges[i][1]);
      done += parts[i]!.length;
      onProgress?.call(done, totalBytes);
    }
  }

  try {
    await Future.wait(List.generate(
        parallel < ranges.length ? parallel : ranges.length, (_) => worker()));
    final sink = File(outPath).openWrite();
    for (final p in parts) {
      sink.add(p!);
    }
    await sink.close();
  } finally {
    if (client == null) c.close();
  }
}


const ytRateLimitMsg =
    'YouTube limitó temporalmente las descargas desde esta red. Reintenta en unos minutos.';

/// Detecta el rate limit de YouTube (RequestLimitExceeded / HTTP 429).
bool ytIsRateLimit(Object e) {
  final t = e.toString();
  return t.contains('RequestLimitExceeded') ||
      t.contains('rate limit') ||
      t.contains('HTTP 429') ||
      t.contains('Too Many Requests');
}
