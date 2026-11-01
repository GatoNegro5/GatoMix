import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/livedj_next.dart';
import 'package:gatomix/core/audio_path.dart';

void main() {
  const String playing = '/Music/Ahora.mp3';
  const String previous = '/Music/Anterior.mp3';
  const String next = '/Music/Siguiente.mp3';

  test('pending null o vacío no se usa', () {
    expect(radioPendingUsable(null, playing: playing, previous: previous), isFalse);
    expect(radioPendingUsable('', playing: playing, previous: previous), isFalse);
  });

  test('pending igual a la que suena no se usa', () {
    expect(
      radioPendingUsable(playing, playing: playing, previous: previous),
      isFalse,
    );
    expect(
      radioPendingUsable(r'\Music\Ahora.mp3', playing: playing),
      isFalse,
    );
  });

  test('pending igual a la anterior no se usa (separadores y mayúsculas)', () {
    expect(
      radioPendingUsable(r'\Music\Anterior.mp3', previous: previous),
      isFalse,
    );
    const String cased = '/music/anterior.mp3';
    expect(sameAudioPath(previous, cased), audioPathFoldsCase());
    expect(
      radioPendingUsable(cased, previous: previous),
      !sameAudioPath(previous, cased),
    );
    expect(
      radioPendingUsable(previous, playing: playing, previous: previous),
      isFalse,
    );
  });

  test('pending distinto de la que suena y de la anterior sí se usa', () {
    expect(
      radioPendingUsable(next, playing: playing, previous: previous),
      isTrue,
    );
    expect(radioPendingUsable(next), isTrue);
  });

  test('10 ciclos: un pending tardío no repite A→B→A ni A→A', () {
    const List<String> pool = <String>[
      'A',
      'B',
      'C',
      'D',
      'E',
      'F',
      'G',
      'H',
      'I',
      'J',
    ];
    String? pending;
    String? onAir;
    String? prev;
    var cursor = 0;
    final List<String> played = <String>[];

    String? choose() {
      if (!radioPendingUsable(pending, playing: onAir, previous: prev)) {
        pending = null;
      }
      if (pending != null) return pending;
      while (cursor < pool.length) {
        final String p = pool[cursor++];
        if (radioPendingUsable(p, playing: onAir, previous: prev)) {
          pending = p;
          return p;
        }
      }
      return null;
    }

    void consume(String path) {
      prev = onAir;
      onAir = path;
      pending = null;
    }

    // Tarea async que llega después del consumo y escribe la pista vieja.
    void lateWriteOld() {
      final String? stale = prev;
      if (stale == null) return;
      if (radioPendingUsable(stale, playing: onAir, previous: prev)) {
        pending = stale;
      }
    }

    for (var i = 0; i < 10; i++) {
      final String? picked = choose();
      expect(picked, isNotNull);
      if (onAir != null) {
        expect(picked, isNot(onAir));
        expect(picked, isNot(prev));
      }
      consume(picked!);
      played.add(picked);
      lateWriteOld();
    }

    expect(played, pool);
    for (var i = 0; i < played.length - 1; i++) {
      expect(played[i + 1], isNot(played[i]), reason: 'A→A en $played');
    }
    for (var i = 0; i < played.length - 2; i++) {
      expect(played[i + 2], isNot(played[i]), reason: 'A→B→A en $played');
    }
  });
}
