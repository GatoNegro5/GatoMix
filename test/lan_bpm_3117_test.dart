import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/core/lan_sync_plan.dart';

/// 3.1.17: BPM resuelto por LAN Sync (Pendiente 20). Sinteticos en %TEMP%.
void main() {
  final String sep = Platform.pathSeparator;

  test('lanBpm: rango musical 40-250, texto o numero', () {
    expect(lanBpm(116.76), 116.76);
    expect(lanBpm('96.39'), 96.39);
    expect(lanBpm(' 250 '), 250);
    expect(lanBpm(9639), 0); // BPM x100 de un .gatomix.json viejo
    expect(lanBpm(39.9), 0);
    expect(lanBpm('NaN'), 0);
    expect(lanBpm('abc'), 0);
    expect(lanBpm(null), 0);
  });

  test('lanBpmToSave: gana el destino; solo BPM valido', () {
    expect(lanBpmToSave(localBpm: 96, incoming: '177.44'), 0);
    expect(lanBpmToSave(localBpm: 0, incoming: '177.44'), 177.44);
    expect(lanBpmToSave(localBpm: 0, incoming: 9639), 0);
    expect(lanBpmToSave(localBpm: 0, incoming: null), 0);
  });

  test('lanBpmQuery: parametro de URL, vacio sin BPM', () {
    expect(lanBpmQuery(116.764), '&bpm=116.76');
    expect(lanBpmQuery(0), '');
    expect(lanBpmQuery(300), '');
  });

  test('saveTrackMusicBatch(stampMtime): BPM + mtime local, sin pisar otras', () async {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_lan3117_');
    try {
      final String other = '${dir.path}${sep}otra.mp3';
      final File got = File('${dir.path}${sep}Billie Jean.mp3')
        ..writeAsBytesSync(<int>[0]);
      File(other).writeAsBytesSync(<int>[0]);
      got.setLastModifiedSync(DateTime(2026, 11, 1, 12));
      await saveTrackMusicBatch(<TrackMusic>[
        (path: other, bpm: 100.0, camelot: '8A'),
      ]);
      Map<String, dynamic> doc() =>
          jsonDecode(GatomixStore.fileOf(dir.path).readAsStringSync())
              as Map<String, dynamic>;
      expect(doc()['djTimestamps'], isNull); // por defecto no sella

      await saveTrackMusicBatch(<TrackMusic>[
        (path: got.path, bpm: 116.76, camelot: null),
      ], stampMtime: true);
      final Map<String, dynamic> meta = doc()['djMetadata'] as Map<String, dynamic>;
      final Map<String, dynamic> stamps =
          doc()['djTimestamps'] as Map<String, dynamic>;
      expect(meta[got.path], 116.76);
      expect(meta[other], <String, dynamic>{'bpm': 100.0, 'key': '8A'});
      expect(meta.length, 2);
      expect(
        stamps[got.path],
        got.lastModifiedSync().millisecondsSinceEpoch,
      );
      expect(stamps.length, 1);
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}