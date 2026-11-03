import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/workspaces/lan_sync_workspace.dart';

void main() {
  test('móvil: raíz Música primero; escritorio sigue alfabético', () {
    final List<String> folders = <String>['Rock', 'Descargas'];
    final List<String> mobile = orderRemoteFolders(folders, mobile: true);
    expect(mobile.first, lanMusicRootToken);
    expect(lanRemoteLabel(mobile.first), 'Música (raíz)');
    expect(
      defaultRemoteSelection(folders, mobile: true),
      lanMusicRootToken,
    );
    final List<String> desktop = orderRemoteFolders(folders, mobile: false);
    expect(desktop.first, 'Descargas');
    expect(defaultRemoteSelection(folders, mobile: false), 'Descargas');
    expect(defaultRemoteSelection(<String>[], mobile: false), isNull);
  });

  test('contadores separados y códigos 403/500 solo en móvil', () {
    final LanJobCounts counts = LanJobCounts()
      ..add(lanClassifyStatus(200))
      ..add(lanClassifyStatus(200, alreadyThere: true))
      ..add(lanClassifyStatus(500))
      ..add(lanClassifyStatus(403));
    expect(counts.copied, 1);
    expect(counts.existed, 1);
    expect(counts.failed, 2);
    expect(
      lanFinalLog(
        mobile: true,
        copied: counts.copied,
        existed: counts.existed,
        failed: counts.failed,
        skippedMixed: 0,
      ),
      'Job Finalizado con 2 fallidos. Copiados: 1 | Ya existían: 1 | Fallidos: 2',
    );
    expect(lanFinalIsRed(mobile: true, failed: 2), isTrue);
    expect(
      lanFinalLog(
        mobile: false,
        copied: 1,
        existed: 0,
        failed: 0,
        skippedMixed: 2,
      ),
      '✅ Job Finalizado. Éxito: 1 | Saltados/Fallos: 2',
    );
    expect(
      lanUploadHttpStatus(mobile: true, denied: true, writeFailed: false),
      403,
    );
    expect(
      lanUploadHttpStatus(mobile: true, denied: false, writeFailed: true),
      500,
    );
    expect(
      lanUploadHttpStatus(mobile: false, denied: true, writeFailed: true),
      200,
    );
    expect(lanFailureNotice(403, 'a.mp3'), contains('almacenamiento'));
    expect(lanFailureNotice(500, 'a.mp3'), contains('escritura'));
  });

  test('send: 1 intento + 3 reintentos, backoff 1, 2 y 4 s', () async {
    var calls = 0;
    final List<Duration> waits = <Duration>[];
    await expectLater(
      lanSendWithRetry(
        () async {
          calls++;
          throw TimeoutException('t');
        },
        wait: (Duration d) async {
          waits.add(d);
        },
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(calls, 4);
    expect(waits, lanSendBackoff);
  });

  test('200 no reintenta; 403 no reintenta', () async {
    var ok = 0;
    final int code = await lanSendWithRetry(() async {
      ok++;
      return 200;
    }, wait: (_) async {});
    expect(code, 200);
    expect(ok, 1);

    var denied = 0;
    final int forbidden = await lanSendWithRetry(() async {
      denied++;
      return 403;
    }, wait: (_) async {});
    expect(forbidden, 403);
    expect(denied, 1);
  });

  test('móvil prefiere wlan; sin preferencia se queda la primera', () {
    final ifaces = <({String name, List<String> addresses})>[
      (name: 'rmnet0', addresses: <String>['10.0.0.2']),
      (name: 'wlan0', addresses: <String>['192.168.1.5']),
    ];
    expect(pickLanIpv4(ifaces, preferWlan: true), '192.168.1.5');
    expect(pickLanIpv4(ifaces, preferWlan: false), '10.0.0.2');
  });

  test('progreso móvil llega a 100% solo al terminar', () {
    expect(
      lanTransferProgress(
        mobile: true,
        completed: 3,
        total: 4,
        jobFinished: false,
        cancelled: false,
      ),
      0.75,
    );
    expect(
      lanTransferProgress(
        mobile: true,
        completed: 4,
        total: 4,
        jobFinished: true,
        cancelled: false,
      ),
      1,
    );
    expect(
      lanTransferProgress(
        mobile: false,
        completed: 0,
        total: 4,
        jobFinished: true,
        cancelled: true,
      ),
      1,
    );
  });
}
