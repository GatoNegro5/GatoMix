import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_files.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('lablrc'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File f(String rel, [String? body]) {
    final file = File('${tmp.path}/$rel')..parent.createSync(recursive: true);
    if (body != null) file.writeAsStringSync(body);
    return file;
  }

  test('mueve el .lrc al origen y borra solo su .bak', () async {
    final lab = f('LAB/Duncan.lrc', '[00:01.00]hola');
    final bak = f('LAB/Duncan.lrc.bak', 'viejo');
    final otherBak = f('LAB/Otro.lrc.bak', 'x');
    final origin = f('Bala/Duncan.lrc');
    final r = await moveLabLrcToOrigin(
      labLrcPath: lab.path,
      originLrcPath: origin.path,
    );
    expect(r, LabLrcRestore.moved);
    expect(origin.readAsStringSync(), '[00:01.00]hola');
    expect(lab.existsSync(), isFalse);
    expect(bak.existsSync(), isFalse);
    expect(otherBak.existsSync(), isTrue);
  });

  test('si el origen ya tiene .lrc no lo pisa', () async {
    final lab = f('LAB/D.lrc', 'nuevo');
    final bak = f('LAB/D.lrc.bak', 'b');
    final origin = f('Bala/D.lrc', 'original');
    final r = await moveLabLrcToOrigin(
      labLrcPath: lab.path,
      originLrcPath: origin.path,
    );
    expect(r, LabLrcRestore.keptOrigin);
    expect(origin.readAsStringSync(), 'original');
    expect(lab.existsSync(), isTrue);
    expect(bak.existsSync(), isTrue);
  });

  test('sin .lrc en LAB: borra .bak huérfano', () async {
    final bak = f('LAB/E.lrc.bak', 'b');
    final r = await moveLabLrcToOrigin(
      labLrcPath: '${tmp.path}/LAB/E.lrc',
      originLrcPath: '${tmp.path}/Bala/E.lrc',
    );
    expect(r, LabLrcRestore.none);
    expect(bak.existsSync(), isFalse);
  });

  test('sameAudioPath', () {
    expect(sameAudioPath('/a/b.mp3', '/a/b.mp3'), isTrue);
    expect(sameAudioPath(null, '/a/b.mp3'), isFalse);
    expect(sameAudioPath('/a/b.mp3', '/a/c.mp3'), isFalse);
  });
}
