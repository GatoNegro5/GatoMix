/// Lectura de las marcas GMX (ya parseadas) para la auditoría por pista.
/// No toca disco: los tests y las 4 plataformas comparten estas reglas.
enum AuditCell { ok, bad, na }

String auditGlyph(AuditCell cell) {
  switch (cell) {
    case AuditCell.ok:
      return '✅';
    case AuditCell.bad:
      return '❌';
    case AuditCell.na:
      return '—';
  }
}

class GmxSnapshot {
  final String type;
  final bool nameOk;
  final String lyr;
  final bool trimMarked;
  final bool lrcShiftTag;
  final bool bpmOk;
  final bool lufsDone;
  final bool backup;
  final bool sealed;
  final bool lrcExists;
  final bool lrcManual;
  final bool lrcShiftFile;
  final bool hasManualCue;
  final bool karaokeFile;

  /// En el teléfono el `_K` no aplica.
  final bool allowKaraoke;
  final bool megamixBySize;

  /// `decode_errors=N` cuando el audio no se recodificó.
  final String reason;

  const GmxSnapshot({
    this.type = '',
    this.nameOk = false,
    this.lyr = '',
    this.trimMarked = false,
    this.lrcShiftTag = false,
    this.bpmOk = false,
    this.lufsDone = false,
    this.backup = false,
    this.sealed = false,
    this.lrcExists = false,
    this.lrcManual = false,
    this.lrcShiftFile = false,
    this.hasManualCue = false,
    this.karaokeFile = false,
    this.allowKaraoke = false,
    this.megamixBySize = false,
    this.reason = '',
  });

  bool get isMegamix =>
      type.toUpperCase() == 'MEGAMIX' ||
      megamixBySize ||
      lyr.toUpperCase() == 'NA';
}

class SongAudit {
  final String path;
  final String fileName;
  final bool megamix;
  final AuditCell name;
  final AuditCell lyrics;
  final AuditCell trim;
  final AuditCell shift;
  final AuditCell bpm;
  final AuditCell lufs;
  final AuditCell cues;
  final AuditCell karaoke;
  final AuditCell backup;
  final bool sealed;

  /// Letra ya cortada y `.lrc` sin marca: no se toca, va al Laboratorio.
  final bool lyricsNeedLab;

  /// Motivo de audio intacto, p. ej. `decode_errors=3`.
  final String reason;

  const SongAudit({
    required this.path,
    required this.fileName,
    required this.megamix,
    required this.name,
    required this.lyrics,
    required this.trim,
    required this.shift,
    required this.bpm,
    required this.lufs,
    required this.cues,
    required this.karaoke,
    required this.backup,
    required this.sealed,
    required this.lyricsNeedLab,
    required this.reason,
  });

  bool get audioRaw => !sealed && !lufsDoneLike && trim == AuditCell.bad;

  bool get lufsDoneLike => lufs == AuditCell.ok;

  /// Pasos que "Completar lo que falta" puede correr sin tocar una letra manual.
  bool get needsWork =>
      name == AuditCell.bad ||
      lyrics == AuditCell.bad ||
      trim == AuditCell.bad ||
      bpm == AuditCell.bad ||
      lufs == AuditCell.bad;

  /// Al LAB van sello, letra y BPM. Los cues no. El desfase ambiguo sí.
  bool get sendToLab =>
      !sealed ||
      lyrics == AuditCell.bad ||
      bpm == AuditCell.bad ||
      lyricsNeedLab;

  String csvLine() {
    String g(AuditCell c) => auditGlyph(c);
    final String tipo = megamix ? 'MEGAMIX' : 'SONG';
    final String motivo = reason.replaceAll(';', ',');
    return '$fileName;$tipo;${g(name)};${g(lyrics)};${g(trim)};${g(shift)};${g(bpm)};${g(lufs)};${g(cues)};${g(karaoke)};${g(backup)};$motivo';
  }
}

SongAudit auditSong(String path, String fileName, GmxSnapshot s) {
  final bool mega = s.isMegamix;

  final AuditCell name = s.nameOk ? AuditCell.ok : AuditCell.bad;

  final AuditCell lyrics;
  if (mega) {
    lyrics = AuditCell.na;
  } else {
    final String lyr = s.lyr.toUpperCase();
    if (lyr == 'SYNC' || lyr == 'PLAIN' || lyr == 'MANUAL') {
      lyrics = AuditCell.ok;
    } else if (lyr == 'RETRY' || lyr == 'NONE') {
      lyrics = AuditCell.bad;
    } else if (s.lrcExists) {
      lyrics = AuditCell.ok;
    } else {
      lyrics = AuditCell.bad;
    }
  }

  final AuditCell trim = s.trimMarked ? AuditCell.ok : AuditCell.bad;
  final AuditCell bpm = s.bpmOk ? AuditCell.ok : AuditCell.bad;
  final AuditCell lufs = s.lufsDone ? AuditCell.ok : AuditCell.bad;
  final AuditCell cues = s.hasManualCue ? AuditCell.ok : AuditCell.bad;

  final bool shifted = s.lrcShiftTag || s.lrcShiftFile;
  final bool manual = s.lrcManual;
  AuditCell shift;
  bool lyricsNeedLab = false;
  if (mega || !s.lrcExists || manual) {
    shift = AuditCell.na;
  } else if (shifted) {
    shift = AuditCell.ok;
  } else if (s.trimMarked) {
    shift = AuditCell.bad;
    lyricsNeedLab = true;
  } else {
    shift = AuditCell.na;
  }

  AuditCell karaoke;
  if (mega || !s.allowKaraoke) {
    karaoke = AuditCell.na;
  } else {
    karaoke = s.karaokeFile ? AuditCell.ok : AuditCell.bad;
  }

  final AuditCell backup = s.backup
      ? AuditCell.ok
      : (s.trimMarked || s.lufsDone ? AuditCell.bad : AuditCell.na);

  return SongAudit(
    path: path,
    fileName: fileName,
    megamix: mega,
    name: name,
    lyrics: lyrics,
    trim: trim,
    shift: shift,
    bpm: bpm,
    lufs: lufs,
    cues: cues,
    karaoke: karaoke,
    backup: backup,
    sealed: s.sealed,
    lyricsNeedLab: lyricsNeedLab,
    reason: s.reason,
  );
}
