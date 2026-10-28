import 'dart:io';

import '../widgets/approx_lyric_icon.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/id3_names.dart';
import '../../core/livedj_next.dart';
import '../../core/net/artist_info.dart';
import '../../core/queue_bpm.dart';
import '../../core/track_file_name.dart';
import '../../providers/livedj_provider.dart';
import 'livedj_sort_button.dart';
import '../../providers/mix_formula.dart';
import '../../providers/theme_provider.dart';
import '../../services/id3_title_artist.dart';
import 'livedj_bpm_badge.dart';
import 'livedj_deck_relevo.dart';

/// Pantalla grande de la canción que está sonando. No usa la carpeta
/// marcada en el Explorador: sigue `currentTrackPath`.
/// El reproductor ocupa 2/3; la cola del Cartridge, el tercio derecho,
/// solo para verla (tocar una fila no suena ni reordena).
class LiveDjFolderPlaylist extends StatelessWidget {
  const LiveDjFolderPlaylist({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: GatoMixTheme.bgDark,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 2, child: _PlayerPane()),
          VerticalDivider(width: 1, color: Colors.white10),
          Expanded(flex: 1, child: _QueuePane()),
        ],
      ),
    );
  }
}

class _PlayerPane extends ConsumerStatefulWidget {
  const _PlayerPane();

  @override
  ConsumerState<_PlayerPane> createState() => _PlayerPaneState();
}

