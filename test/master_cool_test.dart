import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/master_cool.dart';
import 'package:gatomix/core/master_profile.dart';

void main() {
  test('la pausa queda entre 10 y 15 s, con 12 de fábrica', () {
    expect(MasterCool.pauseDefaultMs, 12000);
    expect(MasterCool.clampPauseMs(12000), 12000);
    expect(MasterCool.clampPauseMs(2000), 10000);
    expect(MasterCool.clampPauseMs(30000), 15000);
    expect(MasterCool.clampPauseMs(10000), 10000);
    expect(MasterCool.clampPauseMs(15000), 15000);
  });

  test('móvil 1 hilo, escritorio 2, sin afinidad', () {
    expect(MasterCool.workerThreads('android'), 1);
    expect(MasterCool.workerThreads('ios'), 1);
    expect(MasterCool.workerThreads('windows'), 2);
    expect(MasterCool.workerThreads('macos'), 2);
    expect(MasterProfile.phone.workerThreads, 1);
    expect(MasterProfile.phone.parallel, 1);
    expect(MasterProfile.desktop().workerThreads, 2);
    expect(MasterProfile.desktop().parallel, 1);
    expect(MasterCool.priorityLabel('windows'), 'ecoqos+background');
    expect(MasterCool.priorityLabel('macos'), 'qos-utility');
    expect(MasterCool.priorityLabel('ios'), 'qos-utility');
    expect(MasterCool.priorityLabel('android'), 'nice10');
  });

  test('la barra dice Enfriando… Ns', () {
    expect(MasterCool.label(12000), 'Enfriando… 12s');
    expect(MasterCool.label(11000), 'Enfriando… 11s');
    expect(MasterCool.label(1001), 'Enfriando… 2s');
    expect(MasterCool.label(1), 'Enfriando… 1s');
    expect(MasterCool.label(0), 'Enfriando… 0s');
  });

  test('la X corta la pausa y el térmico alto la alarga', () {
    expect(
      MasterCool.simulate(
        baseMs: 12000,
        tickMs: 100,
        hotAt: (_) => false,
        cancelledAt: (_) => false,
      ),
      12000,
    );
    expect(
      MasterCool.simulate(
        baseMs: 12000,
        tickMs: 100,
        hotAt: (_) => false,
        cancelledAt: (int t) => t >= 500,
      ),
      500,
    );
    expect(
      MasterCool.simulate(
        baseMs: 2000,
        tickMs: 100,
        hotAt: (_) => false,
        cancelledAt: (_) => false,
      ),
      10000,
    );
    expect(
      MasterCool.simulate(
        baseMs: 30000,
        tickMs: 100,
        hotAt: (_) => false,
        cancelledAt: (_) => false,
      ),
      15000,
    );
    expect(
      MasterCool.simulate(
        baseMs: 12000,
        tickMs: 100,
        hotAt: (int t) => t < 15000,
        cancelledAt: (_) => false,
      ),
      15000,
    );
    expect(
      MasterCool.simulate(
        baseMs: 12000,
        tickMs: 100,
        hotAt: (_) => true,
        cancelledAt: (int t) => t >= 20000,
      ),
      20000,
    );
    expect(
      MasterCool.simulate(
        baseMs: 12000,
        tickMs: 100,
        hotAt: (_) => true,
        cancelledAt: (_) => false,
        allowThermal: false,
      ),
      12000,
    );
  });

  test('lote de 7: la 6.ª espera 12 s antes de empezar', () {
    final List<int> pausaAntes = [];
    final List<int> termicoAntes = [];
    const int total = 7;
    for (var i = 0; i < total - 1; i++) {
      final int siguiente = i + 2;
      if (MasterCool.pauseBeforeSong(siguiente)) pausaAntes.add(siguiente);
      if (MasterCool.thermalBeforeSong(siguiente)) termicoAntes.add(siguiente);
    }
    expect(pausaAntes, [6, 7]);
    expect(termicoAntes, isEmpty);

    final List<int> calor = [];
    for (var i = 0; i < 15; i++) {
      final int siguiente = i + 2;
      if (MasterCool.pauseBeforeSong(siguiente) &&
          MasterCool.thermalBeforeSong(siguiente)) {
        calor.add(siguiente);
      }
    }
    expect(calor, [15, 16]);
  });

  test('térmico alto: Android SEVERE o headroom, iOS serious', () {
    expect(MasterCool.thermalIsHigh(platform: 'android', status: 2), isFalse);
    expect(MasterCool.thermalIsHigh(platform: 'android', status: 3), isTrue);
    expect(MasterCool.thermalIsHigh(platform: 'ios', status: 1), isFalse);
    expect(MasterCool.thermalIsHigh(platform: 'ios', status: 2), isTrue);
    expect(MasterCool.thermalIsHigh(platform: 'macos', status: 3), isTrue);
    expect(MasterCool.thermalIsHigh(platform: 'windows', status: 5), isFalse);
    expect(
      MasterCool.thermalIsHigh(platform: 'android', status: null),
      isFalse,
    );
    expect(MasterCool.headroomIsHigh(0.7), isFalse);
    expect(MasterCool.headroomIsHigh(0.71), isTrue);
    expect(MasterCool.headroomIsHigh(double.nan), isFalse);
    expect(MasterCool.headroomIsHigh(null), isFalse);
    expect(
      MasterCool.shouldExtendPause(
        platform: 'android',
        status: 0,
        headroom: 0.8,
      ),
      isTrue,
    );
    expect(
      MasterCool.shouldExtendPause(
        platform: 'android',
        status: 3,
        headroom: 0.1,
      ),
      isTrue,
    );
    expect(
      MasterCool.shouldExtendPause(
        platform: 'android',
        status: 2,
        headroom: 0.7,
      ),
      isFalse,
    );
    expect(
      MasterCool.shouldExtendPause(
        platform: 'windows',
        status: 5,
        headroom: 0.99,
      ),
      isFalse,
    );
    expect(
      MasterCool.shouldExtendPause(platform: 'ios', status: 2, headroom: null),
      isTrue,
    );
    expect(MasterCool.thermalLabel(platform: 'windows'), 'n/a');
    expect(
      MasterCool.thermalLabel(platform: 'android', status: 3, headroom: 0.82),
      'status=severe headroom=0.82',
    );
    expect(MasterCool.thermalLabel(platform: 'ios', status: 2), 'serious');
    expect(MasterCool.thermalLabel(platform: 'macos', status: 3), 'critical');
  });
}
