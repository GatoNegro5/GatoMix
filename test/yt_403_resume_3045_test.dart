import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/yt_chunked_download.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

int _rangeStart(http.Request req) {
  final String? header = req.headers['range'] ?? req.headers['Range'];
  if (header != null) {
    return int.parse(header.split('=').last.split('-').first);
  }
  return int.parse(req.url.queryParameters['range']!.split('-').first);
}

void main() {
  test('403 en el 2º chunk cambia cliente, reanuda y completa', () async {
    final List<int> data = List<int>.generate(3000, (int i) => (i * 3) % 251);
    var host = 'old';
    final List<String> seen = <String>[];
    final MockClient mc = MockClient((http.Request req) async {
      final int from = _rangeStart(req);
      final int to = headerOrQueryEnd(req);
      seen.add('$host:$from');
      if (host == 'old' && from >= 1000) {
        return http.Response('', 403);
      }
      return http.Response.bytes(data.sublist(from, to + 1), 206);
    });
    var switches = 0;
    final Directory dir = await Directory.systemTemp.createTemp('yt403');
    final String out = '${dir.path}/a.m4a';
    await ytChunkedDownload(
      url: Uri.parse('https://old/v?c=ANDROID'),
      totalBytes: data.length,
      outPath: out,
      chunkSize: 1000,
      parallel: 1,
      client: mc,
      refreshUrl: () async {
        switches++;
        host = 'new';
        return Uri.parse('https://new/v?c=IOS');
      },
    );
    expect(switches, 1);
    expect(File(out).readAsBytesSync(), data);
    expect(seen, contains('old:0'));
    expect(seen, contains('old:1000'));
    expect(seen, contains('new:1000'));
    expect(seen.where((String s) => s == 'new:0'), isEmpty);
    expect(seen, contains('new:2000'));
  });

  test('tras 3 clientes el 403 se muestra', () async {
    var switches = 0;
    final MockClient mc = MockClient((http.Request req) async {
      return http.Response('', 403);
    });
    final Directory dir = await Directory.systemTemp.createTemp('yt403cap');
    await expectLater(
      ytChunkedDownload(
        url: Uri.parse('https://x/v?c=ANDROID'),
        totalBytes: 2000,
        outPath: '${dir.path}/o',
        chunkSize: 1000,
        parallel: 1,
        maxRefreshes: 3,
        client: mc,
        refreshUrl: () async {
          switches++;
          return Uri.parse('https://x/v?c=ANDROID&n=$switches');
        },
      ),
      throwsA(
        isA<YtDownloadStalled>().having(
          (YtDownloadStalled e) => e.toString(),
          'mensaje',
          contains('HTTP 403'),
        ),
      ),
    );
    expect(switches, 3);
  });
}

int headerOrQueryEnd(http.Request req) {
  final String? header = req.headers['range'] ?? req.headers['Range'];
  final String raw = header != null
      ? header.split('=').last
      : req.url.queryParameters['range']!;
  return int.parse(raw.split('-').last);
}
