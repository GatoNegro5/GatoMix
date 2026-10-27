import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio_path.dart';
import 'package:gatomix/core/gatomix_radio.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/core/livedj_next.dart';
import 'package:gatomix/core/queue_bpm.dart';
import 'package:gatomix/services/track_tags.dart';

void main() {
  test('radio apagada: la siguiente es la cabeza, no el BPM más cercano', () {
    const String playing = r'C:\Music\80s\Rose Nuth - Have A Cigar.mp3';
    const List<String> queue = <String>[
      r'C:\Music\80s\Toto - Stranger In Town.mp3',
      r'C:\Music\80s\Lipps Inc. - Designer Music.mp3',
      r'C:\Music\80s\Rupert Holmes - Escape.mp3',
    ];
    expect(queueHeadIndex(queue, playing), 0);
    expect(
      liveDjFollowingLabel(
        radioOn: false,
        radioNextPath: r'C:\Music\80s\The Cars - Shake It Up.mp3',
        queuePaths: queue,
        currentPath: playing,
      ),
      'Toto - Stranger In Town.mp3',
    );
    expect(
      nextDifferentAudioIndex(
        <String>[playing, ...queue],
        0,
        playing,
      ),
      1,
    );
  });

  test('apagar la radio no toca el deck y la siguiente es Toto', () {
    const String rose = r'C:\Music\Radio\Rose Nuth - Have A Cigar.mp3';
    const List<String> frozen = <String>[
      r'C:\Music\80s\Toto - Stranger In Town.mp3',
      r'C:\Music\80s\Lipps Inc. - Designer Music.mp3',
    ];
    final RadioOffEffect effect = effectOfRadioOff(
      queue: frozen,
      frozenQueue: frozen,
      playing: rose,
    );
    expect(effect.touchDeck, isFalse);
    expect(effect.deckCommands, isEmpty);
    expect(effect.radioOn, isFalse);
    expect(effect.playing, rose);
    expect(effect.queue, frozen);
    expect(effect.nextPath, frozen.first);
    expect(
      radioArmStillValid(radioOn: false, epoch: 4, armEpoch: 3),
      isFalse,
    );
    expect(
      radioArmStillValid(radioOn: true, epoch: 4, armEpoch: 3),
      isFalse,
    );
    expect(
      radioArmStillValid(radioOn: true, epoch: 4, armEpoch: 4),
      isTrue,
    );
  });

  test('la vista de radio sale del plan en memoria, no de la cola', () {
    const RadioPlan plan = RadioPlan(
      order: <String>[
        r'C:\Music\80s\Donna Summer - Romeo.mp3',
        r'C:\Music\80s\The Cars - Shake It Up.mp3',
        r'C:\Music\80s\Lime - Your Love.mp3',
      ],
      position: 1,
    );
    final List<String> upcoming = radioUpcomingPaths(
      plan: plan,
      nextPath: plan.order[1],
    );
    expect(upcoming.first, endsWith('The Cars - Shake It Up.mp3'));
    expect(upcoming, hasLength(2));
    const List<String> live = <String>[
      r'C:\Music\80s\Toto - Stranger In Town.mp3',
    ];
    expect(
      liveDjSidePaths(
        radioOn: true,
        queuePaths: live,
        radioUpcoming: upcoming,
      ),
      upcoming,
    );
    expect(
      liveDjSidePaths(
        radioOn: false,
        queuePaths: live,
        radioUpcoming: upcoming,
      ),
      live,
    );
    expect(
      liveDjFollowingLabel(
        radioOn: true,
        radioNextPath: upcoming.first,
        queuePaths: live,
        currentPath: plan.order.first,
      ),
      'RADIO ▸ The Cars - Shake It Up.mp3',
    );
  });

  test('un BPM que aparece después no se queda en 0', () {
    final Directory dir = Directory.systemTemp.createTempSync('gatomix_bpm0_');
    final String sep = Platform.pathSeparator;
    final String path = '${dir.path}${sep}Rose Nuth.mp3';
    TrackTags.clear();
    expect(knownBpm(path), 0);
    File('${dir.path}$sep.gatomix.json').writeAsStringSync(
      '{"schema":1,"djMetadata":{"$path":138}}',
    );
    expect(knownBpm(path), 138);
    final int mid = GatomixStore.debugDiskReads;
    for (var i = 0; i < 30; i++) {
      expect(knownBpm(path), 138);
    }
    expect(GatomixStore.debugDiskReads, mid);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
}
