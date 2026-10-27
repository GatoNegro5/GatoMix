import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/lrc_timeline.dart';

void main() {
  const String sample = '[00:10.00]Hola\n[01:02.50]Mundo\n';

  test('resta los ms exactos y anota la marca', () {
    final LrcShift shifted = shiftLrcText(sample, 2500);
    expect(shifted.changed, isTrue);
    expect(shifted.text.startsWith('[gmx_shift:2500]'), isTrue);
    expect(shifted.text.contains('[00:07.50]Hola'), isTrue);
    expect(shifted.text.contains('[01:00.00]Mundo'), isTrue);
    expect(lrcShiftMs(shifted.text), 2500);
  });

  test('un sello que quedaría negativo se clava en cero', () {
    final LrcShift shifted = shiftLrcText('[00:01.00]A\n', 5000);
    expect(shifted.text.contains('[00:00.00]A'), isTrue);
  });

  test('una letra manual no se mueve', () {
    const String manual = '[gmx_manual:1]\n[00:10.00]Hola\n';
    final LrcShift shifted = shiftLrcText(manual, 2500);
    expect(shifted.skippedManual, isTrue);
    expect(shifted.changed, isFalse);
    expect(shifted.text, manual);
  });

  test('un segundo desplazamiento no hace nada', () {
    final LrcShift once = shiftLrcText(sample, 1000);
    final LrcShift twice = shiftLrcText(once.text, 1000);
    expect(twice.alreadyShifted, isTrue);
    expect(twice.changed, isFalse);
    expect(twice.text, once.text);
  });

  test('restaurar devuelve los sellos', () {
    final LrcShift shifted = shiftLrcText(sample, 2500);
    final String back = unshiftLrcText(shifted.text, 2500);
    expect(back.contains('[gmx_shift:'), isFalse);
    expect(back.contains('[00:10.00]Hola'), isTrue);
    expect(back.contains('[01:02.50]Mundo'), isTrue);
  });

  test('el primer verso ignora las marcas', () {
    const String text = '[gmx_shift:1500]\n[00:01.50]\n[00:12.00]Empieza\n';
    expect(firstVerseMs(text), 12000);
  });

  test('un retardo sin corte atrasa los sellos y anota el neto negativo', () {
    final LrcShift shifted = shiftLrcText(sample, 0, extraDelayMs: 80);
    expect(shifted.changed, isTrue);
    expect(lrcShiftMs(shifted.text), -80);
    expect(shifted.text.contains('[00:10.08]Hola'), isTrue);
    expect(shifted.text.contains('[01:02.58]Mundo'), isTrue);
    final String back = unshiftLrcText(shifted.text, 0);
    expect(back.contains('[gmx_shift:'), isFalse);
    expect(back.contains('[00:10.00]Hola'), isTrue);
    expect(back.contains('[01:02.50]Mundo'), isTrue);
  });

  test('corte y retardo se restan: la marca guarda el neto', () {
    final LrcShift shifted = shiftLrcText(sample, 2500, extraDelayMs: 80);
    expect(lrcShiftMs(shifted.text), 2420);
    expect(shifted.text.contains('[00:07.58]Hola'), isTrue);
  });

  test(
    'una letra manual no se mueve aunque haya retardo y el corte sea cero',
    () {
      const String manual = '[gmx_manual:1]\n[00:10.00]Hola\n';
      final LrcShift shifted = shiftLrcText(manual, 0, extraDelayMs: 80);
      expect(shifted.skippedManual, isTrue);
      expect(shifted.changed, isFalse);
      expect(shifted.text, manual);
      expect(lrcIsProtected(manual), isTrue);
      expect(lrcIsProtected('[gmx_shift:-80]\n[00:10.08]Hola\n'), isTrue);
      expect(lrcIsProtected(sample), isFalse);
    },
  );

  test('Take On Me: 1010 ms sin corte medido no mueve la letra', () {
    expect(
      measuredLyricShiftMs(audioCut: false, trimHeadMs: 1010, residualMs: 0),
      isNull,
    );
    expect(
      measuredLyricShiftMs(audioCut: true, trimHeadMs: 0, residualMs: 1010),
      isNull,
    );
    expect(
      measuredLyricShiftMs(audioCut: true, trimHeadMs: 1010, residualMs: 1010),
      isNull,
    );
    expect(
      measuredLyricShiftMs(audioCut: true, trimHeadMs: 1010, residualMs: 0),
      1010,
    );
  });
}
