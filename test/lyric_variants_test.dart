import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_match.dart';
import 'package:gatomix/core/lyric_timing_check.dart';

void main() {
  test('Etapa 2: título sin ruido de versiones y YouTube', () {
    expect(lyricCleanTitle('Your Love (Remix)'), 'Your Love');
    expect(lyricCleanTitle('Kool & The Gang (2)'), 'Kool & The Gang');
    expect(lyricCleanTitle('Escape_K'), 'Escape');
    expect(
      lyricCleanTitle(
        'Good Thing Original Aspect Ratio, Audio Remux & Upscale',
      ),
      'Good Thing',
    );
    expect(lyricCleanTitle('Jump - 2015 Remaster'), 'Jump');
    expect(lyricCleanTitle('Shout (Official Video)'), 'Shout');
    expect(lyricCleanTitle('Despacito ft. Justin Bieber'), 'Despacito');
    expect(lyricCleanTitle('Hungry Eyes'), 'Hungry Eyes');
  });

  test('Etapa 2: primer artista', () {
    expect(lyricPrimaryArtist('Earth, Wind & Fire'), 'Earth, Wind & Fire');
    expect(lyricPrimaryArtist('Hall & Oates'), 'Hall & Oates');
    expect(
      lyricPrimaryArtist('Bob Sinclar vs. Raffaella Carrà'),
      'Bob Sinclar',
    );
    expect(lyricPrimaryArtist('Daddy Yankee feat. Snow'), 'Daddy Yankee');
    expect(lyricPrimaryArtist('Foreigner'), 'Foreigner');
  });

  test(
    'Etapa 2: los respaldos incluyen la variante limpia, sin duplicados',
    () {
      final LyricIdentity id = LyricIdentity(
        artist: 'Lime ft. Denis',
        title: 'Your Love (Remix)',
        durationSec: 300,
      );
      final List<LyricIdentity> fb = lyricFallbackIdentities(id);
      final Set<String> keys = fb.map((e) => '${e.artist}|${e.title}').toSet();
      expect(keys.length, fb.length);
      expect(keys, contains('Lime|Your Love'));
      expect(fb.every((e) => e.durationSec == 300), isTrue);
    },
  );

  test(
    'Etapa 2: letra de otra versión queda FAIL con motivo, sin tocar tiempos',
    () {
      // Caso real GMX_TEST: Jump extended 255 s, letra radio edit 7-153 s.
      final StringBuffer b = StringBuffer();
      for (int s = 7; s <= 153; s += 6) {
        b.writeln(
          '[${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}.00] verso $s',
        );
      }
      final LyricTimingVerdict v = checkLyricTiming(
        lrc: b.toString(),
        durationMs: 255500,
      );
      expect(v.issue, LyricTimingIssue.endsEarly);
      expect(
        lyricRescueFailReason(v, durationMs: 255500),
        startsWith('FAIL:lyric_version_mismatch,audio=256s'),
      );
      expect(
        lyricRescueFailReason(
          const LyricTimingVerdict(LyricTimingIssue.none, 0, 0, ''),
          durationMs: 1,
        ),
        '',
      );
    },
  );
}
