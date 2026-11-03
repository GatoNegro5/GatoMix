import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/workspaces/yt_workspace.dart';

void main() {
  test('rename en el mismo volumen no deja el origen', () {
    final Directory dir = Directory.systemTemp.createTempSync('mvok');
    final File src = File('${dir.path}/a.mp3')..writeAsStringSync('audio');
    final String dst = '${dir.path}/b.mp3';
    moveFile(src.path, dst);
    expect(File(dst).readAsStringSync(), 'audio');
    expect(src.existsSync(), isFalse);
    dir.deleteSync(recursive: true);
  });

  test('EXDEV: copy + delete y el destino queda con los bytes', () {
    final Directory dir = Directory.systemTemp.createTempSync('mvex');
    final File src = File('${dir.path}/a.mp3')..writeAsStringSync('audio');
    final String dst = '${dir.path}/b.mp3';
    File(dst).writeAsStringSync('viejo');
    moveFile(
      src.path,
      dst,
      rename: (String from, String to) {
        throw FileSystemException('EXDEV', from);
      },
    );
    expect(File(dst).readAsStringSync(), 'audio');
    expect(src.existsSync(), isFalse);
    dir.deleteSync(recursive: true);
  });
}
