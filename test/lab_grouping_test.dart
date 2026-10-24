import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/workspaces/lab_workspace.dart';

void main() {
  test('LAB lista todas las canciones agrupadas por carpeta con contador', () {
    final entries = <MapEntry<String, dynamic>>[
      const MapEntry('b.mp3', {'originalPath': r'C:\Music\Baladas\b.mp3'}),
      const MapEntry('z.mp3', 'C:/Music/Cumbias/z.mp3'),
      const MapEntry('a.mp3', {'originalPath': 'C:/Music/Baladas/a.mp3'}),
      const MapEntry('x.mp3', 'Origen desconocido'),
    ];
    final rows = labGroupedRows(entries);
    final headers = rows.whereType<LabFolderHeader>().toList();
    expect(headers.map((h) => h.name), ['Baladas', 'Cuarentena', 'Cumbias']);
    expect(headers.map((h) => h.count), [2, 1, 1]);
    final songs = rows.whereType<MapEntry<String, dynamic>>().map((e) => e.key);
    expect(songs, ['a.mp3', 'b.mp3', 'x.mp3', 'z.mp3']);
    expect(rows.length, 7);
  });
}
