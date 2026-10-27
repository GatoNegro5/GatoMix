import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/yt_chunked_download.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('rangos cubren todo sin huecos', () {
    final r = ytChunkRanges(2500, 1000);
    expect(r, [
      [0, 999],
      [1000, 1999],
      [2000, 2499],
    ]);
  });
  test('Range header para ANDROID, range= para otros', () {
    final a = ytRangeRequest(Uri.parse('https://x/v?c=ANDROID'), 0, 9);
    expect(a.headers['Range'], 'bytes=0-9');
    final w = ytRangeRequest(Uri.parse('https://x/v?c=WEB'), 0, 9);
    expect(w.url.queryParameters['range'], '0-9');
  });
  test('descarga en paralelo, reintenta fallos y arma el archivo', () async {
    final data = List<int>.generate(5000, (i) => i % 251);
    var fails = 1;
    final client = MockClient((req) async {
      final r = req.url.queryParameters['range']!
          .split('-')
          .map(int.parse)
          .toList();
      if (r[0] == 2048 && fails-- > 0) return http.Response('', 500);
      return http.Response.bytes(data.sublist(r[0], r[1] + 1), 206);
    });
    final out = '${Directory.systemTemp.path}/ytchunk_test.bin';
    var last = 0;
    await ytChunkedDownload(
      url: Uri.parse('https://x/v?c=WEB'),
      totalBytes: data.length,
      outPath: out,
      chunkSize: 1024,
      client: client,
      onProgress: (d, t) => last = d,
    );
    expect(File(out).readAsBytesSync(), data);
    expect(last, data.length);
  });

  test('403 persistente: tope de refrescos, sin bucle infinito', () async {
    var refreshes = 0;
    final mc = MockClient((r) async => http.Response('', 403));
    final dir = await Directory.systemTemp.createTemp();
    await expectLater(
      ytChunkedDownload(
        url: Uri.parse('https://x/v?c=ANDROID'),
        totalBytes: 3000,
        outPath: '${dir.path}/o',
        chunkSize: 1000,
        client: mc,
        refreshUrl: () async {
          refreshes++;
          return Uri.parse('https://x/v?c=ANDROID&n=$refreshes');
        },
      ),
      throwsA(isA<YtDownloadStalled>()),
    );
    expect(refreshes, lessThanOrEqualTo(4));
  });

  test('rate limit se detecta', () {
    expect(ytIsRateLimit(Exception('RequestLimitExceeded: too many')), isTrue);
    expect(ytIsRateLimit(Exception('HTTP 500')), isFalse);
  });
}
