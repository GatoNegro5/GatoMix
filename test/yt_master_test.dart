import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/workspaces/yt_workspace.dart';

void main() {
  test('bitrate según la fuente, sin inflar un AAC de 128 a 320', () {
    expect(mp3KbpsForSource(0), 192);
    expect(mp3KbpsForSource(128), 192);
    expect(mp3KbpsForSource(160), 192);
    expect(mp3KbpsForSource(192), 256);
    expect(mp3KbpsForSource(256), 320);
    expect(mp3KbpsForSource(320), 320);
  });

  test('la letra auto se anota y [gmx_manual:1] no', () {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_lrc_');
    final File auto = File('${dir.path}/A-ha - Take On Me.lrc');
    auto.writeAsStringSync('[00:12.00]Talking away\n');
    registerYtAutoLyric(auto.path);
    final Map<String, dynamic> reg =
        jsonDecode(File('${dir.path}/_lyrics_auto.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(reg.containsKey('A-ha - Take On Me.lrc'), isTrue);

    final File manual = File('${dir.path}/A mano.lrc');
    manual.writeAsStringSync('[gmx_manual:1]\n[00:01.00]hola\n');
    registerYtAutoLyric(manual.path);
    final Map<String, dynamic> again =
        jsonDecode(File('${dir.path}/_lyrics_auto.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(again.containsKey('A mano.lrc'), isFalse);
    expect(ytLyricCountsAsAuto('[gmx_manual:1]\n[00:01.00]x'), isFalse);
    expect(ytLyricCountsAsAuto('[00:01.00]x'), isTrue);
    dir.deleteSync(recursive: true);
  });
}
