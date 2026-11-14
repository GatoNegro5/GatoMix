import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio_path.dart';
import 'package:gatomix/core/track_name_clean.dart';

void main() {
  test('3140: BPM del nombre va tras el cantante, sin extension ni BPM', () {
    expect(
      formatTrackTitle(r'C:\Music\Elefante - Angel (137 BPM).mp3'),
      'Elefante (137) - Angel',
    );
  });

  test('3140: _K despues del BPM tambien se limpia', () {
    expect(
      formatTrackTitle('/m/Elefante - Angel (137 BPM)_K.mp3'),
      'Elefante (137) - Angel',
    );
  });

  test('3140: sin BPM queda Cantante - Titulo, nunca ---', () {
    expect(
      formatTrackTitle('/m/Elefante - Asi Es La Vida.mp3'),
      'Elefante - Asi Es La Vida',
    );
  });

  test('3140: BPM del cache se redondea; el del nombre manda', () {
    expect(formatTrackTitle('/m/A - B.mp3', bpm: 116.76), 'A (117) - B');
    expect(formatTrackTitle('/m/A - B (90 BPM).mp3', bpm: 180), 'A (90) - B');
    expect(formatTrackTitle('/m/A - B.mp3', bpm: 300), 'A - B');
  });

  test('3140: sin guion el BPM va al final; nombre sin extension intacto', () {
    expect(formatTrackTitle('/m/Cancion (128 BPM).mp3'), 'Cancion (128)');
    expect(formatTrackTitle('SISTEMA EN ESPERA'), 'SISTEMA EN ESPERA');
  });

  test('3140: el filtro de las listas reconoce los _K', () {
    expect(isKaraokeAudioPath('/m/A - B (90 BPM)_K.mp3'), isTrue);
    expect(isKaraokeAudioPath('/m/A - B (90 BPM).mp3'), isFalse);
  });
}
