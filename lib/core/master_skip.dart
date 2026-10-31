import 'dart:convert';
import 'dart:io';

import 'audio_path.dart';
import 'gatomix_store.dart';

/// 1.0.20: salto rápido del Masterizar. Antes de decodificar nada decide si
/// una pista ya está completa con lecturas baratas:
///  1) índice por carpeta `.gatomix_master_index.json` (ruta relativa +
///     tamaño + mtime + mtime del .lrc + estado), escrito al terminar cada
///     pista;
///  2) si no hay entrada válida, solo el bloque ID3v2 (nunca el audio).
/// Si el archivo cambió, la letra está en RETRY o falta algo, se procesa.
const String masterIndexName = '.gatomix_master_index.json';
const String _sealText = 'ReGenial Master';

/// Medidor de BPM, rejilla y duración. Una anterior no recodifica el audio.
const String kGmxAnalysis = '3031';

enum AnalysisPlan { skip, retag, full }

AnalysisPlan planAnalysis(
  Map<String, String> tags, {
  required bool karaoke,
  bool hasKaraokeTwin = false,
}) {
  final String? miss = missingWork(
    tags,
    karaoke: karaoke,
    hasKaraokeTwin: hasKaraokeTwin,
  );
  if (miss == null) return AnalysisPlan.skip;
  if (miss == 'analysis') return AnalysisPlan.retag;
  return AnalysisPlan.full;
}

const Set<String> _lyrOk = <String>{
  'SYNC',
  'PLAIN',
  'MANUAL',
  'APPROX',
  'NA',
  'NONE',
};

int _syncsafe(List<int> b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

List<int> _deunsync(List<int> src) {
  final List<int> out = <int>[];
  for (int i = 0; i < src.length; i++) {
    out.add(src[i]);
    if (src[i] == 0xFF && i + 1 < src.length && src[i + 1] == 0x00) i++;
  }
  return out;
}

List<String> _splitText(int enc, List<int> raw) {
  // Devuelve los textos separados por el terminador según la codificación.
  if (enc == 1 || enc == 2) {
    final List<String> parts = <String>[];
    final List<int> units = <int>[];
    var i = 0;
    var be = enc == 2;
    var expectBom = enc == 1;
    while (i + 1 < raw.length) {
      if (expectBom) {
        if (raw[i] == 0xFE && raw[i + 1] == 0xFF) {
          be = true;
          i += 2;
          expectBom = false;
          continue;
        } else if (raw[i] == 0xFF && raw[i + 1] == 0xFE) {
          be = false;
          i += 2;
          expectBom = false;
          continue;
        }
        expectBom = false;
      }
      final int cu = be
          ? (raw[i] << 8) | raw[i + 1]
          : (raw[i + 1] << 8) | raw[i];
      i += 2;
      if (cu == 0) {
        parts.add(String.fromCharCodes(units));
        units.clear();
        expectBom = enc == 1;
      } else {
        units.add(cu);
      }
    }
    parts.add(String.fromCharCodes(units));
    return parts;
  }
  final List<String> parts = <String>[];
  var start = 0;
  for (int i = 0; i <= raw.length; i++) {
    if (i == raw.length || raw[i] == 0) {
      final List<int> s = raw.sublist(start, i);
      parts.add(
        enc == 3
            ? utf8.decode(s, allowMalformed: true)
            : latin1.decode(s, allowInvalid: true),
      );
      start = i + 1;
    }
  }
  return parts;
}

/// TXXX (descripción → valor) del bloque ID3v2. El sello `COMM` queda en
/// la clave `__SEAL` = '1'. No toca el audio.
Map<String, String> parseGmxTags(List<int> bytes) {
  final Map<String, String> out = <String, String>{};
  if (bytes.length < 10 ||
      bytes[0] != 0x49 ||
      bytes[1] != 0x44 ||
      bytes[2] != 0x33) {
    return out;
  }
  final int ver = bytes[3];
  if (ver < 3 || ver > 4) return out;
  final int flags = bytes[5];
  final int declared = _syncsafe(bytes, 6);
  final int available = bytes.length - 10;
  final int size = declared < available ? declared : available;
  if (size <= 0) return out;
  List<int> body = bytes.sublist(10, 10 + size);
  if ((flags & 0x80) != 0) body = _deunsync(body);
  var pos = 0;
  if ((flags & 0x40) != 0 && body.length >= 4) {
    pos = ver == 4
        ? _syncsafe(body, 0)
        : 4 + ((body[0] << 24) | (body[1] << 16) | (body[2] << 8) | body[3]);
    if (pos < 0 || pos > body.length) return out;
  }
  while (pos + 10 <= body.length) {
    if (body[pos] == 0) break;
    final String id = latin1.decode(
      body.sublist(pos, pos + 4),
      allowInvalid: true,
    );
    if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(id)) break;
    final int frameSize = ver == 4
        ? _syncsafe(body, pos + 4)
        : (body[pos + 4] << 24) |
              (body[pos + 5] << 16) |
              (body[pos + 6] << 8) |
              body[pos + 7];
    final int flagB = body[pos + 9];
    final int dataStart = pos + 10;
    if (frameSize < 0 || dataStart + frameSize > body.length) break;
    if ((id == 'TXXX' || id == 'COMM') && frameSize > 1) {
      final bool compressed = ver == 3
          ? (flagB & 0x80) != 0
          : (flagB & 0x08) != 0;
      final bool encrypted = ver == 3
          ? (flagB & 0x40) != 0
          : (flagB & 0x04) != 0;
      if (!compressed && !encrypted) {
        List<int> data = body.sublist(dataStart, dataStart + frameSize);
        if (ver == 4 && (flagB & 0x02) != 0) data = _deunsync(data);
        final int enc = data[0];
        if (id == 'TXXX') {
          final List<String> p = _splitText(enc, data.sublist(1));
          if (p.length >= 2) out[p[0]] = p[1].trim();
        } else if (data.length > 4) {
          final List<String> p = _splitText(enc, data.sublist(4));
          if (p.length >= 2 && p[1].trim() == _sealText) out['__SEAL'] = '1';
        }
      }
    }
    pos = dataStart + frameSize;
  }
  return out;
}

