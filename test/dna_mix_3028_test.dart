import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/dna_mix.dart';
import 'package:gatomix/core/exact_mix.dart';
import 'package:gatomix/core/phrase_grid.dart';
import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/providers/mix_formula.dart';
import 'package:gatomix/ui/workspaces/livedj_deck_relevo.dart';

const int _rate = 22050;

void main() {
  test('sin perfil DNA conserva el porcentaje, el cue de 10 s y 18 s', () {
    final DnaDecision d = decideDna(
      outDurationMs: 200000,
      inDurationMs: 200000,
      genreMixOutMs: 150000,
      fallbackCueMs: 10000,
      outBpm: 120,
      inBpm: 122,
      outKey: '8A',
      inKey: '8A',
      echoSupported: true,
      eqSupported: true,
    );
    expect(d.kind, DnaKind.legacy);
    expect(d.mixOutMs, 150000);
    expect(d.cueInMs, 10000);
    expect(d.fadeMs, 18000);
    expect(d.lockTempo, isTrue);
    expect(d.bassSwap, isTrue);
    expect(
      relevoDurationMs(
        derive: true,
        mode: LiveDjMixMode.activeSync,
        formula: MixFormula.dnaEnergy,
      ),
      18000,
    );
  });

  test('(a) compatible e instrumental: blend largo, bass swap, sin eco', () {
    final PhraseTrack low = _tone(60, 128, 80, 0.5, quietUntil: 15);
    expect(low.phrases.first.vocalOn, isFalse);
    expect(low.introEndMs, 15000);
    final DnaDecision d = _pair(low, low, outBpm: 120, inBpm: 128, key: '8A');
    expect(d.kind, DnaKind.longBlend);
    expect(d.bassSwap, isTrue);
    expect(d.lockTempo, isTrue);
    expect(d.fadeMs, 18000);
    expect(d.cueInMs, 15000);
    expect(d.echoDelayMs, 0);
  });

  test('(b) con voz: blend corto y no solapa las frases vocales', () {
    final PhraseTrack voice = _tone(96, 120, 1000, 0.5);
    expect(voice.phrases.first.vocalOn, isTrue);
    final PhraseTrack mixed = _song(96, 120, <_Seg>[
      _Seg(64, 80, 0.5),
      _Seg(16, 1000, 0.5),
      _Seg(16, 80, 0.5),
    ]);
    expect(mixed.phraseAt(64000)!.vocalOn, isTrue);
    expect(mixed.phraseAt(80000)!.vocalOn, isFalse);
    final int genre = (96000 * 0.75).toInt();
    final DnaDecision d = decideDna(
      outDurationMs: 96000,
      inDurationMs: 96000,
      genreMixOutMs: genre,
      fallbackCueMs: 10000,
      outBpm: 120,
      inBpm: 120,
      outKey: '8A',
      inKey: '9A',
      outgoing: mixed,
      incoming: voice,
      echoSupported: true,
      eqSupported: true,
    );
    expect(d.kind, DnaKind.shortBlend);
    expect(d.bassSwap, isFalse);
    expect(d.lockTempo, isTrue);
    expect(d.fadeMs, 16000);
    expect(d.mixOutMs, inInclusiveRange(57600, 76800));
    expect(d.mixOutMs + d.fadeMs, lessThanOrEqualTo(96000));
    expect(d.cueInMs, isNot(16000));
  });

  test('(c) BPM lejos: eco al beat y la entrante no se fuerza', () {
    final PhraseTrack body = _body();
    final DnaDecision echo = decideDna(
      outDurationMs: 180000,
      inDurationMs: 180000,
      genreMixOutMs: 120000,
      fallbackCueMs: 10000,
      outBpm: 100,
      inBpm: 140,
      outKey: '8A',
      inKey: '8B',
      outgoing: body,
      incoming: body,
      echoSupported: true,
      eqSupported: true,
    );
    expect(echo.kind, DnaKind.echoOut);
    expect(echo.lockTempo, isFalse);
    expect(echo.bassSwap, isFalse);
    expect(echo.echoDelayMs, 600);
    expect(echo.echoFeedback, closeTo(0.45, 0.001));
    expect(dnaEchoChain(echo.echoDelayMs, echo.echoFeedback), contains('600'));

    final DnaDecision sweep = decideDna(
      outDurationMs: 180000,
      inDurationMs: 180000,
      genreMixOutMs: 120000,
      fallbackCueMs: 10000,
      outBpm: 120,
      inBpm: 120,
      outKey: '8A',
      inKey: '1A',
      outgoing: body,
      incoming: body,
      echoSupported: false,
      eqSupported: true,
    );
    expect(sweep.kind, DnaKind.filterSweep);
    expect(sweep.lockTempo, isFalse);
    expect(sweep.bassSwap, isFalse);

    final DnaDecision plain = decideDna(
      outDurationMs: 180000,
      inDurationMs: 180000,
      genreMixOutMs: 120000,
      fallbackCueMs: 10000,
      outBpm: 100,
      inBpm: 160,
      outgoing: body,
      incoming: body,
      echoSupported: false,
      eqSupported: false,
    );
    expect(plain.kind, DnaKind.blendFallback);
    expect(plain.lockTempo, isFalse);
    expect(plain.bassSwap, isFalse);
  });

  test('el outro de la segunda mitad se usa aunque quede poco audio', () {
    final PhraseTrack early = _body(outro: 20000);
    final DnaDecision tooSoon = decideDna(
      outDurationMs: 180000,
      inDurationMs: 180000,
      genreMixOutMs: 135000,
      fallbackCueMs: 10000,
      outBpm: 120,
      inBpm: 120,
      outKey: '8A',
      inKey: '8A',
      outgoing: early,
      incoming: early,
      echoSupported: false,
      eqSupported: true,
    );
    expect(tooSoon.mixOutMs, 135000);

    final PhraseTrack late = _body(outro: 178000);
    final DnaDecision tooLate = decideDna(
      outDurationMs: 180000,
      inDurationMs: 180000,
      genreMixOutMs: 135000,
      fallbackCueMs: 10000,
      outBpm: 120,
      inBpm: 120,
      outgoing: late,
      incoming: late,
      echoSupported: false,
      eqSupported: true,
    );
    expect(tooLate.mixOutMs, inInclusiveRange(108000, 144000));
    expect(tooLate.mixOutMs + tooLate.fadeMs, lessThanOrEqualTo(180000));
    final FittedFade lateFade = fitMixFade(
      exactDurationMs: 180000,
      mixOutMs: 178000,
      wantedFadeMs: 18000,
    );
    expect(lateFade.mixOutMs, 178000);
    expect(lateFade.mixOutMs, isNot(180000 - 4000));
    expect(lateFade.fadeMs, 2000);
    expect(lateFade.shortened, isTrue);

    final PhraseTrack drop = _body(outro: 100000);
    final DnaDecision used = decideDna(
      outDurationMs: 180000,
      inDurationMs: 180000,
      genreMixOutMs: 135000,
      fallbackCueMs: 10000,
      outBpm: 120,
      inBpm: 120,
      outKey: '8A',
      inKey: '8A',
      outgoing: drop,
      incoming: drop,
      echoSupported: false,
      eqSupported: true,
    );
    expect(used.mixOutMs, inInclusiveRange(108000, 144000));
    expect(used.kind, DnaKind.longBlend);
  });
}

