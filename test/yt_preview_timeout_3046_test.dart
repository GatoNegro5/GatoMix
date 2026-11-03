import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/workspaces/yt_workspace.dart';

void main() {
  test('el tope de la vista previa móvil es 15 s', () {
    expect(ytPreviewTimeout, const Duration(seconds: 15));
  });

  test('un timeout de vista previa deja el motivo en la barra', () async {
    Object? caught;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 80)).timeout(
        const Duration(milliseconds: 15),
      );
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<TimeoutException>());
    final String text = ytPreviewFailureText(caught!);
    expect(text, startsWith('No se pudo cargar la vista previa:'));
    expect(text, contains('TimeoutException'));
  });
}
