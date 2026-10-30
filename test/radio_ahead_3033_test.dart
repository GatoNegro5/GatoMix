import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio_path.dart';
import 'package:gatomix/core/gatomix_radio.dart';
import 'package:gatomix/core/livedj_next.dart';
import 'package:gatomix/providers/livedj_provider.dart';

class _Live extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

void main() {
  late Directory dir;
  late List<String> files;
  late ProviderContainer box;
  late LiveDjNotifier dj;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('gmx_ahead3033_');
    files = <String>[
      for (var i = 0; i < 8; i++)
        (File('${dir.path}${Platform.pathSeparator}t$i 12${i}bpm.mp3')
              ..writeAsBytesSync(<int>[0]))
            .path,
    ];
    box = ProviderContainer(
      overrides: <Override>[liveDjProvider.overrideWith(_Live.new)],
    );
    dj = box.read(liveDjProvider.notifier);
    dj.useRadioLibrary(dir.path);
    dj.seedRadioIndex(genre: 'bailable', files: files);
    dj.seedRadio(
      memory: RadioMemory.empty.putPlan(
        'bailable',
        RadioPlan(order: files.sublist(1)),
      ),
      genre: 'bailable',
      playing: files[0],
    );
  });

  tearDown(() {
    box.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('la lista de próximas topa en 3', () {
    expect(
      radioUpcomingPaths(ahead: files, nextPath: files[0]).length,
      kRadioAheadCount,
    );
    expect(radioUpcomingPaths(nextPath: files[0]), <String>[files[0]]);
  });

  test('al encender quedan 3 próximas listas y el armado no espera', () async {
    await dj.refillRadioAhead();
    final List<String> up = box.read(liveDjProvider).radioUpcoming;
    expect(up.length, 3);
    expect(up.toSet().length, 3);
    expect(up.any((String p) => sameAudioPath(p, files[0])), isFalse);
    expect(up.every(files.contains), isTrue);
    expect(up.every((String p) => File(p).existsSync()), isTrue);
    // El tick lee la elegida de forma síncrona: sin await, sin disco.
    expect(dj.radioPendingReadyNow, up.first);
  });

  test('consumir la primera repone en segundo plano', () async {
    await dj.refillRadioAhead();
    final List<String> before = box.read(liveDjProvider).radioUpcoming;
    dj.finishRadioMix(before.first);
    final List<String> mid = box.read(liveDjProvider).radioUpcoming;
    expect(mid.length, 2);
    expect(mid, before.sublist(1));
    expect(dj.radioPendingReadyNow, isNull);
    await dj.refillRadioAhead();
    final List<String> after = box.read(liveDjProvider).radioUpcoming;
    expect(after.length, 3);
    expect(after.first, before[1]);
    expect(after.any((String p) => sameAudioPath(p, before.first)), isFalse);
    expect(dj.radioPendingReadyNow, after.first);
  });

  test('un cambio de opción invalida las próximas de la época vieja', () async {
    await dj.refillRadioAhead();
    final List<String> up = box.read(liveDjProvider).radioUpcoming;
    expect(up.length, 3);
    dj.showRadioGenre('bailable');
    expect(box.read(liveDjProvider).radioUpcoming, isNot(up));
    expect(dj.radioPendingReadyNow, isNull);
  });
}
