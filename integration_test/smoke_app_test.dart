// Prueba de humo de GatoMix en dispositivo (Android gm34 / celular real).
// Arranca los motores reales (audio_service, Rust, libmpv) y recorre la
// pantalla principal: Automix, explorador "+ Agregar canciones" y Live DJ con
// el botón de Radio. No usa música del usuario ni internet.
//
// Correr: flutter test integration_test -d <id>
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:gatomix/core/audio/dj_audio_handler.dart';
import 'package:gatomix/main.dart';
import 'package:gatomix/providers/theme_provider.dart';
import 'package:gatomix/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Mismo orden que main(): servicio de audio, Rust, libmpv.
    await initGlobalAudioService();
    await RustLib.init();
    MediaKit.ensureInitialized();
  });

  testWidgets('arranca sin excepciones: Automix, explorador y Live DJ/Radio',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(routerProvider.notifier).setRoute(0);

    // Se salta BootloaderScreen: pide MANAGE_EXTERNAL_STORAGE y abre Ajustes,
    // lo que dejaría la prueba esperando al usuario.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: container.read(themeProvider),
          home: const MainWorkspace(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(find.byType(MainWorkspace), findsOneWidget);

    // Automix (ruta 0): abrir el explorador.
    expect(find.text('+ Agregar canciones'), findsWidgets);
    await tester.tap(find.text('+ Agregar canciones').first);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    if (nav.canPop()) {
      nav.pop();
      await tester.pump(const Duration(seconds: 1));
    }

    // Live DJ (ruta 5): botón de Radio visible.
    container.read(routerProvider.notifier).setRoute(5);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('MODO RADIO'), findsWidgets);
  });
}
