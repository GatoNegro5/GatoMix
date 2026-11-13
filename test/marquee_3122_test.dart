import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/workspaces/livedj_workspace.dart' show NextTrackLine;

/// 3.1.22: Pendiente 22e. El titulo de la pista que sigue no pide cuadros si
/// cabe, en las pausas de 2,5 s ni despues de 3 ciclos.
const TextStyle _style = TextStyle(fontSize: 10, fontFamily: 'Consolas');
final String _long = 'Grupo Niche - Una Aventura (Version Extendida) Remix';
final String _long2 = 'Oscar D Leon - Lloraras (En Vivo Desde Caracas 1985)';

Widget _host(String label, {bool tickers = true}) => Directionality(
      textDirection: TextDirection.ltr,
      child: TickerMode(
        enabled: tickers,
        child: Center(
          child: SizedBox(
            width: 100,
            child: NextTrackLine(label: label, style: _style),
          ),
        ),
      ),
    );

int _ticks() => SchedulerBinding.instance.transientCallbackCount;

double _dx(WidgetTester tester) => tester
    .widget<Transform>(find.descendant(
      of: find.byType(NextTrackLine),
      matching: find.byType(Transform),
    ))
    .transform
    .getTranslation()
    .x;

const Duration _leg = Duration(milliseconds: 14100);
const Duration _pause = Duration(milliseconds: 2600);

/// Recorre los ciclos que faltan, verificando 0 cuadros en cada pausa.
Future<void> _runCycles(WidgetTester tester, int n) async {
  for (int c = 0; c < n; c++) {
    expect(_ticks(), greaterThan(0), reason: 'ida $c');
    await tester.pump(_leg);
    expect(_ticks(), 0, reason: 'pausa al final $c');
    await tester.pump(const Duration(milliseconds: 1200));
    expect(_ticks(), 0, reason: 'pausa al final $c (1,2 s)');
    await tester.pump(_pause);
    expect(_ticks(), greaterThan(0), reason: 'vuelta $c');
    await tester.pump(_leg);
    expect(_ticks(), 0, reason: 'pausa al inicio $c');
    if (c < n - 1) await tester.pump(_pause);
  }
}

void main() {
  test('3.1.22: duracion de pasada igual que antes (4-14 s)', () {
    expect(NextTrackLine.legMs(10), 4000);
    expect(NextTrackLine.legMs(400), 7200);
    expect(NextTrackLine.legMs(5000), 14000);
    expect(NextTrackLine.endPause, const Duration(milliseconds: 2500));
    expect(NextTrackLine.maxCycles, 3);
  });

  testWidgets('3.1.22: si el nombre cabe, 0 cuadros', (tester) async {
    await tester.pumpWidget(_host('Corto'));
    await tester.pump();
    expect(_ticks(), 0);
    await tester.pump(const Duration(seconds: 10));
    expect(_ticks(), 0);
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('3.1.22: ida, pausa, vuelta, pausa; tras 3 ciclos quieto en 0',
      (tester) async {
    await tester.pumpWidget(_host(_long));
    await tester.pump();
    await _runCycles(tester, NextTrackLine.maxCycles);
    expect(_ticks(), 0);
    await tester.pump(const Duration(seconds: 30));
    expect(_ticks(), 0, reason: 'sin cuadros tras 3 ciclos');
    expect(_dx(tester), 0.0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('3.1.22: cambiar el nombre reinicia los ciclos', (tester) async {
    await tester.pumpWidget(_host(_long));
    await tester.pump();
    await _runCycles(tester, NextTrackLine.maxCycles);
    expect(_ticks(), 0);
    await tester.pumpWidget(_host(_long2));
    await tester.pump();
    expect(_ticks(), greaterThan(0), reason: 'nombre nuevo: arranca de nuevo');
    await _runCycles(tester, NextTrackLine.maxCycles);
    await tester.pump(const Duration(seconds: 30));
    expect(_ticks(), 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('3.1.22: TickerMode apagado, 0 cuadros; al volver, sigue',
      (tester) async {
    await tester.pumpWidget(_host(_long, tickers: false));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(_ticks(), 0);
    await tester.pumpWidget(_host(_long));
    await tester.pump();
    expect(_ticks(), greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });
}