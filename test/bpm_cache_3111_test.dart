import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_store.dart';

void main() {
  const String dir = r'C:\GmxTest3111\Salsa';
  final List<String> present = <String>[
    r'C:\GmxTest3111\Salsa\Tema (120 BPM).mp3',
    r'C:\GmxTest3111\Salsa\Sub\Otro.mp3',
  ];

  test('3.1.11: poda nombres viejos renombrados y conserva los actuales', () {
    final Map<String, dynamic> index = <String, dynamic>{
      r'C:\GmxTest3111\Salsa\Tema (120 BPM).mp3': 120.0,
      'Tema (120 BPM).mp3': 120.0,
      r'C:\GmxTest3111\Salsa\Tema.mp3': 93.09,
      'Tema.mp3': 93.09,
      r'C:\GmxTest3111\Salsa\Sub\Otro.mp3': <String, dynamic>{
        'bpm': 128.0,
        'key': '8A',
      },
      'Otro.mp3': 128.0,
      'C:/GmxTest3111/Salsa/Viejo.mp3': 8677,
      r'C:\GmxTest3111\Merengue\Ajeno.mp3': 150.0,
      'notas': 1,
    };
    final Map<String, dynamic> out = pruneMissingBpmKeys(
      index,
      directoryPath: dir,
      presentPaths: present,
    );
    expect(out[r'C:\GmxTest3111\Salsa\Tema (120 BPM).mp3'], 120.0);
    expect(out['Tema (120 BPM).mp3'], 120.0);
    expect(out[r'C:\GmxTest3111\Salsa\Sub\Otro.mp3'], <String, dynamic>{
      'bpm': 128.0,
      'key': '8A',
    });
    expect(out['Otro.mp3'], 128.0);
    expect(out[r'C:\GmxTest3111\Merengue\Ajeno.mp3'], 150.0);
    expect(out['notas'], 1);
    expect(out.containsKey(r'C:\GmxTest3111\Salsa\Tema.mp3'), isFalse);
    expect(out.containsKey('Tema.mp3'), isFalse);
    expect(out.containsKey('C:/GmxTest3111/Salsa/Viejo.mp3'), isFalse);
    expect(out.length, 6);
  });

  test('3.1.11: djTimestamps usa la misma poda', () {
    final Map<String, dynamic> stamps = <String, dynamic>{
      r'C:\GmxTest3111\Salsa\Tema (120 BPM).mp3': 1731500000000,
      r'C:\GmxTest3111\Salsa\Tema.mp3': 1731000000000,
    };
    final Map<String, dynamic> out = pruneMissingBpmKeys(
      stamps,
      directoryPath: dir,
      presentPaths: present,
    );
    expect(out.keys, <String>[r'C:\GmxTest3111\Salsa\Tema (120 BPM).mp3']);
  });

  test('3.1.11: una carpeta hermana con el mismo prefijo no se poda', () {
    final Map<String, dynamic> out = pruneMissingBpmKeys(
      <String, dynamic>{r'C:\GmxTest3111\Salsa2\Otra.mp3': 100.0},
      directoryPath: dir,
      presentPaths: present,
    );
    expect(out.length, 1);
  });
}