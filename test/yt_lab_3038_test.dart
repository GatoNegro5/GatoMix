import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lab_quarantine.dart';
import 'package:gatomix/core/pipeline_controller.dart';

void main() {
  Directory scratch(String name) {
    final Directory dir = Directory.systemTemp.createTempSync('gmx3038_$name');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  void touch(String path, String body) {
    File(path).writeAsStringSync(body);
  }

  test('la re-descarga prefiere m4a y no android_vr', () {
    final List<String> args = ytDlpRedownloadArgs(
      output: 'out.%(ext)s',
      url: 'https://youtube.com/watch?v=abc',
    );
    expect(args[args.indexOf('-f') + 1], 'bestaudio[ext=m4a]/bestaudio/best');
    expect(args.join(' '), isNot(contains('android_vr')));
    expect(args.join(' '), isNot(contains('140/bestaudio')));
    expect(args, contains('https://youtube.com/watch?v=abc'));
  });

  test('el print del bitrate descarga el archivo', () {
    final List<String> args = ytDlpAbrDownloadArgs(
      output: 'raw.m4a',
      url: 'https://youtu.be/x',
    );
    expect(args, contains('--no-simulate'));
    expect(args, contains('--print'));
    expect(args, contains('%(abr)s'));
    expect(args, contains('bestaudio[ext=m4a]/141/140/bestaudio'));
  });

  test('BPM 0 se re-mide una vez y si sigue en 0 queda failed', () async {
    final Directory dir = scratch('bpm');
    final Map<String, dynamic> checkpoint = <String, dynamic>{
      'status': 'in_progress',
      'processed': <String>['tema.mp3'],
      'failed': <String>[],
      'incomplete': <String, dynamic>{'tema.mp3': 'bpm'},
    };
    var calls = 0;
    final MasterBpmSettle settled = await settleMasterBpm(
      checkpoint: checkpoint,
      fileName: 'tema.mp3',
      measured: 0,
      remeasure: () async {
        calls++;
        return 0;
      },
      logDir: dir.path,
    );
    expect(calls, 1);
    expect(settled.failed, isTrue);
    expect(settled.bpm, 0);
    expect(checkpoint['failed'], contains('tema.mp3'));
    expect((checkpoint['failed_reasons'] as Map)['tema.mp3'], 'bpm');
    expect(checkpoint['processed'], isNot(contains('tema.mp3')));
    expect((checkpoint['incomplete'] as Map).containsKey('tema.mp3'), isFalse);
    expect(
      masterCheckpointStatus(checkpoint: checkpoint, critical: false),
      'incomplete',
    );
    final String log = File('${dir.path}${Platform.pathSeparator}.gatomix.log')
        .readAsStringSync();
    expect(log, contains('AVISO tema.mp3 BPM 0.0 incompleta: bpm'));
  });

  test('un segundo BPM válido no marca failed', () async {
    final Map<String, dynamic> checkpoint = <String, dynamic>{
      'processed': <String>[],
      'failed': <String>[],
    };
    var calls = 0;
    final MasterBpmSettle settled = await settleMasterBpm(
      checkpoint: checkpoint,
      fileName: 'ok.mp3',
      measured: 0,
      remeasure: () async {
        calls++;
        return 118;
      },
    );
    expect(calls, 1);
    expect(settled.failed, isFalse);
    expect(settled.bpm, 118);
    expect(checkpoint['failed'], isEmpty);
    expect(checkpoint.containsKey('failed_reasons'), isFalse);
    expect(
      masterCheckpointStatus(checkpoint: checkpoint, critical: false),
      'completed',
    );
  });

  test('un BPM ya medido no se vuelve a medir', () async {
    final Map<String, dynamic> checkpoint = <String, dynamic>{
      'failed': <String>[],
      'processed': <String>['ok.mp3'],
    };
    var calls = 0;
    final MasterBpmSettle settled = await settleMasterBpm(
      checkpoint: checkpoint,
      fileName: 'ok.mp3',
      measured: 96,
      remeasure: () async {
        calls++;
        return 0;
      },
    );
    expect(calls, 0);
    expect(settled.failed, isFalse);
    expect(settled.bpm, 96);
    expect(checkpoint['processed'], contains('ok.mp3'));
    expect(checkpoint['failed'], isEmpty);
  });

  test('la entrega mueve bak, words y _K.lrc y limpia el registro', () {
    final Directory lab = scratch('lab');
    final Directory home = scratch('home');
    final String sep = Platform.pathSeparator;
    final String mp3 = '${lab.path}${sep}tema.mp3';
    touch(mp3, 'audio');
    touch('${lab.path}${sep}tema.lrc', 'lrc');
    touch('${lab.path}${sep}tema.lrc.bak', 'bak');
    touch('${lab.path}${sep}tema.gmx_words.json', '{}');
    touch('${lab.path}${sep}tema_K.lrc', 'kl');
    touch('${lab.path}${sep}tema_K.mp3', 'k');
    File('${lab.path}${sep}$labRegistryName').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'tema.mp3': '${home.path}${sep}tema.mp3',
        'otra.mp3': 'queda',
      }),
    );

    deliverRescuedTrackSync(mp3, home.path, includeKaraoke: true);

    expect(File('${home.path}${sep}tema.mp3').readAsStringSync(), 'audio');
    expect(File('${home.path}${sep}tema.lrc').readAsStringSync(), 'lrc');
    expect(File('${home.path}${sep}tema.lrc.bak').readAsStringSync(), 'bak');
    expect(
      File('${home.path}${sep}tema.gmx_words.json').readAsStringSync(),
      '{}',
    );
    expect(File('${home.path}${sep}tema_K.lrc').readAsStringSync(), 'kl');
    expect(File('${home.path}${sep}tema_K.mp3').readAsStringSync(), 'k');
    expect(File(mp3).existsSync(), isFalse);
    expect(File('${lab.path}${sep}tema.lrc.bak').existsSync(), isFalse);
    expect(File('${lab.path}${sep}tema.gmx_words.json').existsSync(), isFalse);

    final Map<String, dynamic> reg = jsonDecode(
      File('${lab.path}${sep}$labRegistryName').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(reg.containsKey('tema.mp3'), isFalse);
    expect(reg['otra.mp3'], 'queda');

    final String stay = '${lab.path}${sep}otra.mp3';
    touch(stay, 'mp3');
    touch('${lab.path}${sep}otra.lrc.bak', 'bak2');
    touch('${lab.path}${sep}otra.gmx_words.json', '{"a":1}');
    touch('${lab.path}${sep}otra_K.mp3', 'k-se-queda');
    touch('${lab.path}${sep}otra_K.lrc', 'kl-se-queda');
    final Directory home2 = scratch('home2');
    deliverRescuedTrackSync(stay, home2.path, includeKaraoke: false);
    expect(File('${home2.path}${sep}otra.lrc.bak').readAsStringSync(), 'bak2');
    expect(
      File('${home2.path}${sep}otra.gmx_words.json').readAsStringSync(),
      '{"a":1}',
    );
    expect(File('${home2.path}${sep}otra_K.mp3').existsSync(), isFalse);
    expect(File('${home2.path}${sep}otra_K.lrc').existsSync(), isFalse);
    expect(
      File('${lab.path}${sep}otra_K.mp3').readAsStringSync(),
      'k-se-queda',
    );
    expect(
      File('${lab.path}${sep}otra_K.lrc').readAsStringSync(),
      'kl-se-queda',
    );
  });
}
