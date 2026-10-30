import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio/mix_pause.dart';
import 'package:gatomix/core/dj_trace.dart';
import 'package:gatomix/providers/automix_provider.dart';
import 'package:gatomix/providers/livedj_provider.dart';

class _Live extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

class _Auto extends AutomixNotifier {
  @override
  AutomixState build() => AutomixState();
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_pause3030_');
    djTraceFileOverride = '${tmp.path}${Platform.pathSeparator}trace.txt';
  });

  tearDown(() {
    djTraceFileOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('la línea de pausa y de reanudación usa el tiempo de mezcla', () {
    expect(
      mixPauseLine(
        resume: false,
        elapsedMs: 4000,
        fadeMs: 10000,
        rampBpm: 128,
      ),
      'PAUSA en mezcla t=4000 fade=40.0 rampa=128.00',
    );
    expect(
      mixPauseLine(
        resume: true,
        elapsedMs: 4000,
        fadeMs: 10000,
        rampBpm: 128,
      ),
      'REANUDA en mezcla t=4000 fade=40.0 rampa=128.00',
    );
  });

  test('la pausa no cuenta en el reloj del fundido', () async {
    final MixPause mix = MixPause();
    mix.arm();
    mix.setRampBpm(120);
    final MixRunClock clock = mix.beginFade(10000);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final String? paused = mix.pauseAll();
    final int frozen = clock.elapsedMilliseconds;
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(clock.elapsedMilliseconds, frozen);
    expect(paused, contains('t=$frozen'));
    final String? resumed = mix.resumeAll();
    expect(resumed, 'REANUDA${paused!.substring('PAUSA'.length)}');
    expect(clock.elapsedMilliseconds, frozen);
  });

  test('la espera se queda quieta mientras dura la pausa', () async {
    final MixPause mix = MixPause();
    mix.arm();
    final MixRunClock clock = mix.clock();
    var done = false;
    final Future<void> step = mix.slice(400, clock).then((_) {
      done = true;
    });
    mix.pauseAll();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(done, isFalse);
    final int frozen = clock.elapsedMilliseconds;
    expect(clock.elapsedMilliseconds, frozen);
    mix.resumeAll();
    await step;
    expect(done, isTrue);
  });

  test('Live DJ: pausa y reanuda a mitad de mezcla sin soltar el cruce', () async {
    final ProviderContainer box = ProviderContainer(
      overrides: <Override>[liveDjProvider.overrideWith(_Live.new)],
    );
    final LiveDjNotifier dj = box.read(liveDjProvider.notifier);
    dj.useSessionFile('${tmp.path}${Platform.pathSeparator}liveDj.json');
    dj.armMixForTest(fadeMs: 10000, rampBpm: 128, elapsedMs: 4000);
    await dj.togglePlayPause();
    final String paused = dj.lastMixHoldLine!;
    expect(paused, startsWith('PAUSA en mezcla '));
    expect(paused, contains('rampa=128.00'));
    expect(dj.mixPaused, isTrue);
    expect(dj.crossfadeHeld, isTrue);
    await dj.forceNext();
    await dj.seek(Duration.zero);
    expect(dj.crossfadeHeld, isTrue);
    expect(dj.mixPaused, isTrue);
    await dj.togglePlayPause();
    final String resumed = dj.lastMixHoldLine!;
    expect(resumed, 'REANUDA${paused.substring('PAUSA'.length)}');
    expect(dj.mixPaused, isFalse);
    expect(dj.crossfadeHeld, isTrue);
    await dj.forceNext();
    expect(dj.crossfadeHeld, isTrue);
    box.dispose();
  });

  test(
    'pausa entre arm y beginFade: entrante no arranca; al reanudar el fundido completa y _isCrossfading vuelve a false',
    () async {
      final ProviderContainer box = ProviderContainer(
        overrides: <Override>[liveDjProvider.overrideWith(_Live.new)],
      );
      final LiveDjNotifier dj = box.read(liveDjProvider.notifier);
      dj.useSessionFile('${tmp.path}${Platform.pathSeparator}liveDj.json');
      dj.armMixPreFadeForTest(rampBpm: 140);
      final int epoch = dj.mixEpoch;
      await dj.togglePlayPause();
      expect(dj.mixPaused, isTrue);
      expect(dj.crossfadeHeld, isTrue);
      expect(dj.lastMixHoldLine, 'PAUSA en mezcla t=0 fade=0.0 rampa=140.00');
      var incomingStarted = false;
      final Future<void> cross = () async {
        final bool go = await dj.holdIncomingBeforePlay(epoch);
        if (!go) return;
        incomingStarted = true;
        await dj.runFadeForTest(fadeMs: 48);
      }();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(incomingStarted, isFalse);
      expect(dj.crossfadeHeld, isTrue);
      await dj.togglePlayPause();
      await cross;
      expect(incomingStarted, isTrue);
      expect(dj.mixPaused, isFalse);
      expect(dj.crossfadeHeld, isFalse);
      box.dispose();
    },
  );

  test('Automix: pausa y reanuda a mitad de mezcla sin soltar el cruce', () async {
    final ProviderContainer box = ProviderContainer(
      overrides: <Override>[automixProvider.overrideWith(_Auto.new)],
    );
    final AutomixNotifier mix = box.read(automixProvider.notifier);
    mix.armMixForTest(fadeMs: 8000, rampBpm: 126.5, elapsedMs: 2000);
    await mix.togglePlayPause();
    final String paused = mix.lastMixHoldLine!;
    expect(paused, startsWith('PAUSA en mezcla '));
    expect(paused, contains('rampa=126.50'));
    expect(mix.mixPaused, isTrue);
    expect(mix.crossfadeHeld, isTrue);
    await mix.togglePlayPause();
    final String resumed = mix.lastMixHoldLine!;
    expect(resumed, 'REANUDA${paused.substring('PAUSA'.length)}');
    expect(mix.mixPaused, isFalse);
    expect(mix.crossfadeHeld, isTrue);
    box.dispose();
  });
}
