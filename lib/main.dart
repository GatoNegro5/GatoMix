import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:permission_handler/permission_handler.dart';

// 🛠️ INYECCIÓN: El puente de memoria FFI (Rust <> Dart)
import 'package:gatomix/src/rust/frb_generated.dart';

// --- IMPORTACIÓN DE MÓDULOS Y PROVIDERS ---
import 'providers/automix_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/livedj_provider.dart';
import 'providers/pipeline_provider.dart';

import 'core/audio/dj_audio_handler.dart';
import 'core/hal/platform_strategy.dart';

// 🛠️ FIX: Rutas actualizadas a la nueva Clean Architecture
import 'ui/widgets/app_version_label.dart';
import 'ui/workspaces/automix_workspace.dart';
import 'ui/workspaces/dsp_workspace.dart';
import 'ui/workspaces/yt_workspace.dart';
import 'ui/workspaces/lab_workspace.dart';
import 'ui/workspaces/lan_sync_workspace.dart';
import 'ui/workspaces/livedj_workspace.dart';
import 'ui/workspaces/karaoke_workspace.dart';
import 'services/audio_interruption.dart';
import 'core/headless_args.dart';
import 'ui/headless_master_page.dart';

// ==========================================
// ENRUTADOR DE ESTADO (SPA - Single Page App)
// 0: Dj Workspace, 1: Módulos Auto-Master, 2: Descargas YT, 3: Laboratorio, 4: Transferencia LAN, 5: Radio YT
// ==========================================
class RouterNotifier extends Notifier<int> {
  static const int _routeCount = 8;

  @override
  int build() {
    final saved = _readSavedRoute();
    if (saved != null) return saved;
    final inferred = _inferRouteFromAudioSession();
    _writeRoute(inferred);
    return inferred;
  }

  void setRoute(int newRoute) {
    if (newRoute < 0 || newRoute >= _routeCount) return;
    if (state == newRoute) return;
    state = newRoute;
    _writeRoute(newRoute);
  }

  void persistRoute() => _writeRoute(state);

  int? _readSavedRoute() {
    try {
      final file = File(_routeFilePath());
      if (!file.existsSync()) return null;
      final data = jsonDecode(file.readAsStringSync());
      final route = data['route'];
      if (route is int && route >= 0 && route < _routeCount) return route;
    } catch (_) {}
    return null;
  }

  int _inferRouteFromAudioSession() {
    try {
      final file = File(MixStrategyFactory.getStrategy().getSessionPath());
      if (!file.existsSync()) return 0;
      final data = jsonDecode(file.readAsStringSync());
      if (data is! Map) return 0;
      final wasPlaying = data['wasPlaying'] == true;
      final track = data['currentTrackPath'];
      if (wasPlaying && track is String && track.isNotEmpty) return 5;
    } catch (_) {}
    return 0;
  }

  void _writeRoute(int route) {
    try {
      File(_routeFilePath()).writeAsStringSync(jsonEncode({'route': route}));
    } catch (_) {}
  }

  String _routeFilePath() {
    final session = MixStrategyFactory.getStrategy().getSessionPath();
    return '${File(session).parent.path}${Platform.pathSeparator}_ui_route.json';
  }
}

final routerProvider = NotifierProvider<RouterNotifier, int>(
  RouterNotifier.new,
);

