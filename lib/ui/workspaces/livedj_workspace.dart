import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_provider.dart';
import '../../providers/directory_provider.dart';
import '../../providers/livedj_provider.dart';
import '../../providers/mix_formula.dart';
import 'automix_workspace.dart';
import 'livedj_bpm_badge.dart';
import 'livedj_artist_card.dart';
import 'livedj_folder_playlist.dart';
import '../../core/audio/cue_preview.dart';

/// Texto del buscador de la cola (solo filtra la vista; la cola real no cambia).
final liveDjQueueSearchProvider = StateProvider<String>((ref) => '');

/// Vista grande de la carpeta. Apagada: Explorador + carpeta + Cartridge.
final liveDjPlaylistViewProvider = StateProvider<bool>((ref) => false);

class LiveDjWorkspace extends ConsumerWidget {
  const LiveDjWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = Platform.isAndroid || Platform.isIOS;
    final bool playlist = ref.watch(liveDjPlaylistViewProvider);
    if (playlist) {
      return Scaffold(
        backgroundColor: GatoMixTheme.bgDark,
        body: Stack(
          children: [
            const Positioned.fill(child: LiveDjFolderPlaylist()),
            Positioned(
              top: 8,
              right: 56,
              child: Tooltip(
                message: 'Volver a GatoMix',
                child: GestureDetector(
                  onTap: () =>
                      ref.read(liveDjPlaylistViewProvider.notifier).state =
                          false,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      Icons.album,
                      size: 28,
                      color: GatoMixTheme.syncActive,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: GatoMixTheme.bgDark,
      body: Row(
        children: [
          // Explorador: columna izquierda a toda la altura, arranca arriba.
          Expanded(
            flex: 5,
            child: Material(
              color: GatoMixTheme.bgPanel,
              child: LibraryTreePanel(provider: liveDjDirectoryProvider),
            ),
          ),
          const VerticalDivider(width: 1, color: Colors.white10),
          Expanded(
            flex: 19,
            child: Column(
              children: [
                Expanded(
                  flex: compact ? 5 : 5,
                  child: const LiveDjPlayerPanel(),
                ),
                const Divider(height: 1, color: Colors.white10),
                Expanded(
                  flex: compact ? 6 : 5,
                  child: const Row(
                    children: [
                      Expanded(flex: 4, child: LiveDjFolderPanel()),
                      VerticalDivider(width: 1, color: Colors.white10),
                      Expanded(flex: 5, child: LiveDjCartridgePanel()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LiveDjFolderPanel extends ConsumerWidget {
  const LiveDjFolderPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirState = ref.watch(liveDjDirectoryProvider);
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: isMobile ? 4 : 8,
          ),
          color: GatoMixTheme.bgPanel,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  dirState.currentPath.isEmpty
                      ? "Selecciona carpeta..."
                      : dirState.currentPath
                            .replaceAll('\\', '/')
                            .split('/')
                            .last,
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                    fontSize: isMobile ? 11 : 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ElevatedButton.icon(
                onPressed: dirState.files.isEmpty
                    ? null
                    : () async {
                        final rawFiles = dirState.files
                            .whereType<File>()
                            .toList();
                        final notifier = ref.read(liveDjProvider.notifier);
                        notifier.addAllTracks(rawFiles);
                        if (ref.read(liveDjProvider).currentTrackPath == null) {
                          await notifier.togglePlayPause();
                        }
                      },
                icon: Icon(Icons.playlist_add_check, size: isMobile ? 14 : 16),
                label: Text(
                  "Cargar Carpeta",
                  style: TextStyle(fontSize: isMobile ? 10 : 11),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white10,
                  foregroundColor: GatoMixTheme.cyanAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: Size(0, isMobile ? 24 : 30),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: dirState.files.isEmpty
              ? const Center(
                  child: Text(
                    "Carpeta vacía o sin MP3.",
                    style: TextStyle(color: Colors.white38),
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  itemCount: dirState.files.length,
                  itemBuilder: (context, index) {
                    final file = dirState.files[index];
                    final fileName = file.uri.pathSegments.last;

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: const Icon(
                          Icons.audio_file,
                          color: Colors.white24,
                          size: 18,
                        ),
                        title: Text(
                          fileName,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () async {
                          final notifier = ref.read(liveDjProvider.notifier);
                          notifier.addTrack(file);
                          if (ref.read(liveDjProvider).currentTrackPath ==
                              null) {
                            await notifier.togglePlayPause();
                          }
                        },
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.add_circle_outline,
                            color: GatoMixTheme.cyanAccent,
                            size: 20,
                          ),
                          onPressed: () =>
                              ref.read(liveDjProvider.notifier).addTrack(file),
                          tooltip: "Añadir a la Cola",
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class LiveDjPlayerPanel extends ConsumerStatefulWidget {
  /// Solo pruebas: fuerza el acomodo de teléfono o de escritorio.
  final bool? compactOverride;

  const LiveDjPlayerPanel({super.key, this.compactOverride});

  @override
  ConsumerState<LiveDjPlayerPanel> createState() => _LiveDjPlayerPanelState();
}

class _LiveDjPlayerPanelState extends ConsumerState<LiveDjPlayerPanel> {
  double? _dragPosition;
  String? _stealthNextName;
  String? _stealthCacheKey;

  /// Línea vertical en la barra: punto donde arranca la mezcla (DNA / Phrase 8 /
  /// Stealth). `mixMs` = `customMixOutMs` del provider (mismo valor que dispara).
  Widget _mixMarker(double inset, int mixMs, int durMs) {
    if (mixMs <= 0 || durMs <= 0 || mixMs >= durMs) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, c) {
            final double w = c.maxWidth - inset * 2;
            final double x = inset + w * (mixMs / durMs).clamp(0.0, 1.0);
            return Stack(
              children: [
                Positioned(
                  left: x - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: Colors.redAccent),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(liveDjProvider);
    final pos = state.position;
    final dur = state.duration;
    final currentName =
        (state.currentTrackPath ??
                (state.queue.isNotEmpty ? state.queue.first.path : null))
            ?.replaceAll('\\', '/')
            .split('/')
            .last ??
        "SISTEMA EN ESPERA";
    final isPlayingNow = state.isPlaying;
    final canToggle = state.currentTrackPath != null || state.queue.isNotEmpty;

    final isMixBypass = state.currentMixMode == LiveDjMixMode.longBypass;
    final mixFormula = ref.watch(mixFormulaProvider);
    String? nextName;
    if (state.queue.isEmpty) {
      nextName = null;
      _stealthCacheKey = null;
    } else if (mixFormula == MixFormula.stealthGap &&
        state.currentTrackPath != null) {
      final String key =
          '${state.currentTrackPath}|${state.queue.map((f) => f.path).join('|')}';
      if (_stealthCacheKey != key) {
        _stealthCacheKey = key;
        final int i = pickStealthNextIndex(
          remaining: state.queue.map((f) => f.path).toList(),
          currentPath: state.currentTrackPath,
          bpmOf: (p) {
            final fileName = p.replaceAll('\\', '/').split('/').last;
            final match = RegExp(
              r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
              caseSensitive: false,
            ).firstMatch(fileName);
            return match != null ? double.parse(match.group(1)!) : 0.0;
          },
        );
        _stealthNextName =
            (i >= 0 ? state.queue[i].path : state.queue.first.path)
                .replaceAll('\\', '/')
                .split('/')
                .last;
      }
      nextName = _stealthNextName;
    } else if (state.currentTrackPath == null) {
      _stealthCacheKey = null;
      nextName = state.queue.length > 1
          ? state.queue[1].path.replaceAll('\\', '/').split('/').last
          : null;
    } else {
      _stealthCacheKey = null;
      nextName = state.queue.first.path.replaceAll('\\', '/').split('/').last;
    }
    // Radio encendida: el "siguiente" es el que la Radio ya eligió, no la cola.
    if (state.radioOn) {
      final String? rn = state.radioNextPath;
      nextName = rn == null
          ? 'RADIO ▸ eligiendo…'
          : 'RADIO ▸ ${rn.replaceAll('\\', '/').split('/').last}';
    }
    final engineModeStr = isMixBypass
        ? "BYPASS (MEZCLA PROTEGIDA)"
        : (mixFormula == MixFormula.stealthGap
              ? "STEALTH 60% (SIN VOZ)"
              : (mixFormula == MixFormula.phraseGrid
                    ? "PHRASE 8 (GRID 4/4)"
                    : "ACTIVE BEATMATCHING (DNA DJ 60-80%)"));
    final engineModeColor = isMixBypass
        ? GatoMixTheme.cyanAccent
        : (mixFormula == MixFormula.stealthGap
              ? GatoMixTheme.deckB
              : (mixFormula == MixFormula.phraseGrid
                    ? GatoMixTheme.deckA
                    : GatoMixTheme.syncActive));

    final isShuffle = state.mixStrategy == LiveDjMixStrategy.random;
    final compact =
        widget.compactOverride ?? (Platform.isAndroid || Platform.isIOS);
    final bool playlistOn = ref.watch(liveDjPlaylistViewProvider);
    final bool menuOpen = compact ? ref.watch(mobileNavOpenProvider) : false;
    final gap = compact ? 4.0 : 10.0;
    final titleSize = compact ? 13.0 : 16.0;
    final timeSize = compact ? 14.0 : 18.0;

    // ON AIR Radio: encendido = rojo; apagado = rojo vino (look de apagado).
    final bool radioOn = state.radioOn;
    final Color radioColor = radioOn
        ? GatoMixTheme.alertCritical
        : const Color(0xFF7A2E3E);
    final onAirBadge = Tooltip(
      message: radioOn
          ? 'Radio ENCENDIDA: toma canciones de las carpetas de género. Toca para apagar.'
          : 'Radio apagada. Toca para encender (la cola queda congelada).',
      child: GestureDetector(
        onTap: () => ref.read(liveDjProvider.notifier).toggleRadio(),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 6 : 10,
            vertical: compact ? 2 : 4,
          ),
          decoration: BoxDecoration(
            color: radioColor.withValues(alpha: radioOn ? 0.1 : 0.05),
            border: Border.all(color: radioColor),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sensors, color: radioColor, size: 12),
              const SizedBox(width: 5),
              Text(
                "ON AIR Radio",
                style: TextStyle(
                  color: radioColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                ),
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );

    // Controlador de GÉNERO: visible solo con la Radio encendida.
    // Ningún chip marcado = Todo.
    Widget genreChip(
      String label,
      bool selected,
      VoidCallback onTap, {
      bool enabled = true,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Opacity(
          opacity: enabled ? 1.0 : 0.3,
          child: GestureDetector(
            onTap: enabled ? onTap : null,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 10,
                vertical: compact ? 2 : 4,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? GatoMixTheme.syncActive.withValues(alpha: 0.18)
                    : Colors.transparent,
                border: Border.all(
                  color: selected ? GatoMixTheme.syncActive : Colors.white24,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? GatoMixTheme.syncActive : Colors.white54,
                  fontWeight: FontWeight.bold,
                  fontSize: compact ? 10 : 11,
                ),
                maxLines: 1,
              ),
            ),
          ),
        ),
      );
    }

    final Widget radioChips = radioOn
        ? Padding(
            padding: EdgeInsets.only(top: compact ? 3 : 8),
            child: SizedBox(
              height: compact ? 24 : 28,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    genreChip(
                      'Todo',
                      state.radioGenres.isEmpty,
                      () =>
                          ref.read(liveDjProvider.notifier).clearRadioGenres(),
                    ),
                    for (final id in kRadioGenreIds)
                      genreChip(
                        kRadioGenreLabels[id]!,
                        state.radioGenres.contains(id),
                        () => ref
                            .read(liveDjProvider.notifier)
                            .toggleRadioGenre(id),
                        enabled: state.radioGenresAvailable.contains(id),
                      ),
                  ],
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    final studioTitle = Text(
      "STUDIO 1 - LIVEDJ ENGINE",
      style: TextStyle(
        color: Colors.white54,
        fontWeight: FontWeight.bold,
        fontSize: compact ? 10 : 12,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
    );

    final nowPlayingBody = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "NOW PLAYING",
                    style: TextStyle(
                      color: GatoMixTheme.syncActive,
                      fontWeight: FontWeight.bold,
                      fontSize: 9,
                    ),
                  ),
                  SizedBox(height: compact ? 2 : 5),
                  Text(
                    currentName,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: titleSize,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            LiveDjBpmChip(
              path:
                  state.currentTrackPath ??
                  (state.queue.isNotEmpty ? state.queue.first.path : null),
              fontSize: compact ? 10 : 12,
            ),
            Flexible(
              child: LiveDjArtistCard(
                path:
                    state.currentTrackPath ??
                    (state.queue.isNotEmpty ? state.queue.first.path : null),
                compact: compact,
              ),
            ),
            if (compact) ...[
              const SizedBox(width: 8),
              onAirBadge,
              const SizedBox(width: 8),
              Flexible(child: studioTitle),
            ],
            if (!compact) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: playlistOn
                    ? 'Volver a Explorador y Cartridge'
                    : 'Vista de la carpeta',
                child: GestureDetector(
                  onTap: () {
                    ref.read(liveDjPlaylistViewProvider.notifier).state =
                        !playlistOn;
                  },
                  child: Icon(
                    Icons.album,
                    size: 28,
                    color: playlistOn
                        ? GatoMixTheme.syncActive
                        : Colors.white70,
                  ),
                ),
              ),
            ],
          ],
        ),
        radioChips,
        SizedBox(height: compact ? 4 : gap),
        if (compact)
          Row(
            children: [
              Text(
                "${pos.inMinutes.toString().padLeft(2, '0')}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}",
                style: const TextStyle(
                  color: GatoMixTheme.cyanAccent,
                  fontFamily: 'Consolas',
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: const SliderThemeData(
                    trackHeight: 3,
                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape: RoundSliderOverlayShape(overlayRadius: 8),
                    activeTrackColor: GatoMixTheme.syncActive,
                    inactiveTrackColor: Colors.white10,
                    thumbColor: Colors.white,
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Slider(
                        value:
                            _dragPosition ??
                            (dur.inMilliseconds > 0
                                ? pos.inMilliseconds.toDouble().clamp(
                                    0.0,
                                    dur.inMilliseconds.toDouble(),
                                  )
                                : 0.0),
                        min: 0.0,
                        max: dur.inMilliseconds > 0
                            ? dur.inMilliseconds.toDouble()
                            : 1.0,
                        onChangeStart: (val) {
                          setState(() {
                            _dragPosition = val;
                          });
                        },
                        onChanged: (val) {
                          setState(() {
                            _dragPosition = val;
                          });
                        },
                        onChangeEnd: (val) {
                          if (dur.inMilliseconds > 0) {
                            ref
                                .read(liveDjProvider.notifier)
                                .seek(Duration(milliseconds: val.toInt()));
                          }
                          setState(() {
                            _dragPosition = null;
                          });
                        },
                      ),
                      _mixMarker(8, state.customMixOutMs, dur.inMilliseconds),
                    ],
                  ),
                ),
              ),
              Text(
                "-${(dur - pos).inMinutes.toString().padLeft(2, '0')}:${((dur - pos).inSeconds % 60).toString().padLeft(2, '0')}",
                style: const TextStyle(
                  color: Colors.white54,
                  fontFamily: 'Consolas',
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                tooltip: isShuffle
                    ? 'Modo: Aleatorio (Shuffle)'
                    : 'Modo: Secuencial',
                onPressed: () {
                  ref.read(liveDjProvider.notifier).toggleMixStrategy();
                },
                icon: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        (isShuffle
                                ? const Color(0xFFFF007F)
                                : const Color(0xFF00FFFF))
                            .withValues(alpha: 0.18),
                    border: Border.all(
                      color: isShuffle
                          ? const Color(0xFFFF007F)
                          : const Color(0xFF00FFFF),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    isShuffle ? Icons.shuffle : Icons.format_list_numbered,
                    size: 16,
                    color: isShuffle
                        ? const Color(0xFFFF007F)
                        : const Color(0xFF00FFFF),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: canToggle
                    ? () => ref.read(liveDjProvider.notifier).togglePlayPause()
                    : null,
                icon: Icon(
                  isPlayingNow
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill,
                  color: const Color(
                    0xFF39FF14,
                  ).withValues(alpha: canToggle ? 1 : 0.28),
                  size: 42,
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: state.queue.isEmpty
                    ? null
                    : () => ref.read(liveDjProvider.notifier).forceNext(),
                child: Icon(
                  Icons.skip_next,
                  size: 22,
                  color: state.queue.isEmpty ? Colors.white24 : Colors.white70,
                ),
              ),
            ],
          )
        else ...[
          Row(
            children: [
              Text(
                "${pos.inMinutes.toString().padLeft(2, '0')}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}",
                style: TextStyle(
                  color: GatoMixTheme.cyanAccent,
                  fontFamily: 'Consolas',
                  fontSize: timeSize,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                "-${(dur - pos).inMinutes.toString().padLeft(2, '0')}:${((dur - pos).inSeconds % 60).toString().padLeft(2, '0')}",
                style: const TextStyle(
                  color: Colors.white54,
                  fontFamily: 'Consolas',
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 15,
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 3,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: GatoMixTheme.syncActive,
                inactiveTrackColor: Colors.white10,
                thumbColor: Colors.white,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Slider(
                    value:
                        _dragPosition ??
                        (dur.inMilliseconds > 0
                            ? pos.inMilliseconds.toDouble().clamp(
                                0.0,
                                dur.inMilliseconds.toDouble(),
                              )
                            : 0.0),
                    min: 0.0,
                    max: dur.inMilliseconds > 0
                        ? dur.inMilliseconds.toDouble()
                        : 1.0,
                    onChangeStart: (val) {
                      setState(() {
                        _dragPosition = val;
                      });
                    },
                    onChanged: (val) {
                      setState(() {
                        _dragPosition = val;
                      });
                    },
                    onChangeEnd: (val) {
                      if (dur.inMilliseconds > 0) {
                        ref
                            .read(liveDjProvider.notifier)
                            .seek(Duration(milliseconds: val.toInt()));
                      }
                      setState(() {
                        _dragPosition = null;
                      });
                    },
                  ),
                  _mixMarker(12, state.customMixOutMs, dur.inMilliseconds),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 52,
                  height: 52,
                ),
                tooltip: isShuffle
                    ? 'Modo: Aleatorio (Shuffle)'
                    : 'Modo: Secuencial',
                onPressed: () {
                  ref.read(liveDjProvider.notifier).toggleMixStrategy();
                },
                icon: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        (isShuffle
                                ? const Color(0xFFFF007F)
                                : const Color(0xFF00FFFF))
                            .withValues(alpha: 0.18),
                    border: Border.all(
                      color: isShuffle
                          ? const Color(0xFFFF007F)
                          : const Color(0xFF00FFFF),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    isShuffle ? Icons.shuffle : Icons.format_list_numbered,
                    size: 26,
                    color: isShuffle
                        ? const Color(0xFFFF007F)
                        : const Color(0xFF00FFFF),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: canToggle
                    ? () => ref.read(liveDjProvider.notifier).togglePlayPause()
                    : null,
                icon: Icon(
                  isPlayingNow
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill,
                  color: const Color(
                    0xFF39FF14,
                  ).withValues(alpha: canToggle ? 1 : 0.28),
                  size: 45,
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: Icon(
                  Icons.skip_next,
                  color: (state.queue.isEmpty && !state.radioOn)
                      ? Colors.white24
                      : Colors.white70,
                  size: 30,
                ),
                onPressed: (state.queue.isEmpty && !state.radioOn)
                    ? null
                    : () => ref.read(liveDjProvider.notifier).forceNext(),
              ),
            ],
          ),
        ],
      ],
    );

    final Widget? nextStrip = nextName == null
        ? null
        : _NextTrackStrip(label: nextName, compact: compact);

    final songCard = Container(
      margin: EdgeInsets.all(compact ? 6 : 15),
      padding: EdgeInsets.all(compact ? 8 : 15),
      decoration: BoxDecoration(
        color: GatoMixTheme.bgPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: nowPlayingBody,
    );

    final routingBar = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 15,
        vertical: compact ? 4 : 12,
      ),
      color: GatoMixTheme.bgDark,
      child: Row(
        children: [
          Icon(Icons.memory, color: engineModeColor, size: 16),
          const SizedBox(width: 8),
          const Flexible(
            child: Text(
              "TIPO DE MEZCLA:",
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: GestureDetector(
              onTap: isMixBypass
                  ? null
                  : () {
                      final cur = ref.read(mixFormulaProvider);
                      ref
                          .read(mixFormulaProvider.notifier)
                          .state = cur == MixFormula.dnaEnergy
                          ? MixFormula.phraseGrid
                          : (cur == MixFormula.phraseGrid
                                ? MixFormula.stealthGap
                                : MixFormula.dnaEnergy);
                    },
              child: Tooltip(
                message:
                    '1 DNA 60-80%  ·  2 Phrase 8  ·  3 Stealth sin voz. Toca para cambiar.',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: GatoMixTheme.bgDark,
                    border: Border.all(
                      color: engineModeColor.withValues(alpha: 0.5),
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    engineModeStr,
                    style: TextStyle(
                      color: engineModeColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: compact ? 26 : 30,
              child: TextField(
                onChanged: (v) =>
                    ref.read(liveDjQueueSearchProvider.notifier).state = v,
                style: const TextStyle(color: Colors.white, fontSize: 11),
                decoration: InputDecoration(
                  hintText: 'Buscar en la cola',
                  hintStyle: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 14,
                    color: Colors.white38,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 20,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                  filled: true,
                  fillColor: GatoMixTheme.bgDark,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(
                      color: GatoMixTheme.syncActive,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return Column(
      children: [
        if (compact)
          ColoredBox(
            color: GatoMixTheme.bgDark,
            child: Row(
              children: [
                GatoMixMobileModeBar(
                  title: 'Live DJ',
                  accent: GatoMixTheme.syncActive,
                  open: menuOpen,
                  expand: false,
                  onTap: () => ref.read(mobileNavOpenProvider.notifier).state =
                      !menuOpen,
                ),
                Tooltip(
                  message: playlistOn
                      ? 'Volver a GatoMix'
                      : 'Vista de la carpeta',
                  child: GestureDetector(
                    onTap: () {
                      ref.read(liveDjPlaylistViewProvider.notifier).state =
                          !playlistOn;
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(
                        Icons.album,
                        size: 26,
                        color: GatoMixTheme.syncActive,
                      ),
                    ),
                  ),
                ),
                Expanded(child: routingBar),
              ],
            ),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            decoration: const BoxDecoration(
              color: GatoMixTheme.bgDark,
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              children: [
                onAirBadge,
                const SizedBox(width: 15),
                Expanded(child: studioTitle),
              ],
            ),
          ),
        Expanded(
          child: compact
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: GatoMixTheme.bgPanel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, c) {
                                return FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: SizedBox(
                                    width: c.maxWidth,
                                    child: nowPlayingBody,
                                  ),
                                );
                              },
                            ),
                          ),
                          Tooltip(
                            message: playlistOn
                                ? 'Volver a Explorador y Cartridge'
                                : 'Vista de la carpeta',
                            child: GestureDetector(
                              onTap: () {
                                ref
                                        .read(
                                          liveDjPlaylistViewProvider.notifier,
                                        )
                                        .state =
                                    !playlistOn;
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Icon(
                                  Icons.album,
                                  size: 26,
                                  color: playlistOn
                                      ? GatoMixTheme.syncActive
                                      : Colors.white70,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : SingleChildScrollView(child: songCard),
        ),
        ?nextStrip,
        if (!compact) routingBar,
      ],
    );
  }
}

/// Franja de la pista que sigue. Va fuera del bloque que se recorta,
/// pegada encima de la barra de mezcla, con alto propio.
class _NextTrackStrip extends StatelessWidget {
  final String label;
  final bool compact;

  const _NextTrackStrip({required this.label, required this.compact});

  @override
  Widget build(BuildContext context) {
    final double size = compact ? 12 : 13;
    final TextStyle style = TextStyle(
      color: const Color(0xFF00FFFF),
      fontFamily: 'Consolas',
      fontSize: size,
      height: 1.25,
    );
    return Tooltip(
      message: label,
      child: ColoredBox(
        key: const Key('live-dj-next-strip'),
        color: const Color(0xFF00FFFF).withValues(alpha: 0.14),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 14,
              vertical: compact ? 6 : 7,
            ),
            child: _NextTrackLine(label: label, style: style),
          ),
        ),
      ),
    );
  }
}

/// Una línea. Si el nombre cabe, se queda (con puntos suspensivos de
/// respaldo). Si no cabe, se desplaza dentro del recorte.
class _NextTrackLine extends StatefulWidget {
  final String label;
  final TextStyle style;

  const _NextTrackLine({required this.label, required this.style});

  @override
  State<_NextTrackLine> createState() => _NextTrackLineState();
}

class _NextTrackLineState extends State<_NextTrackLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _move;

  @override
  void initState() {
    super.initState();
    _move = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _move.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxW = constraints.maxWidth;
        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.label, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final double textW = painter.width;
        final double textH = painter.height;
        painter.dispose();
        final bool overflow = maxW.isFinite && textW > maxW + 1;
        if (!overflow) {
          if (_move.isAnimating) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _move.stop();
            });
          }
          return Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        final double travel = textW - maxW;
        final int ms = (travel * 18).round().clamp(4000, 14000);
        if (!_move.isAnimating) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _move.isAnimating) return;
            _move.duration = Duration(milliseconds: ms);
            _move.repeat();
          });
        }
        // El texto mide su ancho real y se desliza; el recorte impide
        // que pinte encima de la barra de mezcla.
        return SizedBox(
          width: maxW,
          height: textH,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _move,
              builder: (context, _) {
                final double t = Curves.easeInOut.transform(
                  _move.value < 0.5 ? _move.value * 2 : (1 - _move.value) * 2,
                );
                return Transform.translate(
                  offset: Offset(-travel * t, 0),
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: textW,
                    maxWidth: textW,
                    minHeight: textH,
                    maxHeight: textH,
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: widget.style,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class LiveDjCartridgePanel extends ConsumerWidget {
  const LiveDjCartridgePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(liveDjProvider.select((s) => s.queue));
    final query = ref.watch(liveDjQueueSearchProvider).trim().toLowerCase();
    final visible = <int>[
      for (int i = 0; i < queue.length; i++)
        if (query.isEmpty ||
            queue[i].uri.pathSegments.last.toLowerCase().contains(query))
          i,
    ];
    // Pre-escucha (flecha roja): solo Windows; activa solo con audífono.
    final cue = CuePreviewNotifier.supported
        ? ref.watch(cuePreviewProvider)
        : const CueState();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: const BoxDecoration(
            color: GatoMixTheme.bgPanel,
            border: Border(
              top: BorderSide(color: Colors.white10),
              bottom: BorderSide(color: Colors.white10),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.shuffle, color: Colors.pinkAccent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "CARTRIDGE (${queue.length})",
                  style: const TextStyle(
                    color: Colors.pinkAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 1.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.delete_sweep,
                  color: Colors.redAccent,
                  size: 18,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: queue.isEmpty
                    ? null
                    : () => ref.read(liveDjProvider.notifier).clearQueue(),
                tooltip: "Borrar Cola",
              ),
              IconButton(
                icon: const Icon(
                  Icons.save,
                  color: Colors.cyanAccent,
                  size: 18,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: queue.isEmpty
                    ? null
                    : () => ref.read(liveDjProvider.notifier).savePlaylist(),
                tooltip: "Guardar Playlist",
              ),
              IconButton(
                icon: const Icon(
                  Icons.folder_open,
                  color: Colors.greenAccent,
                  size: 18,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    ref.read(liveDjProvider.notifier).loadPlaylist(),
                tooltip: "Cargar Playlist",
              ),
            ],
          ),
        ),
        Expanded(
          child: queue.isEmpty
              ? const Center(
                  child: Text(
                    "CARTRIDGE VACÍO\nCola de emisión sin pistas.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white24, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  itemCount: visible.length,
                  itemBuilder: (context, vi) {
                    final index = visible[vi];
                    final file = queue[index];
                    final fileName = file.uri.pathSegments.last;

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.drag_handle,
                              color: Colors.white24,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            LiveDjBpmBadge(path: file.path),
                          ],
                        ),
                        title: Text(
                          fileName,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => ref
                            .read(liveDjProvider.notifier)
                            .playTrackFromQueue(index),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (CuePreviewNotifier.supported)
                              IconButton(
                                icon: Icon(
                                  cue.playingPath == file.path
                                      ? Icons.stop
                                      : Icons.play_arrow,
                                  color: cue.available
                                      ? Colors.redAccent
                                      : Colors.white24,
                                  size: 18,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 28,
                                  height: 28,
                                ),
                                visualDensity: VisualDensity.compact,
                                tooltip: cue.available
                                    ? "Pre-escucha (solo audífono)"
                                    : "Conecta un audífono para pre-escuchar",
                                onPressed: cue.available
                                    ? () => ref
                                          .read(cuePreviewProvider.notifier)
                                          .toggle(file.path)
                                    : null,
                              ),
                            IconButton(
                              icon: const Icon(
                                Icons.play_arrow,
                                color: Color(0xFF39FF14),
                                size: 18,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              visualDensity: VisualDensity.compact,
                              tooltip: "Play",
                              onPressed: () {
                                if (CuePreviewNotifier.supported) {
                                  ref.read(cuePreviewProvider.notifier).stop();
                                }
                                ref
                                    .read(liveDjProvider.notifier)
                                    .playTrackFromQueue(index);
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.close,
                                color: Colors.redAccent,
                                size: 16,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => ref
                                  .read(liveDjProvider.notifier)
                                  .removeTrack(file.path),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
