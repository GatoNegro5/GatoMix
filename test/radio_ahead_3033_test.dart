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

Future<void> _until(bool Function() ok, {int ms = 8000}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!ok() && sw.elapsedMilliseconds < ms) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  late Directory dir;
  late List<String> files;
  late ProviderContainer box;
  late LiveDjNotifier dj;

  List<String> upcoming() => box.read(liveDjProvider).radioUpcoming;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('gmx_ahead3034_');
    files = <String>[
      for (var i = 0; i < 10; i++)
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
      memory: RadioMemory.empty.putPlan('bailable', RadioPlan(order: files)),
      genre: 'bailable',
    );
  });

  tearDown(() {
    box.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('con plan válido la lista es el plan entero; ahead no la recorta', () {
    final RadioPlan plan = RadioPlan(order: files, position: 3);
    expect(
      radioUpcomingPaths(plan: plan, ahead: <String>[files[3]]),
      files.sublist(3),
    );
    expect(
      radioUpcomingPaths(plan: plan, nextPath: files[3]).length,
      7,
    );
    // Sin plan (o terminado) solo cuenta la próxima.
    expect(
      radioUpcomingPaths(ahead: <String>[files[1]], nextPath: files[0]),
      <String>[files[1]],
    );
    expect(
      radioUpcomingPaths(
        plan: RadioPlan(order: files, position: 10),
        nextPath: files[0],
      ),
      <String>[files[0]],
    );
  });

  test('pool de 10: la cola muestra las 10 y el armado no espera', () async {
    await dj.refillRadioAhead();
    final List<String> up = upcoming();
    expect(up.length, 10);
    expect(up.toSet().length, 10);
    expect(up.every(files.contains), isTrue);
    // El tick lee la próxima de forma síncrona: sin await, sin disco.
    expect(dj.radioPendingReadyNow, up.first);
  });

  test('consumir una deja 9 y no se repite', () async {
    await dj.refillRadioAhead();
    final String played = dj.radioPendingReadyNow!;
    dj.finishRadioMix(played);
    expect(upcoming().length, 9);
    expect(upcoming().any((String p) => sameAudioPath(p, played)), isFalse);
    await dj.refillRadioAhead();
    expect(upcoming().length, 9);
    expect(dj.radioPendingReadyNow, upcoming().first);
  });

  test('se tocan las 10 sin repetir y al terminar se rearma distinto', () async {
    final List<String> heard = <String>[];
    for (var n = 0; n < 10; n++) {
      await dj.refillRadioAhead();
      expect(upcoming().length, 10 - n, reason: 'antes de la mezcla $n');
      final String next = dj.radioPendingReadyNow!;
      expect(heard.any((String h) => sameAudioPath(h, next)), isFalse);
      heard.add(next);
      dj.finishRadioMix(next);
    }
    expect(heard.toSet().length, 10);
    expect(dj.radioMemoryNow.planOf('bailable')!.finished, isTrue);
    expect(upcoming(), isEmpty);
    await dj.refillRadioAhead();
    await _until(() => upcoming().length == 10);
    final List<String> again = upcoming();
    expect(again.length, 10);
    expect(again.toSet().length, 10);
    expect(again.every(files.contains), isTrue);
    expect(again, isNot(heard));
  });

  test('un cambio de opción invalida la próxima de la época vieja', () async {
    await dj.refillRadioAhead();
    expect(dj.radioPendingReadyNow, isNotNull);
    dj.showRadioGenre('bailable');
    expect(dj.radioPendingReadyNow, isNull);
  });
}
