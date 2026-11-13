import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lan_sync_plan.dart';

void main() {
  const List<String> dir = <String>[
    'Song.mp3',
    'Song.LRC',
    'song_k.MP3',
    'Song_K.lrc',
    'Song_K.mp3.part',
    'Otra.mp3',
  ];

  test('3.1.05: hermanos _K/_k y .lrc sin mayusculas, nunca .part', () {
    expect(lanCompanions('Song.mp3', dir),
        <String>['Song.LRC', 'song_k.MP3', 'Song_K.lrc']);
    expect(lanCompanions('song_k.MP3', dir),
        <String>['Song.mp3', 'Song.LRC', 'Song_K.lrc']);
    expect(lanCompanions('Song.lrc', dir), isEmpty);
    expect(lanCompanions('Song_K.mp3.part', dir), isEmpty);
  });

  test('3.1.05: listado ignora .part', () {
    expect(lanSyncable('Song_K.mp3.part'), isFalse);
    expect(lanSyncable('Song.MP3'), isTrue);
    expect(lanSyncable('Song.LRC'), isTrue);
    expect(lanSyncable('cover.jpg'), isFalse);
  });

  test('3.1.05: destino reutiliza el nombre con otras mayusculas', () {
    expect(lanResolveName(dir, 'SONG_K.MP3'), 'song_k.MP3');
    expect(lanResolveName(dir, 'Nueva.mp3'), 'Nueva.mp3');
    expect(lanResolveName(<String>['A.mp3.part'], 'a.mp3.part'), 'a.mp3.part');
  });

  test('3.1.05: ya existe = mismo nombre y mismo tamano', () {
    final List<dynamic> remote = <dynamic>[
      <String, dynamic>{'name': 'Song_K.mp3', 'size_bytes': 1000},
      <String, dynamic>{'name': 'Viejo.mp3'},
    ];
    expect(lanRemoteHas(remote, 'song_k.mp3'), isTrue);
    expect(lanAlreadyThere(remote, 'song_k.mp3', 1000), isTrue);
    expect(lanAlreadyThere(remote, 'Song_K.mp3', 400), isFalse); // parcial
    expect(lanAlreadyThere(remote, 'viejo.MP3', 5), isTrue); // sin size_bytes
    expect(lanAlreadyThere(remote, 'Nada.mp3', 5), isFalse);
  });

  test('3.1.05: IP de Wi-Fi en las 4 plataformas', () {
    expect(lanIsWlanName('wlan0'), isTrue);
    expect(lanIsWlanName('Wi-Fi'), isTrue);
    expect(lanIsWlanName('en0'), isTrue);
    expect(lanIsWlanName('Ethernet'), isFalse);
    expect(lanBaseName(r'C:\M\Song_K.mp3'), 'Song_K.mp3');
    expect(lanBaseName('/sdcard/Music/Song.mp3'), 'Song.mp3');
  });
}