/// Lee solo la cabecera y el bloque ID3v2 completo (con la carátula), nunca
/// los frames de audio.
Map<String, String> readGmxTagsFromFile(String path) {
  RandomAccessFile? raf;
  try {
    raf = File(path).openSync();
    final List<int> head = raf.readSync(10);
    if (head.length < 10 ||
        head[0] != 0x49 ||
        head[1] != 0x44 ||
        head[2] != 0x33) {
      return <String, String>{};
    }
    final int size = _syncsafe(head, 6);
    final List<int> body = raf.readSync(size);
    return parseGmxTags(<int>[...head, ...body]);
  } catch (_) {
    return <String, String>{};
  } finally {
    raf?.closeSync();
  }
}

/// Reglas de "ya completa" sobre las marcas GMX.
/// - `_K`: solo audio (corte, −14 LUFS, BPM); nunca letra ni sello.
/// - MEGAMIX: audio + sello; la letra no aplica.
/// - Canción: audio + sello + letra resuelta (RETRY o sin marca = pendiente)
///   + revisión de letra hecha; si existe su `_K`, también GMX_K.
String? missingWork(
  Map<String, String> tags, {
  required bool karaoke,
  bool hasKaraokeTwin = false,
}) {
  final int? trim = int.tryParse(tags['GMX_TRIM_MS'] ?? '');
  if (trim == null || trim < 0) return 'trim';
  if (!tags.containsKey('GMX_LUFS_DONE')) return 'lufs';
  if (tags['GMX_BPM_OK'] != '1') return 'bpm';
  if (karaoke) {
    if (tags['GMX_ANALYSIS'] != kGmxAnalysis) return 'analysis';
    return null;
  }
  if (tags['__SEAL'] != '1') return 'seal';
  if (tags['GMX_NAME_OK'] != '1') return 'name';
  if (tags['GMX_BACKUP'] != '1') return 'backup';
  final bool mega = tags['GMX_TYPE'] == 'MEGAMIX';
  if (mega) {
    if (tags['GMX_ANALYSIS'] != kGmxAnalysis) return 'analysis';
    return null;
  }
  final String lyr = tags['GMX_LYR'] ?? '';
  if (lyr == 'RETRY') return 'lyr_retry';
  if (!_lyrOk.contains(lyr)) return 'lyr';
  if (!tags.containsKey('GMX_LYR_CHECK')) return 'lyr_check';
  if (hasKaraokeTwin && tags['GMX_K'] != '1') return 'k';
  if (tags['GMX_ANALYSIS'] != kGmxAnalysis) return 'analysis';
  return null;
}

bool _lrcIsApproxFile(String mp3) {
  final File f = File(_lrcOf(mp3));
  if (!f.existsSync()) return false;
  RandomAccessFile? raf;
  try {
    raf = f.openSync();
    final String head = latin1.decode(raf.readSync(64), allowInvalid: true);
    return head
        .replaceFirst('\uFEFF', '')
        .trimLeft()
        .toLowerCase()
        .startsWith('[gmx_approx');
  } catch (_) {
    return false;
  } finally {
    raf?.closeSync();
  }
}

bool isKaraokePath(String path) => path.toLowerCase().endsWith('_k.mp3');

String _lrcOf(String mp3) =>
    mp3.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '.lrc');

String _twinOf(String mp3) =>
    mp3.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '_K.mp3');

int _mtime(File f) =>
    f.existsSync() ? f.lastModifiedSync().millisecondsSinceEpoch : 0;

class SkipDecision {
  final bool skip;
  final String reason;
  const SkipDecision(this.skip, this.reason);
}

