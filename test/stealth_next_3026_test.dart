import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/core/livedj_next.dart';
import 'package:gatomix/core/queue_bpm.dart';
import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/providers/mix_formula.dart';
import 'package:gatomix/services/track_tags.dart';
import 'package:gatomix/ui/workspaces/livedj_workspace.dart';

const String _rose = '/m/Rose 100bpm.mp3';
const String _toto = '/m/Toto 170bpm.mp3';
const String _lipps = '/m/Lipps 104bpm.mp3';
const String _holmes = '/m/Holmes.mp3';
const List<String> _queue = <String>[_toto, _lipps, _holmes];

class _Harness extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

class _PanelDj extends LiveDjNotifier {
  @override
  LiveDjState build() => _panelState;
}

LiveDjState _panelState = LiveDjState();

String _file(String path) => path.replaceAll('\\', '/').split('/').last;

/// Igual que el cruce: quita de la cola la ruta que entra al deck.
List<String> _queueWithout(List<String> queue, String enters) {
  final List<String> left = List<String>.from(queue);
  final int at = left.indexWhere((String p) => p == enters);
  if (at >= 0) left.removeAt(at);
  return left;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Stealth radio apagada: BPM más cercano, barra = deck = cola', () {
    final int i = offAirNextIndex(
      paths: _queue,
      currentPath: _rose,
      stealth: true,
      bpmOf: knownBpm,
    );
    expect(i, 1, reason: '104 está más cerca de 100 que 170; Holmes sin BPM');
    final String enters = _queue[i];
    final String? bar = LiveDjNextLabel().text(
      radioOn: false,
      radioNextPath: _toto,
      queuePaths: _queue,
      currentPath: _rose,
      stealth: true,
      bpmOf: knownBpm,
    );
    expect(bar, _file(enters));
    expect(bar, 'Lipps 104bpm.mp3');
    final List<String> left = _queueWithout(_queue, enters);
    expect(left, isNot(contains(enters)));
    expect(left, <String>[_toto, _holmes]);
    expect(_file(enters), bar);

    final ProviderContainer box = ProviderContainer(
      overrides: <Override>[liveDjProvider.overrideWith(_Harness.new)],
    );
    addTearDown(box.dispose);
    box.read(mixFormulaProvider.notifier).state = MixFormula.stealthGap;
    final LiveDjNotifier dj = box.read(liveDjProvider.notifier);
    dj.seedOffAirQueue(queue: _queue, playing: _rose);
    expect(dj.debugNextQueueIndex(), i);
    expect(_queue[dj.debugNextQueueIndex()], enters);
  });

  test('Stealth no elige la que suena y deja las sin BPM al final', () {
    const List<String> queue = <String>[
      _rose,
      '/m/none-a.mp3',
      _toto,
      '/m/none-b.mp3',
      _lipps,
    ];
    double bpmOf(String path) {
      if (path.endsWith('Rose 100bpm.mp3')) return 100;
      if (path.endsWith('Toto 170bpm.mp3')) return 170;
      if (path.endsWith('Lipps 104bpm.mp3')) return 104;
      return 0;
    }

    expect(
      offAirNextIndex(
        paths: queue,
        currentPath: _rose,
        stealth: true,
        bpmOf: bpmOf,
      ),
      4,
    );
    expect(
      liveDjFollowingLabel(
        radioOn: false,
        radioNextPath: null,
        queuePaths: queue,
        currentPath: _rose,
        stealth: true,
        bpmOf: bpmOf,
      ),
      'Lipps 104bpm.mp3',
    );
    const List<String> onlySilent = <String>['/m/none-a.mp3', '/m/none-b.mp3'];
    expect(
      offAirNextIndex(
        paths: onlySilent,
        currentPath: _rose,
        stealth: true,
        bpmOf: bpmOf,
      ),
      0,
    );
  });

  test('DNA y Phrase 8 siguen en la cabeza', () {
    for (final MixFormula formula in <MixFormula>[
      MixFormula.dnaEnergy,
      MixFormula.phraseGrid,
    ]) {
      final ProviderContainer box = ProviderContainer(
        overrides: <Override>[liveDjProvider.overrideWith(_Harness.new)],
      );
      addTearDown(box.dispose);
      box.read(mixFormulaProvider.notifier).state = formula;
      final LiveDjNotifier dj = box.read(liveDjProvider.notifier);
      dj.seedOffAirQueue(queue: _queue, playing: _rose);
      expect(dj.debugNextQueueIndex(), 0, reason: formula.name);
      expect(
        liveDjFollowingLabel(
          radioOn: false,
          radioNextPath: _lipps,
          queuePaths: _queue,
          currentPath: _rose,
        ),
        'Toto 170bpm.mp3',
      );
      final String? bar = LiveDjNextLabel().text(
        radioOn: false,
        radioNextPath: _lipps,
        queuePaths: _queue,
        currentPath: _rose,
        stealth: false,
        bpmOf: knownBpm,
      );
      expect(bar, 'Toto 170bpm.mp3');
      expect(_queue[dj.debugNextQueueIndex()], _toto);
    }
  });

  test('Stealth con la radio encendida muestra la lista de la radio', () {
    const String cars = '/m/The Cars - Shake It Up.mp3';
    const String lime = '/m/Lime - Your Love.mp3';
    const List<String> upcoming = <String>[cars, lime];
    final String? bar = LiveDjNextLabel().text(
      radioOn: true,
      radioNextPath: cars,
      queuePaths: _queue,
      currentPath: _rose,
      stealth: true,
      bpmOf: knownBpm,
    );
    expect(bar, 'RADIO ▸ The Cars - Shake It Up.mp3');
    expect(bar, isNot('Lipps 104bpm.mp3'));
    expect(
      liveDjSidePaths(
        radioOn: true,
        queuePaths: _queue,
        radioUpcoming: upcoming,
      ),
      upcoming,
    );
    expect(
      liveDjSidePaths(
        radioOn: false,
        queuePaths: _queue,
        radioUpcoming: upcoming,
      ),
      _queue,
    );
  });

  test('el BPM de Stealth sale de memoria y el reloj no relee el JSON', () {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_stealth26_');
    final String sep = Platform.pathSeparator;
    final String playing = '${dir.path}${sep}Rose.mp3';
    final String far = '${dir.path}${sep}Toto.mp3';
    final String near = '${dir.path}${sep}Lipps.mp3';
    final String none = '${dir.path}${sep}Holmes.mp3';
    final List<String> queue = <String>[far, none, near];
    TrackTags.clear();
    File('${dir.path}$sep.gatomix.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'schema': 1,
        'djMetadata': <String, dynamic>{playing: 100, far: 170, near: 104},
      }),
    );
    expect(knownBpm(near), 104);
    expect(knownBpm(playing), 100);
    expect(knownBpm(none), 0);
    final int reads = GatomixStore.debugDiskReads;
    final LiveDjNextLabel label = LiveDjNextLabel();
    for (var n = 0; n < 30; n++) {
      final int i = offAirNextIndex(
        paths: queue,
        currentPath: playing,
        stealth: true,
        bpmOf: knownBpm,
      );
      expect(i, 2);
      expect(
        label.text(
          radioOn: false,
          radioNextPath: null,
          queuePaths: queue,
          currentPath: playing,
          stealth: true,
          bpmOf: knownBpm,
        ),
        'Lipps.mp3',
      );
    }
    expect(GatomixStore.debugDiskReads, reads);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('la barra de Live DJ muestra la misma pista que entra', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const Size size = Size(1280, 720);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;

    _panelState = LiveDjState(
      isPlaying: true,
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 4),
      currentTrackPath: _rose,
      queue: <File>[for (final String p in _queue) File(p)],
    );
    final ProviderContainer box = ProviderContainer(
      overrides: <Override>[liveDjProvider.overrideWith(_PanelDj.new)],
    );
    addTearDown(box.dispose);
    box.read(mixFormulaProvider.notifier).state = MixFormula.stealthGap;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: box,
        child: const MaterialApp(
          home: Scaffold(body: LiveDjPlayerPanel(compactOverride: false)),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final LiveDjNotifier dj = box.read(liveDjProvider.notifier);
    final int i = dj.debugNextQueueIndex();
    final String enters = dj.state.queue[i].path;
    expect(_file(enters), 'Lipps 104bpm.mp3');
    expect(find.text('Lipps 104bpm.mp3'), findsOneWidget);
    expect(
      _queueWithout(dj.state.queue.map((File f) => f.path).toList(), enters),
      <String>[_toto, _holmes],
    );

    box.read(mixFormulaProvider.notifier).state = MixFormula.dnaEnergy;
    await tester.pump();
    expect(dj.debugNextQueueIndex(), 0);
    expect(find.text('Toto 170bpm.mp3'), findsOneWidget);

    box.read(mixFormulaProvider.notifier).state = MixFormula.phraseGrid;
    await tester.pump();
    expect(dj.debugNextQueueIndex(), 0);
    expect(find.text('Toto 170bpm.mp3'), findsOneWidget);

    dj.seedOffAirQueue(
      queue: _queue,
      playing: _rose,
      radioOn: true,
      radioNextPath: '/m/The Cars - Shake It Up.mp3',
      radioUpcoming: const <String>[
        '/m/The Cars - Shake It Up.mp3',
        '/m/Lime - Your Love.mp3',
      ],
    );
    box.read(mixFormulaProvider.notifier).state = MixFormula.stealthGap;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('RADIO ▸ The Cars - Shake It Up.mp3'), findsOneWidget);
    expect(find.text('Lipps 104bpm.mp3'), findsNothing);
  });
}
