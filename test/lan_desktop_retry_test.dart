import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gatomix/ui/workspaces/lan_sync_workspace.dart';

void main() {
  late Directory tmp;
  late String path;
  final Uri uri = Uri.parse('http://192.168.1.5:55055/api/upload?dir=ROOT');
  final List<Duration> waits = <Duration>[];
  Future<void> noWait(Duration d) async => waits.add(d);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('lan3107');
    path = '${tmp.path}${Platform.pathSeparator}Song_K.mp3';
    File(path).writeAsBytesSync(List<int>.filled(2048, 7));
    waits.clear();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('3.1.07: microcorte y luego 200 = exito en 2 intentos', () async {
    int calls = 0;
    final MockClient client = MockClient((http.Request r) async {
      calls++;
      if (calls == 1) throw const SocketException('microcorte Wi-Fi');
      expect(r.method, 'POST');
      expect(r.bodyBytes.length, greaterThan(2048)); // multipart rehecho
      return http.Response('ok', 200);
    });
    final int code = await lanSendWithRetry(
      () => lanUploadOnce(client, uri, path),
      wait: noWait,
    );
    expect(code, 200);
    expect(calls, 2);
    expect(waits, <Duration>[const Duration(seconds: 1)]);
  });

  test('3.1.07: 500 cuatro veces = fallo final tras 4 intentos', () async {
    int calls = 0;
    final MockClient client = MockClient((http.Request r) async {
      calls++;
      return http.Response('err', 500);
    });
    final int code = await lanSendWithRetry(
      () => lanUploadOnce(client, uri, path),
      wait: noWait,
    );
    expect(code, 500);
    expect(calls, 4);
    expect(waits, lanSendBackoff);
  });

  test('3.1.07: 403 no se reintenta', () async {
    int calls = 0;
    final MockClient client = MockClient((http.Request r) async {
      calls++;
      return http.Response('no', 403);
    });
    final int code = await lanSendWithRetry(
      () => lanUploadOnce(client, uri, path),
      wait: noWait,
    );
    expect(code, 403);
    expect(calls, 1);
  });

  test('3.1.07: red caida en los 4 intentos = excepcion (cuenta 1 fallo)', () async {
    int calls = 0;
    final MockClient client = MockClient((http.Request r) async {
      calls++;
      throw const SocketException('sin red');
    });
    await expectLater(
      lanSendWithRetry(() => lanUploadOnce(client, uri, path), wait: noWait),
      throwsA(isA<SocketException>()),
    );
    expect(calls, 4);
  });
}
