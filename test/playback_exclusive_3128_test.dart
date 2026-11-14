import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio/playback_owner.dart';
import 'package:gatomix/core/dj_trace.dart';
import 'package:gatomix/providers/automix_provider.dart';
import 'package:gatomix/providers/livedj_provider.dart';

class _Live extends LiveDjNotifier {
  @override
  LiveDjState build() {
    attachPlaybackExclusion();
    return LiveDjState();
  }
}

class _Auto extends AutomixNotifier {
  @override
  AutomixState build() {
    attachPlaybackExclusion();
    return AutomixState();
  }
}

void main() {
  late Directory tmp;
  late ProviderContainer box;
  late AutomixNotifier auto;
  late LiveDjNotifier live;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_excl3128_');
    djTraceFileOverride = '${tmp.path}${Platform.pathSeparator}trace.txt';
    box = ProviderContainer(
      overrides: <Override>[
        automixProvider.overrideWith(_Auto.new),
        liveDjProvider.overrideWith(_Live.new),
      ],
    );
    auto = box.read(automixProvider.notifier);
    live = box.read(liveDjProvider.notifier);
    live.useSessionFile('${tmp.path}${Platform.pathSeparator}liveDj.json');
  });

  tearDown(() {
    box.dispose();
    djTraceFileOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('3128 cambiar de pestana (leer ambos motores) no pausa a nadie', () {
    auto.armMixForTest(fadeMs: 8000, rampBpm: 126, elapsedMs: 2000);
    live.armMixForTest(fadeMs: 8000, rampBpm: 128, elapsedMs: 2000);
    box.read(automixProvider);
    box.read(liveDjProvider);
    expect(auto.mixPaused, isFalse);
    expect(live.mixPaused, isFalse);
    expect(box.read(playbackOwnerProvider).owner, isNull);
  });

  test('3128 Play en Live DJ pausa a Automix a mitad de cruce', () async {
    auto.armMixForTest(fadeMs: 8000, rampBpm: 126, elapsedMs: 2000);
    await live.claimPlaybackForTest();
    expect(auto.mixPaused, isTrue);
    expect(auto.crossfadeHeld, isTrue);
    expect(auto.yieldedToOtherEngine, 1);
    expect(live.yieldedToOtherEngine, 0);
    expect(box.read(playbackOwnerProvider).owner, PlaybackEngine.liveDj);
  });

  test('3128 Play en Automix reanuda su cruce y pausa a Live DJ', () async {
    auto.armMixForTest(fadeMs: 8000, rampBpm: 126, elapsedMs: 2000);
    live.armMixForTest(fadeMs: 8000, rampBpm: 128, elapsedMs: 2000);
    await live.claimPlaybackForTest();
    expect(auto.mixPaused, isTrue);
    await auto.togglePlayPause();
    expect(auto.mixPaused, isFalse);
    expect(live.mixPaused, isTrue);
    expect(live.yieldedToOtherEngine, 1);
    expect(box.read(playbackOwnerProvider).owner, PlaybackEngine.automix);
  });

  test('3128 un motor que reclama no se pausa a si mismo', () async {
    auto.armMixForTest(fadeMs: 8000, rampBpm: 126, elapsedMs: 2000);
    await auto.claimPlaybackForTest();
    await auto.claimPlaybackForTest();
    expect(auto.mixPaused, isFalse);
    expect(auto.yieldedToOtherEngine, 0);
  });
}
