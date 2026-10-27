import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/song_watchdog.dart';

void main() {
  final DateTime t0 = DateTime(2026, 10, 25, 11);
  test('no stall before the limit', () {
    expect(headlessStalled(t0, t0.add(const Duration(minutes: 29))), isFalse);
  });
  test('stall at the limit', () {
    expect(headlessStalled(t0, t0.add(const Duration(minutes: 30))), isTrue);
  });
  test('custom limit', () {
    expect(
      headlessStalled(
        t0,
        t0.add(const Duration(seconds: 5)),
        limit: const Duration(seconds: 5),
      ),
      isTrue,
    );
  });
}
