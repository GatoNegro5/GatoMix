import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/mobile/music_picker_screen.dart';

// PNG valido de 1x1: la portada se puede decodificar sin error.
final List<int> _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// Arbol sintetico en %TEMP% (cero ReGenial): Salsa/{A.mp3, A.jpg, A.lrc,
/// Sub/B.mp3, Sub/C.m4a}, Merengue/D.mp3, Suelta.mp3 y .oculta/E.mp3.
Directory _tree() {
  final Directory root = Directory.systemTemp.createTempSync(
    'gatomix_picker_3124_',
  );
  void put(String rel, List<int> bytes) {
    File('${root.path}${Platform.pathSeparator}'
        '${rel.replaceAll('/', Platform.pathSeparator)}')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  put('Salsa/A.mp3', <int>[1]);
  put('Salsa/A.jpg', _png);
  put('Salsa/A.lrc', utf8.encode('[00:00.00] hola'));
  put('Salsa/Sub/B.mp3', <int>[2]);
  put('Salsa/Sub/C.m4a', <int>[3]);
  put('Merengue/D.mp3', <int>[4]);
  put('Suelta.mp3', <int>[5]);
  put('.oculta/E.mp3', <int>[6]);
  return root;
}

void _cleanup(Directory root) {
  try {
    if (root.existsSync()) root.deleteSync(recursive: true);
  } catch (_) {}
}

String _name(String path) => path.split(Platform.pathSeparator).last;

void _landscape(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

MusicPickerScreen _picker(
  Directory root, {
  required Future<void> Function(List<File> files) onMix,
}) {
  return MusicPickerScreen(
    rootPath: root.path,
    queuePaths: const <String>[],
    onEnqueue: (_) {},
    onUndo: (_) {},
    onPlayNext: (_) {},
    onMixFolder: onMix,
  );
}

/// La carpeta se lee en Isolate: espera a que no quede nada cargando.
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
  testWidgets('3124 carpetas, conteo recursivo y portada', (
    WidgetTester tester,
  ) async {
    _landscape(tester);
    final Directory root = _tree();
    addTearDown(() => _cleanup(root));

    final MusicPickerListing top = musicPickerReadFolder(root.path);
    expect(top.readable, isTrue);
    expect(top.folders.map(_name).toList(), <String>['Merengue', 'Salsa']);
    expect(top.songs.map(_name).toList(), <String>['Suelta.mp3']);

    final MusicPickerDeepScan deep = musicPickerDeepScan(root.path);
    final String salsa = top.folders[1];
    expect(deep.byFolder[salsa]!.map(_name).toList(), <String>[
      'A.mp3',
      'B.mp3',
      'C.m4a',
    ]);
    expect(deep.byFolder[top.folders[0]]!.map(_name).toList(), <String>[
      'D.mp3',
    ]);
    expect(deep.all, hasLength(5));
    final String a = deep.byFolder[salsa]!.first;
    expect(_name(deep.covers[a]!), 'A.jpg');
    expect(deep.covers.values.whereType<String>(), hasLength(1));
    expect(deep.lrc, <String>{a});

    await tester.pumpWidget(
      MaterialApp(home: _picker(root, onMix: (_) async {})),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('3 canciones'), findsOneWidget);
    expect(find.text('1 canciones'), findsOneWidget);
    expect(find.text('.oculta'), findsNothing);

    await tester.tap(find.text('Salsa'));
    await _settle(tester);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('\u{1F3A4}'), findsOneWidget);
    final Image image = tester.widget<Image>(find.byType(Image));
    expect(_name((image.image as FileImage).file.path), 'A.jpg');
    expect(tester.takeException(), isNull);
  });

  testWidgets('3124 build sin disco: 0 llamadas sincronas tras cargar', (
    WidgetTester tester,
  ) async {
    _landscape(tester);
    final Directory root = _tree();
    addTearDown(() => _cleanup(root));
    final ValueNotifier<bool> probe = ValueNotifier<bool>(false);
    addTearDown(probe.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: probe,
          builder: (BuildContext context, bool on, Widget? child) {
            // Control positivo: el conteo si ve lo que se construye en build.
            if (on) File('${root.path}${Platform.pathSeparator}sonda.txt');
            return child!;
          },
          child: _picker(root, onMix: (_) async {}),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('3 canciones'), findsOneWidget);

    int calls = 0;
    final Zone real = Zone.root;
    await IOOverrides.runZoned(
      () async {
        // Re-render, busqueda y cambio de pestana con la carpeta ya cargada.
        tester.element(find.byType(MusicPickerScreen)).markNeedsBuild();
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'sal');
        await tester.pump();
        expect(find.text('A'), findsOneWidget);
        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        await tester.tap(find.byTooltip('Canciones'));
        await tester.pump();
        await tester.tap(find.byTooltip('Carpetas'));
        await tester.pump();
        expect(calls, 0);
        probe.value = true;
        await tester.pump();
        expect(calls, greaterThan(0));
      },
      createDirectory: (String path) {
        calls++;
        return real.run(() => Directory(path));
      },
      createFile: (String path) {
        calls++;
        return real.run(() => File(path));
      },
      fseGetTypeSync: (String path, bool followLinks) {
        calls++;
        return real.run(
          () => FileSystemEntity.typeSync(path, followLinks: followLinks),
        );
      },
      statSync: (String path) {
        calls++;
        return real.run(() => FileStat.statSync(path));
      },
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('3124 Mezclar todo: 48 px, pistas de la subcarpeta, sin doble toque', (
    WidgetTester tester,
  ) async {
    _landscape(tester);
    final Directory root = _tree();
    addTearDown(() => _cleanup(root));
    final List<List<String>> mixed = <List<String>>[];
    final Completer<void> done = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: _picker(
          root,
          onMix: (List<File> files) {
            mixed.add(<String>[for (final File f in files) _name(f.path)]);
            return done.future;
          },
        ),
      ),
    );
    await _settle(tester);
    final Finder salsaMix = find.descendant(
      of: find.widgetWithText(InkWell, 'Salsa'),
      matching: find.widgetWithText(TextButton, 'Mezclar todo'),
    );
    expect(tester.getSize(salsaMix).height, greaterThanOrEqualTo(48.0));
    expect(
      tester.getSize(find.byTooltip('Carpetas')).height,
      greaterThanOrEqualTo(48.0),
    );

    await tester.tap(salsaMix);
    await tester.pump();
    await tester.tap(salsaMix);
    await tester.pump();
    expect(mixed, <List<String>>[
      <String>['A.mp3', 'B.mp3', 'C.m4a'],
    ]);
    done.complete();
    await tester.pump();
    await tester.tap(salsaMix);
    await tester.pump();
    expect(mixed, hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
