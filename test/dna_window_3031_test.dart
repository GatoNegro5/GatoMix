import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/dna_mix.dart';
import 'package:gatomix/core/phrase_grid.dart';

void main() {
  test('outro al 50, 90 y 98 por ciento queda en 60-80 y el fundido cabe', () {
    const int dur = 180000;
    for (final int outro in <int>[90000, 162000, 176400]) {
      final DnaDecision d = _at(dur, outro: outro);
      expect(d.mixOutMs, inInclusiveRange(108000, 144000), reason: 'outro $outro');
      expect(d.mixOutMs + d.fadeMs, lessThanOrEqualTo(dur));
      expect(d.mixSource, isNot('outro'));
    }
  });

  test('outro dentro de la ventana se usa', () {
    final DnaDecision d = _at(180000, outro: 120000);
    expect(d.mixOutMs, 120000);
    expect(d.mixSource, 'outro');
    expect(d.mixOutMs + d.fadeMs, lessThanOrEqualTo(180000));
  });

  test('voz en todo el rango: el punto sigue en 60-80', () {
    final PhraseTrack voice = PhraseTrack(
      bpm: 120,
      beatMs: 0,
      durationMs: 200000,
      outroMs: -1,
      introEndMs: -1,
      bodyRms: 0.4,
      phrases: const <PhrasePhrase>[
        PhrasePhrase(startMs: 0, rms: 0.4, vocal: 1),
        PhrasePhrase(startMs: 140000, rms: 0.4, vocal: 1),
        PhrasePhrase(startMs: 190000, rms: 0.4, vocal: 1),
      ],
    );
    final DnaDecision d = decideDna(
      outDurationMs: 200000,
      inDurationMs: 200000,
      genreMixOutMs: 150000,
      fallbackCueMs: 10000,
      outBpm: 120,
      inBpm: 120,
      outKey: '8A',
      inKey: '8A',
      outgoing: voice,
      incoming: voice,
      echoSupported: false,
      eqSupported: true,
    );
    expect(d.mixOutMs, inInclusiveRange(120000, 160000));
    expect(d.mixOutMs + d.fadeMs, lessThanOrEqualTo(200000));
    expect(d.mixSource, 'frase');
  });
}

DnaDecision _at(int dur, {required int outro}) {
  final PhraseTrack track = PhraseTrack(
    bpm: 120,
    beatMs: 0,
    durationMs: dur,
    outroMs: outro,
    introEndMs: 10000,
    bodyRms: 0.2,
    phrases: const <PhrasePhrase>[
      PhrasePhrase(startMs: 0, rms: 0.2, vocal: 0.1),
      PhrasePhrase(startMs: 130000, rms: 0.05, vocal: 0.05),
    ],
  );
  return decideDna(
    outDurationMs: dur,
    inDurationMs: dur,
    genreMixOutMs: (dur * 0.75).round(),
    fallbackCueMs: 10000,
    outBpm: 120,
    inBpm: 120,
    outKey: '8A',
    inKey: '8A',
    outgoing: track,
    incoming: track,
    echoSupported: false,
    eqSupported: true,
  );
}
