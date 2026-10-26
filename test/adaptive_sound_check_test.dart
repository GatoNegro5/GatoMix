import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/services/adaptive_eq.dart';

Uint8List _sine(double amp, int secs) {
  final int n = 44100 * secs;
  final ByteData bd = ByteData(n * 2);
  for (int i = 0; i < n; i++) {
    bd.setInt16(
      i * 2,
      (amp * 32767 * sin(2 * pi * 1000 * i / 44100)).round(),
      Endian.little,
    );
  }
  return bd.buffer.asUint8List();
}

void main() {
  group('1.0.19 Sound Check', () {
    test('objetivo −14 LUFS', () {
      expect(AdaptiveEq.targetLufs, -14.0);
      expect(AdaptiveEq.soundCheckGainDb(lufs: -10, peakDb: -0.1), -4.0);
    });
    test('ya masterizada (GMX_LUFS_DONE) cerca de −14: ganancia 0', () {
      expect(
        AdaptiveEq.soundCheckGainDb(lufs: -14.6, peakDb: -1, lufsDone: true),
        0,
      );
    });
    test('canción baja sube sin pasar pico −1,5 dB', () {
      expect(AdaptiveEq.soundCheckGainDb(lufs: -24, peakDb: -6), 4.5);
      expect(AdaptiveEq.soundCheckGainDb(lufs: -40, peakDb: -30), 9.0);
    });
    test('sonoridad integrada de toda la pista, no de un tramo', () {
      final (List<double>, double) loud = AdaptiveEq.loudnessBlocks(
        _sine(0.5, 3),
      );
      final (List<double>, double) soft = AdaptiveEq.loudnessBlocks(
        _sine(0.05, 3),
      );
      final double l = AdaptiveEq.gatedLufs(loud.$1)!;
      final double s = AdaptiveEq.gatedLufs(soft.$1)!;
      expect(l - s, closeTo(20, 0.5));
      final double all = AdaptiveEq.gatedLufs(<double>[
        ...loud.$1,
        ...soft.$1,
      ])!;
      expect(all, closeTo(l, 0.5)); // compuerta relativa −10 LU
      expect(AdaptiveEq.gatedLufs(<double>[]), isNull);
    });
  });
}
