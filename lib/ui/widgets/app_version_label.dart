import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Versión instalada (la del pubspec = la del tag de GitHub), en texto chico.
/// Sirve para saber de qué build habla una captura.
class AppVersionLabel extends StatelessWidget {
  const AppVersionLabel({super.key});

  static final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  /// Commit corto inyectado al compilar: `--dart-define=GIT_SHA=abc1234`.
  static const String gitSha = String.fromEnvironment(
    'GIT_SHA',
    defaultValue: 'dev',
  );

  /// `3.1.01 (abc1234)`: YY con 2 dígitos, sin `+N` ni build (Ley 5).
  static String format(
    String version,
    String buildNumber, [
    String sha = gitSha,
  ]) {
    final shortSha = sha.length > 7 ? sha.substring(0, 7) : sha;
    final parts = version.trim().split('.');
    final shown = parts.length == 3 && int.tryParse(parts[2]) != null
        ? '${parts[0]}.${parts[1]}.${parts[2].padLeft(2, '0')}'
        : version.trim();
    return '$shown ($shortSha)';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        if (info == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Text(
            'v${format(info.version, info.buildNumber)}',
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white38,
              letterSpacing: 0.6,
            ),
          ),
        );
      },
    );
  }
}
