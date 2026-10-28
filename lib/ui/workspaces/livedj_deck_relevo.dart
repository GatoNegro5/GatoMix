import 'dart:math' as math;
import 'dart:ui' show ImageFilter, MaskFilter, BlurStyle, TileMode;

import 'package:flutter/material.dart';

import '../../core/phrase_grid.dart';
import '../../providers/livedj_provider.dart';
import '../../providers/mix_formula.dart';
import '../../providers/theme_provider.dart';

/// Alto de la tarjeta «la que viene» dentro del relevo.
const double kRelevoCardHeight = 64;

/// Por debajo de este lado, el móvil corto no desenfoca.
const double kRelevoBlurMinSide = 480;

/// El motor no publica el progreso del crossfade (sigue dentro de
/// `_executeMixEngine`). La vista usa la misma duración del lazo DAWN
/// en automático: DNA 18 s, bypass 4 s, Stealth `phraseFadeMs`,
/// Phrase 8 el fundido de 8 o 16 compases. Si no se puede derivar, 700 ms.
int relevoDurationMs({
  required bool derive,
  LiveDjMixMode? mode,
  MixFormula? formula,
  double bpm = 0,
  int durationMs = 0,
  bool instrumental = false,
}) {
  if (!derive || mode == null || formula == null) return 700;
  if (mode == LiveDjMixMode.longBypass) return 4000;
  if (formula == MixFormula.stealthGap) {
    final int ms = phraseFadeMs(
      incomingBpm: bpm,
      incomingDurationMs: durationMs,
    );
    return ms <= 0 ? 700 : ms;
  }
  if (formula == MixFormula.phraseGrid) {
    final int ms = phraseGridFadeMs(
      bpm: bpm,
      instrumental: instrumental,
      durationMs: durationMs,
    );
    return ms <= 0 ? 700 : ms;
  }
  return 18000;
}

/// BPM para el pulso visual. Prefijo `112 -` o un `128 bpm` en el nombre.
/// 0 si no hay un BPM de canción. No toca el audio.
double relevoBpm(String? path) {
  if (path == null || path.isEmpty) return 0;
  var name = path.replaceAll('\\', '/');
  final int slash = name.lastIndexOf('/');
  if (slash >= 0) name = name.substring(slash + 1);
  final int dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  final RegExpMatch? tagged = RegExp(
    r'(\d{2,3}(?:\.\d+)?)\s*bpm',
    caseSensitive: false,
  ).firstMatch(name);
  if (tagged != null) {
    final double? v = double.tryParse(tagged.group(1)!);
    if (v != null && v >= 40 && v <= 250) return v;
  }
  final String lead = name.split(' - ').first.trim();
  if (RegExp(r'^\d{2,3}(?:\.\d+)?$').hasMatch(lead)) {
    final double? v = double.tryParse(lead);
    if (v != null && v >= 40 && v <= 250) return v;
  }
  return 0;
}

int relevoBeatMs(double bpm) {
  if (bpm < 40 || bpm > 250) return 500;
  return (60000 / bpm).round().clamp(240, 1500);
}

double relevoCardExtent(double viewport) {
  if (viewport < 96) return math.max(32, viewport * 0.34);
  return kRelevoCardHeight;
}

double relevoMainHeight(double viewport) =>
    math.max(0, viewport - relevoCardExtent(viewport));

/// A sale hacia arriba. B entra desde abajo la misma distancia: la empuja.
double relevoOutgoingTop(double t, double mainH) => -t.clamp(0.0, 1.0) * mainH;

double relevoIncomingTop(double t, double mainH) =>
    (1 - t.clamp(0.0, 1.0)) * mainH;

/// Carátula que sale: 1.0 → 0.85. El giro y el blur van aparte.
double relevoOutgoingScale(double t) => 1.0 - 0.15 * t.clamp(0.0, 1.0);

/// Carátula que entra, con rebote suave. En 0 sigue en 0.55 y en 1 en 1.
double relevoIncomingScale(double t) {
  final double u = t.clamp(0.0, 1.0);
  return 0.55 + 0.45 * Curves.easeOutBack.transform(u);
}

