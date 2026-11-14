import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/mobile/music_picker_screen.dart';

// 3.1.38: DJ Crate Browser de una sola vista. Archivos sinteticos en %TEMP%.
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
  final String s = Platform.pathSeparator;

  test(
    '3138 orden de crates: Musica, ReGenial, generos, Descargas, tecnicas',
    () {
      final String r = '${s}m';
      String p(String n) => '$r$s$n';
      final List<String> crates = musicPickerCrates(
        root: r,
        top: <String>[
          p('GatoMix_LAB'),
          p('Vacia'),
          p('Rock'),
          p('DjPlaylists'),
          p('Descargas'),
          p('ReGenial'),
          p('Bachata'),
          p('DJStudio_LAB'),
        ],
        counts: <String, int>{
          p('GatoMix_LAB'): 2,
          p('Vacia'): 0,
          p('Rock'): 3,
          p('DjPlaylists'): 1,
          p('Descargas'): 4,
          p('ReGenial'): 10,
          p('Bachata'): 5,
          p('DJStudio_LAB'): 0,
        },
      );
      expect(crates, <String>[
        r,
        p('ReGenial'),
        p('Bachata'),
        p('Rock'),
        p('Descargas'),
        p('DjPlaylists'),
        p('GatoMix_LAB'),
      ]);
      final List<String> withSubs = musicPickerCrates(
        root: r,
        top: <String>[p('ReGenial'), p('Rock')],
        counts: <String, int>{
          p('ReGenial'): 3,
          p('Rock'): 1,
          '${p('ReGenial')}${s}Salsa': 3,
          '${p('ReGenial')}${s}Vacia': 0,
        },
        parent: p('ReGenial'),
        subs: <String>[
          '${p('ReGenial')}${s}Salsa',
          '${p('ReGenial')}${s}Vacia',
        ],
      );
      expect(withSubs, <String>[
        r,
        p('ReGenial'),
        '${p('ReGenial')}${s}Salsa',
        p('Rock'),
      ]);
      expect(
        musicPickerTopCrate(r, '${p('ReGenial')}${s}Salsa', s),
        p('ReGenial'),
      );
      expect(musicPickerTopCrate(r, r, s), isNull);
    },
  );

  test('3138 Musica limpia: sin Descargas, DjPlaylists ni LAB', () {
    final String r = '${s}m';
    final List<File> clean = musicPickerCleanLibrary(<File>[
      File('$r${s}suelta.mp3'),
      File('$r${s}ReGenial${s}Salsa${s}a.mp3'),
      File('$r${s}Descargas${s}d.mp3'),
      File('$r${s}DjPlaylists${s}p.mp3'),
      File('$r${s}GatoMix_LAB${s}x${s}l.mp3'),
      File('$r${s}djstudio_lab${s}l.mp3'),
    ], r);
    expect(clean.map((File f) => f.path).toList(), <String>[
      '$r${s}suelta.mp3',
      '$r${s}ReGenial${s}Salsa${s}a.mp3',
    ]);
  });

  testWidgets('3138 una sola vista: cinta + canciones, Mezclar todo limpio', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final Directory dir = Directory.systemTemp.createTempSync('picker3138');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    void song(String rel) {
      final File f = File('${dir.path}$s$rel');
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(<int>[1]);
    }

    song('ReGenial${s}Salsa${s}Alfa.mp3');
    song('ReGenial${s}Salsa${s}Beta.mp3');
    song('Rock${s}Gamma.mp3');
    song('GatoMix_LAB${s}Render.mp3');
    song('DjPlaylists${s}Lista.mp3');
    Directory('${dir.path}${s}Vacia').createSync();

    final List<int> mixed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MusicPickerScreen(
          rootPath: dir.path,
          queuePaths: const <String>[],
          onEnqueue: (File _) {},
          onUndo: (File _) {},
          onPlayNext: (File _) {},
          onMixFolder: (List<File> files) async => mixed.add(files.length),
        ),
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Carpetas'), findsNothing);
    expect(find.byTooltip('Canciones'), findsNothing);
    expect(find.text('M\u00fasica'), findsOneWidget);
    expect(find.text('3 canciones'), findsOneWidget);
    expect(find.text('Vacia'), findsNothing);
    final double regenial = tester.getRect(find.text('ReGenial')).left;
    expect(tester.getRect(find.text('M\u00fasica')).left, lessThan(regenial));
    expect(find.text('Alfa'), findsOneWidget);
    expect(find.text('Render'), findsNothing);
    await tester.tap(find.text('Mezclar todo'));
    await tester.pump();
    expect(mixed, <int>[3]);

    await tester.tap(find.text('ReGenial'));
    await _settle(tester);
    expect(find.text('Salsa'), findsOneWidget);
    expect(find.text('Alfa'), findsOneWidget);
    expect(find.text('Gamma'), findsNothing);
    await tester.enterText(find.byType(TextField), 'beta');
    await tester.pump();
    expect(find.text('Alfa'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
