import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/core/phrase_grid.dart';
import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/providers/mix_formula.dart';
import 'package:gatomix/ui/workspaces/livedj_deck_relevo.dart';

const int _rate = 22050;

void main() {
  test('1. el outro es la primera bajada sostenida de la segunda mitad', () {
    final PhraseTrack drop = _at(128, 120, quietFrom: 80);
    expect(drop.outroMs, 80000);
    final PhrasePlan used = _plan(drop, durationMs: 128000, bpm: 120);
    expect(used.energyExit, isTrue);
    expect(used.mixOutMs, 80000);
    final int snap = snapPhraseGridMixOut(
      durationMs: 128000,
      dnaMixOutMs: (128000 * 0.75).toInt(),
      bpm: 120,
    );
    expect(used.mixOutMs, isNot(snap));

    // La bajada a los 64 s cae antes del 60 %: respaldo DNA a 8 compases.
    final PhraseTrack before = _at(128, 120, quietFrom: 64);
    expect(before.outroMs, 64000);
    final PhrasePlan backed = _plan(before, durationMs: 128000, bpm: 120);
    expect(backed.energyExit, isFalse);
    expect(backed.mixOutMs, snap);
    expect(backed.mixOutMs, isNot(64000));

    final PhrasePlan none = planPhrase8(
      outDurationMs: 128000,
      inDurationMs: 128000,
      fallbackMixOutMs: snap,
      fallbackCueMs: 10000,
      incomingBpm: 120,
      incomingRate: 1,
    );
    expect(none.mixOutMs, snap);
    expect(none.cueInMs, 10000);
    expect(none.energyExit, isFalse);
  });

  test('2. la entrante entra en el downbeat de la frase, no en 10 s', () {
    final PhraseTrack intro = _at(96, 120, quietUntil: 16);
    expect(intro.introEndMs, 16000);
    final PhrasePlan fromIntro = _plan(intro, durationMs: 96000, bpm: 120);
    expect(fromIntro.phraseEntry, isTrue);
    expect(fromIntro.cueInMs, 16000);
    expect(fromIntro.cueInMs, isNot(10000));

    final PhraseTrack loud = _at(96, 120);
    expect(loud.introEndMs, -1);
    final PhrasePlan fromTen = _plan(loud, durationMs: 96000, bpm: 120);
    expect(fromTen.cueInMs, 16000);
    expect(fromTen.phraseEntry, isTrue);
  });

  test('3. 16 compases si el cruce es instrumental, 8 si hay voz, tope 8–18 s', () {
    final PhraseTrack low = _tone(seconds: 60, bpm: 128, hz: 80, amp: 0.5);
    expect(low.phrases.first.vocalOn, isFalse);
    final PhrasePlan instrumental = _plan(low, durationMs: 60000, bpm: 128);
    expect(instrumental.instrumental, isTrue);
    expect(instrumental.fadeMs, 18000);

    final PhraseTrack voice = _tone(seconds: 60, bpm: 128, hz: 1000, amp: 0.5);
    expect(voice.phrases.first.vocalOn, isTrue);
    final PhrasePlan vocal = _plan(voice, durationMs: 60000, bpm: 128);
    expect(vocal.instrumental, isFalse);
    expect(vocal.fadeMs, 15000);

    expect(
      phraseGridFadeMs(bpm: 90, instrumental: true, durationMs: 200000),
      18000,
    );
    expect(
      phraseGridFadeMs(bpm: 90, instrumental: false, durationMs: 200000),
      18000,
    );
    expect(vocal.fadeMs, inInclusiveRange(8000, 18000));
    expect(instrumental.fadeMs, inInclusiveRange(8000, 18000));
  });

  test('4. el fundido usa el BPM de la entrante ya igualado', () {
    expect(
      phraseSoundingBpm(incomingBpm: 128, incomingRate: 120 / 128),
      closeTo(120, 1e-9),
    );
    final PhraseTrack voice = _tone(seconds: 60, bpm: 128, hz: 1000, amp: 0.5);
    final int snap = snapPhraseGridMixOut(
      durationMs: 60000,
      dnaMixOutMs: (60000 * 0.75).toInt(),
      bpm: 128,
    );
    final PhrasePlan plan = planPhrase8(
      outDurationMs: 60000,
      inDurationMs: 60000,
      fallbackMixOutMs: snap,
      fallbackCueMs: 10000,
      incomingBpm: 128,
      incomingRate: 120 / 128,
      outgoing: voice,
      incoming: voice,
    );
    expect(plan.instrumental, isFalse);
    expect(plan.fadeMs, 16000);
    expect(plan.fadeMs, isNot(13714));
    expect(
      phraseFadeMs(incomingBpm: 128, incomingDurationMs: 180000),
      15000,
    );
    expect(
      phraseFadeMs(incomingBpm: 90, incomingDurationMs: 200000),
      12000,
    );
  });

  test('5. no junta dos frases vocales si hay una frase cercana sin voz', () {
    final PhraseTrack outgoing = _song(
      seconds: 96,
      bpm: 120,
      parts: <_Part>[
        _Part(64, 80, 0.50),
        _Part(16, 1000, 0.50),
        _Part(16, 80, 0.50),
      ],
    );
    final PhraseTrack incoming = _song(
      seconds: 96,
      bpm: 120,
      parts: <_Part>[
        _Part(16, 80, 0.50),
        _Part(16, 1000, 0.50),
        _Part(16, 80, 0.50),
        _Part(48, 1000, 0.50),
      ],
    );
    expect(outgoing.phraseAt(64000)!.vocalOn, isTrue);
    expect(outgoing.phraseAt(80000)!.vocalOn, isFalse);
    expect(incoming.phraseAt(16000)!.vocalOn, isTrue);
    expect(incoming.phraseAt(32000)!.vocalOn, isFalse);

    final PhrasePlan moved = _planPair(outgoing, incoming, 96000, 120);
    expect(moved.mixOutMs, 80000);
    expect(moved.cueInMs, 16000);

    final PhraseTrack allVoice = _tone(seconds: 96, bpm: 120, hz: 1000, amp: 0.5);
    final PhrasePlan entryMoves = _planPair(allVoice, incoming, 96000, 120);
    final int snap = snapPhraseGridMixOut(
      durationMs: 96000,
      dnaMixOutMs: (96000 * 0.75).toInt(),
      bpm: 120,
    );
    expect(entryMoves.mixOutMs, snap);
    expect(entryMoves.cueInMs, 32000);

    final PhrasePlan stuck = _planPair(allVoice, allVoice, 96000, 120);
    expect(stuck.mixOutMs, snap);
    expect(stuck.cueInMs, 16000);
  });

  test('la banda vocal separa 1 kHz de 80 Hz', () {
    final PhraseTrack high = _tone(seconds: 32, bpm: 120, hz: 1000, amp: 0.5);
    final PhraseTrack low = _tone(seconds: 32, bpm: 120, hz: 80, amp: 0.5);
    expect(high.phrases.first.vocal, greaterThan(0.7));
    expect(low.phrases.first.vocal, lessThan(0.2));
  });

  test('el perfil se guarda en la carpeta y el tick solo lee memoria', () {
    final Directory dir = Directory.systemTemp.createTempSync('phrase3027');
    addTearDown(() {
      PhraseGridMemory.debugReset();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final String path = '${dir.path}/tema.mp3';
    File(path).writeAsStringSync('x');
    final PhraseTrack track = _tone(seconds: 32, bpm: 120, hz: 80, amp: 0.4);
    PhraseGridMemory.save(path, track);
    PhraseGridMemory.debugReset();
    final int reads = GatomixStore.debugDiskReads;
    expect(PhraseGridMemory.peek(path), isNull);
    expect(GatomixStore.debugDiskReads, reads);
    PhraseGridMemory.absorbDir(dir.path);
    final PhraseTrack? back = PhraseGridMemory.peek(path);
    expect(back, isNotNull);
    expect(back!.outroMs, track.outroMs);
    expect(back.introEndMs, track.introEndMs);
    expect(back.phrases.length, track.phrases.length);
    expect(back.phrases.first.vocal, closeTo(track.phrases.first.vocal, 0.001));
    final int warm = GatomixStore.debugDiskReads;
    PhraseGridMemory.peek(path);
    PhraseGridMemory.stamp(path);
    expect(GatomixStore.debugDiskReads, warm);
    final Map<String, dynamic> section = GatomixStore.readMap(
      dir.path,
      phraseGridSection,
    );
    expect(section.containsKey(path), isTrue);
    expect(GatomixStore.readMap(dir.path, 'djMetadata'), isEmpty);
  });

  test('el relevo de Phrase usa el fundido nuevo y Stealth el de antes', () {
    expect(
      relevoDurationMs(
        derive: true,
        mode: LiveDjMixMode.activeSync,
        formula: MixFormula.dnaEnergy,
      ),
      18000,
    );
    expect(
      relevoDurationMs(
        derive: true,
        mode: LiveDjMixMode.activeSync,
        formula: MixFormula.stealthGap,
        bpm: 90,
        durationMs: 200000,
      ),
      phraseFadeMs(incomingBpm: 90, incomingDurationMs: 200000),
    );
    expect(
      relevoDurationMs(
        derive: true,
        mode: LiveDjMixMode.activeSync,
        formula: MixFormula.phraseGrid,
        bpm: 128,
        durationMs: 200000,
      ),
      15000,
    );
    expect(
      relevoDurationMs(
        derive: true,
        mode: LiveDjMixMode.activeSync,
        formula: MixFormula.phraseGrid,
        bpm: 128,
        durationMs: 200000,
        instrumental: true,
      ),
      18000,
    );
  });
}

PhraseTrack _at(
  int seconds,
  double bpm, {
  int quietFrom = 0,
  int quietUntil = 0,
}) {
  final List<_Part> parts;
  if (quietUntil > 0) {
    parts = <_Part>[
      _Part(quietUntil.toDouble(), 80, 0.05),
      _Part((seconds - quietUntil).toDouble(), 80, 0.50),
    ];
  } else if (quietFrom > 0) {
    parts = <_Part>[
      _Part(quietFrom.toDouble(), 80, 0.50),
      _Part((seconds - quietFrom).toDouble(), 80, 0.05),
    ];
  } else {
    parts = <_Part>[_Part(seconds.toDouble(), 80, 0.50)];
  }
  return _song(seconds: seconds, bpm: bpm, parts: parts);
}

PhraseTrack _tone({
  required int seconds,
  required double bpm,
  required double hz,
  required double amp,
}) {
  return analyzePhraseSamples(
    samples: _sine(seconds: seconds.toDouble(), hz: hz, amp: amp),
    sampleRate: _rate,
    bpm: bpm,
  )!;
}

PhrasePlan _plan(PhraseTrack track, {required int durationMs, required double bpm}) {
  final int snap = snapPhraseGridMixOut(
    durationMs: durationMs,
    dnaMixOutMs: (durationMs * 0.75).toInt(),
    bpm: bpm,
  );
  return planPhrase8(
    outDurationMs: durationMs,
    inDurationMs: durationMs,
    fallbackMixOutMs: snap,
    fallbackCueMs: 10000,
    incomingBpm: bpm,
    incomingRate: 1,
    outgoing: track,
    incoming: track,
  );
}

PhrasePlan _planPair(
  PhraseTrack outgoing,
  PhraseTrack incoming,
  int durationMs,
  double bpm,
) {
  final int snap = snapPhraseGridMixOut(
    durationMs: durationMs,
    dnaMixOutMs: (durationMs * 0.75).toInt(),
    bpm: bpm,
  );
  return planPhrase8(
    outDurationMs: durationMs,
    inDurationMs: durationMs,
    fallbackMixOutMs: snap,
    fallbackCueMs: 10000,
    incomingBpm: bpm,
    incomingRate: 1,
    outgoing: outgoing,
    incoming: incoming,
  );
}

class _Part {
  final double seconds;
  final double hz;
  final double amp;
  const _Part(this.seconds, this.hz, this.amp);
}

PhraseTrack _song({
  required int seconds,
  required double bpm,
  required List<_Part> parts,
}) {
  final Float32List samples = _join(<Float32List>[
    for (final _Part p in parts)
      _sine(seconds: p.seconds, hz: p.hz, amp: p.amp),
  ]);
  final int want = seconds * _rate;
  final Float32List cut = samples.length == want
      ? samples
      : samples.sublist(0, math.min(want, samples.length));
  return analyzePhraseSamples(samples: cut, sampleRate: _rate, bpm: bpm)!;
}

Float32List _sine({
  required double seconds,
  required double hz,
  required double amp,
}) {
  final int n = (seconds * _rate).round();
  final Float32List out = Float32List(n);
  const double pi2 = math.pi * 2;
  for (var i = 0; i < n; i++) {
    out[i] = amp * math.sin(pi2 * hz * i / _rate);
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