Future<void> main([List<String> args = const []]) async {
  // 🛠️ REGLA: Cero Deducciones. Atrapamos cualquier colapso pre-runApp.
  try {
    WidgetsFlutterBinding.ensureInitialized();

    // 🛠️ INYECCIÓN OS: Levantar el servicio nativo de Audio (Lockscreen/Background)
    // Debe arrancar antes de cualquier otra lógica pesada o permisos.
    await initGlobalAudioService();

    // 🛠️ FASE 3: Perforación de Scoped Storage en Runtime (Android 11+)
    if (Platform.isAndroid) {
      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
      }
      if (await Permission.storage.isDenied) {
        await Permission.storage.request();
      }
    }

    // 🛠️ VETO TÉCNICO APLICADO: Escudo protector de Plataforma.
    // SystemChrome no existe en Desktop y destruye el Isolate si se invoca.
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    // 🛠️ BINDING 2: Inicialización del Motor Nativo DSP en Rust
    await RustLib.init();

    // 🛠️ BINDING 3: Inicialización del Motor de Reproducción de Audio (libmpv)
    MediaKit.ensureInitialized();

    final String? labRescue = parseLabRescueArg(args);
    final String? masterFolder = labRescue ?? parseMasterFolderArg(args);
    if (masterFolder != null) {
      runApp(
        ProviderScope(
          child: HeadlessMasterApp(
            folder: masterFolder,
            autoLab: parseAutoLabFlag(args),
            labRescue: labRescue != null,
          ),
        ),
      );
      return;
    }
    runApp(const ProviderScope(child: GatoMixApp()));
  } catch (e, stackTrace) {
    // 🛠️ TRACKER DE KERNEL: Si algo falla a nivel binario, no mostramos pantalla gris.
    debugPrint("🔴 [FATAL BOOT ERROR]: $e");
    debugPrint("🔴 [STACK TRACE]: $stackTrace");
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF1A0000),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(
                "💥 FATAL BOOT ERROR\nEl núcleo nativo ha colapsado.\n\n$e",
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontFamily: 'Consolas',
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GatoMixApp extends ConsumerWidget {
  const GatoMixApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appTheme = ref.watch(themeProvider);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      builder: (context, child) {
        return _MobileAudioLifecycle(child: child ?? const SizedBox.shrink());
      },
      home: const BootloaderScreen(),
    );
  }
}

class _MobileAudioLifecycle extends ConsumerStatefulWidget {
  final Widget child;

  const _MobileAudioLifecycle({required this.child});

  @override
  ConsumerState<_MobileAudioLifecycle> createState() =>
      _MobileAudioLifecycleState();
}

