import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/core/phrase_grid.dart';

PhraseTrack _track({int outro = 150000, int intro = 9000}) => PhraseTrack(
  bpm: 120,
  beatMs: 1000,
  durationMs: 180000,
  outroMs: outro,
  introEndMs: intro,
  bodyRms: 0.2,
  phrases: const <PhrasePhrase>[
    PhrasePhrase(startMs: 200, rms: 0.1, vocal: 0),
    PhrasePhrase(startMs: 1000, rms: 0.2, vocal: 0.5),
    PhrasePhrase(startMs: 17000, rms: 0.3, vocal: 0.7),
  ],
);

void main() {
  test('shift: beat, frases, intro, outro y duracion restan el recorte', () {
    final PhraseTrack? s = shiftPhraseTrack(_track(), 500);
    expect(s, isNotNull);
    expect(s!.beatMs, 500);
    expect(s.durationMs, 179500);
    expect(s.introEndMs, 8500);
    expect(s.outroMs, 149500);
    expect(s.phrases.map((PhrasePhrase p) => p.startMs), <int>[500, 16500]);
    expect(shiftPhraseTrack(_track(outro: -1), 500)!.outroMs, -1);
    expect(identical(shiftPhraseTrack(_track(), 0), _track()), isFalse);
    expect(shiftPhraseTrack(_track(), 0)!.beatMs, 1000);
  });

  test('shift: inconsistente devuelve null', () {
    expect(shiftPhraseTrack(_track(), 1200), isNull); // beat < 0
    expect(shiftPhraseTrack(_track(), 200000), isNull); // dur <= 0
  });

  test('shiftForTrim: mueve o borra la entrada del .gatomix.json en %TEMP%', () {
    final Directory dir = Directory.systemTemp.createTempSync('gmx3114_pg');
    final String a = '${dir.path}${Platform.pathSeparator}a.mp3';
    final String b = '${dir.path}${Platform.pathSeparator}b.mp3';
    PhraseGridMemory.debugReset();
    PhraseGridMemory.save(a, _track());
    PhraseGridMemory.save(b, _track());
    PhraseGridMemory.shiftForTrim(a, 300);
    PhraseGridMemory.shiftForTrim(b, 5000);
    final Map<String, dynamic> map = GatomixStore.readMap(dir.path, phraseGridSection);
    expect((map[a] as Map)['beat'], 700);
    expect(PhraseGridMemory.peek(a)!.beatMs, 700);
    expect(map.containsKey(b), isFalse);
    expect(PhraseGridMemory.peek(b), isNull);
    PhraseGridMemory.debugReset();
  });
}
