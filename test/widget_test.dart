import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gatomix/main.dart';

// La app real arranca Rust, Isar y audio nativo; aquí solo se comprueba que
// main.dart compila y expone la raíz GatoMixApp (antes buscaba MyApp, que no existe).
void main() {
  test('main.dart expone GatoMixApp', () {
    expect(const GatoMixApp(), isA<Widget>());
  });
}
