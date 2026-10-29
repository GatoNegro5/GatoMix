import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/deck_duration.dart';
import 'package:gatomix/core/livedj_next.dart';

void main() {
  // Hurt So Good: el audio acaba a los 03:35 y el conteo de frames sigue ~01:08.
  const int playedMs = 215000;
  const int frameMs = 283000;

  test('conteo más largo que el reproductor: manda el corto creíble', () {
    expect(
      resolveDeckDurationMs(frameMs: frameMs, playerMs: playedMs),
      playedMs,
    );
  });

  test('libmpv alarga por bitrate: manda el conteo, que es el corto', () {
    expect(resolveDeckDurationMs(frameMs: 200000, playerMs: 240000), 200000);
  });

  test('reproductor en 0 o bajo la mitad del conteo: manda el conteo', () {
    expect(resolveDeckDurationMs(frameMs: frameMs, playerMs: 0), frameMs);
    expect(
      resolveDeckDurationMs(frameMs: frameMs, playerMs: frameMs ~/ 2 - 1),
      frameMs,
    );
  });

  test('coinciden a 1,5 s: se queda la del reproductor', () {
    expect(
      resolveDeckDurationMs(frameMs: playedMs, playerMs: playedMs + 1200),
      playedMs + 1200,
    );
  });

  test('sin conteo: se queda la del reproductor', () {
    expect(resolveDeckDurationMs(frameMs: 0, playerMs: playedMs), playedMs);
  });

  test('una corta creíble ya publicada no se estira con el conteo', () {
    expect(
      resolveDeckDurationMs(
        frameMs: frameMs,
        playerMs: frameMs,
        heldMs: playedMs,
      ),
      playedMs,
    );
  });

  test('una corta posterior creíble sustituye a la publicada', () {
    expect(
      resolveDeckDurationMs(
        frameMs: frameMs,
        playerMs: playedMs,
        heldMs: frameMs,
      ),
      playedMs,
    );
  });

  test('una estimación de arranque no achica la duración publicada', () {
    expect(
      resolveDeckDurationMs(frameMs: frameMs, playerMs: 30000, heldMs: frameMs),
      frameMs,
    );
  });

  test('el 75 % de la duración real no se mueve; un disparo tardío sí', () {
    final int real = playedMs;
    final int dna75 = (real * 0.75).round();
    expect(clampMixTriggerMs(triggerMs: dna75, realDurationMs: real), dna75);
    expect(
      clampMixTriggerMs(triggerMs: (real * 0.65).round(), realDurationMs: real),
      (real * 0.65).round(),
    );
    expect(
      clampMixTriggerMs(triggerMs: (real * 0.80).round(), realDurationMs: real),
      (real * 0.80).round(),
    );
    // Plan calculado sobre el conteo largo: cae después del audio.
    expect(
      clampMixTriggerMs(
        triggerMs: (frameMs * 0.80).round(),
        realDurationMs: real,
      ),
      real - kMinMixLengthMs,
    );
    expect(
      clampMixTriggerMs(triggerMs: frameMs - 4000, realDurationMs: real),
      real - kMinMixLengthMs,
    );
  });

  test('disparo 0 o duración 0 no se inventan', () {
    expect(clampMixTriggerMs(triggerMs: 0, realDurationMs: playedMs), 0);
    expect(clampMixTriggerMs(triggerMs: 150000, realDurationMs: 0), 150000);
  });

  test(
    'pista corta: no se baja el disparo de los 10 s si ya es antes del final',
    () {
      const int dur = 15000;
      const int trigger = 11250;
      expect(
        clampMixTriggerMs(triggerMs: trigger, realDurationMs: dur),
        trigger,
      );
      expect(
        clampMixTriggerMs(triggerMs: 20000, realDurationMs: dur),
        dur - kMinMixLengthMs,
      );
    },
  );

  test('duración del reproductor más corta y creíble es el final real', () {
    expect(
      earlyPlaybackEndMs(
        computedEndMs: frameMs,
        positionMs: 0,
        playerDurationMs: playedMs,
        deckCompleted: false,
        positionStalled: false,
      ),
      playedMs,
    );
  });

  test('deck terminado o posición quieta antes del final calculado', () {
    expect(
      earlyPlaybackEndMs(
        computedEndMs: frameMs,
        positionMs: playedMs,
        playerDurationMs: frameMs,
        deckCompleted: true,
        positionStalled: false,
      ),
      playedMs,
    );
    expect(
      earlyPlaybackEndMs(
        computedEndMs: frameMs,
        positionMs: playedMs,
        playerDurationMs: frameMs,
        deckCompleted: false,
        positionStalled: true,
      ),
      playedMs,
    );
  });

  test('sin parada y sin reproductor corto: el cálculo sigue', () {
    expect(
      earlyPlaybackEndMs(
        computedEndMs: frameMs,
        positionMs: 100000,
        playerDurationMs: frameMs,
        deckCompleted: false,
        positionStalled: false,
      ),
      isNull,
    );
    expect(
      earlyPlaybackEndMs(
        computedEndMs: frameMs,
        positionMs: 10000,
        playerDurationMs: frameMs,
        deckCompleted: true,
        positionStalled: false,
      ),
      isNull,
    );
    expect(
      earlyPlaybackEndMs(
        computedEndMs: frameMs,
        positionMs: frameMs - 500,
        playerDurationMs: frameMs,
        deckCompleted: true,
        positionStalled: true,
      ),
      isNull,
    );
  });

  test('la posición quieta cuenta solo en play, no en pausa ni en buffer', () {
    final PlaybackStallWatch watch = PlaybackStallWatch();
    expect(
      watch.stalled(
        positionMs: playedMs,
        playing: true,
        buffering: false,
        nowMs: 0,
      ),
      isFalse,
    );
    expect(
      watch.stalled(
        positionMs: playedMs,
        playing: true,
        buffering: false,
        nowMs: 1600,
      ),
      isTrue,
    );
    expect(
      watch.stalled(
        positionMs: playedMs + 1000,
        playing: true,
        buffering: false,
        nowMs: 3200,
      ),
      isFalse,
    );
    expect(
      watch.stalled(
        positionMs: playedMs + 1000,
        playing: false,
        buffering: false,
        nowMs: 9000,
      ),
      isFalse,
    );
    final PlaybackStallWatch buffered = PlaybackStallWatch();
    buffered.stalled(
      positionMs: playedMs,
      playing: true,
      buffering: false,
      nowMs: 0,
    );
    expect(
      buffered.stalled(
        positionMs: playedMs,
        playing: true,
        buffering: true,
        nowMs: 5000,
      ),
      isFalse,
    );
  });

  test('fin sin mezcla: el deck armado entra; sin armado, no', () {
    expect(
      handoffToArmedDeck(
        standbyArmed: true,
        armedPath: r'C:\Music\next.mp3',
        radioOn: false,
        armedIsCurrent: false,
        armedInQueue: true,
      ),
      isTrue,
    );
    expect(
      handoffToArmedDeck(
        standbyArmed: false,
        armedPath: r'C:\Music\next.mp3',
        radioOn: false,
        armedIsCurrent: false,
        armedInQueue: true,
      ),
      isFalse,
    );
    expect(
      handoffToArmedDeck(
        standbyArmed: true,
        armedPath: r'C:\Music\now.mp3',
        radioOn: false,
        armedIsCurrent: true,
        armedInQueue: true,
      ),
      isFalse,
    );
    expect(
      handoffToArmedDeck(
        standbyArmed: true,
        armedPath: r'C:\Music\radio.mp3',
        radioOn: false,
        armedIsCurrent: false,
        armedInQueue: false,
      ),
      isFalse,
    );
    expect(
      handoffToArmedDeck(
        standbyArmed: true,
        armedPath: r'C:\Music\radio.mp3',
        radioOn: true,
        armedIsCurrent: false,
        armedInQueue: false,
      ),
      isTrue,
    );
  });
}
