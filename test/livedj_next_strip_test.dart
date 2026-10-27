import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/ui/workspaces/livedj_workspace.dart';

/// No abre los decks: solo pinta el panel para medir la franja.
class _FakeLiveDj extends LiveDjNotifier {
  @override
  LiveDjState build() {
    return LiveDjState(
      isPlaying: true,
      radioOn: true,
      radioGenresAvailable: const {'bailable', 'rock'},
      position: const Duration(minutes: 9, seconds: 37),
      duration: const Duration(minutes: 52, seconds: 37),
      currentMixMode: LiveDjMixMode.longBypass,
      currentTrackPath:
          r'C:\Music\ReGenial\Cumbias\Mix Cumbancheros #1 150 BPM.mp3',
      radioNextPath: _nextPath,
      queue: [
        File(r'C:\Music\ReGenial\Cumbias\Mix Cumbancheros #1 150 BPM.mp3'),
      ],
    );
  }
}

String _nextPath =
    r'C:\Music\ReGenial\80s Ingles\Céline Dion - The Power Of Love.mp3';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String next = r'RADIO ▸ Céline Dion - The Power Of Love.mp3';
  const String longNext =
      'RADIO ▸ Céline Dion - The Power Of Love (Live at the Paris Olympia 1995 Remastered Extended Version).mp3';

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    required bool compact,
    String? nextPath,
  }) async {
    _nextPath =
        nextPath ??
        r'C:\Music\ReGenial\80s Ingles\Céline Dion - The Power Of Love.mp3';
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [liveDjProvider.overrideWith(_FakeLiveDj.new)],
        child: MaterialApp(
          home: Scaffold(body: LiveDjPlayerPanel(compactOverride: compact)),
        ),
      ),
    );
    await tester.pump();
  }

  void expectStripVisible(
    WidgetTester tester,
    Size size, {
    bool aboveMixBar = false,
  }) {
    expect(tester.takeException(), isNull);
    final Finder strip = find.byKey(const Key('live-dj-next-strip'));
    expect(strip, findsOneWidget);
    final Rect box = tester.getRect(strip);
    expect(box.height, greaterThan(18));
    expect(box.top, greaterThanOrEqualTo(0));
    expect(box.bottom, lessThanOrEqualTo(size.height + 0.5));
    expect(box.left, greaterThanOrEqualTo(-0.5));
    expect(box.right, lessThanOrEqualTo(size.width + 0.5));
    expect(find.text(next), findsOneWidget);
    final Rect text = tester.getRect(find.text(next));
    expect(text.top, greaterThanOrEqualTo(box.top - 0.5));
    expect(text.bottom, lessThanOrEqualTo(box.bottom + 0.5));
    if (aboveMixBar) {
      final Rect bar = tester.getRect(find.text('TIPO DE MEZCLA:'));
      expect(box.bottom, lessThanOrEqualTo(bar.top + 0.5));
    }
  }

  testWidgets('escritorio estrecho: la franja queda entera sobre la mezcla', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const Size size = Size(1100, 430);
    await pump(tester, size: size, compact: false);
    expectStripVisible(tester, size, aboveMixBar: true);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('ventana baja: la franja no se esconde bajo la barra', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const Size size = Size(1280, 360);
    await pump(tester, size: size, compact: false);
    expectStripVisible(tester, size, aboveMixBar: true);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('teléfono vertical: la franja entra en la pantalla', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const Size size = Size(390, 800);
    await pump(tester, size: size, compact: true);
    expectStripVisible(tester, size);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('teléfono horizontal: la franja no se recorta', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const Size size = Size(844, 390);
    await pump(tester, size: size, compact: true);
    expectStripVisible(tester, size);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('nombre largo: se desplaza dentro de la franja, sobre la mezcla', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const Size size = Size(640, 420);
    await pump(
      tester,
      size: size,
      compact: false,
      nextPath:
          r'C:\Music\ReGenial\80s Ingles\Céline Dion - The Power Of Love (Live at the Paris Olympia 1995 Remastered Extended Version).mp3',
    );
    expect(tester.takeException(), isNull);
    final Finder strip = find.byKey(const Key('live-dj-next-strip'));
    expect(strip, findsOneWidget);
    final Rect box = tester.getRect(strip);
    expect(box.height, greaterThan(18));
    expect(box.bottom, lessThanOrEqualTo(size.height + 0.5));
    final Rect bar = tester.getRect(find.text('TIPO DE MEZCLA:'));
    expect(box.bottom, lessThanOrEqualTo(bar.top + 0.5));
    expect(find.text(longNext), findsOneWidget);
    final Rect text = tester.getRect(find.text(longNext));
    expect(text.top, greaterThanOrEqualTo(box.top - 0.5));
    expect(text.bottom, lessThanOrEqualTo(box.bottom + 0.5));
    // El nombre no cabe: el recorte lo mantiene dentro del ancho de la franja.
    expect(text.width, greaterThan(box.width));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