double relevoOutgoingOpacity(double t) =>
    (1 - Curves.easeInCubic.transform(t.clamp(0.0, 1.0))).clamp(0.0, 1.0);

double relevoIncomingOpacity(double t) {
  final double eased = Curves.easeOut.transform(t.clamp(0.0, 1.0));
  return (0.45 + 0.55 * eased).clamp(0.0, 1.0);
}

/// Blur solo si el lado corto aguanta. En móvil corto queda opacidad y slide.
bool relevoBlurEnabled(double shortestSide) =>
    shortestSide >= kRelevoBlurMinSide;

/// 0 antes del remate, 1 al cerrar el mismo t (no alarga el cruce).
double relevoPeek(double t) {
  final double u = t.clamp(0.0, 1.0);
  if (u < 0.85) return 0;
  return ((u - 0.85) / 0.15).clamp(0.0, 1.0);
}

/// Flash del color entrante, dentro del tramo final de t.
double relevoFlashOpacity(double t) {
  final double u = t.clamp(0.0, 1.0);
  if (u < 0.90 || u >= 1) return 0;
  final double x = (u - 0.90) / 0.10;
  final double peak = x < 0.45 ? x / 0.45 : (1 - x) / 0.55;
  return peak.clamp(0.0, 1.0) * 0.32;
}

/// Onda expansiva. 0 antes del remate; en t=1 ya llenó y se apaga.
double relevoWave(double t) {
  final double u = t.clamp(0.0, 1.0);
  if (u < 0.88) return 0;
  return ((u - 0.88) / 0.12).clamp(0.0, 1.0);
}

bool relevoWide(double screenWidth) => screenWidth >= 800;

/// Hueco de la carátula dentro del panel, el mismo recorte que la ficha.
class RelevoCoverBox {
  final double left;
  final double bottom;
  final double side;

  const RelevoCoverBox(this.left, this.bottom, this.side);
}

RelevoCoverBox relevoCoverBox({
  required double paneWidth,
  required double paneHeight,
  required bool wide,
}) {
  final double padL = wide ? 24 : 12;
  final double padR = wide ? 16 : 10;
  final double padT = wide ? 16 : 8;
  final double padB = wide ? 8 : 4;
  final double innerH = math.max(0, paneHeight - padT - padB);
  final double innerW = math.max(0, paneWidth - padL - padR);
  final double side = math.min(innerH, innerW * 0.62).clamp(0.0, 440.0);
  return RelevoCoverBox(padL, padB, side);
}

/// Derrame radial: el color entrante nace donde está B y come al saliente.
class RelevoSpill {
  final Alignment center;
  final double radius;
  final List<Color> colors;
  final List<double> stops;

  const RelevoSpill({
    required this.center,
    required this.radius,
    required this.colors,
    required this.stops,
  });
}

RelevoSpill relevoSpill({
  required Color outgoing,
  required Color incoming,
  required double t,
  required bool handoff,
  required double viewport,
}) {
  if (!handoff || viewport <= 0) {
    return const RelevoSpill(
      center: Alignment.bottomCenter,
      radius: 0,
      colors: [Color(0x00000000), Color(0x00000000)],
      stops: [0, 1],
    );
  }
  final double u = t.clamp(0.0, 1.0);
  final double mainH = relevoMainHeight(viewport);
  final double anchor = (relevoIncomingTop(u, mainH) + mainH * 0.82).clamp(
    0.0,
    viewport,
  );
  final double ay = ((anchor / viewport) * 2 - 1).clamp(-1.0, 1.0);
  final Color hot = Color.lerp(GatoMixTheme.bgDark, incoming, 0.78)!;
  final Color mid = Color.lerp(
    GatoMixTheme.bgDark,
    Color.lerp(outgoing, incoming, u)!,
    0.50,
  )!;
  final Color edge = Color.lerp(GatoMixTheme.bgDark, outgoing, 0.36 * (1 - u))!;
  return RelevoSpill(
    center: Alignment(0, ay),
    radius: 0.18 + 1.45 * u,
    colors: [hot, mid, edge],
    stops: const [0.0, 0.42, 1.0],
  );
}

