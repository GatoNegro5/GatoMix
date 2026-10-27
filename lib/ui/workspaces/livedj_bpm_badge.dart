import 'dart:io';

import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/services/track_tags.dart';
import 'package:flutter/material.dart';

/// BPM para el Cartridge de Live DJ. Código propio: no comparte caché con
/// Automix (`bpmCacheProvider`).
///
/// Orden de búsqueda por canción:
///  1. `_dj_metadata.json` en la carpeta de la pista o en sus carpetas padre
///     (Masterizar lo guarda en la carpeta raíz escaneada, con clave = ruta
///     absoluta; se acepta también clave = nombre de archivo).
///  2. Etiqueta ID3 `TBPM` dentro del propio MP3.
///  3. Nombre del archivo (`... 128 BPM ...`).

class _BpmIndex {
  final Map<String, double> byPath = {};
  final Map<String, double> byName = {};
}

final Map<String, Future<_BpmIndex?>> _indexCache = {};
final Map<String, Future<double>> _bpmCache = {};

String _normPath(String p) => p.replaceAll('\\', '/').toLowerCase();

String _baseName(String p) {
  final n = p.replaceAll('\\', '/');
  final i = n.lastIndexOf('/');
  return i >= 0 ? n.substring(i + 1) : n;
}

Future<_BpmIndex?> _loadIndex(String dir) {
  return _indexCache.putIfAbsent(dir, () async {
    try {
      final Map<String, dynamic> decoded = readDjMetadata(dir);
      if (decoded.isEmpty) return null;
      final idx = _BpmIndex();
      decoded.forEach((key, value) {
        double? bpm;
        if (value is num) {
          bpm = value.toDouble();
        } else if (value is Map && value['bpm'] is num) {
          bpm = (value['bpm'] as num).toDouble();
        }
        if (bpm == null) return;
        final double musical = TrackTags.musicalBpm(bpm);
        if (musical <= 0) return;
        final k = key.toString();
        idx.byPath[_normPath(k)] = musical;
        idx.byName[_baseName(k).toLowerCase()] = musical;
      });
      return idx;
    } catch (_) {
      return null;
    }
  });
}

int _syncsafe(List<int> b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

double _parseBpmText(List<int> bytes) {
  final String text = String.fromCharCodes(
    bytes.where((b) => b == 0x2C || b == 0x2E || (b >= 0x30 && b <= 0x39)),
  );
  final match = RegExp(r'(\d{1,6}(?:[.,]\d+)?)').firstMatch(text);
  if (match == null) return 0.0;
  final double raw =
      double.tryParse(match.group(1)!.replaceAll(',', '.')) ?? 0.0;
  return TrackTags.musicalBpm(raw);
}

/// Lee la etiqueta ID3v2 `TBPM` saltando frames grandes (carátulas).
Future<double> _id3Bpm(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    final head = await raf.read(10);
    if (head.length < 10 ||
        head[0] != 0x49 ||
        head[1] != 0x44 ||
        head[2] != 0x33) {
      return 0.0;
    }
    final ver = head[3];
    if (ver < 2 || ver > 4) return 0.0;
    final tagEnd = 10 + _syncsafe(head, 6);
    var pos = 10;

    if (ver >= 3 && (head[5] & 0x40) != 0) {
      await raf.setPosition(pos);
      final ext = await raf.read(4);
      if (ext.length < 4) return 0.0;
      pos += ver == 4
          ? _syncsafe(ext, 0)
          : 4 + ((ext[0] << 24) | (ext[1] << 16) | (ext[2] << 8) | ext[3]);
    }

    final hdrLen = ver == 2 ? 6 : 10;
    while (pos + hdrLen <= tagEnd) {
      await raf.setPosition(pos);
      final h = await raf.read(hdrLen);
      if (h.length < hdrLen || h[0] == 0) break;
      final id = String.fromCharCodes(h.sublist(0, ver == 2 ? 3 : 4));
      final int size = ver == 2
          ? ((h[3] << 16) | (h[4] << 8) | h[5])
          : (ver == 4
                ? _syncsafe(h, 4)
                : ((h[4] << 24) | (h[5] << 16) | (h[6] << 8) | h[7]));
      if (size <= 0 || pos + hdrLen + size > tagEnd) break;
      if (id == 'TBPM' || id == 'TBP') {
        final body = await raf.read(size);
        if (body.length > 1) return _parseBpmText(body.sublist(1));
        return 0.0;
      }
      pos += hdrLen + size;
    }
  } catch (_) {
    // sin etiqueta legible
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
  return 0.0;
}

Future<double> _resolveBpm(String path) async {
  final normFull = _normPath(path);
  final name = _baseName(path).toLowerCase();

  // 1) _dj_metadata.json en la carpeta de la pista o en sus padres.
  var dir = File(path).parent;
  for (var depth = 0; depth < 6; depth++) {
    final idx = await _loadIndex(dir.path);
    if (idx != null) {
      final hit = idx.byPath[normFull] ?? idx.byName[name];
      if (hit != null && hit > 0) return hit;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  // 2) Etiqueta ID3 TBPM.
  final tag = await _id3Bpm(path);
  if (tag > 0) return tag;

  // 3) Nombre del archivo.
  final match = RegExp(
    r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
    caseSensitive: false,
  ).firstMatch(_baseName(path));
  if (match == null) return 0.0;
  return TrackTags.musicalBpm(double.parse(match.group(1)!));
}

Future<double> _liveDjBpmFor(String path) {
  return _bpmCache.putIfAbsent(path, () {
    final fut = _resolveBpm(path);
    // Un "sin dato" no se recuerda para siempre: Masterizar puede generar
    // el BPM después y debe aparecer sin reiniciar la app.
    fut.then((v) {
      if (v <= 0) {
        Future.delayed(const Duration(seconds: 45), () {
          _bpmCache.remove(path);
          _indexCache.clear();
        });
      }
    });
    return fut;
  });
}

/// Info de la canción (BPM) a la derecha del título en NOW PLAYING.
class LiveDjBpmChip extends StatelessWidget {
  final String? path;
  final double fontSize;
  const LiveDjBpmChip({super.key, required this.path, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    final p = path;
    if (p == null) return const SizedBox.shrink();
    return FutureBuilder<double>(
      future: _liveDjBpmFor(p),
      builder: (context, snap) {
        final bpm = snap.data ?? 0.0;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            bpm > 0 ? '${bpm.round()} BPM' : '– BPM',
            maxLines: 1,
            style: TextStyle(
              color: bpm > 0 ? Colors.white : Colors.white38,
              fontWeight: FontWeight.bold,
              fontSize: fontSize,
            ),
          ),
        );
      },
    );
  }
}

/// BPM de la canción, mostrado a la izquierda de cada fila del Cartridge.
class LiveDjBpmBadge extends StatelessWidget {
  final String path;
  const LiveDjBpmBadge({super.key, required this.path});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      child: FutureBuilder<double>(
        future: _liveDjBpmFor(path),
        builder: (context, snap) {
          final bpm = snap.data ?? 0.0;
          return Text(
            bpm > 0 ? bpm.round().toString() : '–',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: bpm > 0 ? Colors.white : Colors.white24,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          );
        },
      ),
    );
  }
}
