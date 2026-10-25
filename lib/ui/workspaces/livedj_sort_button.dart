import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/livedj_order.dart';
import '../../providers/livedj_provider.dart';

/// Orden de la cola en Secuencial: A-Z, BPM ↑, BPM ↓ o como se cargó.
/// En Shuffle se ve apagado (manda el armado por grupos).
class LiveDjSortButton extends ConsumerWidget {
  const LiveDjSortButton({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(liveDjProvider.select((s) => s.sortMode));
    final shuffle = ref.watch(
      liveDjProvider.select((s) => s.mixStrategy == LiveDjMixStrategy.random),
    );
    final Color accent = Theme.of(context).colorScheme.secondary;
    final Color tint = shuffle
        ? Colors.white24
        : (mode == LiveDjSortMode.manual ? Colors.white70 : accent);
    return PopupMenuButton<LiveDjSortMode>(
      tooltip: shuffle
          ? 'Orden (solo Secuencial)'
          : 'Orden: ${kLiveDjSortLabels[mode]}',
      initialValue: mode,
      padding: EdgeInsets.zero,
      icon: Icon(Icons.sort, size: size, color: tint),
      onSelected: (m) => ref.read(liveDjProvider.notifier).setSortMode(m),
      itemBuilder: (context) => [
        for (final m in LiveDjSortMode.values)
          CheckedPopupMenuItem<LiveDjSortMode>(
            value: m,
            checked: m == mode,
            child: Text(kLiveDjSortLabels[m]!),
          ),
      ],
    );
  }
}