class _PlayerPaneState extends ConsumerState<_PlayerPane>
    with TickerProviderStateMixin {
  double? _dragPosition;
  final LiveDjNextLabel _nextLabel = LiveDjNextLabel();
  late final AnimationController _relevo;
  late final AnimationController _beat;
  String? _handoffFrom;
  String? _handoffTo;
  bool _activeIsA = true;
  Color _outDeck = GatoMixTheme.deckA;
  Color _inDeck = GatoMixTheme.deckB;

  @override
  void initState() {
    super.initState();
    _relevo = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _beat = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _relevo.addStatusListener(_onRelevo);
  }

  @override
  void dispose() {
    _relevo.removeStatusListener(_onRelevo);
    _relevo.dispose();
    _beat.dispose();
    super.dispose();
  }

  void _onRelevo(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    _beat.stop();
    _beat.value = 0;
    setState(() => _handoffFrom = null);
  }

  void _beginRelevo(String prev, String next) {
    final LiveDjState live = ref.read(liveDjProvider);
    final MixFormula formula = ref.read(mixFormulaProvider);
    final double bpm = relevoBpm(next);
    int ms = relevoDurationMs(
      derive: true,
      mode: live.currentMixMode,
      formula: formula,
      bpm: bpm,
      durationMs: live.duration.inMilliseconds,
    );
    if (formula == MixFormula.phraseGrid) {
      final int published = ref.read(liveDjProvider.notifier).publishedFadeMs;
      if (published > 0) ms = published;
    }
    setState(() {
      _handoffFrom = prev;
      _handoffTo = next;
      _outDeck = _activeIsA ? GatoMixTheme.deckA : GatoMixTheme.deckB;
      _inDeck = _activeIsA ? GatoMixTheme.deckB : GatoMixTheme.deckA;
      _activeIsA = !_activeIsA;
    });
    _beat.duration = Duration(milliseconds: relevoBeatMs(bpm));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _handoffFrom != prev) return;
      _beat.repeat();
      _relevo.duration = Duration(milliseconds: ms);
      _relevo.forward(from: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(liveDjProvider.select((s) => s.currentTrackPath), (
      String? prev,
      String? next,
    ) {
      if (prev == null ||
          prev.isEmpty ||
          next == null ||
          next.isEmpty ||
          prev == next) {
        return;
      }
      _beginRelevo(prev, next);
    });
    // El reloj no reconstruye la carátula: solo estos campos, y la posición
    // la mira `_PlayClock`.
    final String? track = ref.watch(
      liveDjProvider.select((s) => s.currentTrackPath),
    );
    final List<File> queue = ref.watch(liveDjProvider.select((s) => s.queue));
    final bool radioOn = ref.watch(liveDjProvider.select((s) => s.radioOn));
    final String? radioNext = ref.watch(
      liveDjProvider.select((s) => s.radioNextPath),
    );
    final LiveDjMixStrategy strategy = ref.watch(
      liveDjProvider.select((s) => s.mixStrategy),
    );
    final bool playing = ref.watch(liveDjProvider.select((s) => s.isPlaying));
    final Duration dur = ref.watch(liveDjProvider.select((s) => s.duration));
    final int mixOut = ref.watch(
      liveDjProvider.select((s) => s.customMixOutMs),
    );
    final MixFormula mixFormula = ref.watch(mixFormulaProvider);
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final String? nextName = _nextLabel.text(
      radioOn: radioOn,
      radioNextPath: radioNext,
      queuePaths: <String>[for (final File f in queue) f.path],
      currentPath: track,
      stealth: mixFormula == MixFormula.stealthGap,
      bpmOf: knownBpm,
    );
    final isShuffle = strategy == LiveDjMixStrategy.random;
    final canToggle = track != null || queue.isNotEmpty;
    final canSkip = queue.isNotEmpty || radioOn;

    final Widget controls = Padding(
      padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 0, wide ? 16 : 10, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PlayClock(
            wide: wide,
            dur: dur,
            mixOutMs: mixOut,
            dragPosition: _dragPosition,
            onDrag: (double? v) => setState(() => _dragPosition = v),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: isShuffle
                    ? 'Modo: Aleatorio (Shuffle)'
                    : 'Modo: Secuencial',
                onPressed: () =>
                    ref.read(liveDjProvider.notifier).toggleMixStrategy(),
                icon: Icon(
                  isShuffle ? Icons.shuffle : Icons.format_list_numbered,
                  color: isShuffle
                      ? const Color(0xFFFF007F)
                      : const Color(0xFF00FFFF),
                  size: wide ? 26 : 22,
                ),
              ),
              LiveDjSortButton(size: wide ? 24 : 20),
              IconButton(
                onPressed: canToggle
                    ? () => ref.read(liveDjProvider.notifier).togglePlayPause()
                    : null,
                icon: Icon(
                  playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                  color: const Color(0xFF39FF14)
                      .withValues(alpha: canToggle ? 1 : 0.28),
                  size: wide ? 46 : 40,
                ),
              ),
              IconButton(
                onPressed: canSkip
                    ? () => ref.read(liveDjProvider.notifier).forceNext()
                    : null,
                icon: Icon(
                  Icons.skip_next,
                  color: canSkip ? Colors.white70 : Colors.white24,
                  size: wide ? 30 : 26,
                ),
              ),
            ],
          ),
        ],
      ),
    );
    final bool handoff = _handoffFrom != null;
    final String? faceOut = handoff ? _handoffFrom : track;
    final String? faceIn = handoff ? _handoffTo : null;
    final TrackDisplay entering = (faceIn == null || faceIn.isEmpty)
        ? const TrackDisplay(headline: '', subtitle: '', artist: '')
        : resolveTrackDisplay(file: parseTrackFileName(faceIn));
    final String following = nextName ?? '';
    final Listenable motion = Listenable.merge([_relevo, _beat]);
    final Widget outgoingFace = _SongFace(path: faceOut, wide: wide);
    final Widget incomingFace = _SongFace(
      path: faceIn,
      wide: wide,
      controls: false,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 600;
        final double maxW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 800;
        return Column(
          children: [
            Expanded(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: motion,
                  builder: (context, _) {
                    return DeckRelevo(
                      t: handoff ? _relevo.value : 0,
                      handoff: handoff,
                      outgoing: outgoingFace,
                      incoming: incomingFace,
                      cardTitle: entering.headline,
                      cardSubtitle: entering.subtitle,
                      followingTitle: following,
                      outgoingDeck: _outDeck,
                      incomingDeck: _inDeck,
                      beatPhase: _beat.value,
                    );
                  },
                ),
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.min(190, math.max(72, maxH * 0.36)),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topCenter,
                child: SizedBox(width: math.max(1, maxW), child: controls),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SongFace extends StatelessWidget {
  final String? path;
  final bool wide;
  final bool controls;

  const _SongFace({
    required this.path,
    required this.wide,
    this.controls = true,
  });

  @override
  Widget build(BuildContext context) {
    final String? facePath = path;
    return FutureBuilder<Id3Names>(
      future: (facePath == null || facePath.isEmpty)
          ? null
          : loadId3TitleArtist(facePath),
      builder: (context, snap) {
        final Id3Names id3 = snap.data ?? const Id3Names();
        final TrackDisplay display = (facePath == null || facePath.isEmpty)
            ? const TrackDisplay(
                headline: 'Nada sonando',
                subtitle: '',
                artist: '',
              )
            : resolveTrackDisplay(
                file: parseTrackFileName(facePath),
                id3Artist: id3.artist,
                id3Title: id3.title,
              );
        final String headline = display.headline.isEmpty
            ? 'Nada sonando'
            : display.headline;
        return Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              wide ? 24 : 12,
              wide ? 16 : 8,
              wide ? 16 : 10,
              wide ? 8 : 4,
            ),
            child: LayoutBuilder(
              builder: (context, inner) {
                final double side = _coverSide(inner.maxHeight, inner.maxWidth);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _NowCover(artist: _coverQuery(display.artist), side: side),
                    SizedBox(width: wide ? 20 : 12),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, textBox) {
                          return FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.bottomLeft,
                            child: SizedBox(
                              width: math.max(1, textBox.maxWidth),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    headline,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: wide ? 36 : 22,
                                      height: 1.05,
                                    ),
                                  ),
                                  if (display.subtitle.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      display.subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: wide ? 16 : 13,
                                      ),
                                    ),
                                  ],
                                  if (controls) ...[
                                    const SizedBox(height: 6),
                                    SizedBox(
                                      height: 28,
                                      child: ListView(
                                        scrollDirection: Axis.horizontal,
                                        physics: const ClampingScrollPhysics(),
                                        children: [
                                          LiveDjBpmChip(
                                            path: facePath,
                                            fontSize: wide ? 12 : 10,
                                          ),
                                          const SizedBox(width: 8),
                                          _OnAirBadge(compact: !wide),
                                        ],
                                      ),
                                    ),
                                    _RadioSlot(compact: !wide),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

double _coverSide(double maxH, double maxW) {
  if (!maxH.isFinite || !maxW.isFinite || maxH <= 0 || maxW <= 0) return 96;
  final double side = math.min(maxH, maxW * 0.62);
  return side.clamp(0.0, 440.0);
}

/// Mismo recorte que la ficha del artista: el primer nombre, no "112".
String _coverQuery(String artist) {
  final String a = artist.trim();
  if (a.isEmpty) return '';
  return a
      .split(
        RegExp(
          r'\s*(?:,|&|\bft\.?\b|\bfeat\.?\b|\bx\b| y )\s*',
          caseSensitive: false,
        ),
      )
      .first
      .trim();
}

/// La misma cola del Cartridge. Solo se muestra: no hay play, borrado ni orden.
class _QueuePane extends ConsumerWidget {
  const _QueuePane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool radioOn = ref.watch(liveDjProvider.select((s) => s.radioOn));
    final List<String> upcoming = ref.watch(
      liveDjProvider.select((s) => s.radioUpcoming),
    );
    final List<File> queue = ref.watch(liveDjProvider.select((s) => s.queue));
    final List<String> paths = liveDjSidePaths(
      radioOn: radioOn,
      queuePaths: <String>[for (final File f in queue) f.path],
      radioUpcoming: upcoming,
    );
    return ColoredBox(
      color: GatoMixTheme.bgDark,
      child: Column(
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.only(left: 12, right: 108),
            alignment: Alignment.centerLeft,
            color: GatoMixTheme.bgPanel,
            child: Text(
              'COLA (${paths.length})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: GatoMixTheme.deckB,
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: paths.isEmpty
                ? Center(
                    child: Text(
                      radioOn ? 'RADIO ▸ eligiendo…' : 'COLA VACÍA',
                      style: const TextStyle(
                        color: GatoMixTheme.textHidden,
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: paths.length,
                    itemBuilder: (context, index) {
                      return _QueueLine(path: paths[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _QueueLine extends StatelessWidget {
  final String path;

  const _QueueLine({required this.path});

  @override
  Widget build(BuildContext context) {
    final TrackFileName file = parseTrackFileName(path);
    return FutureBuilder<Id3Names>(
      future: loadId3TitleArtist(path),
      builder: (context, snap) {
        final Id3Names id3 = snap.data ?? const Id3Names();
        final TrackDisplay display = resolveTrackDisplay(
          file: file,
          id3Artist: id3.artist,
          id3Title: id3.title,
        );
        final String headline = display.headline.isEmpty
            ? path.replaceAll('\\', '/').split('/').last
            : display.headline;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              LiveDjBpmBadge(path: path),
              ApproxLyricIcon(path: path, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: GatoMixTheme.textMain,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    if (display.subtitle.isNotEmpty)
                      Text(
                        display.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: GatoMixTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Los chips de la Radio solo ocupan alto cuando está encendida.
class _RadioSlot extends ConsumerWidget {
  final bool compact;

  const _RadioSlot({required this.compact});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool on = ref.watch(liveDjProvider.select((s) => s.radioOn));
    if (!on) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: _RadioChips(compact: compact),
    );
  }
}

Widget _mixMarker(double inset, int mixMs, int durMs) {
  if (mixMs <= 0 || durMs <= 0 || mixMs >= durMs) {
    return const SizedBox.shrink();
  }
  return Positioned.fill(
    child: IgnorePointer(
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth - inset * 2;
          final x = inset + w * (mixMs / durMs).clamp(0.0, 1.0);
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

class _OnAirBadge extends ConsumerWidget {
  final bool compact;
  const _OnAirBadge({required this.compact});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final radioOn = ref.watch(liveDjProvider.select((s) => s.radioOn));
    final color = radioOn
        ? GatoMixTheme.alertCritical
        : const Color(0xFF7A2E3E);
    return GestureDetector(
      onTap: () => ref.read(liveDjProvider.notifier).toggleRadio(),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 10,
          vertical: compact ? 2 : 4,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: radioOn ? 0.1 : 0.05),
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sensors, color: color, size: 12),
            const SizedBox(width: 5),
            Text(
              'ON AIR Radio',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadioChips extends ConsumerWidget {
  final bool compact;
  const _RadioChips({required this.compact});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Set<String> genres = ref.watch(
      liveDjProvider.select((s) => s.radioGenres),
    );
    final Set<String> available = ref.watch(
      liveDjProvider.select((s) => s.radioGenresAvailable),
    );
    Widget chip(
      String label,
      bool selected,
      VoidCallback onTap, {
      bool enabled = true,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Opacity(
          opacity: enabled ? 1 : 0.3,
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
              ),
            ),
          ),
        ),
      );
    }

    final notifier = ref.read(liveDjProvider.notifier);
    return SizedBox(
      height: compact ? 24 : 28,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          chip('Todo', genres.isEmpty, notifier.clearRadioGenres),
          for (final id in kRadioGenreIds)
            chip(
              kRadioGenreLabels[id]!,
              genres.contains(id),
              () => notifier.toggleRadioGenre(id),
              enabled: available.contains(id),
            ),
        ],
      ),
    );
  }
}

/// Reloj y barra. Mira solo la posición: la carátula no se reconstruye
/// en cada tick.
class _PlayClock extends ConsumerWidget {
  final bool wide;
  final Duration dur;
  final int mixOutMs;
  final double? dragPosition;
  final ValueChanged<double?> onDrag;

  const _PlayClock({
    required this.wide,
    required this.dur,
    required this.mixOutMs,
    required this.dragPosition,
    required this.onDrag,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Duration pos = ref.watch(liveDjProvider.select((s) => s.position));
    final int durMs = dur.inMilliseconds;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              "${pos.inMinutes.toString().padLeft(2, '0')}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}",
              style: TextStyle(
                color: GatoMixTheme.cyanAccent,
                fontFamily: 'Consolas',
                fontSize: wide ? 16 : 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            Text(
              "-${(dur - pos).inMinutes.toString().padLeft(2, '0')}:${((dur - pos).inSeconds % 60).toString().padLeft(2, '0')}",
              style: TextStyle(
                color: Colors.white54,
                fontFamily: 'Consolas',
                fontSize: wide ? 14 : 12,
              ),
            ),
          ],
        ),
        SizedBox(
          height: 28,
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
                      dragPosition ??
                      (durMs > 0
                          ? pos.inMilliseconds.toDouble().clamp(
                              0.0,
                              durMs.toDouble(),
                            )
                          : 0.0),
                  min: 0.0,
                  max: durMs > 0 ? durMs.toDouble() : 1.0,
                  onChangeStart: onDrag,
                  onChanged: onDrag,
                  onChangeEnd: (double v) {
                    if (durMs > 0) {
                      ref
                          .read(liveDjProvider.notifier)
                          .seek(Duration(milliseconds: v.toInt()));
                    }
                    onDrag(null);
                  },
                ),
                _mixMarker(12, mixOutMs, durMs),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NowCover extends StatelessWidget {
  final String artist;
  final double side;
  const _NowCover({required this.artist, required this.side});

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: const Color(0xFF1B4F72),
      child: Icon(Icons.music_note, color: Colors.white24, size: side * 0.4),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: side,
        height: side,
        child: artist.isEmpty
            ? fallback
            : FutureBuilder<ArtistInfo?>(
                future: loadArtistInfo(artist),
                builder: (context, snap) {
                  final photo = snap.data?.photoPath;
                  if (photo != null && File(photo).existsSync()) {
                    final int px =
                        (side * MediaQuery.devicePixelRatioOf(context))
                            .round()
                            .clamp(64, 1600);
                    return Image.file(
                      File(photo),
                      fit: BoxFit.cover,
                      cacheWidth: px,
                      cacheHeight: px,
                    );
                  }
                  return fallback;
                },
              ),
      ),
    );
  }
}
