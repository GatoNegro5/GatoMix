import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_files.dart';
import 'package:gatomix/core/lyric_match.dart';
import 'package:gatomix/ui/workspaces/lab_lyric_search.dart';

LyricCandidate _plain() => const LyricCandidate(
  artist: 'Don Medardo y sus Players - Topic',
  title: 'Este Amor No Se Toca',
  album: '',
  durationSec: 222,
  deltaSec: 3,
  score: 80,
  synced: false,
  doubtful: false,
  warning: '',
  body: 'Este amor no se toca\nes solo mío\n\nNo lo toques',
  lrclibId: 1,
  firstStampMs: null,
  fromGet: false,
);

void main() {
  test('letra plana: el .lrc lleva la marca Y el texto completo', () async {
    final c = _plain();
    expect(c.fileText, startsWith('[gmx_plain:1]\n'));
    expect(c.fileText, contains('es solo mío'));
    final dir = await Directory.systemTemp.createTemp('lab_lrc');
    final lrc = '${dir.path}/Este Amor No Se Toca.lrc';
    await File(lrc).writeAsString('[gmx_dudosa:1]\n[00:30.45] vieja');
    await writeLrcKeepingBak(lrc, c.fileText);
    final back = await File(lrc).readAsString();
    expect(back, c.fileText);
    expect(back.split('\n').length, greaterThan(3));
    await dir.delete(recursive: true);
  });

  test('vista previa plana muestra todas las líneas sin la marca', () {
    final lines = labPlainPreviewLines(_plain().fileText);
    expect(lines.first, 'Este amor no se toca');
    expect(lines, contains('No lo toques'));
    expect(lines.any((l) => l.contains('gmx_')), isFalse);
    expect(
      labPreviewHeader(_plain(), _plain().fileText),
      contains('PLANA · 3 líneas'),
    );
  });

  test('tiempos de la sincronizada', () {
    expect(labStamp(30450), '[00:30.45]');
    expect(labStamp(125070), '[02:05.07]');
  });
}
