import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_files.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('redl'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('re-descarga: el primer .bak guarda el original', () {
    final lrc = '${tmp.path}/A.lrc';
    File(lrc).writeAsStringSync('original');
    expect(stashLrcBeforeRedownloadSync(lrc), isTrue);
    expect(File(lrc).existsSync(), isFalse);
    expect(File('$lrc.bak').readAsStringSync(), 'original');
  });

  test('re-descarga no pisa un .lrc.bak existente', () {
    final lrc = '${tmp.path}/B.lrc';
    File('$lrc.bak').writeAsStringSync('original');
    File(lrc).writeAsStringSync('del LAB');
    expect(stashLrcBeforeRedownloadSync(lrc), isTrue);
    expect(File('$lrc.bak').readAsStringSync(), 'original');
    expect(File(lrc).existsSync(), isFalse);
  });

  test('sin .lrc previo deja el marcador y Deshacer borra la nueva', () async {
    final lrc = '${tmp.path}/C.lrc';
    expect(stashLrcBeforeRedownloadSync(lrc), isFalse);
    expect(File('$lrc.bak').readAsStringSync().trim(), kLrcNoOriginalMark);
    File(lrc).writeAsStringSync('[00:01.00]nueva');
    await undoAppliedLrc(lrc);
    expect(File(lrc).existsSync(), isFalse);
  });

  test('marcador existente no se cambia por la letra del LAB', () {
    final lrc = '${tmp.path}/D.lrc';
    File('$lrc.bak').writeAsStringSync('$kLrcNoOriginalMark\n');
    File(lrc).writeAsStringSync('del LAB');
    stashLrcBeforeRedownloadSync(lrc);
    expect(File('$lrc.bak').readAsStringSync().trim(), kLrcNoOriginalMark);
  });
}
