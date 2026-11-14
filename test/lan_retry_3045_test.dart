import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lan_sync_plan.dart';
import 'package:gatomix/ui/workspaces/lan_sync_workspace.dart';

void main() {
  test(
    '3.1.36 DESTINO: raiz de Musica primero en las 4 plataformas, sin auxiliares',
    () {
      final List<String> folders = <String>[
        'Rock',
        'Descargas',
        'DjPlaylists',
        'DjPlaylists/2026',
        'djstudio_LAB',
        'GatoMix_LAB',
        'GatoMix_LAB/x',
        'ReGenial',
        'ReGenial/Salsa',
      ];
      for (final bool m in <bool>[true, false]) {
        final List<String> d = orderRemoteFolders(folders, mobile: m);
        expect(d, <String>[
          lanMusicRootToken,
          'ReGenial',
          'ReGenial/Salsa',
          'Rock',
        ]);
        expect(defaultRemoteSelection(folders, mobile: m), lanMusicRootToken);
        expect(
          defaultRemoteSelection(<String>[], mobile: m),
          lanMusicRootToken,
        );
        expect(
          withMusicRootFirst(<String>['Descargas', 'Rock'], mobile: m),
          <String>[lanMusicRootToken, 'Rock'],
        );
      }
      expect(lanRemoteLabel(lanMusicRootToken), 'Música (raíz)');
    },
  );

  test('3.1.36 espejo desde la raiz de Musica (Windows y movil)', () {
    expect(
      lanMirrorFolder(
        musicBase: r'C:\Users\ASUS\Music',
        selectedPath: r'C:\Users\ASUS\Music\ReGenial\Salsa',
        filePath: r'C:\Users\ASUS\Music\ReGenial\Salsa\a.mp3',
      ),
      'ReGenial/Salsa',
    );
    expect(
      lanMirrorFolder(
        musicBase: r'C:\Users\ASUS\Music',
        selectedPath: r'C:\Users\ASUS\Music\ReGenial',
        filePath: r'C:\Users\ASUS\Music\ReGenial\Merengue\b.mp3',
      ),
      'ReGenial/Merengue',
    );
    expect(
      lanMirrorFolder(
        musicBase: '/storage/emulated/0/Music',
        selectedPath: '/storage/emulated/0/Music/ReGenial',
        filePath: '/storage/emulated/0/Music/ReGenial/c.mp3',
      ),
      'ReGenial',
    );
    expect(
      lanMirrorFolder(
        musicBase: r'C:\Users\ASUS\Music',
        selectedPath: r'D:\Mixes',
        filePath: r'D:\Mixes\Live\d.mp3',
      ),
      'Mixes/Live',
    );
  });

  test(
    '3.1.37 ORIGEN = raiz de Musica: espejo sin Music/ extra y sin auxiliares',
    () {
      const String base = r'C:\Users\ASUS\Music';
      expect(
        lanMirrorFolder(
          musicBase: base,
          selectedPath: base,
          filePath: r'C:\Users\ASUS\Music\ReGenial\Salsa\a.mp3',
        ),
        'ReGenial/Salsa',
      );
      expect(
        lanMirrorFolder(
          musicBase: base,
          selectedPath: base,
          filePath: r'C:\Users\ASUS\Music\suelta.mp3',
        ),
        '',
      );
      bool skip(String sel, String f) =>
          lanSkipOnClone(musicBase: base, selectedPath: sel, filePath: f);
      expect(skip(base, r'C:\Users\ASUS\Music\Descargas\x.mp3'), isTrue);
      expect(skip(base, r'C:\Users\ASUS\Music\DjPlaylists\l.txt'), isTrue);
      expect(skip(base, r'C:\Users\ASUS\Music\GatoMix_LAB\r\m.mp3'), isTrue);
      expect(skip(base, r'C:\Users\ASUS\Music\djstudio_lab\m.mp3'), isTrue);
      expect(skip(base, r'C:\Users\ASUS\Music\.cache\m.mp3'), isTrue);
      expect(skip(base, r'C:\Users\ASUS\Music\ReGenial\Salsa\a.mp3'), isFalse);
      expect(skip(base, r'C:\Users\ASUS\Music\suelta.mp3'), isFalse);
      // Una carpeta elegida a proposito no se filtra.
      expect(
        skip(
          r'C:\Users\ASUS\Music\Descargas',
          r'C:\Users\ASUS\Music\Descargas\x.mp3',
        ),
        isFalse,
      );
      // WIPE desde la raiz: carpeta vacia, el servidor no borra nada.
      expect(lanWipeTarget(lanRelUnder(base, base)), isNull);
    },
  );

  test('3.1.36 blindaje: .., ReGenial y WIPE solo de la carpeta clonada', () {
    expect(lanUnsafeRel('ROOT/../Windows'), isTrue);
    expect(lanUnsafeRel(r'ReGenial\..\..\x'), isTrue);
    expect(lanUnsafeRel('/etc'), isTrue);
    expect(lanUnsafeRel(r'C:\x'), isTrue);
    expect(lanUnsafeRel('ROOT/ReGenial/Salsa'), isFalse);
    expect(lanUnderReGenial('ROOT/regenial/Salsa/a.mp3'), isTrue);
    expect(lanUnderReGenial('/ReGenial/Salsa'), isTrue);
    expect(lanUnderReGenial('ROOT/Rock'), isFalse);
    expect(lanWipeTarget('ReGenial'), 'ReGenial');
    expect(lanWipeTarget('ROOT/ReGenial/Salsa'), 'ReGenial/Salsa');
    expect(lanWipeTarget(null), isNull);
    expect(lanWipeTarget(''), isNull);
    expect(lanWipeTarget('ROOT'), isNull);
    expect(lanWipeTarget('DjPlaylists'), isNull);
    expect(lanWipeTarget('Descargas/x'), isNull);
    expect(lanWipeTarget('GatoMix_LAB'), isNull);
    expect(lanWipeTarget('../x'), isNull);
    expect(lanWipeTarget('.gatomix.json'), isNull);
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
