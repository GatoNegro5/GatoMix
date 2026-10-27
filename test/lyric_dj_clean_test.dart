import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_match.dart';

void main() {
  test('sufijos DJ fuera del título', () {
    expect(lyricCleanTitle('No Limit (Alejandro Dark Intro & Outro) 140 Bpm'), 'No Limit');
    expect(lyricCleanTitle('You Can Do Magic (Clean)'), 'You Can Do Magic');
    expect(lyricCleanTitle('Should Be Dancing (Intro)'), 'Should Be Dancing');
    expect(lyricCleanTitle("Keepin' Magic Alive (Intro Mashup)"), "Keepin' Magic Alive");
  });
  test('mashup cuenta como medley', () {
    expect(lyricLooksMedley("Keepin' Magic Alive (Intro Mashup)"), isTrue);
  });
  test('MIX por nombre + duración, no por tamaño', () {
    expect(lyricLooksMegamix('Berlin - The Metro.mp3', 351000), isFalse);
    expect(lyricLooksMegamix('Bee Gees - Night Fever (Remix).mp3', 420000), isFalse);
    expect(lyricLooksMegamix('80s Megamix.mp3', 420000), isTrue);
    expect(lyricLooksMegamix('Algo.mp3', 900000), isTrue);
    expect(lyricLooksMegamix('Enganchados Cumbia.mp3', 200000), isFalse);
  });
}
