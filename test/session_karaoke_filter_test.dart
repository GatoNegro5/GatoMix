import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/session_store.dart';

void main() {
  test('restaurar sesion descarta pistas _K', () {
    final saved = [
      '/m/80s/A - Uno.mp3',
      '/m/80s/A - Uno_K.mp3',
      '/m/80s/B - Dos_k.MP3',
      '/m/80s/C - Tres.mp3',
    ];
    final out = resolvePlayableSessionPaths(saved, exists: (_) => true);
    expect(out, ['/m/80s/A - Uno.mp3', '/m/80s/C - Tres.mp3']);
  });
  test('renombrada por Masterizar no reaparece como _K', () {
    final out = resolvePlayableSessionPaths(
      ['/m/x/A - Uno.mp3'],
      exists: (_) => false,
      listDir: (_) => ['/m/x/A - Uno_K.mp3'],
    );
    expect(out.where(isKaraokeSessionPath), isEmpty);
  });
  test('isKaraokeSessionPath', () {
    expect(isKaraokeSessionPath('a_K.mp3'), isTrue);
    expect(isKaraokeSessionPath('Kool_Kat.mp3'), isFalse);
    expect(isKaraokeSessionPath('Mix_Kids.mp3'), isFalse);
  });
}
