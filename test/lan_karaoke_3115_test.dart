import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lan_sync_plan.dart';

void main() {
  const List<String> dir = <String>[
    'Tema.mp3',
    'Tema.lrc',
    'Tema.txt',
    'Tema_K.mp3',
    'Tema_K.lrc',
    'Tema_K.mp3.part',
    'Otro.mp3',
  ];

  test('3.1.15 lanIsKaraokeMp3 solo marca <base>_K.mp3', () {
    expect(lanIsKaraokeMp3('Tema_K.mp3'), isTrue);
    expect(lanIsKaraokeMp3(r'C:\\M\\tema_k.MP3'), isTrue);
    expect(lanIsKaraokeMp3('/sd/M/Tema_K.mp3'), isTrue);
    expect(lanIsKaraokeMp3('Tema.mp3'), isFalse);
    expect(lanIsKaraokeMp3('Tema_K.lrc'), isFalse);
    expect(lanIsKaraokeMp3('Tema_K.mp3.part'), isFalse);
    expect(lanIsKaraokeMp3('Track.mp3'), isFalse);
  });

  test('3.1.15 con _K: igual que 3.1.05 (lrc, txt, _K.mp3, _K.lrc; nunca .part)', () {
    expect(
      lanCompanions('Tema.mp3', dir).toSet(),
      <String>{'Tema.lrc', 'Tema.txt', 'Tema_K.mp3', 'Tema_K.lrc'},
    );
  });

  test('3.1.15 sin _K: no viaja el _K.mp3, los .lrc/.txt si', () {
    expect(
      lanCompanions('Tema.mp3', dir, withKaraoke: false).toSet(),
      <String>{'Tema.lrc', 'Tema.txt', 'Tema_K.lrc'},
    );
    // Un _K elegido a mano trae su pista normal y sus letras.
    expect(
      lanCompanions('Tema_K.mp3', dir, withKaraoke: false).toSet(),
      <String>{'Tema.mp3', 'Tema.lrc', 'Tema.txt', 'Tema_K.lrc'},
    );
  });

  test('3.1.15 .gatomix.json y .gmxpart siguen fuera de LAN Sync', () {
    expect(lanSyncable('.gatomix.json'), isFalse);
    expect(lanSyncable('Tema_K.mp3.gmxpart'), isFalse);
    expect(lanSyncable('Tema_K.mp3.part'), isFalse);
    expect(lanSyncable('Tema_K.mp3'), isTrue);
  });
}
