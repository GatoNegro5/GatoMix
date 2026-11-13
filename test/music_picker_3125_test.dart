import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/providers/automix_provider.dart';
import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/ui/mobile/music_picker_screen.dart';
import 'package:gatomix/ui/workspaces/automix_workspace.dart';
import 'package:gatomix/ui/workspaces/livedj_workspace.dart';

// 3.1.25: panel lateral derecho, barra de 48 px, filas de 56 dp y boton
// "+ Agregar canciones" de 48 px. Todo sobre %TEMP% (cero ReGenial) y sin
// tocar el boton real (abriria la carpeta de musica del usuario).

class _FakeLiveDj extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

class _FakeAutomix extends AutomixNotifier {
  @override
  AutomixState build() => AutomixState();
}

class _FakeQueue extends AutomixQueueNotifier {
  @override
  List<File> build() => <File>[];
}

class _FakePlayed extends PlayedTracksNotifier {
  @override
  Set<String> build() => <String>{};
}

class _FakeSort extends TrackSortNotifier {
  @override
  TrackSortMode build() => TrackSortMode.alphabetical;
}

const List<String> _words = <String>[
  'Alfa', 'Bravo', 'Charlie', 'Delta', 'Eco', 'Foxtrot', 'Golf', 'Hotel',
  'India', 'Julieta',
];

final String _longFolder = 'Carpeta${'Larga' * 24}';

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Raiz con 10 canciones sueltas, 6 carpetas cortas y una de nombre largo.
Directory _tree() {
  final Directory root = Directory.systemTemp.createTempSync('gatomix_3125_');
  final String s = Platform.pathSeparator;
  for (final String w in _words) {
    File('${root.path}${s}Tema $w.mp3').writeAsBytesSync(<int>[1]);
  }
  for (final String w in _words.take(6)) {
    File('${root.path}${s}Carpeta $w${s}Pista $w.mp3')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[2]);
  }
  File('${root.path}$s$_longFolder${s}Interna.mp3')
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[3]);
  addTearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
  });
  return root;
}

