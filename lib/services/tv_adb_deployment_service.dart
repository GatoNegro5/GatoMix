import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/brand_paths.dart';
import '../core/net/safe_download.dart';

enum TvAdbTargetState { connected, discoverable, pairingRequired }

class TvAdbTarget {
  final String endpoint;
  final String name;
  final TvAdbTargetState state;
  final String? pairingEndpoint;
  final bool installed;

  const TvAdbTarget({
    required this.endpoint,
    required this.name,
    required this.state,
    this.pairingEndpoint,
    this.installed = false,
  });

  String get host {
    final ip = RegExp(r'(\d{1,3}(?:\.\d{1,3}){3})').firstMatch(endpoint);
    return ip?.group(1) ?? endpoint.split(':').first;
  }

  bool get paired => state == TvAdbTargetState.connected;

  bool get canInstall => state == TvAdbTargetState.connected;

  TvAdbTarget copyWith({
    String? endpoint,
    String? name,
    TvAdbTargetState? state,
    String? pairingEndpoint,
    bool? installed,
  }) {
    return TvAdbTarget(
      endpoint: endpoint ?? this.endpoint,
      name: name ?? this.name,
      state: state ?? this.state,
      pairingEndpoint: pairingEndpoint ?? this.pairingEndpoint,
      installed: installed ?? this.installed,
    );
  }
}

class TvAdbPairingRequiredException implements Exception {
  final TvAdbTarget target;
  final String message;

  const TvAdbPairingRequiredException({
    required this.target,
    required this.message,
  });

  @override
  String toString() => message;
}

