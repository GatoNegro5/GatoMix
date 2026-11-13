import 'package:flutter/widgets.dart';

/// 3.1.18: IndexedStack que congela las animaciones de las pestanas ocultas.
///
/// En Flutter 3.47 IndexedStack envuelve cada hijo en Visibility.maintain
/// (maintainAnimation = true), asi que los tickers de las pestanas ocultas
/// seguian pidiendo cuadros a 60 Hz. Aqui solo la pestana visible tiene
/// TickerMode activo; el estado de todas se conserva igual que antes.
class TickerStack extends StatelessWidget {
  const TickerStack({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: index,
      children: <Widget>[
        for (int i = 0; i < children.length; i++)
          TickerMode(enabled: i == index, child: children[i]),
      ],
    );
  }
}
