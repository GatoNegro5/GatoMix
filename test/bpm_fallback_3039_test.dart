import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/pipeline_controller.dart';

void main() {
  test('el promedio ignora ceros y negativos', () {
    expect(averageValidBpm(<num>[0, 118, 0, 122, -4]), 120);
    expect(averageValidBpm(<num>[0, 100, 0]), 100);
  });

  test('sin BPM válido no hay promedio', () {
    expect(averageValidBpm(<num>[0, 0, 0]), isNull);
    expect(averageValidBpm(<num>[-1, 0]), isNull);
    expect(averageValidBpm(const <num>[]), isNull);
  });

  test('el promedio se redondea al entero', () {
    expect(averageValidBpm(<num>[100.4]), 100);
    expect(averageValidBpm(<num>[100.5]), 101);
    expect(averageValidBpm(<num>[10, 11]), 11);
    expect(averageValidBpm(<num>[99, 100, 0]), 100);
  });

  test('la re-descarga pide m4a antes que el resto', () {
    final List<String> args = ytDlpRedownloadArgs(
      output: 'out.%(ext)s',
      url: 'https://youtu.be/z',
    );
    expect(args[args.indexOf('-f') + 1], 'bestaudio[ext=m4a]/bestaudio/best');
  });

  test('otras pistas de la carpeta alimentan el promedio', () {
    final List<num> samples = otherFolderBpms(<String, dynamic>{
      '/musica/a.mp3': 110,
      '/musica/b.mp3': 0,
      '/musica/c.mp3': <String, dynamic>{'bpm': 130, 'key': '8A'},
      '/otra/d.mp3': 200,
      'e.mp3': 90,
    }, '/musica/a.mp3');
    expect(averageValidBpm(samples), 110);
  });

  test('BPM 0 con promedio de carpeta no queda failed', () async {
    final Directory dir = Directory.systemTemp.createTempSync('gmx3039_bpm');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final Map<String, dynamic> checkpoint = <String, dynamic>{
      'status': 'in_progress',
      'processed': <String>[],
      'failed': <String>[],
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
      folderBpm: averageValidBpm(<num>[0, 108, 112]),
    );
    expect(calls, 1);
    expect(settled.failed, isFalse);
    expect(settled.estimated, isTrue);
    expect(settled.bpm, 110);
    expect(checkpoint['failed'], isEmpty);
    expect(checkpoint.containsKey('failed_reasons'), isFalse);
    expect(
      masterCheckpointStatus(checkpoint: checkpoint, critical: false),
      'completed',
    );
    final String log = File('${dir.path}${Platform.pathSeparator}.gatomix.log')
        .readAsStringSync();
    expect(log, contains('AVISO tema.mp3 BPM estimado 110 (promedio carpeta)'));
  });
}
