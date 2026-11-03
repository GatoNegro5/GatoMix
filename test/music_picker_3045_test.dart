import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/mobile/music_picker_screen.dart';

void main() {
  testWidgets('oculta _K, muestra micrófono con lrc y el tap encola', (
    WidgetTester tester,
  ) async {
    final Directory dir = await Directory.systemTemp.createTemp('picker3045');
    File('${dir.path}/Cancion.mp3').writeAsBytesSync(<int>[1, 2, 3]);
    File('${dir.path}/Cancion.lrc').writeAsStringSync('[00:00.00] hola');
    File('${dir.path}/Otra_K.mp3').writeAsBytesSync(<int>[9]);
    final List<String> queued = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MusicPickerScreen(
          rootPath: dir.path,
          queuePaths: const <String>[],
          onEnqueue: (File file) => queued.add(file.path),
          onUndo: (_) {},
          onPlayNext: (_) {},
          onAddFolder: (_) {},
          onMixFolder: (_) async {},
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('_K'), findsNothing);
    expect(find.text('🎤'), findsOneWidget);
    expect(find.text('Cancion'), findsOneWidget);
    await tester.tap(find.text('Cancion'));
    await tester.pump();
    expect(queued, hasLength(1));
    expect(queued.single, endsWith('Cancion.mp3'));
    expect(find.text('Deshacer'), findsWidgets);
    await dir.delete(recursive: true);
  });
}
