import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_radio.dart';
import 'package:gatomix/core/mode_session.dart';
import 'package:gatomix/core/session_restore.dart';
import 'package:gatomix/core/session_store.dart';

void main() {
  String sep = Platform.pathSeparator;

  test('automix.json reúne la sesión y reanuda donde quedó', () {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_am_');
    final String s = sep;
    File('${dir.path}${s}tema.mp3').writeAsStringSync('audio');
    File('${dir.path}${s}tema.lrc').writeAsStringSync('[00:01.00]hola');
    File('${dir.path}${s}tema_K.mp3').writeAsStringSync('karaoke');
    File('${dir.path}${s}player_session.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'playlist': <String>['/mix/a.mp3', '/mix/b.mp3', '/mix/c.mp3'],
        'currentIndex': 1,
        'positionMs': 15000,
        'mixStrategy': 1,
        'autoMixArmed': true,
        'wasPlaying': true,
      }),
    );
    File('${dir.path}${s}_automix_session.json').writeAsStringSync(
      jsonEncode(<String>['/mix/a.mp3', '/mix/b.mp3', '/mix/c.mp3']),
    );
    File('${dir.path}${s}_played_tracks_session.json').writeAsStringSync(
      jsonEncode(<String>['/mix/a.mp3']),
    );
    File('${dir.path}${s}_automix_sort.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{'sortMode': 'bpmAsc'}),
    );
    File('${dir.path}${s}_ui_route.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{'route': 0}),
    );

    final Map<String, dynamic> doc = migrateAutomixDir(dir.path);
    expect(doc['playlist'], <String>['/mix/a.mp3', '/mix/b.mp3', '/mix/c.mp3']);
    expect(doc['currentIndex'], 1);
    expect(doc['positionMs'], 15000);
    expect(doc['mixStrategy'], 1);
    expect(doc['autoMixArmed'], isTrue);
    expect(doc['wasPlaying'], isTrue);
    expect(doc['queue'], <String>['/mix/a.mp3', '/mix/b.mp3', '/mix/c.mp3']);
    expect(doc['played'], <String>['/mix/a.mp3']);
    expect(doc['sortMode'], 'bpmAsc');
    expect(doc['uiRoute'], 0);
    expect(File('${dir.path}${s}automix.json').existsSync(), isTrue);
    expect(File('${dir.path}${s}player_session.json').existsSync(), isFalse);
    expect(File('${dir.path}${s}_automix_session.json').existsSync(), isFalse);
    expect(
      File('${dir.path}${s}_played_tracks_session.json').existsSync(),
      isFalse,
    );
    expect(File('${dir.path}${s}_automix_sort.json').existsSync(), isFalse);
    expect(File('${dir.path}${s}_ui_route.json').existsSync(), isTrue);
    expect(File('${dir.path}${s}tema.mp3').readAsStringSync(), 'audio');
    expect(File('${dir.path}${s}tema.lrc').readAsStringSync(), contains('hola'));
    expect(File('${dir.path}${s}tema_K.mp3').readAsStringSync(), 'karaoke');

    final AutomixSessionRestore back = restoreAutomixSession(
      doc,
      exists: (_) => true,
      listDir: (_) => const <String>[],
    );
    expect(back.playlist, <String>['/mix/a.mp3', '/mix/b.mp3', '/mix/c.mp3']);
    expect(back.index, 1);
    expect(back.positionMs, 15000);
    expect(back.wasPlaying, isTrue);
    expect(back.mixStrategyIndex, 1);
    dir.deleteSync(recursive: true);
  });

  test('liveDj.json conserva la sesión y reanuda cola y posición', () {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_ld_');
    final String s = sep;
    final Map<String, dynamic> old = <String, dynamic>{
      'schema': 2,
      'queue': <String>['/dj/b.mp3', '/dj/c.mp3'],
      'currentTrackPath': '/dj/a.mp3',
      'positionMs': 32500,
      'mixMode': 0,
      'mixStrategy': 1,
      'mixFormula': 2,
      'wasPlaying': true,
      'radioOn': false,
      'radioGenres': <String>['rock'],
      'sortMode': 'bpmAsc',
    };
    File('${dir.path}${s}_livedj_session.json').writeAsStringSync(jsonEncode(old));
    final Map<String, dynamic> doc = migrateLiveDjDir(dir.path);
    expect(jsonEqualMap(doc, old), isTrue);
    expect(File('${dir.path}${s}_livedj_session.json').existsSync(), isFalse);
    expect(File('${dir.path}${s}liveDj.json').existsSync(), isTrue);
    final LiveDjSessionRestore back = restoreLiveDjSession(
      doc,
      exists: (_) => true,
      listDir: (_) => const <String>[],
    );
    expect(back.queue, <String>['/dj/b.mp3', '/dj/c.mp3']);
    expect(back.currentTrackPath, '/dj/a.mp3');
    expect(back.positionMs, 32500);
    expect(back.wasPlaying, isTrue);
    expect(back.mixStrategyIndex, 1);
    dir.deleteSync(recursive: true);
  });

  test('LiveDj_Radio.json hereda .gatomix_radio.json y sigue en la posición', () {
    final Directory root = Directory.systemTemp.createTempSync('gmx_rd_');
    final String s = sep;
    File('${root.path}${s}.gatomix_radio.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'schema': 1,
        'history': <String>['/old/a.mp3'],
        'pairs': <String>['p'],
        'waveUp': false,
        'inWave': 3,
        'previousBpm': 110,
        'plans': <String, dynamic>{
          'rock': <String, dynamic>{
            'order': <String>['/rock/a.mp3', '/rock/b.mp3', '/rock/c.mp3'],
            'position': 2,
            'pairs': <String>['ab'],
            'previousPairs': <String>['zz'],
          },
        },
      }),
    );
    final RadioMemory mem = GatomixRadio.load(root.path);
    expect(mem.history, <String>['/old/a.mp3']);
    expect(mem.planOf('rock')!.position, 2);
    expect(mem.planOf('rock')!.order, <String>[
      '/rock/a.mp3',
      '/rock/b.mp3',
      '/rock/c.mp3',
    ]);
    expect(mem.waveUp, isFalse);
    expect(mem.inWave, 3);
    expect(File('${root.path}${s}.gatomix_radio.json').existsSync(), isFalse);
    expect(File('${root.path}${s}LiveDj_Radio.json').existsSync(), isTrue);
    final RadioMemory again = GatomixRadio.load(root.path);
    expect(again.planOf('rock')!.position, 2);
    expect(again.history, mem.history);
    root.deleteSync(recursive: true);
  });

  test('borrar la cola vacía solo el json de ese modo', () async {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_cl_');
    final String s = sep;
    final String automix = '${dir.path}${s}automix.json';
    final String livedj = '${dir.path}${s}liveDj.json';
    final String radio = '${dir.path}${s}LiveDj_Radio.json';
    final String tags = '${dir.path}${s}.gatomix.json';
    File(automix).writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'schema': 1,
        'queue': <String>['/Rock/a.mp3', '/Rock/b.mp3'],
        'playlist': <String>['/Rock/a.mp3', '/Rock/b.mp3'],
        'currentIndex': 1,
        'positionMs': 8000,
        'wasPlaying': true,
        'played': <String>['/Rock/a.mp3'],
        'pairs': <String>['ab'],
        'recent': <List<Object>>[
          <Object>['/Rock/a.mp3', 1],
        ],
        'waveUp': false,
        'inWave': 6,
        'previousBpm': 128,
        'sortMode': 'bpmAsc',
        'mixStrategy': 1,
      }),
    );
    final String liveText = jsonEncode(<String, dynamic>{
      'schema': 2,
      'queue': <String>['/dj/a.mp3'],
      'currentTrackPath': '/dj/now.mp3',
      'positionMs': 1000,
      'wasPlaying': true,
      'sortMode': 'manual',
    });
    final String radioText = jsonEncode(<String, dynamic>{
      'schema': 1,
      'plans': <String, dynamic>{
        'rock': <String, dynamic>{
          'order': <String>['/rock/a.mp3'],
          'position': 1,
          'pairs': <String>[],
          'previousPairs': <String>[],
        },
      },
    });
    final String tagText = jsonEncode(<String, dynamic>{
      'schema': 1,
      'djMetadata': <String, dynamic>{
        '/Rock/a.mp3': <String, dynamic>{'bpm': 120, 'key': '8A'},
      },
      'shuffle': <String, dynamic>{
        'pairs': <String>['no-tocar'],
      },
    });
    File(livedj).writeAsStringSync(liveText);
    File(radio).writeAsStringSync(radioText);
    File(tags).writeAsStringSync(tagText);

    clearModeQueueSync(automix, playbackList: true);
    final Map<String, dynamic> cleared = readModeDoc(automix);
    expect(modeQueueIsClear(cleared), isTrue);
    expect(cleared['sortMode'], 'bpmAsc');
    expect(cleared['mixStrategy'], 1);
    expect(File(livedj).readAsStringSync(), liveText);
    expect(File(radio).readAsStringSync(), radioText);
    expect(File(tags).readAsStringSync(), tagText);

    clearModeQueueSync(livedj);
    expect(modeQueueIsClear(readModeDoc(livedj)), isTrue);
    expect(readModeDoc(livedj)['sortMode'], 'manual');
    expect(modeQueueIsClear(readModeDoc(automix)), isTrue);
    expect(File(radio).readAsStringSync(), radioText);
    expect(File(tags).readAsStringSync(), tagText);
    expect(jsonDecode(tagText)['djMetadata'], <String, dynamic>{
      '/Rock/a.mp3': <String, dynamic>{'bpm': 120, 'key': '8A'},
    });
    dir.deleteSync(recursive: true);
  });

  test('un guardado pendiente no revive la cola y la nueva arranca limpia', () async {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_nw_');
    final String s = sep;
    final String path = '${dir.path}${s}automix.json';
    final Future<void> pending = SessionStore.writeJson(path, <String, dynamic>{
      'schema': 1,
      'queue': <String>['/Rock/vieja.mp3'],
      'playlist': <String>['/Rock/vieja.mp3'],
      'positionMs': 9000,
      'played': <String>['/Rock/vieja.mp3'],
      'pairs': <String>['vieja'],
      'waveUp': false,
      'inWave': 4,
      'previousBpm': 140,
      'wasPlaying': true,
    });
    clearModeQueueSync(path, playbackList: true);
    await pending;
    expect(modeQueueIsClear(readModeDoc(path)), isTrue);
    expect(jsonEncode(readModeDoc(path)).contains('Rock'), isFalse);

    await patchModeDoc(path, <String, dynamic>{
      'queue': <String>['/Cumbias/a 90bpm.mp3'],
      'playlist': <String>['/Cumbias/a 90bpm.mp3'],
      'currentIndex': 0,
    });
    final Map<String, dynamic> fresh = readModeDoc(path);
    expect(fresh['queue'], <String>['/Cumbias/a 90bpm.mp3']);
    expect(fresh['playlist'], <String>['/Cumbias/a 90bpm.mp3']);
    expect(fresh['played'], isEmpty);
    expect(fresh['pairs'], isEmpty);
    expect(fresh['positionMs'], 0);
    expect(fresh['wasPlaying'], isFalse);
    expect(fresh['inWave'], 0);
    expect(fresh['waveUp'], isTrue);
    expect(fresh['previousBpm'], 0);
    expect(jsonEncode(fresh).contains('Rock'), isFalse);
    expect(jsonEncode(fresh).contains('vieja'), isFalse);
    dir.deleteSync(recursive: true);
  });

  test('Automix inserta en el hueco de BPM', () {
    final List<String> queue = <String>[
      '/q/siguiente 100bpm 8A.mp3',
      '/q/a 104bpm 8A.mp3',
      '/q/b 112bpm 9A.mp3',
      '/q/c 120bpm 9A.mp3',
    ];
    final List<String> next = automixInsertAtGap(
      queue: queue,
      incoming: <String>['/q/nueva 108bpm 8A.mp3'],
      bpmOf: (String p) {
        final RegExpMatch? m = RegExp(r'(\d+)bpm').firstMatch(p);
        return m == null ? 0 : double.parse(m.group(1)!);
      },
      keyOf: (String p) {
        final RegExpMatch? m = RegExp(r'(\d{1,2}[AB])').firstMatch(p);
        return m?.group(1);
      },
      lockedPrefix: 1,
      playing: '/q/sonando 98bpm 8A.mp3',
      pinned: queue.first,
    );
    expect(next.first, queue.first);
    expect(next[1], queue[1]);
    expect(next[2], '/q/nueva 108bpm 8A.mp3');
    expect(next.contains('/q/sonando 98bpm 8A.mp3'), isFalse);
    expect(next.length, queue.length + 1);
  });
}

bool jsonEqualMap(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, dynamic> e in a.entries) {
    if (!b.containsKey(e.key)) return false;
    if (jsonEncode(e.value) != jsonEncode(b[e.key])) return false;
  }
  return true;
}
