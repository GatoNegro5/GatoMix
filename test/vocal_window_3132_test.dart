import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/phrase_grid.dart';
import 'package:gatomix/providers/mix_formula.dart';

// 3.1.32: hueco sin voz dentro de la ventana (salida 60-80 % por posicion,
// entrada en [cueMin, cueMax]) y golpe exacto del Set In de Automix.
// Puro: perfiles sinteticos, sin Player, sin archivos, sin ReGenial.
const double _voc = phraseVocalMinRatio + 0.30;
const double _rms = phraseVocalMinRms * 4;

/// Frases cada 4 s en [0, D); [quiet] sin voz; [vocal] fija la voz de alguna.
List<PhrasePhrase> _profile(
  int d, {
  Set<int> quiet = const <int>{},
  Map<int, double> vocal = const <int, double>{},
}) {
  return <PhrasePhrase>[
    for (var ms = 0; ms < d; ms += 4000)
      PhrasePhrase(
        startMs: ms,
        rms: _rms,
        vocal: quiet.contains(ms) ? 0.05 : (vocal[ms] ?? _voc),
      ),
  ];
}

void main() {
  const int d = 200000;

  test('salida: hueco instrumental al 66/74 % frente a voz en los bordes', () {
    final ActiveWindow both = activeWindow(
      durationMs: d,
      cueInMs: 20000,
      fadeMs: 4000,
      candidateMs: 160000, // la formula pedia el borde del 80 % (cantado)
      bpm: 120,
      phrases: _profile(d, quiet: <int>{132000, 148000}),
    );
    expect(both.mixOutMs, 148000); // 74 %, el hueco mas cercano
    expect(both.origin, 'hueco');
    final ActiveWindow only66 = activeWindow(
      durationMs: d,
      cueInMs: 20000,
      fadeMs: 4000,
      candidateMs: 160000,
      bpm: 120,
      phrases: _profile(d, quiet: <int>{132000}),
    );
    expect(only66.mixOutMs, 132000); // 66 %
    expect(only66.origin, 'hueco');
    // El tramo del fundido cuenta: hueco de una frase con fundido de dos
    // frases cantadas pierde frente a dos frases seguidas sin voz.
    final ActiveWindow span = activeWindow(
      durationMs: d,
      cueInMs: 20000,
      fadeMs: 8000,
      candidateMs: 132000,
      bpm: 120,
      phrases: _profile(d, quiet: <int>{132000, 148000, 152000}),
    );
    expect(span.mixOutMs, 148000);
  });

  test('salida: todo cantado en 60-80 % elige la frase de menor voz', () {
    final ActiveWindow w = activeWindow(
      durationMs: d,
      cueInMs: 20000,
      fadeMs: 4000,
      candidateMs: 125000,
      bpm: 120,
      phrases: _profile(d, vocal: <int, double>{140000: phraseVocalMinRatio + 0.05}),
    );
    expect(w.mixOutMs, 140000);
    expect(w.origin, 'frase');
    expect(w.voice, closeTo(phraseVocalMinRatio + 0.05, 1e-9));
    expect(w.mixOutMs, inInclusiveRange(120000, 160000));
  });

  test('entrada: frase instrumental sobre la cantada en [cueMin, cueMax]', () {
    final ActivePick pick = activeCuePick(
      durationMs: d,
      bpm: 120,
      preferMs: 20000,
      fadeMs: 4000,
      phrases: _profile(d, quiet: <int>{32000, 60000}),
    );
    expect(pick.ms, 32000); // 60000 cae fuera del 20 %
    expect(pick.origin, 'hueco');
    expect(
      activeCueInMs(
        durationMs: d,
        bpm: 120,
        preferMs: 20000,
        fadeMs: 4000,
        phrases: _profile(d, quiet: <int>{32000}),
      ),
      32000,
    );
  });

  test('sin perfil (o sin frases en la ventana) = rejilla de la 3.1.31', () {
    for (final int dur in <int>[60000, 200000, 300000]) {
      for (final double bpm in <double>[0, 117, 128]) {
        ActiveWindow run(List<PhrasePhrase>? ph) => activeWindow(
          durationMs: dur,
          cueInMs: 30000,
          fadeMs: 16000,
          candidateMs: (dur * 0.75).round(),
          bpm: bpm,
          gridMs: 250,
          cueMinMs: 8000,
          phrases: ph,
        );
        final ActiveWindow none = run(null);
        final ActiveWindow empty = run(const <PhrasePhrase>[]);
        final ActiveWindow outside = run(_profile(20000));
        for (final ActiveWindow w in <ActiveWindow>[empty, outside]) {
          expect(w.mixOutMs, none.mixOutMs);
          expect(w.fadeMs, none.fadeMs);
        }
        expect(none.voice, -1);
        expect(none.origin, isNot('hueco'));
        final int c0 = activeCueInMs(durationMs: dur, bpm: bpm, gridMs: 250);
        expect(
          activeCueInMs(
            durationMs: dur,
            bpm: bpm,
            gridMs: 250,
            phrases: const <PhrasePhrase>[],
          ),
          c0,
        );
      }
    }
  });

  test('Set In manual de Automix al golpe mas cercano (<= medio golpe)', () {
    for (final double bpm in <double>[90, 117, 128, 174]) {
      final double p = 60000.0 / bpm;
      for (var cue = 0; cue <= 60000; cue += 37) {
        final int m = snapCueToBeat(
          cueMs: cue,
          beatMs: 123.4,
          bpm: bpm,
          manual: true,
        );
        expect((m - cue).abs(), lessThanOrEqualTo(p / 2 + 1), reason: '$bpm $cue');
        final double k = (m - 123.4) / p;
        expect((k - k.round()).abs() * p, lessThanOrEqualTo(0.5 + 1e-9));
        final int a = snapCueToBeat(
          cueMs: cue,
          beatMs: 123.4,
          bpm: bpm,
          manual: false,
        );
        expect(a, greaterThanOrEqualTo(cue - 1));
        expect(a - cue, lessThan(p + 1));
      }
    }
    expect(snapCueToBeat(cueMs: 9876, beatMs: 10, bpm: 0, manual: true), 9876);
  });
}
