import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lab_quarantine.dart';

void main() {
  Directory scratch(String name) {
    final Directory dir = Directory.systemTemp.createTempSync('gmx3036_$name');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  void touch(String path, String body) {
    File(path).writeAsStringSync(body);
  }

  test('ida al LAB mueve mp3, lrc, bak y karaoke juntos', () {
    final Directory src = scratch('src');
    final Directory lab = scratch('lab');
    final String base = '${src.path}${Platform.pathSeparator}tema';
    touch('$base.mp3', 'audio');
    touch('$base.lrc', 'letra');
    touch('$base.lrc.bak', 'bak');
    touch('${base}_K.mp3', 'k');
    touch('${base}_K.lrc', 'kl');

    expect(moveCompanionsToSync('$base.mp3', lab.path), isTrue);

    for (final String name in <String>[
      'tema.mp3',
      'tema.lrc',
      'tema.lrc.bak',
      'tema_K.mp3',
      'tema_K.lrc',
    ]) {
      expect(File('${lab.path}${Platform.pathSeparator}$name').existsSync(), isTrue);
      expect(File('${src.path}${Platform.pathSeparator}$name').existsSync(), isFalse);
    }

    final String again = '${src.path}${Platform.pathSeparator}tema';
    touch('$again.mp3', 'otro');
    touch('$again.lrc', 'otra');
    expect(moveCompanionsToSync('$again.mp3', lab.path), isFalse);
    expect(File('$again.mp3').readAsStringSync(), 'otro');
    expect(
      File('${lab.path}${Platform.pathSeparator}tema.mp3').readAsStringSync(),
      'audio',
    );
  });

  test('regreso devuelve los compañeros sin sobrescribir', () {
    final Directory lab = scratch('lab');
    final Directory origin = scratch('origin');
    final String labBase = '${lab.path}${Platform.pathSeparator}tema';
    final String originMp3 = '${origin.path}${Platform.pathSeparator}tema.mp3';
    touch('$labBase.mp3', 'audio');
    touch('$labBase.lrc', 'letra');
    touch('$labBase.lrc.bak', 'bak');
    touch('${labBase}_K.mp3', 'k');
    touch('${labBase}_K.lrc', 'kl');

    final LabReturn back = restoreCompanionsToSync(
      labAudio: '$labBase.mp3',
      originAudio: originMp3,
    );
    expect(back.blocked, isFalse);
    expect(back.lrcKeptAtOrigin, isFalse);
    expect(File(originMp3).readAsStringSync(), 'audio');
    expect(
      File('${origin.path}${Platform.pathSeparator}tema.lrc').readAsStringSync(),
      'letra',
    );
    expect(
      File('${origin.path}${Platform.pathSeparator}tema_K.mp3').readAsStringSync(),
      'k',
    );
    expect(File('$labBase.mp3').existsSync(), isFalse);
    expect(File('${labBase}_K.lrc').existsSync(), isFalse);

    touch('$labBase.mp3', 'nuevo');
    touch('$labBase.lrc', 'nueva');
    touch('${labBase}_K.mp3', 'k2');
    final LabReturn blocked = restoreCompanionsToSync(
      labAudio: '$labBase.mp3',
      originAudio: originMp3,
    );
    expect(blocked.blocked, isTrue);
    expect(File(originMp3).readAsStringSync(), 'audio');
    expect(File('$labBase.mp3').readAsStringSync(), 'nuevo');
    expect(File('${labBase}_K.mp3').readAsStringSync(), 'k2');
  });

  test('el rescate borra el _K viejo y manda el trío con el mismo base', () {
    final Directory folder = scratch('rescue');
    final String base = '${folder.path}${Platform.pathSeparator}tema';
    touch('$base.mp3', 'audio');
    touch('$base.lrc', 'letra');
    touch('${base}_K.mp3', 'viejo');
    touch('${base}_K.lrc', 'vieja');

    final List<String> gone = deleteStaleKaraokeSync('$base.mp3');
    expect(gone.length, 2);
    expect(File('$base.mp3').readAsStringSync(), 'audio');
    expect(File('$base.lrc').readAsStringSync(), 'letra');
    expect(File('${base}_K.mp3').existsSync(), isFalse);
    expect(File('${base}_K.lrc').existsSync(), isFalse);
    expect(karaokeMp3Beside('$base.mp3'), '${base}_K.mp3');

    final Directory lab = scratch('rescue_lab');
    final Directory home = scratch('rescue_home');
    final String labMp3 = '${lab.path}${Platform.pathSeparator}tema.mp3';
    touch(labMp3, 'nuevo');
    touch(lrcBesideAudio(labMp3), 'nueva');
    touch(karaokeMp3Beside(labMp3), 'k-nuevo');
    deliverRescuedTrackSync(labMp3, home.path, includeKaraoke: true);
    expect(
      File('${home.path}${Platform.pathSeparator}tema.mp3').readAsStringSync(),
      'nuevo',
    );
    expect(
      File('${home.path}${Platform.pathSeparator}tema.lrc').readAsStringSync(),
      'nueva',
    );
    expect(
      File('${home.path}${Platform.pathSeparator}tema_K.mp3').readAsStringSync(),
      'k-nuevo',
    );
    expect(File(labMp3).existsSync(), isFalse);

    final String stay = '${lab.path}${Platform.pathSeparator}otra.mp3';
    touch(stay, 'mp3');
    touch(lrcBesideAudio(stay), 'lrc');
    touch(karaokeMp3Beside(stay), 'k-se-queda');
    final Directory home2 = scratch('rescue_home2');
    deliverRescuedTrackSync(stay, home2.path, includeKaraoke: false);
    expect(File('${home2.path}${Platform.pathSeparator}otra.mp3').existsSync(), isTrue);
    expect(File('${home2.path}${Platform.pathSeparator}otra.lrc').existsSync(), isTrue);
    expect(
      File('${home2.path}${Platform.pathSeparator}otra_K.mp3').existsSync(),
      isFalse,
    );
    expect(File(karaokeMp3Beside(stay)).readAsStringSync(), 'k-se-queda');
  });

  test('archivos faltantes no se inventan ni rompen el movimiento', () {
    final Directory src = scratch('miss_src');
    final Directory lab = scratch('miss_lab');
    final String mp3 = '${src.path}${Platform.pathSeparator}sola.mp3';
    touch(mp3, 'solo');

    expect(companionsOf(mp3), <String>[mp3]);
    expect(deleteStaleKaraokeSync(mp3), isEmpty);
    expect(moveCompanionsToSync(mp3, lab.path), isTrue);
    expect(
      File('${lab.path}${Platform.pathSeparator}sola.mp3').existsSync(),
      isTrue,
    );
    expect(
      File('${lab.path}${Platform.pathSeparator}sola.lrc').existsSync(),
      isFalse,
    );
    expect(
      File('${lab.path}${Platform.pathSeparator}sola_K.mp3').existsSync(),
      isFalse,
    );

    final LabReturn back = restoreCompanionsToSync(
      labAudio: '${lab.path}${Platform.pathSeparator}sola.mp3',
      originAudio: mp3,
    );
    expect(back.blocked, isFalse);
    expect(File(mp3).readAsStringSync(), 'solo');
  });

  test('reentrar al LAB relee los archivos que la lista vieja no tenía', () {
    final Directory lab = scratch('scan');
    touch('${lab.path}${Platform.pathSeparator}a.mp3', 'a');
    Map<String, dynamic> visible = rescanLabRegistry(lab.path, {});
    expect(visible.keys.toList(), <String>['a.mp3']);

    touch('${lab.path}${Platform.pathSeparator}b.mp3', 'b');
    touch('${lab.path}${Platform.pathSeparator}c.mp3', 'c');
    touch('${lab.path}${Platform.pathSeparator}nota.txt', 'x');
    expect(visible.length, 1);

    visible = rescanLabRegistry(lab.path, visible);
    expect(visible.length, 3);
    expect(visible['b.mp3'], labManualOriginLabel);
    expect(visible.containsKey('nota.txt'), isFalse);
    expect(visible.containsKey('c.mp3'), isTrue);

    File('${lab.path}${Platform.pathSeparator}c.mp3').deleteSync();
    visible = rescanLabRegistry(lab.path, visible);
    expect(visible.containsKey('c.mp3'), isFalse);
    expect(visible.containsKey('a.mp3'), isTrue);
  });

  test('un segundo envio al LAB se encola sin duplicados', () {
    expect(enqueueLabSend(<String>['a.mp3'], ''), <String>['a.mp3']);
    expect(
      enqueueLabSend(const <String>[], 'b.mp3', inFlight: 'a.mp3'),
      <String>['b.mp3'],
    );
    expect(
      enqueueLabSend(<String>['b.mp3'], 'b.mp3', inFlight: 'a.mp3'),
      <String>['b.mp3'],
    );
    expect(
      enqueueLabSend(const <String>[], 'a.mp3', inFlight: 'a.mp3'),
      isEmpty,
    );
    expect(
      enqueueLabSend(<String>['b.mp3'], 'c.mp3', inFlight: 'a.mp3'),
      <String>['b.mp3', 'c.mp3'],
    );
  });
}
