import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/workspaces/lab_lyric_search.dart';

void main() {
  group('Buscar letra del LAB toma la canción seleccionada', () {
    test('ID3 de otra canción: manda el nombre de archivo', () {
      final n = labDialogNames(
        fileName: 'Este Amor No Se Toca.mp3',
        id3Artist: 'Unknown',
        id3Title: 'Medardo -Casarme No',
      );
      expect(n.artist, '');
      expect(n.title, 'Este Amor No Se Toca');
    });

    test('ID3 correcto se usa', () {
      final n = labDialogNames(
        fileName: 'Triste Y Sola.mp3',
        id3Artist: 'Patricia Teherán',
        id3Title: 'Triste Y Sola',
      );
      expect(n.artist, 'Patricia Teherán');
      expect(n.title, 'Triste Y Sola');
    });

    test('sin ID3: Artista - Título del archivo, con o sin espacios', () {
      final a = labDialogNames(fileName: 'Medardo - La Revancha.mp3');
      expect([a.artist, a.title], ['Medardo', 'La Revancha']);
      final b = labNamesFromFile('Medardo -Casarme No.mp3');
      expect([b.artist, b.title], ['Medardo', 'Casarme No']);
      final c = labNamesFromFile('Medardo-La Revancha.mp3');
      expect([c.artist, c.title], ['Medardo', 'La Revancha']);
    });

    test('mensaje claro cuando no encuentra', () {
      final m = labNotFoundMessage('Medardo', 'Este Amor No Se Toca');
      expect(m, contains('No se encontró letra'));
      expect(m, contains('Medardo – Este Amor No Se Toca'));
      expect(m, contains('Buscar de nuevo'));
    });
  });
}
