import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/services/karaoke_engine.dart';

void main() {
  test('capBytes = 1800 s a 320 kbps', () {
    expect(KaraokeEngine.capBytes, 72000000);
    expect(KaraokeEngine.capMs, 1800000);
  });

  test('solo los _K que llegan al tope pagan medicion', () {
    expect(KaraokeEngine.needsDurationCheck(71999999), isFalse);
    expect(KaraokeEngine.needsDurationCheck(72002872), isTrue);
    expect(KaraokeEngine.needsDurationCheck(72075923), isTrue);
  });

  test('3.1.16: _K truncado en 30:00 de un megamix: se vuelve a separar', () {
    expect(KaraokeEngine.karaokeNeedsWork(srcMs: 2400000, kMs: 1800045),
        KaraokeWork.queue);
  });

  test('3.1.16: fuente >30 min sin _K: se separa (streaming)', () {
    expect(KaraokeEngine.karaokeNeedsWork(srcMs: 1800000), KaraokeWork.queue);
    expect(KaraokeEngine.karaokeNeedsWork(srcMs: 3720000), KaraokeWork.queue);
  });

  test('3.1.16: timeout 3x la duracion, minimo 10 min, 60 min sin duracion', () {
    expect(KaraokeEngine.karaokeTimeout(null), const Duration(minutes: 60));
    expect(KaraokeEngine.karaokeTimeout(120000), const Duration(minutes: 10));
    expect(KaraokeEngine.karaokeTimeout(3720000), const Duration(minutes: 186));
  });

  test('_K completo (dentro de la tolerancia de LAME): listo', () {
    expect(KaraokeEngine.karaokeNeedsWork(srcMs: 1850000, kMs: 1849500),
        KaraokeWork.done);
  });

  test('fuente <30 min: se separa', () {
    expect(KaraokeEngine.karaokeNeedsWork(srcMs: 1799999), KaraokeWork.queue);
    expect(KaraokeEngine.karaokeNeedsWork(srcMs: 300000, kMs: 120000),
        KaraokeWork.queue);
  });

  test('duracion no medida: se encola y decide Rust', () {
    expect(KaraokeEngine.karaokeNeedsWork(), KaraokeWork.queue);
  });
}