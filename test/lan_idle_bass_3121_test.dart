import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/services/adaptive_eq.dart';
import 'package:gatomix/ui/widgets/ticker_stack.dart';
import 'package:gatomix/ui/workspaces/lan_sync_workspace.dart'
    show lanPassiveSweepAllowed;

/// 3.1.21: Pendiente 22d (barrido LAN solo visible) y guardia del bass swap.
class _Probe extends StatefulWidget {
  const _Probe(this.log);
  final List<bool> log;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.log.add(TickerMode.valuesOf(context).enabled);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  test('22d: el barrido pasivo solo corre con LAN Sync visible', () {
    bool ok({bool v = true, bool m = false, bool s = true}) =>
        lanPassiveSweepAllowed(
          mounted: true,
          sweeping: true,
          visible: v,
          mobile: m,
          serverUp: s,
        );
    expect(ok(), isTrue);
    expect(ok(v: false), isFalse);
    expect(ok(m: true, s: false), isFalse);
    expect(ok(m: true), isTrue);
    expect(
      lanPassiveSweepAllowed(
        mounted: false,
        sweeping: true,
        visible: true,
        mobile: false,
        serverUp: true,
      ),
      isFalse,
    );
  });

  testWidgets('22d: TickerStack avisa al entrar y salir de la pestana', (
    WidgetTester t,
  ) async {
    final List<bool> lan = <bool>[];
    Widget app(int i) => Directionality(
      textDirection: TextDirection.ltr,
      child: TickerStack(
        index: i,
        children: <Widget>[const SizedBox(), _Probe(lan)],
      ),
    );
    await t.pumpWidget(app(0));
    await t.pumpWidget(app(1));
    await t.pumpWidget(app(0));
    expect(lan, <bool>[false, true, false]);
  });

  test('bass swap: onReady tardio conserva el corte de graves', () {
    final Object deck = Object();
    const String kill =
        'equalizer=f=45:width_type=o:w=2.5:g=-24,equalizer=f=110:width_type=o:w=1.6:g=-14';
    const String base = 'equalizer=f=1000:width_type=o:w=1:g=2';
    AdaptiveEq.holdAf(deck, kill);
    expect(AdaptiveEq.withHold(deck, base), '$base,$kill');
    expect(AdaptiveEq.withHold(deck, ''), kill);
    AdaptiveEq.holdAf(deck, null); // swap hecho
    expect(AdaptiveEq.withHold(deck, base), base);
    AdaptiveEq.holdAf(deck, '');
    expect(AdaptiveEq.afHoldFor(deck), isNull);
  });
}