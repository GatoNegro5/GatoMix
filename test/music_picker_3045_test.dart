import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/mobile/music_picker_screen.dart';

// 3.1.24: la carpeta se lee en Isolate; espera a que no quede nada cargando.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 60; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.text('...').evaluate().isEmpty) {
      return;
    }
  }
}

void main() {
  final List<Size> sizes = <Size>[const Size(360, 800), const Size(800, 400)];

  for (final Size size in sizes) {
    testWidgets(
      'picker ${size.width.toInt()}x${size.height.toInt()}: tap, long-press, sin overflow',
      (WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final Directory dir = Directory.systemTemp.createTempSync('picker3045');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        File('${dir.path}/Cancion.mp3').writeAsBytesSync(<int>[1, 2, 3]);
        File('${dir.path}/Cancion.lrc').writeAsStringSync('[00:00.00] hola');
        File('${dir.path}/Otra_K.mp3').writeAsBytesSync(<int>[9]);
        final String longSong = 'Tema${'Largo' * 24}.mp3';
        File('${dir.path}/$longSong').writeAsBytesSync(<int>[4]);
        final String folderName = 'Carpeta${'Larga' * 24}';
        final Directory folder = Directory('${dir.path}/$folderName')
          ..createSync();
        File('${folder.path}/Interna.mp3').writeAsBytesSync(<int>[5]);

        final List<String> queued = <String>[];
        final List<String> next = <String>[];
        final List<int> mixed = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: MusicPickerScreen(
              rootPath: dir.path,
              queuePaths: const <String>[],
              onEnqueue: (File file) => queued.add(file.path),
              onUndo: (File file) => queued.remove(file.path),
              onPlayNext: (File file) => next.add(file.path),
              onAddFolder: (_) {},
              onMixFolder: (List<File> files) async {
                mixed.add(files.length);
              },
            ),
          ),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Buscar'), findsOneWidget);
        expect(find.text('Carpetas'), findsOneWidget);
        expect(find.text('Canciones'), findsOneWidget);
        expect(find.textContaining('toca para ver'), findsNothing);
        expect(find.text('▶ Mezclar'), findsNothing);
        expect(find.textContaining('_K'), findsNothing);
        expect(find.text(folderName), findsOneWidget);
        expect(find.text('1 canciones'), findsOneWidget);
        expect(find.text('Mezclar todo'), findsOneWidget);

        await tester.tap(find.text('Mezclar todo'));
        await tester.pump();
        expect(mixed, <int>[1]);
        expect(tester.takeException(), isNull);

        await tester.tap(find.text(folderName));
        await _settle(tester);
        expect(find.byIcon(Icons.arrow_back), findsOneWidget);
        expect(find.text('Interna'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byIcon(Icons.arrow_back));
        await _settle(tester);
        expect(find.text('Carpetas'), findsOneWidget);

        await tester.tap(find.text('Canciones'));
        await tester.pump();
        // 3.0.48: en la raíz la lista es recursiva y se calcula async.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('_K'), findsNothing);
        expect(find.text('🎤'), findsOneWidget);
        expect(find.text('Cancion'), findsOneWidget);
        expect(find.text(longSong.replaceAll('.mp3', '')), findsOneWidget);

        await tester.tap(find.text('Cancion'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 750));
        expect(queued, hasLength(1));
        expect(queued.single, endsWith('Cancion.mp3'));
        expect(find.text('Agregada a la cola'), findsOneWidget);
        expect(find.text('Deshacer'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('Deshacer'));
        await tester.pump();
        expect(queued, isEmpty);

        await tester.longPress(find.text('Cancion'));
        await tester.pump();
        expect(next, hasLength(1));
        expect(next.single, endsWith('Cancion.mp3'));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
