import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/master_skip.dart';

List<int> _ss(int n) => <int>[
  (n >> 21) & 0x7f,
  (n >> 14) & 0x7f,
  (n >> 7) & 0x7f,
  n & 0x7f,
];

List<int> _frame(String id, List<int> data) => <int>[
  ...latin1.encode(id),
  ..._ss(data.length),
  0,
  0,
  ...data,
];

List<int> _mp3(Map<String, String> tags, {bool seal = true}) {
  final List<int> body = <int>[];
  tags.forEach((k, v) {
    body.addAll(
      _frame('TXXX', <int>[3, ...utf8.encode(k), 0, ...utf8.encode(v)]),
    );
  });
  if (seal) {
    body.addAll(
      _frame('COMM', <int>[
        3,
        ...latin1.encode('eng'),
        0,
        ...utf8.encode('ReGenial Master'),
      ]),
    );
  }
  return <int>[
    ...latin1.encode('ID3'),
    4,
    0,
    0,
    ..._ss(body.length),
    ...body,
    ...List<int>.filled(4096, 0xAA), // "audio" que nunca se lee
  ];
}

const Map<String, String> _done = <String, String>{
  'GMX_NAME_OK': '1',
  'GMX_TYPE': 'SONG',
  'GMX_BACKUP': '1',
  'GMX_LYR': 'SYNC',
  'GMX_LYR_CHECK': 'OK',
  'GMX_TRIM_MS': '80',
  'GMX_LUFS_DONE': '-14.0',
  'GMX_BPM_OK': '1',
};

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('gmx_skip'));
  tearDown(() => dir.deleteSync(recursive: true));

  String put(String name, List<int> bytes) {
    final File f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return f.path;
  }

  List<String> pending(MasterSkipIndex idx, List<String> paths) =>
      paths.where((p) => !idx.decide(p).skip).toList();

  test('carpeta ya OK + 10 nuevas: solo se procesan las 10 nuevas', () {
    final List<String> all = <String>[
      for (int i = 0; i < 30; i++) put('ok$i.mp3', _mp3(_done)),
      for (int i = 0; i < 10; i++) put('nueva$i.mp3', _mp3(const {})),
    ];
    final MasterSkipIndex idx = MasterSkipIndex.load(dir.path);
    final Stopwatch sw = Stopwatch()..start();
    final List<String> todo = pending(idx, all);
    sw.stop();
    expect(todo.map((p) => p.split('/').last).toList(), <String>[
      for (int i = 0; i < 10; i++) 'nueva$i.mp3',
    ]);
    expect(sw.elapsedMilliseconds, lessThan(2000));
    idx.save();
    // Segunda pasada: las 30 salen del índice, sin leer tags.
    final MasterSkipIndex again = MasterSkipIndex.load(dir.path);
    expect(again.decide(all.first).reason, 'index');
    expect(pending(again, all).length, 10);
  });

  test('archivo modificado se reprocesa', () {
    final String p = put('a.mp3', _mp3(_done));
    final MasterSkipIndex idx = MasterSkipIndex.load(dir.path);
    idx.record(p);
    expect(idx.decide(p).skip, isTrue);
    File(p).writeAsBytesSync(<int>[..._mp3(_done), 1, 2, 3]);
    final SkipDecision d = idx.decide(p);
    expect(d.skip, isFalse);
    expect(d.reason, 'changed');
  });

  test('letra en RETRY se reintenta', () {
    final String p = put(
      'r.mp3',
      _mp3(<String, String>{..._done, 'GMX_LYR': 'RETRY'}),
    );
    final MasterSkipIndex idx = MasterSkipIndex.load(dir.path);
    expect(idx.decide(p).reason, 'lyr_retry');
    idx.record(p);
    expect(idx.decide(p).skip, isFalse);
  });

  test('_K solo audio: sin letra ni sello se da por completo', () {
    final Map<String, String> audio = <String, String>{
      'GMX_TRIM_MS': '0',
      'GMX_LUFS_DONE': '-14.0',
      'GMX_BPM_OK': '1',
    };
    final String k = put('t_K.mp3', _mp3(audio, seal: false));
    final MasterSkipIndex idx = MasterSkipIndex.load(dir.path);
    expect(idx.decide(k).skip, isTrue);
    final String song = put('t2.mp3', _mp3(audio, seal: false));
    expect(idx.decide(song).skip, isFalse);
  });

  test('megamix no exige letra; canción con _K exige GMX_K', () {
    final String m = put(
      'mix.mp3',
      _mp3(
        <String, String>{..._done, 'GMX_TYPE': 'MEGAMIX', 'GMX_LYR': 'NA'}
          ..remove('GMX_LYR_CHECK'),
      ),
    );
    final MasterSkipIndex idx = MasterSkipIndex.load(dir.path);
    expect(idx.decide(m).skip, isTrue);
    final String s = put('song.mp3', _mp3(_done));
    put('song_K.mp3', _mp3(const {}));
    expect(idx.decide(s).reason, 'k');
  });

  test('cambio del .lrc fuerza reproceso', () {
    final String p = put('l.mp3', _mp3(_done));
    final MasterSkipIndex idx = MasterSkipIndex.load(dir.path);
    idx.record(p);
    File('${dir.path}/l.lrc').writeAsStringSync('[00:01.00]hola');
    expect(idx.decide(p).skip, isFalse);
  });

  test('1.0.20+39: .lrc APPROX nuevo con tags completos no se reprocesa', () {
    final Map<String, String> tags = Map.of(_done)..['GMX_LYR'] = 'APPROX';
    final String p = put('a.mp3', _mp3(tags));
    final MasterSkipIndex idx = MasterSkipIndex.load(dir.path);
    idx.record(p);
    File('${dir.path}/a.lrc').writeAsStringSync('[gmx_approx]\n[00:01.00]hola');
    final SkipDecision d = idx.decide(p);
    expect(d.skip, isTrue);
    expect(d.reason, 'tags');
    expect(idx.decide(p).reason, 'index');
  });

  group('1.0.20 Indeep (decode_errors) no queda como procesada', () {
    const Map<String, String> indeep = <String, String>{
      'GMX_NAME_OK': '1',
      'GMX_TYPE': 'SONG',
      'GMX_BACKUP': '1',
      'GMX_LYR': 'NONE',
      'GMX_LYR_CHECK': 'SKIP',
      'GMX_BPM_OK': '1',
      'GMX_REASON': 'decode_errors=200',
      'GMX_V': '2',
    };
    test('record devuelve trim, el índice la deja PENDING y no se salta', () {
      final Directory d = Directory.systemTemp.createTempSync('gmx_indeep');
      try {
        final String p = '${d.path}${Platform.pathSeparator}Indeep.mp3';
        File(p).writeAsBytesSync(_mp3(indeep, seal: false));
        final MasterSkipIndex idx = MasterSkipIndex(d.path);
        expect(idx.record(p), 'trim');
        expect(idx.entries['Indeep.mp3']!['state'], 'PENDING');
        final SkipDecision s = idx.decide(p);
        expect(s.skip, isFalse);
        expect(s.reason, 'index:trim');
        expect(
          checkpointBucket(lyricRetry: false, miss: idx.record(p)),
          'incomplete',
        );
      } finally {
        d.deleteSync(recursive: true);
      }
    });
    test('checkpointBucket', () {
      expect(checkpointBucket(lyricRetry: false, miss: null), 'processed');
      expect(checkpointBucket(lyricRetry: false, miss: 'lufs'), 'incomplete');
      expect(checkpointBucket(lyricRetry: true, miss: null), isNull);
    });
  });
}