class TvAdbDeploymentService {
  Future<String> _resolveAdb() async {
    final sdkRoots = <String?>[
      Platform.environment['ANDROID_SDK_ROOT'],
      Platform.environment['ANDROID_HOME'],
      if (Platform.isWindows)
        '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk',
      if (Platform.isMacOS)
        '${Platform.environment['HOME']}/Library/Android/sdk',
    ];

    for (final root in sdkRoots.whereType<String>()) {
      final candidate = Platform.isWindows
          ? '$root\\platform-tools\\adb.exe'
          : '$root/platform-tools/adb';
      if (File(candidate).existsSync()) return candidate;
    }

    // adb en el PATH.
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', [
        Platform.isWindows ? 'adb.exe' : 'adb',
      ]);
      if (r.exitCode == 0) {
        final first = const LineSplitter()
            .convert('${r.stdout}')
            .map((e) => e.trim())
            .firstWhere((e) => e.isNotEmpty, orElse: () => '');
        if (first.isNotEmpty && File(first).existsSync()) return first;
      }
    } catch (_) {}

    // platform-tools propio de la app (se baja una sola vez, gratis, de Google).
    final own =
        '${_appDataDir()}${Platform.pathSeparator}platform-tools'
        '${Platform.pathSeparator}${Platform.isWindows ? 'adb.exe' : 'adb'}';
    if (File(own).existsSync()) return own;
    return _installPlatformTools(own);
  }

  /// Carpeta de datos propia de DJ Studio para herramientas descargadas.
  String _appDataDir() {
    final base = Platform.isWindows
        ? (Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path)
        : '${Platform.environment['HOME'] ?? Directory.systemTemp.path}'
              '${Platform.isMacOS ? '/Library/Application Support' : '/.local/share'}';
    return ensureBrandDataDir(base).path;
  }

  Future<String> _installPlatformTools(String expectedAdb) async {
    final os = Platform.isWindows
        ? 'windows'
        : (Platform.isMacOS ? 'darwin' : 'linux');
    final dir = _appDataDir();
    final zip = '$dir${Platform.pathSeparator}platform-tools.zip';
    onStatus?.call('Descargando ADB (platform-tools de Google)…');
    await downloadFileRobust(
      'https://dl.google.com/android/repository/platform-tools-latest-$os.zip',
      zip,
    );
    onStatus?.call('Instalando ADB…');
    final ProcessResult r;
    if (Platform.isWindows) {
      r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Expand-Archive -Force -Path '$zip' -DestinationPath '$dir'",
      ]);
    } else {
      r = await Process.run('unzip', ['-o', '-q', zip, '-d', dir]);
      if (File(expectedAdb).existsSync()) {
        await Process.run('chmod', ['+x', expectedAdb]);
      }
    }
    try {
      File(zip).deleteSync();
    } catch (_) {}
    if (!File(expectedAdb).existsSync()) {
      throw StateError(
        'No se pudo instalar ADB automáticamente: ${r.stderr}'.trim(),
      );
    }
    return expectedAdb;
  }

  /// Mensajes de progreso para la UI (descarga de ADB, etc.).
  void Function(String message)? onStatus;

  /// Conexión manual por IP[:puerto] (sin puerto = 5555). Devuelve el
  /// resultado REAL de `adb connect` para mostrarlo tal cual.
  Future<String> connectManual(String input) async {
    var endpoint = input.trim();
    if (!endpoint.contains(':')) endpoint = '$endpoint:5555';
    final result = await _adb(['connect', endpoint]);
    return '${result.stdout}\n${result.stderr}'.trim();
  }

  Future<ProcessResult> _adb(List<String> arguments) async {
    final adb = await _resolveAdb();
    return Process.run(adb, arguments, runInShell: false);
  }

  Future<List<TvAdbTarget>> discover() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      throw UnsupportedError(
        'La instalación ADB solo se ejecuta en escritorio.',
      );
    }

    await _adb(['start-server']);
    final targets = <String, TvAdbTarget>{};

    final devices = await _adb(['devices', '-l']);
    for (final line in const LineSplitter().convert('${devices.stdout}')) {
      final match = RegExp(r'^(\S+)\s+device\b(.*)$').firstMatch(line.trim());
      if (match == null) continue;
      final serial = match.group(1)!;
      final details = match.group(2) ?? '';
      final model = RegExp(r'\bmodel:(\S+)').firstMatch(details)?.group(1);
      if (!await _isTelevision(serial)) continue;
      final host = await _serialLanHost(serial) ?? serial.split(':').first;
      final installed = await isAppInstalled(serial);
      final candidate = TvAdbTarget(
        endpoint: serial,
        name: (model ?? 'Google TV').replaceAll('_', ' '),
        state: TvAdbTargetState.connected,
        installed: installed,
      );
      final existing = targets[host];
      if (existing == null ||
          _preferEndpoint(candidate.endpoint, existing.endpoint)) {
        targets[host] = existing == null
            ? candidate
            : candidate.copyWith(pairingEndpoint: existing.pairingEndpoint);
      } else {
        targets[host] = existing.copyWith(installed: installed);
      }
    }

    for (final service in await _readMdnsServices()) {
      final host = service.host;
      final existing = targets[host];

      if (service.isPairing) {
        if (existing == null) {
          targets[host] = TvAdbTarget(
            endpoint: service.endpoint,
            name: 'Google TV — requiere código',
            state: TvAdbTargetState.pairingRequired,
            pairingEndpoint: service.endpoint,
          );
        } else if (existing.state != TvAdbTargetState.connected) {
          targets[host] = existing.copyWith(
            name: 'Google TV — requiere código',
            state: TvAdbTargetState.pairingRequired,
            pairingEndpoint: service.endpoint,
          );
        } else {
          targets[host] = existing.copyWith(pairingEndpoint: service.endpoint);
        }
        continue;
      }

      if (existing == null) {
        targets[host] = TvAdbTarget(
          endpoint: service.endpoint,
          name: 'Google TV — disponible',
          state: TvAdbTargetState.discoverable,
        );
      } else if (existing.state == TvAdbTargetState.pairingRequired) {
        targets[host] = existing.copyWith(endpoint: service.endpoint);
      }
    }

    if (targets.isEmpty) {
      await _scanLegacyAdb(targets);
    }

    return targets.values.toList()
      ..sort((a, b) => a.state.index.compareTo(b.state.index));
  }

  Future<List<_MdnsAdbService>> _readMdnsServices() async {
    final mdns = await _adb(['mdns', 'services']);
    final pattern = RegExp(
      r'(_adb-tls-(?:connect|pairing)\._tcp)'
      r'\D+(\d{1,3}(?:\.\d{1,3}){3})[:\s]+(\d+)',
    );
    final services = <_MdnsAdbService>[];
    for (final line in const LineSplitter().convert('${mdns.stdout}')) {
      final match = pattern.firstMatch(line.trim());
      if (match == null) continue;
      services.add(
        _MdnsAdbService(
          isPairing: match.group(1)!.contains('pairing'),
          host: match.group(2)!,
          port: match.group(3)!,
        ),
      );
    }
    return services;
  }

  Future<String?> _serialLanHost(String serial) async {
    final dotted = RegExp(r'(\d{1,3}(?:\.\d{1,3}){3})').firstMatch(serial);
    if (dotted != null) return dotted.group(1);
    try {
      final result = await _adb([
        '-s',
        serial,
        'shell',
        'ip',
        '-4',
        'addr',
        'show',
        'wlan0',
      ]);
      return RegExp(
        r'inet (\d{1,3}(?:\.\d{1,3}){3})',
      ).firstMatch('${result.stdout}')?.group(1);
    } catch (_) {
      return null;
    }
  }

  bool _preferEndpoint(String incoming, String current) {
    final ipPort = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}:\d+$');
    return ipPort.hasMatch(incoming) && !ipPort.hasMatch(current);
  }

  Future<bool> isAppInstalled(String serial) async {
    try {
      final result = await _adb([
        '-s',
        serial,
        'shell',
        'pm',
        'path',
        'com.gatonegro5.gatomix.tv',
      ]);
      return '${result.stdout}'.contains('package:');
    } catch (_) {
      return false;
    }
  }

  Future<void> launchApp(String serial) async {
    await _adb([
      '-s',
      serial,
      'shell',
      'monkey',
      '-p',
      'com.gatonegro5.gatomix.tv',
      '-c',
      'android.intent.category.LEANBACK_LAUNCHER',
      '1',
    ]);
  }

  Future<bool> _isTelevision(String serial) async {
    return await _probeTelevision(serial) ?? false;
  }

  /// `null` cuando ADB no devolvió la propiedad: no es una negativa.
  Future<bool?> _probeTelevision(String serial) async {
    try {
      final result = await _adb([
        '-s',
        serial,
        'shell',
        'getprop',
        'ro.build.characteristics',
      ]);
      final value = '${result.stdout}'.trim().toLowerCase();
      if (value.isEmpty) return null;
      return value.contains('tv') || value.contains('leanback');
    } catch (_) {
      return null;
    }
  }

  Future<void> _scanLegacyAdb(Map<String, TvAdbTarget> targets) async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final address = interfaces
        .expand((interface) => interface.addresses)
        .map((item) => item.address)
        .where((item) => item.split('.').length == 4)
        .firstOrNull;
    if (address == null) return;

    final octets = address.split('.');
    final subnet = '${octets[0]}.${octets[1]}.${octets[2]}';
    for (int start = 1; start <= 254; start += 32) {
      final probes = <Future<void>>[];
      for (int host = start; host < start + 32 && host <= 254; host++) {
        final ip = '$subnet.$host';
        if (ip == address) continue;
        probes.add(_probeLegacyEndpoint(ip, targets));
      }
      await Future.wait(probes);
    }
  }

  Future<void> _probeLegacyEndpoint(
    String ip,
    Map<String, TvAdbTarget> targets,
  ) async {
    try {
      final socket = await Socket.connect(
        ip,
        5555,
        timeout: const Duration(milliseconds: 220),
      );
      socket.destroy();
      targets[ip] = TvAdbTarget(
        endpoint: '$ip:5555',
        name: 'Android TV — depuración de red',
        state: TvAdbTargetState.discoverable,
      );
    } catch (_) {}
  }

  Future<String> pair({required String endpoint, required String code}) async {
    final result = await _adb(['pair', endpoint, code.trim()]);
    final output = '${result.stdout}\n${result.stderr}'.trim();
    if (result.exitCode != 0 ||
        !output.toLowerCase().contains('successfully paired')) {
      throw StateError(
        output.isEmpty
            ? 'No se pudo emparejar. Revisa que el IP:puerto sea el del '
                  'diálogo “Vincular con dispositivo” y que siga abierto.'
            : output,
      );
    }
    final host = endpoint.split(':').first;
    final connectEndpoint = await _resolveConnectEndpoint(host);
    if (connectEndpoint != null) {
      await _tryConnect(connectEndpoint);
    }
    return output;
  }

  Future<void> buildInstallAndLaunch({
    required TvAdbTarget target,
    required void Function(String message) onProgress,
  }) async {
    var endpoint = target.endpoint;
    if (target.state != TvAdbTargetState.connected) {
      onProgress('Conectando con $endpoint…');
      var connected = await _tryConnect(endpoint);
      if (!connected) {
        final refreshed = await _resolveConnectEndpoint(target.host);
        if (refreshed != null && refreshed != endpoint) {
          onProgress('Puerto renovado, reintentando en $refreshed…');
          connected = await _tryConnect(refreshed);
          if (connected) endpoint = refreshed;
        }
      }
      if (!connected) {
        final pairing = await resolvePairingEndpoint(target.host);
        throw TvAdbPairingRequiredException(
          target: target.copyWith(
            pairingEndpoint: pairing ?? target.pairingEndpoint,
            state: TvAdbTargetState.pairingRequired,
            name: 'Google TV — requiere código',
          ),
          message:
              'Esta TV exige emparejarse antes de instalar. '
              'Abre Emparejar dispositivo en la TV e ingresa el código.',
        );
      }
    }

    final isTelevision = await _probeTelevision(endpoint);
    if (isTelevision == false) {
      throw StateError(
        '$endpoint no es un dispositivo TV/Leanback. Elige otro destino.',
      );
    }
    if (isTelevision == null) {
      onProgress('Aviso: ADB no confirmó Leanback; continuando…');
    }

    final alreadyInstalled = target.installed || await isAppInstalled(endpoint);
    if (alreadyInstalled) {
      onProgress('APK ya instalado. Abriendo…');
    } else {
      // Con el proyecto gatomix_tv local se compila como siempre; sin él
      // (laptop sin Flutter) se baja el APK ya compilado del último release.
      final Directory? project = _tryResolveTvProject();
      final File apk = project == null
          ? await _downloadTvApk(onProgress)
          : File(
              '${project.path}${Platform.pathSeparator}build${Platform.pathSeparator}'
              'app${Platform.pathSeparator}outputs${Platform.pathSeparator}'
              'flutter-apk${Platform.pathSeparator}app-release.apk',
            );

      if (project != null && _requiresBuild(project, apk)) {
        onProgress('Compilando GatoMix Karaoke…');
        final build = await Process.start(
          Platform.isWindows ? 'flutter.bat' : 'flutter',
          ['build', 'apk', '--release'],
          workingDirectory: project.path,
          runInShell: true,
        );
        final stdoutSub = build.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(onProgress);
        final stderrSub = build.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(onProgress);
        final buildExit = await build.exitCode;
        await stdoutSub.cancel();
        await stderrSub.cancel();
        if (buildExit != 0 || !apk.existsSync()) {
          throw StateError('Falló la compilación del APK para Google TV.');
        }
      } else if (project != null) {
        onProgress('APK release vigente; omitiendo recompilación.');
      }

      onProgress('Instalando APK en ${target.name}…');
      final install = await _adb([
        '-s',
        endpoint,
        'install',
        '-r',
        '-d',
        apk.path,
      ]);
      final installOutput = '${install.stdout}\n${install.stderr}'.trim();
      if (install.exitCode != 0 ||
          !installOutput.toLowerCase().contains('success')) {
        throw StateError(installOutput);
      }
    }

    onProgress('Abriendo GatoMix Karaoke en la TV…');
    await launchApp(endpoint);
    onProgress(
      alreadyInstalled
          ? 'TV lista. No se reinstaló el APK.'
          : 'Instalación terminada. Revisa la pantalla de la TV.',
    );
  }

  Future<bool> _tryConnect(String endpoint) async {
    final connect = await _adb(['connect', endpoint]);
    if (connect.exitCode != 0) return false;
    final output = '${connect.stdout}\n${connect.stderr}'.toLowerCase();
    return output.contains('connected to') &&
        !output.contains('failed to connect');
  }

  /// El puerto TLS de conexión rota tras cada emparejamiento o reinicio.
  Future<String?> _resolveConnectEndpoint(String host) async {
    for (final service in await _readMdnsServices()) {
      if (!service.isPairing && service.host == host) return service.endpoint;
    }
    return null;
  }

  Future<String?> resolvePairingEndpoint(String host) async {
    for (final service in await _readMdnsServices()) {
      if (service.isPairing && service.host == host) return service.endpoint;
    }
    return null;
  }

  bool _requiresBuild(Directory project, File apk) {
    if (!apk.existsSync()) return true;
    final apkModified = apk.lastModifiedSync();
    final sourcePaths = [
      'pubspec.yaml',
      'lib${Platform.pathSeparator}main.dart',
      'android${Platform.pathSeparator}app${Platform.pathSeparator}'
          'build.gradle.kts',
      'android${Platform.pathSeparator}app${Platform.pathSeparator}src'
          '${Platform.pathSeparator}main${Platform.pathSeparator}'
          'AndroidManifest.xml',
    ];
    return sourcePaths.any((relative) {
      final source = File('${project.path}${Platform.pathSeparator}$relative');
      return source.existsSync() &&
          source.lastModifiedSync().isAfter(apkModified);
    });
  }

  Directory? _tryResolveTvProject() {
    try {
      return _resolveTvProject();
    } catch (_) {
      return null;
    }
  }

  /// APK de Karaoke TV ya compilado por el CI (release más reciente).
  Future<File> _downloadTvApk(void Function(String) onProgress) async {
    final dir = Directory('${_appDataDir()}${Platform.pathSeparator}tv');
    dir.createSync(recursive: true);
    final apk = File('${dir.path}${Platform.pathSeparator}gatomix-tv.apk');
    onProgress('Descargando GatoMix Karaoke (APK)…');
    await downloadFileRobust(
      'https://github.com/GatoNegro5/GatoMix/releases/latest/download/gatomix-tv.apk',
      apk.path,
    );
    return apk;
  }

  Directory _resolveTvProject() {
    final roots = <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ];
    for (final root in roots) {
      var cursor = root;
      for (int depth = 0; depth < 10; depth++) {
        final candidate = Directory(
          '${cursor.path}${Platform.pathSeparator}gatomix_tv',
        );
        if (File(
          '${candidate.path}${Platform.pathSeparator}pubspec.yaml',
        ).existsSync()) {
          return candidate;
        }
        if (cursor.parent.path == cursor.path) break;
        cursor = cursor.parent;
      }
    }
    throw StateError(
      'No se encontró gatomix_tv/. Ejecuta desde el repositorio de GatoMix.',
    );
  }
}

class _MdnsAdbService {
  final bool isPairing;
  final String host;
  final String port;

  const _MdnsAdbService({
    required this.isPairing,
    required this.host,
    required this.port,
  });

  String get endpoint => '$host:$port';
}