/// Relevo visual de dos decks. Solo pinta: no abre reproductores ni
/// escribe el motor. [t] es el progreso del cruce, 0 al empezar y 1 al terminar.
/// B sube desde la tarjeta y empuja a A fuera por arriba.
class DeckRelevo extends StatelessWidget {
  final double t;
  final bool handoff;
  final Widget outgoing;
  final Widget incoming;
  final String cardTitle;
  final String cardSubtitle;
  final String followingTitle;
  final String followingSubtitle;
  final Color outgoingDeck;
  final Color incomingDeck;
  final double beatPhase;

  const DeckRelevo({
    super.key,
    required this.t,
    required this.handoff,
    required this.outgoing,
    required this.incoming,
    required this.outgoingDeck,
    required this.incomingDeck,
    this.cardTitle = '',
    this.cardSubtitle = '',
    this.followingTitle = '',
    this.followingSubtitle = '',
    this.beatPhase = 0,
  });

  @override
  Widget build(BuildContext context) {
    final double u = t.clamp(0.0, 1.0);
    final bool live = handoff;
    final double shown = live ? u : 0;
    final bool wide = relevoWide(MediaQuery.sizeOf(context).width);
    return LayoutBuilder(
      builder: (context, constraints) {
        final double h = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 360;
        final double w = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 640;
        final double cardH = relevoCardExtent(h);
        final double mainH = relevoMainHeight(h);
        final bool soft = relevoBlurEnabled(math.min(w, h));
        final double outScale = live ? relevoOutgoingScale(shown) : 1;
        final double inScale = live ? relevoIncomingScale(shown) : 0.55;
        final bool entering = live && shown < 1;
        final double pulse = entering
            ? 1 + 0.04 * math.sin(beatPhase * math.pi * 2)
            : 1.0;
        final RelevoSpill spill = relevoSpill(
          outgoing: outgoingDeck,
          incoming: incomingDeck,
          t: shown,
          handoff: live,
          viewport: h,
        );
        final double flash = live ? relevoFlashOpacity(shown) : 0;
        final double wave = live ? relevoWave(shown) : 0;
        return ClipRect(
          child: DecoratedBox(
            key: const Key('relevo-stage'),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1B3A4B), GatoMixTheme.bgDark],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const SizedBox.expand(),
                DecoratedBox(
                  key: const Key('relevo-wash'),
                  decoration: BoxDecoration(
                    gradient: live
                        ? RadialGradient(
                            center: spill.center,
                            radius: spill.radius,
                            colors: spill.colors,
                            stops: spill.stops,
                          )
                        : null,
                    color: live ? null : const Color(0x00000000),
                  ),
                  child: const SizedBox.expand(),
                ),
                Positioned(
                  top: relevoOutgoingTop(shown, mainH),
                  left: 0,
                  right: 0,
                  height: mainH,
                  child: KeyedSubtree(
                    key: const Key('relevo-outgoing'),
                    child: Opacity(
                      opacity: live ? relevoOutgoingOpacity(shown) : 1,
                      child: _blurred(
                        sigma: soft ? shown * 10 : 0,
                        child: Transform(
                          alignment: Alignment.center,
                          transform: _tilt(shown * 0.34, axisY: false),
                          child: Transform(
                            key: const Key('relevo-outgoing-scale'),
                            alignment: Alignment.topCenter,
                            transform: Matrix4.diagonal3Values(
                              outScale,
                              outScale,
                              1,
                            ),
                            child: outgoing,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: live ? relevoIncomingTop(shown, mainH) : mainH,
                  left: 0,
                  right: 0,
                  height: mainH,
                  child: KeyedSubtree(
                    key: const Key('relevo-incoming'),
                    child: Opacity(
                      opacity: live ? relevoIncomingOpacity(shown) : 0,
                      child: Transform.translate(
                        offset: Offset(
                          0,
                          (1 - Curves.easeOut.transform(shown)) * 36,
                        ),
                        child: _blurred(
                          sigma: soft
                              ? (1 - Curves.easeOutCubic.transform(shown)) * 8
                              : 0,
                          child: Transform(
                            alignment: Alignment.center,
                            transform: _tilt(
                              (1 - Curves.easeOutCubic.transform(shown)) *
                                  -0.55,
                              axisY: true,
                            ),
                            child: Transform(
                              key: const Key('relevo-incoming-scale'),
                              alignment: Alignment.bottomCenter,
                              transform: Matrix4.diagonal3Values(
                                inScale,
                                inScale,
                                1,
                              ),
                              child: _IncomingPlate(
                                paneWidth: w,
                                paneHeight: mainH,
                                wide: wide,
                                progress: shown,
                                beatPhase: beatPhase,
                                color: incomingDeck,
                                soft: soft,
                                showFx: live,
                                child: incoming,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Opacity(
                      key: const Key('relevo-flash'),
                      opacity: flash,
                      child: ColoredBox(
                        color: Color.lerp(
                          GatoMixTheme.bgDark,
                          incomingDeck,
                          0.85,
                        )!,
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      key: const Key('relevo-wave'),
                      painter: _WavePainter(
                        progress: wave,
                        center: spill.center,
                        color: incomingDeck,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 0,
                  height: cardH,
                  child: Transform.scale(
                    key: const Key('relevo-card'),
                    scale: pulse,
                    alignment: Alignment.center,
                    child: _RelevoCard(
                      entering: entering,
                      peek: live ? relevoPeek(shown) : 0,
                      shimmer: entering && shown < 0.40 ? shown / 0.40 : -1,
                      title: cardTitle,
                      subtitle: cardSubtitle,
                      followingTitle: followingTitle,
                      followingSubtitle: followingSubtitle,
                      deck: incomingDeck,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Matrix4 _tilt(double radians, {required bool axisY}) {
  final Matrix4 m = Matrix4.identity()..setEntry(3, 2, 0.0014);
  if (axisY) {
    m.rotateY(radians);
  } else {
    m.rotateX(radians);
  }
  return m;
}

Widget _blurred({required double sigma, required Widget child}) {
  if (sigma < 0.4) return child;
  return ImageFiltered(
    imageFilter: ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: TileMode.decal,
    ),
    child: child,
  );
}

class _IncomingPlate extends StatelessWidget {
  final double paneWidth;
  final double paneHeight;
  final bool wide;
  final double progress;
  final double beatPhase;
  final Color color;
  final bool soft;
  final bool showFx;
  final Widget child;

  const _IncomingPlate({
    required this.paneWidth,
    required this.paneHeight,
    required this.wide,
    required this.progress,
    required this.beatPhase,
    required this.color,
    required this.soft,
    required this.showFx,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final RelevoCoverBox box = relevoCoverBox(
      paneWidth: paneWidth,
      paneHeight: paneHeight,
      wide: wide,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (showFx && box.side > 8)
          Positioned(
            key: const Key('relevo-ring'),
            left: box.left - 7,
            bottom: box.bottom - 7,
            width: box.side + 14,
            height: box.side + 14,
            child: IgnorePointer(
              child: CustomPaint(
                painter: _CoverFxPainter(
                  progress: progress,
                  beatPhase: beatPhase,
                  color: color,
                  soft: soft,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CoverFxPainter extends CustomPainter {
  final double progress;
  final double beatPhase;
  final Color color;
  final bool soft;

  const _CoverFxPainter({
    required this.progress,
    required this.beatPhase,
    required this.color,
    required this.soft,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2 - 3;
    if (r <= 0) return;
    final double beat = math.sin(beatPhase * math.pi * 2);
    final double glowA = 0.20 + 0.30 * (0.5 + 0.5 * beat);
    final Paint glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7 + 7 * (0.5 + 0.5 * beat)
      ..color = color.withValues(alpha: glowA);
    if (soft) {
      glow.maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    }
    canvas.drawCircle(c, r, glow);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: 0.30),
    );
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      math.pi * 2 * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3.5
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _CoverFxPainter old) =>
      old.progress != progress ||
      old.beatPhase != beatPhase ||
      old.color != color ||
      old.soft != soft;
}

class _WavePainter extends CustomPainter {
  final double progress;
  final Alignment center;
  final Color color;

  const _WavePainter({
    required this.progress,
    required this.center,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final Offset c = center.alongSize(size);
    final double radius = progress * size.longestSide * 0.85;
    canvas.drawCircle(
      c,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10 * (1 - progress) + 2
        ..color = color.withValues(alpha: (1 - progress) * 0.85),
    );
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.progress != progress || old.center != center || old.color != color;
}

class _RelevoCard extends StatelessWidget {
  final bool entering;
  final double peek;
  final double shimmer;
  final String title;
  final String subtitle;
  final String followingTitle;
  final String followingSubtitle;
  final Color deck;

  const _RelevoCard({
    required this.entering,
    required this.peek,
    required this.shimmer,
    required this.title,
    required this.subtitle,
    required this.followingTitle,
    required this.followingSubtitle,
    required this.deck,
  });

  @override
  Widget build(BuildContext context) {
    if (!entering && followingTitle.isEmpty) return const SizedBox.shrink();
    final Color fill = entering
        ? Color.lerp(GatoMixTheme.bgPanel, deck, 0.55)!
        : GatoMixTheme.bgPanel;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: entering ? deck : GatoMixTheme.textHidden),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!entering)
              _CardCopy(
                entering: false,
                title: followingTitle,
                subtitle: followingSubtitle,
                deck: deck,
              )
            else if (peek <= 0)
              _CardCopy(
                entering: true,
                title: title,
                subtitle: subtitle,
                deck: deck,
              )
            else
              Stack(
                fit: StackFit.expand,
                children: [
                  FractionalTranslation(
                    translation: Offset(0, -peek),
                    child: _CardCopy(
                      entering: true,
                      title: title,
                      subtitle: subtitle,
                      deck: deck,
                    ),
                  ),
                  FractionalTranslation(
                    translation: Offset(0, 1 - peek),
                    child: _CardCopy(
                      entering: false,
                      title: followingTitle,
                      subtitle: followingSubtitle,
                      deck: deck,
                    ),
                  ),
                ],
              ),
            if (shimmer >= 0 && shimmer < 1)
              _ShimmerBand(t: shimmer, deck: deck),
          ],
        ),
      ),
    );
  }
}

class _CardCopy extends StatelessWidget {
  final bool entering;
  final String title;
  final String subtitle;
  final Color deck;

  const _CardCopy({
    required this.entering,
    required this.title,
    required this.subtitle,
    required this.deck,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (entering)
            Text(
              'ENTRANDO',
              key: const Key('relevo-entrando'),
              maxLines: 1,
              style: TextStyle(
                color: deck,
                fontWeight: FontWeight.bold,
                fontSize: 10,
                letterSpacing: 1.1,
              ),
            ),
          Text(
            title,
            key: Key(entering ? 'relevo-card-title' : 'relevo-next'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: GatoMixTheme.textMain,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: GatoMixTheme.textMuted,
                fontSize: 11,
              ),
            ),
        ],
      ),
    );
  }
}

class _ShimmerBand extends StatelessWidget {
  final double t;
  final Color deck;

  const _ShimmerBand({required this.t, required this.deck});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double band = math.max(24, constraints.maxWidth * 0.28);
          final double x = -band + (constraints.maxWidth + band) * t;
          return Stack(
            children: [
              Positioned(
                left: x,
                top: 0,
                bottom: 0,
                width: band,
                child: DecoratedBox(
                  key: const Key('relevo-shimmer'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        deck.withValues(alpha: 0),
                        deck.withValues(alpha: 0.55),
                        GatoMixTheme.textMain.withValues(alpha: 0.20),
                        deck.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