PhraseTrack _body({int outro = -1}) {
  return PhraseTrack(
    bpm: 120,
    beatMs: 0,
    durationMs: 180000,
    outroMs: outro,
    introEndMs: 16000,
    bodyRms: 0.3,
    phrases: const <PhrasePhrase>[
      PhrasePhrase(startMs: 0, rms: 0.05, vocal: 0.1),
      PhrasePhrase(startMs: 16000, rms: 0.3, vocal: 0.1),
      PhrasePhrase(startMs: 100000, rms: 0.08, vocal: 0.1),
    ],
  );
}

DnaDecision _pair(
  PhraseTrack outgoing,
  PhraseTrack incoming, {
  required double outBpm,
  required double inBpm,
  required String key,
}) {
  return decideDna(
    outDurationMs: outgoing.durationMs,
    inDurationMs: incoming.durationMs,
    genreMixOutMs: (outgoing.durationMs * 0.75).toInt(),
    fallbackCueMs: 10000,
    outBpm: outBpm,
    inBpm: inBpm,
    outKey: key,
    inKey: key,
    outgoing: outgoing,
    incoming: incoming,
    echoSupported: true,
    eqSupported: true,
  );
}

PhraseTrack _tone(
  int seconds,
  double bpm,
  double hz,
  double amp, {
  int quietUntil = 0,
}) {
  final List<_Seg> parts = quietUntil > 0
      ? <_Seg>[
          _Seg(quietUntil.toDouble(), hz, 0.04),
          _Seg((seconds - quietUntil).toDouble(), hz, amp),
        ]
      : <_Seg>[_Seg(seconds.toDouble(), hz, amp)];
  return _song(seconds, bpm, parts);
}

class _Seg {
  final double seconds;
  final double hz;
  final double amp;
  const _Seg(this.seconds, this.hz, this.amp);
}

PhraseTrack _song(int seconds, double bpm, List<_Seg> parts) {
  final Float32List samples = _join(<Float32List>[
    for (final _Seg s in parts) _sine(s.seconds, s.hz, s.amp),
  ]);
  final int want = seconds * _rate;
  final Float32List cut = samples.length == want
      ? samples
      : Float32List.sublistView(samples, 0, math.min(want, samples.length));
  return analyzePhraseSamples(samples: cut, sampleRate: _rate, bpm: bpm)!;
}

Float32List _sine(double seconds, double hz, double amp) {
  final int n = (seconds * _rate).round();
  final Float32List out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = amp * math.sin(math.pi * 2 * hz * i / _rate);
  }
  return out;
}

Float32List _join(List<Float32List> parts) {
  var n = 0;
  for (final Float32List p in parts) {
    n += p.length;
  }
  final Float32List out = Float32List(n);
  var o = 0;
  for (final Float32List p in parts) {
    out.setRange(o, o + p.length, p);
    o += p.length;
  }
  return out;
}
