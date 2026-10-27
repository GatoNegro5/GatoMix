// Ícono tomate de "letra aproximada" (1.0.20+38). Se detecta leyendo el
// `.lrc` ([gmx_approx]) para que funcione igual en el celular tras copiar.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/lyric_approx.dart';
import '../../core/lyric_files.dart';
import '../../src/rust/api/core_dsp.dart' as rust_dsp;

const Color kApproxTomato = Color(0xFFFF6347);

final Map<String, (int, bool)> _cache = {};

/// Revisión global: sube cuando se confirma una letra.
final ValueNotifier<int> approxLyricRevision = ValueNotifier<int>(0);

bool isApproxLyric(String audioPath) {
  try {
    final File f = File(approxLrcPath(audioPath));
    if (!f.existsSync()) return false;
    final int m = f.lastModifiedSync().millisecondsSinceEpoch;
    final (int, bool)? c = _cache[f.path];
    if (c != null && c.$1 == m) return c.$2;
    final RandomAccessFile r = f.openSync();
    final String head;
    try {
      head = String.fromCharCodes(r.readSync(64));
    } finally {
      r.closeSync();
    }
    final bool a = lrcIsApprox(head.replaceFirst('\uFEFF', ''));
    _cache[f.path] = (m, a);
    return a;
  } catch (_) {
    return false;
  }
}

/// "Sí, la letra está OK": quita la marca, GMX_LYR=MANUAL en la canción
/// normal (nunca en el `_K`). El cambio de mtime actualiza el índice.
Future<bool> confirmApproxLyric(String audioPath) async {
  final File f = File(approxLrcPath(audioPath));
  if (!f.existsSync()) return false;
  final String txt = await f.readAsString();
  if (!lrcIsApprox(txt)) return true;
  await f.writeAsString(stripApproxMark(txt));
  _cache.remove(f.path);
  final String owner = approxOwnerAudio(audioPath);
  try {
    await rust_dsp.setGmxMark(
      inputPath: owner,
      key: 'GMX_LYR',
      value: 'MANUAL',
    );
  } catch (_) {}
  notifyLrcChanged(owner);
  approxLyricRevision.value++;
  return true;
}

class ApproxLyricIcon extends StatelessWidget {
  final String path;
  final double size;
  const ApproxLyricIcon({super.key, required this.path, this.size = 18});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: approxLyricRevision,
      builder: (context, _, _) {
        if (!isApproxLyric(path)) return const SizedBox.shrink();
        return IconButton(
          icon: Icon(Icons.lyrics, color: kApproxTomato, size: size),
          tooltip: 'Letra aproximada – ajustar',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () => askConfirmApprox(context, path),
        );
      },
    );
  }
}

Future<void> askConfirmApprox(BuildContext context, String path) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('¿La letra está OK?'),
      content: const Text(
        'Es una letra aproximada. Si ya la revisaste, se marcará como confirmada y el ícono desaparece.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kApproxTomato),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Sí'),
        ),
      ],
    ),
  );
  if (ok == true) await confirmApproxLyric(path);
}
