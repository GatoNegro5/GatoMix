import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/widgets/app_version_label.dart';

void main() {
  test('formato de versión con build y commit corto', () {
    expect(
      AppVersionLabel.format('3.1.1', '30101', 'abc1234def'),
      '3.1.01 (abc1234)',
    );
    expect(AppVersionLabel.format('3.1.99', '30199', 'dev'), '3.1.99 (dev)');
    expect(AppVersionLabel.format('3.2.1', '', 'dev'), '3.2.01 (dev)');
  });
}
