import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/mobile/music_picker_screen.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('gm_picker_');
    for (final String d in <String>['Rock80s', 'Salsa', 'Electro/Sub']) {
      Directory('${root.path}/$d').createSync(recursive: true);
      for (int i = 1; i <= 2; i++) {
        File('${root.path}/$d/tema$i.mp3').writeAsStringSync('x');
      }
    }
    File('${root.path}/Salsa/tema1_K.mp3').writeAsStringSync('x');
    File('${root.path}/Salsa/notas.txt').writeAsStringSync('x');
    Directory('${root.path}/.oculto').createSync();
    File('${root.path}/.oculto/x.mp3').writeAsStringSync('x');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('lista recursiva async encuentra todas las canciones', () async {
    final List<File> all = await musicPickerSongsUnderAsync(root.path);
    expect(all.length, 6);
  });

  test('buscar Salsa desde la raíz encuentra por carpeta', () async {
    final List<File> all = await musicPickerSongsUnderAsync(root.path);
    final List<File> hits = musicPickerFilterSongs(all, root.path, 'salsa');
    expect(hits.length, 2);
    expect(hits.every((File f) => f.path.contains('Salsa')), isTrue);
  });

  test(
    'búsqueda vacía devuelve todo y subcarpetas profundas cuentan',
    () async {
      final List<File> all = await musicPickerSongsUnderAsync(root.path);
      expect(musicPickerFilterSongs(all, root.path, '  ').length, 6);
      expect(musicPickerFilterSongs(all, root.path, 'sub').length, 2);
    },
  );
}
