import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/audio_path.dart';
import 'package:gatomix/core/gatomix_radio.dart';
import 'package:gatomix/providers/livedj_provider.dart';

double bpmOf(String p) {
  final RegExpMatch? m = RegExp(r'(\d+)bpm').firstMatch(p);
  return m == null ? 0 : double.parse(m.group(1)!);
}

List<String> poolOf(String dir, int n) => <String>[
  for (var i = 0; i < n; i++) '$dir/t$i ${100 + i}bpm.mp3',
];

class _RadioHarness extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

void main() {
  test('el fallback no elige la que suena ni la anterior', () {
    const String volvere = '/m/Wilfrido Vargas - Volvere 158bpm.mp3';
    const String capi = '/m/Myke Towers - La Capi 158bpm.mp3';
    expect(
      radioQuickNext(
        pool: const <String>[volvere, capi],
        anchor: capi,
        previous: volvere,
        bpmOf: bpmOf,
        rng: Random(1),
      ),
      isNull,
    );
    const String otra = '/m/Toto - Stranger 156bpm.mp3';
    final String? next = radioQuickNext(
      pool: const <String>[volvere, capi, otra],
      anchor: capi,
      previous: volvere,
      bpmOf: bpmOf,
      rng: Random(1),
    );
    expect(next, otra);
  });

  test('20 mezclas de Bailable recorren la lista y la posición avanza 20', () async {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_baila20_');
    final List<String> pool = poolOf(dir.path, 25);
    final RadioSync built = syncRadioPlan(
      saved: null,
      pool: pool,
      bpmOf: bpmOf,
      rng: Random(7),
    );
    expect(built.plan.order.length, 25);
    final ProviderContainer box = ProviderContainer(
      overrides: <Override>[liveDjProvider.overrideWith(_RadioHarness.new)],
    );
    final LiveDjNotifier dj = box.read(liveDjProvider.notifier);
    dj.useRadioLibrary(dir.path);
    final String volvere = '${dir.path}/Wilfrido Vargas - Volvere 158bpm.mp3';
    dj.seedRadio(
      memory: RadioMemory.empty.putPlan('bailable', built.plan),
      genre: 'bailable',
      playing: volvere,
    );
    final List<String> heard = <String>[];
    for (var n = 0; n < 20; n++) {
      final String? next = dj.followRadioNext(pool, bpmOf: bpmOf);
      expect(next, built.plan.order[n], reason: 'mezcla $n');
      expect(next, isNot(volvere));
      if (heard.isNotEmpty) expect(next, isNot(heard.last));
      heard.add(next!);
      dj.finishRadioMix(next);
      expect(dj.radioMemoryNow.planOf('bailable')!.position, n + 1);
    }
    expect(heard.toSet().length, 20);
    expect(
      dj.radioMemoryNow.planOf('bailable')!.order.sublist(0, 20),
      heard,
    );
    await dj.flushRadioSave();
    final RadioMemory loaded = GatomixRadio.load(dir.path);
    expect(loaded.planOf('bailable')!.position, 20);
    expect(
      sameRadioOrder(loaded.planOf('bailable')!.order, built.plan.order),
      isTrue,
    );
    box.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('cambiar de opción no reinicia la posición de Bailable', () {
    final List<String> baila = poolOf('/b', 10);
    final List<String> ochenta = poolOf('/o', 10);
    final RadioPlan bailaPlan = syncRadioPlan(
      saved: null,
      pool: baila,
      bpmOf: bpmOf,
      rng: Random(2),
    ).plan;
    final RadioPlan ochentaPlan = syncRadioPlan(
      saved: null,
      pool: ochenta,
      bpmOf: bpmOf,
      rng: Random(3),
    ).plan.copy(position: 4);
    final ProviderContainer box = ProviderContainer(
      overrides: <Override>[liveDjProvider.overrideWith(_RadioHarness.new)],
    );
    final LiveDjNotifier dj = box.read(liveDjProvider.notifier);
    dj.seedRadio(
      memory: RadioMemory.empty
          .putPlan('bailable', bailaPlan)
          .putPlan('ochenteras', ochentaPlan),
      genre: 'bailable',
      playing: '/now/Volvere 158bpm.mp3',
    );
    final String? first = dj.followRadioNext(baila, bpmOf: bpmOf);
    expect(first, bailaPlan.order.first);
    dj.finishRadioMix(first!);
    dj.finishRadioMix(dj.followRadioNext(baila, bpmOf: bpmOf)!);
    dj.finishRadioMix(dj.followRadioNext(baila, bpmOf: bpmOf)!);
    expect(dj.radioMemoryNow.planOf('bailable')!.position, 3);
    dj.showRadioGenre('ochenteras');
    final String? o = dj.followRadioNext(ochenta, bpmOf: bpmOf);
    expect(o, ochentaPlan.order[4]);
    expect(dj.state.radioNextPath, o);
    expect(dj.radioMemoryNow.planOf('bailable')!.position, 3);
    expect(
      sameRadioOrder(dj.radioMemoryNow.planOf('bailable')!.order, bailaPlan.order),
      isTrue,
    );
    box.dispose();
  });

  test('con la actual clavada en el puesto 0 no se repite y no hay A→B→A', () {
    const String volvere = '/m/Wilfrido Vargas - Volvere 158bpm.mp3';
    const String capi = '/m/Myke Towers - La Capi 157bpm.mp3';
    final List<String> rest = poolOf('/m', 8);
    final RadioPlan stuck = RadioPlan(
      order: <String>[volvere, capi, ...rest],
      position: 0,
    );
    final ProviderContainer box = ProviderContainer(
      overrides: <Override>[liveDjProvider.overrideWith(_RadioHarness.new)],
    );
    final LiveDjNotifier dj = box.read(liveDjProvider.notifier);
    dj.seedRadio(
      memory: RadioMemory.empty.putPlan('bailable', stuck),
      genre: 'bailable',
      playing: volvere,
    );
    final String? first = dj.followRadioNext(<String>[
      volvere,
      capi,
      ...rest,
    ], bpmOf: bpmOf);
    expect(first, capi);
    dj.finishRadioMix(first!);
    final String? second = dj.followRadioNext(<String>[
      volvere,
      capi,
      ...rest,
    ], bpmOf: bpmOf);
    expect(second, isNot(volvere));
    expect(second, isNot(capi));
    expect(second, rest.first);
    box.dispose();
  });

  test('Automix sigue el orden, no el BPM más cercano', () {
    const List<String> q = <String>[
      '/a/uno 128bpm.mp3',
      '/a/dos 134bpm.mp3',
      '/a/tres 129bpm.mp3',
    ];
    expect(nextDifferentAudioIndex(q, 0, q.first), 1);
  });
}
