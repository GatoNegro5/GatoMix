import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_radio.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/core/queue_bpm.dart';
import 'package:gatomix/core/session_store.dart';

void main() {
  test(
    'un segundo de ticks no relee el JSON, no rearma y no repinta de más',
    () {
      final Directory dir = Directory.systemTemp.createTempSync(
        'gatomix_tick_',
      );
      final String sep = Platform.pathSeparator;
      final String path = '${dir.path}${sep}Lime - You Love.mp3';
      File(
        '${dir.path}$sep.gatomix.json',
      ).writeAsStringSync('{"schema":1,"djMetadata":{"$path":128}}');
      final int before = GatomixStore.debugDiskReads;
      for (var i = 0; i < 60; i++) {
        expect(knownBpm(path), 128);
      }
      expect(GatomixStore.debugDiskReads - before, lessThanOrEqualTo(2));
      final int mid = GatomixStore.debugDiskReads;
      for (var i = 0; i < 60; i++) {
        expect(knownBpm(path), 128);
        expect(readStoredCamelot(path), isNull);
      }
      expect(GatomixStore.debugDiskReads, mid);

      var lastUi = -1;
      var paints = 0;
      var lastSave = 4000;
      var saves = 0;
      var assemble = 0;
      var inFlight = false;
      const bool planOpen = false;
      for (var i = 0; i < 60; i++) {
        final int pos = i.isOdd ? 0 : 4000 + i * 16;
        if (uiPositionShouldPublish(pos, lastUi)) {
          paints++;
          lastUi = pos;
        }
        if (sessionPositionShouldSave(pos, lastSave)) {
          saves++;
          lastSave = pos;
        }
        // Igual que el provider: el futuro sigue vivo todo el segundo.
        if (radioAssembleShouldStart(inFlight: inFlight, planOpen: planOpen)) {
          assemble++;
          inFlight = true;
        }
      }
      expect(paints, lessThanOrEqualTo(4));
      expect(saves, 0);
      expect(assemble, 1);
      expect(
        radioAssembleShouldStart(inFlight: true, planOpen: false),
        isFalse,
      );
      expect(
        radioAssembleShouldStart(inFlight: false, planOpen: true),
        isFalse,
      );
      // La lista terminada pide otra vuelta, una sola.
      expect(
        radioAssembleShouldStart(inFlight: false, planOpen: false),
        isTrue,
      );
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    },
  );

  test('el reloj avanza y un glitch a 0 no publica', () {
    expect(uiPositionShouldPublish(0, -1), isTrue);
    expect(uiPositionShouldPublish(0, 8000), isFalse);
    expect(uiPositionShouldPublish(8200, 8000), isFalse);
    expect(uiPositionShouldPublish(8300, 8000), isTrue);
    var last = 1000;
    var n = 0;
    for (var ms = 1000; ms < 2000; ms += 16) {
      if (uiPositionShouldPublish(ms, last)) {
        n++;
        last = ms;
      }
    }
    expect(n, lessThanOrEqualTo(5));
    expect(n, greaterThanOrEqualTo(3));
  });
}
