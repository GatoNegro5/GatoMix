import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/queue_bpm.dart';

void main() {
  // Carpeta inexistente en %TEMP%: sin .gatomix.json ni tags, solo el nombre.
  final String dir = '${Directory.systemTemp.path}${Platform.pathSeparator}gmx3114_none';
  String p(String name) => '$dir${Platform.pathSeparator}$name';

  test('knownBpm: el nombre pasa por el rango 40-250', () {
    expect(knownBpm(p('Tema A (999 BPM).mp3')), 0);
    expect(knownBpm(p('Tema B (1 BPM).mp3')), 0);
    expect(knownBpm(p('Tema C (39 BPM).mp3')), 0);
    expect(knownBpm(p('Tema D (251 BPM).mp3')), 0);
    expect(knownBpm(p('Tema E (117 BPM).mp3')), 117);
    expect(knownBpm(p('Tema F (245 BPM).mp3')), 245);
    expect(knownBpm(p('Tema G (40 BPM).mp3')), 40);
    expect(knownBpm(p('Tema H (250 BPM).mp3')), 250);
  });
}
