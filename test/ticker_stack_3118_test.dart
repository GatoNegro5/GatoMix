import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/widgets/ticker_stack.dart';

// 3.1.18: las animaciones de pestanas ocultas quedan congeladas y el estado
// de cada pestana se conserva al cambiar de indice.
class _Spinner extends StatefulWidget {
  const _Spinner({super.key});
  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
  )..repeat();
  int frames = 0;

  @override
  void initState() {
    super.initState();
    c.addListener(() => frames++);
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  testWidgets('TickerStack congela la pestana oculta y conserva estado',
      (WidgetTester tester) async {
    final GlobalKey<_SpinnerState> a = GlobalKey<_SpinnerState>();
    final GlobalKey<_SpinnerState> b = GlobalKey<_SpinnerState>();
    Widget app(int i) => Directionality(
          textDirection: TextDirection.ltr,
          child: TickerStack(
            index: i,
            children: <Widget>[_Spinner(key: a), _Spinner(key: b)],
          ),
        );

    await tester.pumpWidget(app(0));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(a.currentState!.frames, greaterThan(0));
    expect(b.currentState!.frames, 0);

    final _SpinnerState stateA = a.currentState!;
    await tester.pumpWidget(app(1));
    final int framesA = stateA.frames;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(b.currentState!.frames, greaterThan(0));
    expect(a.currentState!.frames, framesA);
    expect(identical(a.currentState, stateA), isTrue);
  });
}