class _MobileAudioLifecycleState extends ConsumerState<_MobileAudioLifecycle>
    with WidgetsBindingObserver {
  late final AudioInterruptionGuard _focusGuard;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    globalAudioHandler.onAppDismissed = _silenceEngines;
    // Llamadas / otras apps de audio: pausa y reanuda como app profesional.
    _focusGuard = AudioInterruptionGuard(ref);
    unawaited(_focusGuard.start());
  }

  @override
  void dispose() {
    _focusGuard.dispose();
    if (identical(globalAudioHandler.onAppDismissed, _silenceEngines)) {
      globalAudioHandler.onAppDismissed = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _silenceEngines() async {
    try {
      ref.read(routerProvider.notifier).persistRoute();
    } catch (_) {}
    try {
      await ref.read(automixProvider.notifier).persistSession();
    } catch (_) {}
    try {
      await ref.read(liveDjProvider.notifier).persistSession();
    } catch (_) {}
    try {
      await ref.read(automixProvider.notifier).parkIdleDecks(force: true);
    } catch (_) {}
    try {
      await ref.read(liveDjProvider.notifier).parkIdleDecks(force: true);
    } catch (_) {}
    try {
      await globalAudioHandler.stop();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (state != AppLifecycleState.resumed) {
      globalAudioHandler.noteAppBackgrounded();
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      try {
        ref.read(routerProvider.notifier).persistRoute();
      } catch (_) {}
      try {
        ref.read(automixProvider.notifier).persistSession();
      } catch (_) {}
      try {
        ref.read(liveDjProvider.notifier).persistSession();
      } catch (_) {}
      return;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ==========================================
// ESCUDO DE PERMISOS Y ARRANQUE NATIVO
// ==========================================
class BootloaderScreen extends StatefulWidget {
  const BootloaderScreen({super.key});

  @override
  State<BootloaderScreen> createState() => _BootloaderScreenState();
}

class _BootloaderScreenState extends State<BootloaderScreen> {
  String _statusText = "Inicializando motores C++...";

  @override
  void initState() {
    super.initState();
    _requestPermissionsAndBoot();
  }

  Future<void> _requestPermissionsAndBoot() async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      setState(() => _statusText = "Verificando llaves de I/O nativo...");

      if (Platform.isAndroid) {
        final status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          await Permission.manageExternalStorage.request();
        }
        await Permission.storage.request();
      } else {
        await Permission.storage.request();
      }
    }

    setState(() => _statusText = "Cargando espacio de trabajo...");
    await Future.delayed(const Duration(milliseconds: 600));

    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              const MainWorkspace(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GatoMixTheme.bgDark,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/branding/gatomix_logo.png',
              width: 96,
              height: 96,
            ),
            const SizedBox(height: 30),
            const CircularProgressIndicator(color: GatoMixTheme.deckA),
            const SizedBox(height: 20),
            Text(
              _statusText,
              style: const TextStyle(
                color: GatoMixTheme.textMuted,
                fontFamily: 'Consolas',
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// VISTA PRINCIPAL (UI ENRUTADA CON DISEÑO HÁPTICO)
// ==========================================
class MainWorkspace extends ConsumerStatefulWidget {
  const MainWorkspace({super.key});

  @override
  ConsumerState<MainWorkspace> createState() => _MainWorkspaceState();
}

class _MainWorkspaceState extends ConsumerState<MainWorkspace> {
  void _openMenu() {
    ref.read(mobileNavOpenProvider.notifier).state = true;
  }

  void _closeMenu() {
    ref.read(mobileNavOpenProvider.notifier).state = false;
  }

  Widget _stage(int currentRoute) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [GatoMixTheme.bgPanel, GatoMixTheme.bgDark],
        ),
      ),
      child: IndexedStack(
        index: currentRoute,
        children: const [
          AutomixWorkspace(),
          DspNlpWorkspace(),
          YoutubeSearchAndDownloadWorkspace(),
          LabWorkspace(),
          LanSyncWorkspace(),
          LiveDjWorkspace(),
          KaraokeWorkspace(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(automixProvider.select((s) => s.isPlaying), (prev, next) {
      final gov = ref.read(hardwareGovernorProvider.notifier);
      if (next) {
        gov.lockForLivePerformance();
      } else {
        gov.releaseLock();
      }
    });
    ref.listen<bool>(liveDjProvider.select((s) => s.isPlaying), (prev, next) {
      final gov = ref.read(hardwareGovernorProvider.notifier);
      if (next) {
        gov.lockForLivePerformance();
      } else {
        gov.releaseLock();
      }
    });
    final currentRoute = ref.watch(routerProvider);
    final bool isMobileOS = Platform.isAndroid || Platform.isIOS;
    final bool menuOpen = ref.watch(mobileNavOpenProvider);
    final bool inlineChrome =
        isMobileOS && (currentRoute == 0 || currentRoute == 5);
    final nav = _GatoMixNavColumn(
      currentRoute: currentRoute,
      isMobileOS: isMobileOS,
      onAfterSelect: isMobileOS ? _closeMenu : null,
      compactSheet: isMobileOS,
    );

    final bool playlistFull =
        currentRoute == 5 && ref.watch(liveDjPlaylistViewProvider);
    if (!isMobileOS) {
      return Scaffold(
        body: Row(
          children: [
            if (!playlistFull)
              Material(
                color: GatoMixTheme.bgDark,
                child: SizedBox(width: 160, child: nav),
              ),
            Expanded(child: _stage(currentRoute)),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: GatoMixTheme.bgDark,
      body: SafeArea(
        child: Column(
          children: [
            if (!inlineChrome)
              GatoMixMobileModeBar(
                title: _moduleTitle(currentRoute, isMobileOS),
                accent: _moduleAccent(currentRoute),
                open: menuOpen,
                onTap: menuOpen ? _closeMenu : _openMenu,
              ),
            Expanded(
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: MediaQuery.viewPaddingOf(context).right == 0
                            ? 48
                            : 0,
                      ),
                      child: _stage(currentRoute),
                    ),
                  ),
                  if (menuOpen)
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: _closeMenu,
                        behavior: HitTestBehavior.opaque,
                        child: const ColoredBox(color: Color(0x99000000)),
                      ),
                    ),
                  if (menuOpen)
                    Positioned(
                      left: 8,
                      top: inlineChrome ? 40 : 6,
                      width: 228,
                      child: Material(
                        color: GatoMixTheme.bgDark,
                        elevation: 18,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xFF2A2E37)),
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                          ),
                          child: ListView(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            children: [nav],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _moduleTitle(int route, bool mobile) {
  switch (route) {
    case 0:
      return "Automix";
    case 1:
      return "Masterizar";
    case 2:
      return "Descargas YT";
    case 3:
      return "Laboratorio";
    case 4:
      return "LAN Sync";
    case 5:
      return "Live DJ";
    case 6:
      return "Karaoke";
    default:
      return "GatoMix";
  }
}

Color _moduleAccent(int route) {
  switch (route) {
    case 0:
      return GatoMixTheme.deckA;
    case 1:
      return GatoMixTheme.deckB;
    case 2:
      return GatoMixTheme.cyanAccent;
    case 3:
      return GatoMixTheme.alertCritical;
    case 4:
      return GatoMixTheme.masterPeak;
    case 5:
      return GatoMixTheme.syncActive;
    case 6:
      return const Color(0xFF39FF14);
    default:
      return GatoMixTheme.textMain;
  }
}

class _GatoMixNavColumn extends ConsumerWidget {
  final int currentRoute;
  final bool isMobileOS;
  final VoidCallback? onAfterSelect;
  final bool compactSheet;

  const _GatoMixNavColumn({
    required this.currentRoute,
    required this.isMobileOS,
    this.onAfterSelect,
    this.compactSheet = false,
  });

  void _go(WidgetRef ref, int route) {
    ref.read(routerProvider.notifier).setRoute(route);
    onAfterSelect?.call();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTrackPath = ref.watch(
      automixProvider.select((s) => s.currentTrackPath),
    );

    Widget tile({
      required IconData icon,
      required String label,
      required int route,
      required Color accent,
    }) {
      final active = currentRoute == route;
      const Color menuIdle = Color(0xFF00E676);
      const Color menuSelected = Color(0xFF43B3AE);
      final Color ink = active ? menuSelected : menuIdle;
      return ListTile(
        dense: true,
        visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
        minVerticalPadding: 0,
        minLeadingWidth: 22,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        leading: Icon(icon, size: 18, color: ink),
        title: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            height: 1.05,
            color: ink,
            fontWeight: FontWeight.bold,
          ),
        ),
        onTap: () => _go(ref, route),
      );
    }

    final tiles = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        tile(
          icon: Icons.album,
          label: "Automix",
          route: 0,
          accent: GatoMixTheme.deckA,
        ),
        tile(
          icon: Icons.radio,
          label: "Live DJ",
          route: 5,
          accent: GatoMixTheme.syncActive,
        ),
        tile(
          icon: Icons.cloud_download,
          label: "Descargas YT",
          route: 2,
          accent: GatoMixTheme.cyanAccent,
        ),
        tile(
          icon: Icons.science,
          label: "Laboratorio",
          route: 3,
          accent: GatoMixTheme.alertCritical,
        ),
        tile(
          icon: Icons.settings,
          label: "Masterizar",
          route: 1,
          accent: GatoMixTheme.deckB,
        ),
        tile(
          icon: Icons.wifi_tethering,
          label: "LAN Sync",
          route: 4,
          accent: GatoMixTheme.masterPeak,
        ),
        tile(
          icon: Icons.mic_external_on,
          label: "Karaoke",
          route: 6,
          accent: const Color(0xFF39FF14),
        ),
      ],
    );

    final motor = currentTrackPath == null
        ? const SizedBox.shrink()
        : Container(
            padding: EdgeInsets.all(compactSheet ? 10 : 15),
            decoration: const BoxDecoration(
              color: GatoMixTheme.bgPanel,
              border: Border(top: BorderSide(color: Colors.white10)),
            ),
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "MOTOR AUDIO",
                  style: TextStyle(
                    color: GatoMixTheme.textHidden,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  currentTrackPath.replaceAll('\\', '/').split('/').last,
                  style: const TextStyle(
                    color: GatoMixTheme.syncActive,
                    fontSize: 11,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );

    return Column(
      mainAxisSize: compactSheet ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Image.asset(
            'assets/branding/gatomix_wordmark.png',
            height: 44,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
          ),
        ),
        const AppVersionLabel(),
        if (compactSheet)
          tiles
        else
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: tiles,
            ),
          ),
        motor,
      ],
    );
  }
}
