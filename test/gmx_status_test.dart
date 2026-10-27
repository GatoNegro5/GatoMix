import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gmx_status.dart';

SongAudit _row(GmxSnapshot snap) =>
    auditSong('/music/Tema.mp3', 'Tema.mp3', snap);

void main() {
  test('un megamix no cuenta la letra ni el _K', () {
    final SongAudit row = _row(
      const GmxSnapshot(
        type: 'MEGAMIX',
        nameOk: true,
        trimMarked: true,
        bpmOk: true,
        lufsDone: true,
        backup: true,
        sealed: true,
        allowKaraoke: true,
      ),
    );
    expect(row.megamix, isTrue);
    expect(row.lyrics, AuditCell.na);
    expect(row.karaoke, AuditCell.na);
    expect(row.needsWork, isFalse);
    expect(row.csvLine(), contains('MEGAMIX'));
    expect(row.csvLine(), contains('—'));
  });

  test('letra cortada sin marca va al Laboratorio', () {
    final SongAudit row = _row(
      const GmxSnapshot(
        nameOk: true,
        lyr: 'SYNC',
        trimMarked: true,
        bpmOk: true,
        lufsDone: true,
        lrcExists: true,
        sealed: true,
        backup: true,
        allowKaraoke: true,
        karaokeFile: true,
      ),
    );
    expect(row.shift, AuditCell.bad);
    expect(row.lyricsNeedLab, isTrue);
    expect(row.sendToLab, isTrue);
    expect(row.needsWork, isFalse);
  });

  test('en el teléfono el _K no aplica', () {
    final SongAudit row = _row(
      const GmxSnapshot(
        nameOk: true,
        lyr: 'SYNC',
        trimMarked: true,
        lrcShiftTag: true,
        bpmOk: true,
        lufsDone: true,
        backup: true,
        sealed: true,
        lrcExists: true,
        allowKaraoke: false,
      ),
    );
    expect(row.karaoke, AuditCell.na);
    expect(auditGlyph(row.karaoke), '—');
  });

  test('el motivo de paquetes rotos queda en el informe', () {
    final SongAudit row = _row(const GmxSnapshot(reason: 'decode_errors=4'));
    expect(row.reason, 'decode_errors=4');
    expect(row.csvLine(), endsWith(';decode_errors=4'));
  });

  test('RETRY de letra es un faltante, no un megamix', () {
    final SongAudit row = _row(
      const GmxSnapshot(lyr: 'RETRY', lrcExists: true),
    );
    expect(row.lyrics, AuditCell.bad);
    expect(row.megamix, isFalse);
    expect(row.needsWork, isTrue);
  });
}
