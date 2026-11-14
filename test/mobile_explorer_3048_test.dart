import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/ui/mobile/music_picker_screen.dart';
import 'package:gatomix/ui/workspaces/livedj_workspace.dart';

class _FakeLiveDj extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

void main() {
  for (final Size size in <Size>[const Size(360, 800), const Size(800, 400)]) {
    testWidgets(
      'Live DJ móvil ${size.width.toInt()}x${size.height.toInt()}: sin columna vieja ni disco',
      (WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        debugLiveDjForceMobile = true;
        addTearDown(() => debugLiveDjForceMobile = null);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [liveDjProvider.overrideWith(_FakeLiveDj.new)],
            child: const MaterialApp(home: LiveDjWorkspace()),
          ),
        );
        await tester.pump();
        expect(find.byType(LiveDjFolderPanel), findsNothing);
        expect(find.text('Cargar Carpeta'), findsNothing);
        expect(find.byIcon(Icons.album), findsNothing);
        expect(find.text('+ Agregar canciones'), findsOneWidget);
      },
    );

    testWidgets(
      'hoja ${size.width.toInt()}x${size.height.toInt()}: tocar canción la encola',
      (WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final Directory dir = Directory.systemTemp.createTempSync('pick3048');
        addTearDown(() => dir.deleteSync(recursive: true));
        File('${dir.path}/Cancion.mp3').writeAsBytesSync(<int>[1]);
        final List<String> queued = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: MusicPickerScreen(
              rootPath: dir.path,
              queuePaths: const <String>[],
              onEnqueue: (File f) => queued.add(f.path),
              onUndo: (File f) => queued.remove(f.path),
              onPlayNext: (_) {},
              onMixFolder: (_) async {},
            ),
          ),
        );
        await tester.pump();
        // La lista recursiva corre en Isolate.run (v3.0.48): esperar en tiempo real.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        await tester.pump();
        await tester.tap(find.text('Cancion'));
        await tester.pump();
        expect(queued.length, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
