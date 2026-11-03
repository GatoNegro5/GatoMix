import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_match.dart';
import 'package:gatomix/providers/nlp_provider.dart';

void main() {
  test('tras 3 intentos 429/5xx/timeout es servidor ocupado', () {
    expect(lyricRetryDelayMs(0), 3000);
    expect(lyricRetryDelayMs(1), 10000);
    expect(
      lyricFetchOutcomeFor(LyricStatus.retry),
      LyricFetchOutcome.serverDown,
    );
    expect(
      lyricIngestNotice(lyricFetchOutcomeFor(LyricStatus.retry)),
      kLyricServerBusyNotice,
    );
    expect(
      lyricFetchOutcomeFor(LyricStatus.noMatch),
      LyricFetchOutcome.notFound,
    );
    expect(
      lyricIngestNotice(LyricFetchOutcome.notFound),
      'No se encontró letra para esta canción.',
    );
    expect(lyricFetchOutcomeFor(LyricStatus.ok), LyricFetchOutcome.found);
    expect(
      lyricFetchOutcomeFor(LyricStatus.failed),
      LyricFetchOutcome.notFound,
    );
    expect(lyricIngestNotice(LyricFetchOutcome.found), isNull);
  });
}
