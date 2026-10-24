import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/workspaces/lab_preview_player.dart';

void main() {
  test('reloj mm:ss', () {
    expect(labClock(0), '00:00');
    expect(labClock(65999), '01:05');
    expect(labClock(-5), '00:00');
  });

  test('saltos ±10 s quedan dentro de la canción', () {
    expect(labSeekTarget(5000, -10000, 200000), 0);
    expect(labSeekTarget(195000, 10000, 200000), 200000);
    expect(labSeekTarget(30000, 10000, 200000), 40000);
    expect(labSeekTarget(30000, 10000, 0), 40000);
  });

  test('línea activa: sincronizada sí, plana -1', () {
    const lrc = '[00:10.00] uno\n[00:20.00] dos\n[00:30.00] tres';
    expect(labActiveLine(lrc, 5000), -1);
    expect(labActiveLine(lrc, 20000), 1);
    expect(labActiveLine(lrc, 99000), 2);
    expect(labActiveLine('[gmx_plain:1]\nhola\nmundo', 50000), -1);
  });
}
