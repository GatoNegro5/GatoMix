import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/analysis_window.dart';

void main() {
  test('3.1.09: toda pista con duracion conocida se mide', () {
    expect(canAnalyzeFull(3715000), isTrue); // Mix Salsa Romantica 61:55
    expect(canAnalyzeFull(1221336), isTrue); // Mix Shakira 20:21
    expect(canAnalyzeFull(343235), isTrue); // Lloraras 5:43
    expect(canAnalyzeFull(0), isFalse);
    // La ventana de 3.1.04 no cambia (Se elimina: NADA).
    expect(fitsAnalysisWindow(900000), isFalse);
  });

  test('3.1.09: timeout proporcional, igual que antes debajo de 15 min', () {
    const Duration b90 = Duration(seconds: 90);
    expect(analysisTimeout(343235, b90), b90);
    expect(analysisTimeout(900000, b90), b90);
    expect(analysisTimeout(900001, b90), b90 * 2);
    expect(analysisTimeout(3715000, b90), b90 * 5);
    expect(analysisTimeout(3715000, const Duration(seconds: 120)),
        const Duration(seconds: 600));
  });

  test('3.1.09: el cache re-escanea los megamixes sin BPM', () {
    expect(needsBpmScan(storedTimestamp: null, modified: 5, hasCachedBpm: false), isTrue);
    expect(needsBpmScan(storedTimestamp: 4, modified: 5, hasCachedBpm: true), isTrue);
    expect(needsBpmScan(storedTimestamp: 5, modified: 5, hasCachedBpm: false), isTrue);
    expect(needsBpmScan(storedTimestamp: 5, modified: 5, hasCachedBpm: true), isFalse);
  });
}
