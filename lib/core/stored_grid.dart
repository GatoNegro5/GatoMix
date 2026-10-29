import 'package:gatomix/src/rust/api/core_dsp.dart' show BeatGrid;

import 'master_skip.dart';

class GridSeg {
  final double startMs;
  final double anchorMs;
  final double periodMs;
  const GridSeg(this.startMs, this.anchorMs, this.periodMs);
}

/// `ancla;periodo` o `ancla;periodo|inicio,ancla,periodo;...`
class StoredGrid {
  final double anchorMs;
  final double periodMs;
  final List<GridSeg> segments;

  const StoredGrid(this.anchorMs, this.periodMs, this.segments);

  static StoredGrid? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final List<String> parts = raw.split('|');
    final List<String> head = parts.first.split(';');
    if (head.length < 2) return null;
    final double anchor = double.tryParse(head[0]) ?? double.nan;
    final double period = double.tryParse(head[1]) ?? double.nan;
    if (anchor.isNaN || period <= 0) return null;
    final List<GridSeg> segs = <GridSeg>[];
    if (parts.length > 1) {
      for (final String piece in parts[1].split(';')) {
        final List<String> f = piece.split(',');
        if (f.length < 3) continue;
        final double start = double.tryParse(f[0]) ?? double.nan;
        final double a = double.tryParse(f[1]) ?? double.nan;
        final double p = double.tryParse(f[2]) ?? double.nan;
        if (start.isNaN || a.isNaN || p <= 0) continue;
        segs.add(GridSeg(start, a, p));
      }
    }
    return StoredGrid(anchor, period, segs);
  }

  /// Golpe en o después de [fromMs], y el BPM de ese tramo.
  ({double beatMs, double bpm})? at(int fromMs) {
    double anchor = anchorMs;
    double period = periodMs;
    for (final GridSeg s in segments) {
      if (s.startMs <= fromMs) {
        anchor = s.anchorMs;
        period = s.periodMs;
      }
    }
    if (period <= 0) return null;
    final double k = ((fromMs - anchor) / period).ceilToDouble();
    return (beatMs: anchor + k * period, bpm: 60000.0 / period);
  }
}

final Map<String, StoredGrid?> _gridMem = <String, StoredGrid?>{};

BeatGrid? beatFromTag(String path, int fromMs) {
  if (path.isEmpty) return null;
  final StoredGrid? grid = _gridMem.putIfAbsent(
    path,
    () => StoredGrid.parse(readGmxTagsFromFile(path)['GMX_GRID']),
  );
  if (grid == null) return null;
  final hit = grid.at(fromMs);
  if (hit == null) return null;
  return BeatGrid(ok: true, bpm: hit.bpm, beatMs: hit.beatMs);
}

void forgetStoredGrid(String path) => _gridMem.remove(path);
