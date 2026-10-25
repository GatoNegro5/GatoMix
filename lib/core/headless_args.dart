/// Lectura del argumento `--master-folder <ruta>` (o `--master-folder=<ruta>`).
/// Devuelve null si no viene: la app arranca normal, sin cambios en la UI.
String? parseMasterFolderArg(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--master-folder') {
      if (i + 1 < args.length && args[i + 1].trim().isNotEmpty) {
        return args[i + 1].trim();
      }
      return null;
    }
    if (a.startsWith('--master-folder=')) {
      final v = a.substring('--master-folder='.length).trim();
      return v.isEmpty ? null : v;
    }
  }
  return null;
}
