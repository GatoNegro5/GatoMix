import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lyric_match.dart';
import 'package:gatomix/services/lyric_retry_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lyric_retry');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  LyricRetryQueue queue({
    required Future<LyricFetchOutcome> Function(String path) fetch,
    void Function(String name)? onFound,
    bool Function(String path)? exists,
  }) {
    return LyricRetryQueue(
      storeFile: File('${dir.path}/lyric_retry_queue.json'),
      fetch: fetch,
      onFound: onFound,
      exists: exists,
      clock: () => DateTime.utc(2026, 11, 3, 23, 0),
    );
  }

  test('la cola persiste mp3, recorte y fecha', () async {
    final LyricRetryQueue first = queue(fetch: (_) async => LyricFetchOutcome.serverDown);
    await first.enqueue(mp3Path: '${dir.path}/Tema.mp3', trimmedMs: 1500);
    await first.enqueue(mp3Path: '${dir.path}/Otra.mp3', trimmedMs: 40);

    final LyricRetryQueue second = queue(
      fetch: (_) async => LyricFetchOutcome.serverDown,
    );
    await second.load();
    expect(second.entries, hasLength(2));
    expect(second.entries.first.mp3Path, endsWith('Tema.mp3'));
    expect(second.entries.first.trimmedMs, 1500);
    expect(second.entries.first.addedAt, DateTime.utc(2026, 11, 3, 23, 0));
    expect(second.entries.last.trimmedMs, 40);
  });

  test('found desplaza el lrc y lo quita; notFound y serverDown', () async {
    final String mp3 = '${dir.path}/Tema.mp3';
    final String missing = '${dir.path}/Borrada.mp3';
    final String down = '${dir.path}/Ocupada.mp3';
    final String none = '${dir.path}/SinLetra.mp3';
    File(mp3).writeAsBytesSync(<int>[1]);
    File(down).writeAsBytesSync(<int>[1]);
    File(none).writeAsBytesSync(<int>[1]);
    File(missing).writeAsBytesSync(<int>[1]);

    final List<String> fetched = <String>[];
    final List<String> notices = <String>[];
    final LyricRetryQueue box = queue(
      onFound: notices.add,
      fetch: (String path) async {
        fetched.add(path);
        if (path.endsWith('Ocupada.mp3')) return LyricFetchOutcome.serverDown;
        if (path.endsWith('SinLetra.mp3')) return LyricFetchOutcome.notFound;
        await File(
          path.replaceAll('.mp3', '.lrc'),
        ).writeAsString('[00:01.50]hola\n');
        return LyricFetchOutcome.found;
      },
    );
    await box.enqueue(mp3Path: mp3, trimmedMs: 1500);
    await box.enqueue(mp3Path: none, trimmedMs: 0);
    await box.enqueue(mp3Path: down, trimmedMs: 800);
    await box.enqueue(mp3Path: missing, trimmedMs: 200);
    File(missing).deleteSync();

    await box.tick();

    expect(fetched, isNot(contains(missing)));
    expect(box.entries.map((LyricRetryEntry e) => e.mp3Path), [down]);
    expect(notices, <String>['Tema.mp3']);
    expect(File('${dir.path}/Tema.lrc').readAsStringSync(), '[00:00.00]hola');
    expect(File('${dir.path}/SinLetra.lrc').existsSync(), isFalse);

    final LyricRetryQueue again = queue(
      fetch: (_) async => LyricFetchOutcome.serverDown,
    );
    await again.load();
    expect(again.entries, hasLength(1));
    expect(again.entries.single.mp3Path, down);
    expect(again.entries.single.trimmedMs, 800);
  });

  test('un tick en curso no se pisa con otro', () async {
    final String mp3 = '${dir.path}/Tema.mp3';
    File(mp3).writeAsBytesSync(<int>[1]);
    final Completer<void> gate = Completer<void>();
    var calls = 0;
    final LyricRetryQueue box = queue(
      fetch: (_) async {
        calls++;
        await gate.future;
        return LyricFetchOutcome.serverDown;
      },
    );
    await box.enqueue(mp3Path: mp3, trimmedMs: 0);
    final Future<void> first = box.tick();
    await box.tick();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls, 1);
    expect(box.isTicking, isTrue);
    gate.complete();
    await first;
    expect(box.isTicking, isFalse);
    expect(box.entries, hasLength(1));
  });
}
