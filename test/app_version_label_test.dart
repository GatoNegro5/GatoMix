import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/widgets/app_version_label.dart';

void main() {
  test('formato de versión con build y commit corto', () {
    expect(
      AppVersionLabel.format('1.0.1', '15', 'abc1234def'),
      '1.0.1 (build 15 · abc1234)',
    );
    expect(AppVersionLabel.format('1.0.1', '', 'dev'), '1.0.1 (dev)');
  });
}
