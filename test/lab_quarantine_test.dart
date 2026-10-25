import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/headless_args.dart';
import 'package:gatomix/core/lab_quarantine.dart';

void main() {
  late Directory root;
  late String music, lab;
  final String s = Platform.pathSeparator;
  setUp(() {
    root = Directory.systemTemp.createTempSync('gmx_lab_');
    music = '${root.path}${s}Rock';
    lab = '${root.path}${s}GatoMix_LAB';
    Directory(music).createSync();
    for (final String n in <String>['a', 'b']) {
      File('$music$s$n.mp3').writeAsStringSync('mp3 $n');
      File('$music$s$n.lrc').writeAsStringSync('[00:10.00]x');
    }
    File('$music${s}a_K.mp3').writeAsStringSync('k');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('diario de FAIL: anota, borra al arreglarse, ignora no-FAIL', () {
    recordLyricFailSync('$music${s}a.mp3', 'FAIL:lyric_wrong_song,cov=0.10');
    recordLyricFailSync('$music${s}b.mp3', 'FAIL:x');
    recordLyricFailSync('$music${s}b.mp3', null);
    recordLyricFailSync('$music${s}b.mp3', 'REVIEW');
    expect(readLyricFails(music), <String, String>{
      'a.mp3': 'FAIL:lyric_wrong_song,cov=0.10',
    });
  });

  test('auto-LAB mueve con compañeros, registra origen y es reversible', () {
    recordLyricFailSync('$music${s}a.mp3', 'FAIL:lyric_wrong_song,cov=0.10');
    final List<LabMove> m = moveFailsToLab(music, lab);
    expect(m.single.fileName, 'a.mp3');
    expect(File('$lab${s}a.mp3').existsSync(), isTrue);
    expect(File('$lab${s}a.lrc').existsSync(), isTrue);
    expect(File('$lab${s}a_K.mp3').existsSync(), isTrue);
    expect(File('$music${s}a.mp3').existsSync(), isFalse);
    expect(File('$music${s}b.mp3').existsSync(), isTrue); // b no falló
    expect(readLyricFails(music), isEmpty);
    expect(readLyricFails(lab).keys, <String>['a.mp3']);
    // Sigue fallando en el LAB: no vuelve.
    expect(restoreFixedFromLab(lab), isEmpty);
    // Rescate: el Masterizar en el LAB la arregla → vuelve a su carpeta.
    recordLyricFailSync('$lab${s}a.mp3', null);
    expect(restoreFixedFromLab(lab), <String>['$music${s}a.mp3']);
    expect(File('$music${s}a.mp3').readAsStringSync(), 'mp3 a');
    expect(File('$music${s}a_K.mp3').existsSync(), isTrue);
    expect(File('$lab${s}a.mp3').existsSync(), isFalse);
  });

  test('nunca pisa: si ya existe en el LAB, no se mueve', () {
    Directory(lab).createSync();
    File('$lab${s}a.mp3').writeAsStringSync('otra');
    recordLyricFailSync('$music${s}a.mp3', 'FAIL:x');
    expect(moveFailsToLab(music, lab), isEmpty);
    expect(File('$music${s}a.mp3').existsSync(), isTrue);
    expect(File('$lab${s}a.mp3').readAsStringSync(), 'otra');
  });

  test('argumentos sin clics', () {
    expect(parseLabRescueArg(<String>['--lab-rescue', 'X']), 'X');
    expect(parseLabRescueArg(<String>['--lab-rescue=Y']), 'Y');
    expect(
      parseAutoLabFlag(<String>['--master-folder', 'Z', '--auto-lab']),
      isTrue,
    );
    expect(parseMasterFolderArg(<String>['--master-folder', 'Z']), 'Z');
    expect(parseAutoLabFlag(<String>[]), isFalse);
  });
}
