// Uso: dart run tool/validate_ai_align.dart <dir_lrc> <dir_json>
import 'dart:io';
import 'package:gatomix/core/lyric_ai_align.dart';
import 'package:gatomix/core/lyric_timing_check.dart';
import 'dart:convert';

void main(List<String> a) {
  final Map<String, int> tally = {};
  for (final f
      in Directory(a[1]).listSync().whereType<File>().toList()
        ..sort((x, y) => x.path.compareTo(y.path))) {
    if (!f.path.endsWith('.json')) continue;
    final name = f.uri.pathSegments.last.replaceAll('.json', '');
    final lrcF = File('${a[0]}/$name.lrc');
    if (!lrcF.existsSync()) continue;
    final js = f.readAsStringSync();
    final dur = ((jsonDecode(js)['dur'] as num) * 1000).round();
    final lrc = lrcF.readAsStringSync();
    final before = checkLyricTiming(lrc: lrc, durationMs: dur);
    final r = alignLyricToWords(
      lrc: lrc,
      words: parseTimedWordsJson(js),
      durationMs: dur,
    );
    if (r.lrc != null) {
      final r2 = alignLyricToWords(
        lrc: r.lrc!,
        words: parseTimedWordsJson(js),
        durationMs: dur,
      );
      print(
        '   RECHECK ${r2.kind.name} med=${r2.medianOffsetMs} sp=${r2.spreadMs} anc=${r2.anchored}/${r2.lines}',
      );
    }
    tally[r.kind.name] = (tally[r.kind.name] ?? 0) + 1;
    print(
      '${name.padRight(42).substring(0, 42)} before=${before.issue.name.padRight(17)} '
      '${r.kind.name.padRight(13)} cov=${r.coverage.toStringAsFixed(2)} '
      'anc=${r.anchored}/${r.lines} med=${r.medianOffsetMs} sp=${r.spreadMs} ${r.reason} ${r.failReason}',
    );
  }
  print(tally);
}
