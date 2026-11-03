import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/livedj_next.dart';

void main() {
  const String now = '/m/now.mp3';
  const String next = '/m/next.mp3';

  test('deck cambió durante el await: el armado no vale', () {
    expect(
      armStillValid(
        tickPath: now,
        currentPath: now,
        armPath: next,
        isCrossfading: false,
        sameActive: true,
        sameDeck: false,
      ),
      isFalse,
    );
  });

  test('la entrante es la que ya suena: el armado no vale', () {
    expect(
      armStillValid(
        tickPath: now,
        currentPath: now,
        armPath: now,
        isCrossfading: false,
        sameActive: true,
        sameDeck: true,
      ),
      isFalse,
    );
  });

  test('cruce en curso: el armado no vale', () {
    expect(
      armStillValid(
        tickPath: now,
        currentPath: now,
        armPath: next,
        isCrossfading: true,
        sameActive: true,
        sameDeck: true,
      ),
      isFalse,
    );
  });

  test('mismo deck, misma pista y sin cruce: el armado vale', () {
    expect(
      armStillValid(
        tickPath: now,
        currentPath: now,
        armPath: next,
        isCrossfading: false,
        sameActive: true,
        sameDeck: true,
      ),
      isTrue,
    );
  });
}