MusicPickerScreen _picker(
  Directory root,
  List<String> queued, {
  VoidCallback? onClose,
}) {
  return MusicPickerScreen(
    rootPath: root.path,
    queuePaths: const <String>[],
    onEnqueue: (File f) => queued.add(f.path),
    onUndo: (File f) => queued.remove(f.path),
    onPlayNext: (_) {},
    onMixFolder: (_) async {},
    onClose: onClose,
  );
}

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
  for (final Size size in <Size>[const Size(800, 400), const Size(844, 390)]) {
    testWidgets(
      '3125 panel derecho ${size.width.toInt()}x${size.height.toInt()}: 45 %, Deshacer dentro, cierra fuera',
      (WidgetTester tester) async {
        _size(tester, size);
        final Directory root = _tree();
        final List<String> queued = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (BuildContext ctx) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showMusicPickerPanel(
                      ctx,
                      child: (VoidCallback close) =>
                          _picker(root, queued, onClose: close),
                    ),
                    child: const Text('abrir'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('abrir'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await _settle(tester);

        final Rect panel = tester.getRect(find.byType(MusicPickerScreen));
        final double expected = (size.width * 0.45).clamp(340.0, 420.0);
        expect(panel.width, moreOrLessEquals(expected));
        expect(panel.right, moreOrLessEquals(size.width));
        expect(panel.height, moreOrLessEquals(size.height));
        expect(find.byTooltip('Cerrar'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('Canciones'));
        await _settle(tester);
        // La lista es perezosa: se filtra para que la fila quede a la vista.
        await tester.enterText(find.byType(TextField), 'Tema Alfa');
        await _settle(tester);
        await tester.tap(
          find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.text('Tema Alfa'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 750));
        expect(queued, hasLength(1));
        final Rect undo = tester.getRect(find.text('Deshacer'));
        expect(undo.left, greaterThanOrEqualTo(panel.left));
        expect(undo.right, lessThanOrEqualTo(panel.right));
        expect(tester.takeException(), isNull);

        await tester.tapAt(Offset(40, size.height / 2));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(MusicPickerScreen), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final double w in <double>[340, 360, 380]) {
    testWidgets('3125 barra de 48 px a ${w.toInt()} dp con carpeta larga', (
      WidgetTester tester,
    ) async {
      _size(tester, const Size(800, 360));
      final Directory root = _tree();
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: w,
              child: _picker(root, <String>[], onClose: () {}),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text(_longFolder),
        100,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // scrollUntilVisible solo garantiza que este construida (cacheExtent).
      await tester.ensureVisible(find.text(_longFolder));
      await tester.pump();
      await tester.tap(find.text(_longFolder));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Canciones'));
      await _settle(tester);
      expect(find.text('Interna'), findsOneWidget);

      final double top = tester.getRect(find.byTooltip('Atr\u00e1s')).top;
      for (final String tip in <String>[
        'Atr\u00e1s',
        'Carpetas',
        'Canciones',
        'Cerrar',
      ]) {
        final Rect r = tester.getRect(find.byTooltip(tip));
        expect(r.height, moreOrLessEquals(48.0), reason: tip);
        expect(r.width, moreOrLessEquals(48.0), reason: tip);
        expect(r.top, moreOrLessEquals(top), reason: tip);
      }
      final Rect field = tester.getRect(find.byType(TextField));
      expect(field.width, greaterThanOrEqualTo(w - 8 - 4 * 48 - 0.5));
      expect(field.top, greaterThanOrEqualTo(top - 0.5));
      expect(field.bottom, lessThanOrEqualTo(top + 48.5));
      expect(tester.getRect(find.byTooltip('Cerrar')).right,
          lessThanOrEqualTo(800.0));
    });
  }

  testWidgets('3125 al menos 4.5 filas visibles a 800x360', (
    WidgetTester tester,
  ) async {
    _size(tester, const Size(800, 360));
    final Directory root = _tree();
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 360,
            child: _picker(root, <String>[], onClose: () {}),
          ),
        ),
      ),
    );
    await _settle(tester);
    final Rect view = tester.getRect(find.byType(CustomScrollView));
    final double folderStep = tester.getRect(find.text('Carpeta Bravo')).top -
        tester.getRect(find.text('Carpeta Alfa')).top;
    expect(folderStep, moreOrLessEquals(56.0));
    expect(view.height / folderStep, greaterThanOrEqualTo(4.5));

    await tester.tap(find.byTooltip('Canciones'));
    await _settle(tester);
    final Size row = tester.getSize(
      find
          .ancestor(of: find.text('Pista Alfa'), matching: find.byType(SizedBox))
          .first,
    );
    expect(row.height, moreOrLessEquals(56.0));
    expect(view.height / row.height, greaterThanOrEqualTo(4.5));
    expect(tester.takeException(), isNull);
  });

  for (final double h in <double>[360, 410]) {
    testWidgets('3125 Live DJ 800x${h.toInt()}: Agregar canciones de 48 px', (
      WidgetTester tester,
    ) async {
      _size(tester, Size(800, h));
      debugLiveDjForceMobile = true;
      addTearDown(() => debugLiveDjForceMobile = null);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [liveDjProvider.overrideWith(_FakeLiveDj.new)],
          child: const MaterialApp(home: LiveDjWorkspace()),
        ),
      );
      await tester.pump();
      final Finder add = find.widgetWithText(TextButton, '+ Agregar canciones');
      expect(add, findsOneWidget);
      expect(tester.getSize(add).height, greaterThanOrEqualTo(48.0));
      expect(tester.takeException(), isNull);
    });
  }

  for (final double w in <double>[780, 800]) {
    testWidgets(
      '3125 Automix ${w.toInt()}x360 con letra armada (flex 2): 48 px sin overflow',
      (WidgetTester tester) async {
        _size(tester, Size(w, 360));
        debugAutomixForceMobile = true;
        addTearDown(() => debugAutomixForceMobile = null);
        // Misma proporcion que AutomixWorkspace con la sincronizacion armada:
        // mezclador flex 8 (aqui un relleno), divisor y AutomixPanel flex 2.
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              automixProvider.overrideWith(_FakeAutomix.new),
              automixQueueProvider.overrideWith(_FakeQueue.new),
              playedTracksProvider.overrideWith(_FakePlayed.new),
              trackSortProvider.overrideWith(_FakeSort.new),
            ],
            child: const MaterialApp(
              home: Scaffold(
                body: Column(
                  children: <Widget>[
                    Expanded(flex: 8, child: SizedBox.expand()),
                    Divider(height: 1),
                    Expanded(flex: 2, child: AutomixPanel()),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final Finder add = find.widgetWithText(TextButton, '+ Agregar canciones');
        expect(add, findsOneWidget);
        expect(tester.getSize(add).height, greaterThanOrEqualTo(48.0));
        expect(tester.getRect(add).bottom,
            lessThanOrEqualTo(tester.getRect(find.byType(AutomixPanel)).bottom));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
