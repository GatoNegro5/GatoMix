import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/analysis_window.dart';

void main() {
  test('3.1.04: ventana por duracion exacta (datos reales Paso 0)', () {
    expect(fitsAnalysisWindow(782087), isTrue); // Earth, Wind & Fire 13:02
    expect(fitsAnalysisWindow(863591), isTrue); // Mix De Locura 14:24
    expect(fitsAnalysisWindow(1221336), isFalse); // Mix Shakira 20:21
    expect(fitsAnalysisWindow(899999), isTrue);
    expect(fitsAnalysisWindow(900000), isFalse);
    expect(fitsAnalysisWindow(0), isFalse);
  });
}
