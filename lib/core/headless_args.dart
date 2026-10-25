/// Lectura del argumento `--master-folder <ruta>` (o `--master-folder=<ruta>`).
/// Devuelve null si no viene: la app arranca normal, sin cambios en la UI.
String? parseMasterFolderArg(List<String> args) =>
    _valueArg(args, '--master-folder');

/// 1.0.13: `--lab-rescue <ruta del LAB>`: masteriza el Laboratorio y devuelve
/// a su carpeta las pistas que quedaron bien.
String? parseLabRescueArg(List<String> args) => _valueArg(args, '--lab-rescue');

/// 1.0.13: `--auto-lab`: al terminar `--master-folder`, las letras en FAIL
/// van al Laboratorio (reversible por quarantine_registry.json).
bool parseAutoLabFlag(List<String> args) => args.contains('--auto-lab');

String? _valueArg(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == name) {
      if (i + 1 < args.length && args[i + 1].trim().isNotEmpty) {
        return args[i + 1].trim();
      }
      return null;
    }
    if (a.startsWith('$name=')) {
      final v = a.substring(name.length + 1).trim();
      return v.isEmpty ? null : v;
    }
  }
  return null;
}