/// Índice por carpeta. Claves = ruta relativa con '/'.
class MasterSkipIndex {
  final String root;
  final Map<String, Map<String, dynamic>> entries;

  MasterSkipIndex(this.root, [Map<String, Map<String, dynamic>>? e])
    : entries = e ?? <String, Map<String, dynamic>>{};

  File get file => GatomixStore.fileOf(root);

  static MasterSkipIndex load(String root) {
    final MasterSkipIndex idx = MasterSkipIndex(root);
    try {
      final dynamic d = GatomixStore.section(root, 'masterIndex');
      if (d is Map &&
          (d['schema'] == 1 || d['schema'] == 2) &&
          d['entries'] is Map) {
        (d['entries'] as Map).forEach((k, v) {
          if (v is Map) {
            final String nk = audioPathKey(
              '$k'.replaceAll('\\', '/'),
              absolute: false,
            );
            idx.entries[nk] = Map<String, dynamic>.from(v);
          }
        });
      }
    } catch (_) {}
    return idx;
  }

  void save() {
    try {
      GatomixStore.putSection(root, 'masterIndex', <String, dynamic>{
        'schema': 2,
        'entries': entries,
      });
    } catch (_) {}
  }

  String key(String path) {
    String p = path.replaceAll('\\', '/');
    final String r = root.replaceAll('\\', '/');
    if (p.toLowerCase().startsWith('${r.toLowerCase()}/')) {
      p = p.substring(r.length + 1);
    }
    return audioPathKey(p, absolute: false);
  }

  Map<String, dynamic> _stat(String path) {
    final File f = File(path);
    return <String, dynamic>{
      'size': f.lengthSync(),
      'mtime': _mtime(f),
      'lrc': _mtime(File(_lrcOf(path))),
      'twin': isKaraokePath(path) ? false : File(_twinOf(path)).existsSync(),
    };
  }

  /// Guarda el estado al terminar una pista (re-lee solo el tag). Devuelve
  /// lo que falta (null = completa; 'missing' si el archivo no está).
  String? record(String path) {
    if (!File(path).existsSync()) return 'missing';
    final Map<String, dynamic> s = _stat(path);
    final Map<String, String> tags = readGmxTagsFromFile(path);
    final String? miss = missingWork(
      tags,
      karaoke: isKaraokePath(path),
      hasKaraokeTwin: s['twin'] == true,
    );
    s['state'] = miss == null ? 'OK' : 'PENDING';
    s['analysis'] = tags['GMX_ANALYSIS'] ?? '';
    if (miss != null) s['miss'] = miss;
    entries[key(path)] = s;
    return miss;
  }

  SkipDecision decide(String path) {
    final File f = File(path);
    if (!f.existsSync()) return const SkipDecision(false, 'missing');
    final Map<String, dynamic> s = _stat(path);
    final Map<String, dynamic>? e = entries[key(path)];
    if (e != null &&
        e['size'] == s['size'] &&
        e['mtime'] == s['mtime'] &&
        e['lrc'] == s['lrc'] &&
        e['twin'] == s['twin']) {
      if (e['state'] == 'OK' && e['analysis'] == kGmxAnalysis) {
        return const SkipDecision(true, 'index');
      }
      if (e['state'] == 'OK') {
        return const SkipDecision(false, 'analysis');
      }
      return SkipDecision(false, 'index:${e['miss'] ?? e['state']}');
    }
    // Sin entrada (o cambió): respaldo por el tag ID3. Si el archivo cambió
    // respecto al índice, se procesa aunque el tag diga completo.
    if (e != null && (e['size'] != s['size'] || e['mtime'] != s['mtime'])) {
      return const SkipDecision(false, 'changed');
    }
    if (e != null && e['lrc'] != s['lrc'] && !_lrcIsApproxFile(path)) {
      return const SkipDecision(false, 'lrc_changed');
    }
    // 1.0.20+39: un .lrc APPROX que apareció después del índice no fuerza
    // reproceso; manda el tag (si está completo, se salta y se actualiza).
    final Map<String, String> tags = readGmxTagsFromFile(path);
    final String? miss = missingWork(
      tags,
      karaoke: isKaraokePath(path),
      hasKaraokeTwin: s['twin'] == true,
    );
    if (miss != null) return SkipDecision(false, miss);
    s['state'] = 'OK';
    s['analysis'] = tags['GMX_ANALYSIS'] ?? '';
    entries[key(path)] = s;
    return const SkipDecision(true, 'tags');
  }
}

/// 1.0.20: a qué lista del checkpoint va una pista tras MasterTrack.run.
/// Solo 'processed' si las marcas quedaron completas; si falta algo
/// (Indeep: decode_errors=200, audio intacto sin TRIM/LUFS) va a
/// 'incomplete' y la próxima corrida la vuelve a intentar. RETRY = ninguna.
String? checkpointBucket({required bool lyricRetry, required String? miss}) {
  if (lyricRetry) return null;
  return miss == null ? 'processed' : 'incomplete';
}
