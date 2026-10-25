import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/headless_args.dart';

void main() {
  test('sin argumento arranca normal', () {
    expect(parseMasterFolderArg(const []), isNull);
    expect(parseMasterFolderArg(const ['--otro']), isNull);
  });
  test('forma con espacio', () {
    expect(parseMasterFolderArg(const ['--master-folder', r'C:\M\80s Ingles']),
        r'C:\M\80s Ingles');
  });
  test('forma con igual', () {
    expect(parseMasterFolderArg(const ['--master-folder=/x/y']), '/x/y');
  });
  test('sin valor no activa', () {
    expect(parseMasterFolderArg(const ['--master-folder']), isNull);
    expect(parseMasterFolderArg(const ['--master-folder=']), isNull);
  });
}
