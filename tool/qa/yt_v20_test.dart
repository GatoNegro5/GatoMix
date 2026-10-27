import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_match.dart';
import 'package:gatomix/core/track_name_clean.dart';

Future<dynamic> j(Uri u) async {
  for (var a = 0; a < 3; a++) {
    final c = HttpClient()..userAgent = 'GatoMix-QA';
    try {
      final r = await (await c.getUrl(u)).close();
      final b = await r.transform(utf8.decoder).join();
      if (r.statusCode == 200) return jsonDecode(b);
      if (r.statusCode == 404) return null;
    } catch (_) {
    } finally {
      c.close();
    }
    await Future.delayed(Duration(milliseconds: 1500 << a));
  }
  return null;
}

String first(String s) => s
    .split('\n')
    .map((l) => l.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim())
    .firstWhere((l) => l.isNotEmpty, orElse: () => '');

void main() {
  test('yt v21', () async {
    for (final line in File(
      '/workspace/mc/v21/yt/list.tsv',
    ).readAsLinesSync()) {
      final p = line.split('\t');
      var dur = int.parse(p[1]);
      final title = p[2];
      if (p[0] == '_u69ZThtRSk') dur = 241;
      // yt_workspace.dart: safeTitle -> cleanTrackFileName -> stem
      final stem = ytTitleToStem(title);
      final c = cleanTrackFileName(stem);
      // nlp_provider.lookupSafeLyric
      final ids = lyricIdentities(path: '/tmp/$stem.m4a', durationSec: dur);
      final pool = <Map<String, dynamic>>[];
      final used = <String>[];
      Future<void> collect(LyricIdentity id) async {
        final q = lrclibTitleOnlyUri(id);
        if (q != null) {
          used.add('q=${q.queryParameters['q']}');
          final r = await j(q);
          if (r is List)
            pool.addAll(r.map((e) => Map<String, dynamic>.from(e)));
          return;
        }
        used.add('get+search ${id.artist}|${id.title}');
        final g = await j(lrclibGetUri(id));
        if (g is Map) pool.add(Map<String, dynamic>.from(g));
        final s = await j(lrclibSearchUri(id));
        if (s is List) pool.addAll(s.map((e) => Map<String, dynamic>.from(e)));
      }

      for (final id in ids) {
        await collect(id);
      }
      var main = ids.first;
      List<LyricIdentity> also = ids.length > 1 ? ids.sublist(1) : const [];
      if (pool.isEmpty) {
        for (final fb in lyricFallbackIdentities(ids.first)) {
          await collect(fb);
          if (pool.isNotEmpty) {
            main = fb;
            also = const [];
            break;
          }
        }
      }
      final ch = chooseLrclibLyric(main, also: also, searched: pool);
      print(
        'YT «$title» ${dur}s\n   stem=«$stem» artist=«${c.artist}» title=«${c.title}»\n   ${used.join(' ; ')} -> ${pool.length} filas, letra=${ch.hasText ? '${ch.kind.name} «${first(ch.body)}»' : 'NO'}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
