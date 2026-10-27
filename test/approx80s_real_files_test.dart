import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_approx.dart';
import 'package:gatomix/ui/widgets/approx_lyric_icon.dart';

// Copias de los 5 .lrc APPROX reales de "80s Ingles" (laptop).
void main() {
  final src = Directory('test/fixtures/approx80s');
  final lrcs = src.listSync().whereType<File>().toList();

  test('los 5 .lrc reales llevan [gmx_approx] y la app los detecta', () {
    expect(lrcs.length, 5);
    for (final f in lrcs) {
      final mp3 = f.path.replaceAll(RegExp(r'\.lrc$'), '.mp3');
      expect(lrcIsApprox(f.readAsStringSync()), isTrue, reason: f.path);
      expect(isApproxLyric(mp3), isTrue, reason: f.path);
      // Su _K comparte la letra de la canción normal.
      final k = mp3.replaceAll(RegExp(r'\.mp3$'), '_K.mp3');
      expect(isApproxLyric(k), isTrue, reason: k);
    }
  });

  test('Sí → quita marca en copia; deja de ser APPROX; versos intactos',
      () async {
    final tmp = Directory.systemTemp.createTempSync('approx80s');
    for (final f in lrcs) {
      final c = File('${tmp.path}/${f.uri.pathSegments.last}');
      f.copySync(c.path);
      final mp3 = c.path.replaceAll(RegExp(r'\.lrc$'), '.mp3');
      final before = c.readAsStringSync();
      expect(isApproxLyric(mp3), isTrue);
      expect(await confirmApproxLyric(mp3), isTrue);
      final after = c.readAsStringSync();
      expect(lrcIsApprox(after), isFalse);
      expect(after.contains('gmx_approx'), isFalse);
      expect(isApproxLyric(mp3), isFalse);
      final verses = RegExp(r'^\[\d', multiLine: true);
      expect(verses.allMatches(after).length,
          verses.allMatches(before).length);
      // Una letra confirmada (MANUAL) no se reemplaza por una APPROX.
      expect(lrcSyncShouldReplace(existing: after, incoming: before, overwrite: true), isFalse);
    }
    // Originales sin tocar.
    for (final f in lrcs) {
      expect(lrcIsApprox(f.readAsStringSync()), isTrue);
    }
    tmp.deleteSync(recursive: true);
  });
}
