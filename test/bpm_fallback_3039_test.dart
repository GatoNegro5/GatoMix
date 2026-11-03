import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/pipeline_controller.dart';

void main() {
  test('la re-descarga pide m4a antes que el resto', () {
    final List<String> args = ytDlpRedownloadArgs(
      output: 'out.%(ext)s',
      url: 'https://youtu.be/z',
    );
    expect(args[args.indexOf('-f') + 1], 'bestaudio[ext=m4a]/bestaudio/best');
  });

  test('BPM medido no se vuelve a medir', () async {
    final Map<String, dynamic> checkpoint = <String, dynamic>{
      'status': 'in_progress',
      'processed': <String>[],
      'failed': <String>[],
    };
    var calls = 0;
    final MasterBpmSettle settled = await settleMasterBpm(
      checkpoint: checkpoint,
      fileName: 'tema.mp3',
      measured: 118,
      remeasure: () async {
        calls++;
        return 0;
      },
    );
    expect(calls, 0);
    expect(settled.failed, isFalse);
    expect(settled.bpm, 118);
    expect(checkpoint.containsKey('failed_reasons'), isFalse);
  });

  test('BPM 0 tras re-medir queda failed con aviso', () async {
    final Directory dir = Directory.systemTemp.createTempSync('gmx3040_bpm');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final Map<String, dynamic> checkpoint = <String, dynamic>{
      'status': 'in_progress',
      'processed': <String>['tema.mp3'],
      'failed': <String>[],
      'incomplete': <String, dynamic>{'tema.mp3': 'x'},
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
    expect(checkpoint['failed'], <String>['tema.mp3']);
    expect(checkpoint['processed'], isEmpty);
    expect(checkpoint['incomplete'], isEmpty);
    expect(checkpoint['failed_reasons'], <String, dynamic>{'tema.mp3': 'bpm'});
    expect(
      masterCheckpointStatus(checkpoint: checkpoint, critical: false),
      'incomplete',
    );
    final String log = File('${dir.path}${Platform.pathSeparator}.gatomix.log')
        .readAsStringSync();
    expect(log, contains('AVISO tema.mp3 BPM 0.0 incompleta: bpm'));
  });

  test('si la re-medición devuelve BPM, no queda failed', () async {
    final Map<String, dynamic> checkpoint = <String, dynamic>{
      'failed': <String>[],
      'processed': <String>[],
    };
    final MasterBpmSettle settled = await settleMasterBpm(
      checkpoint: checkpoint,
      fileName: 'tema.mp3',
      measured: 0,
      remeasure: () async => 96.18,
    );
    expect(settled.failed, isFalse);
    expect(settled.bpm, 96.18);
    expect(checkpoint.containsKey('failed_reasons'), isFalse);
  });
}
