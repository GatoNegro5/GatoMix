import 'dart:io';
import '../../core/lyric_approx.dart';
import '../widgets/approx_lyric_icon.dart';
import 'dart:async';
import 'dart:convert';
import '../../djiphone/iphone_library.dart';
import 'karaoke_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import '../../core/lan_sync_plan.dart';
import '../../core/gatomix_store.dart' show TrackMusic, saveTrackMusicBatch;
import '../../core/queue_bpm.dart' show knownBpm;

/// Destino remoto de la raíz Música. El servidor ya resuelve `ROOT`.
const String lanMusicRootToken = 'ROOT';
const String lanMusicRootLabel = 'Música (raíz)';

const Duration lanSendTimeout = Duration(seconds: 60);
const List<Duration> lanSendBackoff = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
];
const int lanSendMaxAttempts = 4;

/// 3.1.05: ultima IP que respondio `/api/whoami` en esta sesion.
String? _lanLastPeerIp;

enum LanFileResult { copied, existed, failed }

class LanJobCounts {
  int copied = 0;
  int existed = 0;
  int failed = 0;

  void add(LanFileResult result) {
    switch (result) {
      case LanFileResult.copied:
        copied++;
      case LanFileResult.existed:
        existed++;
      case LanFileResult.failed:
        failed++;
    }
  }
}

LanFileResult lanClassifyStatus(int status, {bool alreadyThere = false}) {
  if (alreadyThere) return LanFileResult.existed;
  if (status == 200) return LanFileResult.copied;
  return LanFileResult.failed;
}

String? lanFailureNotice(int status, String name) {
  if (status == 403) return 'Permiso de almacenamiento denegado: $name';
  if (status == 500) return 'Falló la escritura remota: $name';
  if (status != 200) return 'Falló el envío: $name ($status)';
  return null;
}

String lanFinalLog({
  required bool mobile,
  required int copied,
  required int existed,
  required int failed,
  required int skippedMixed,
}) {
  if (!mobile) {
    return "✅ Job Finalizado. Éxito: $copied | Saltados/Fallos: $skippedMixed";
  }
  if (failed > 0) {
    return "Job Finalizado con $failed fallidos. Copiados: $copied | Ya existían: $existed | Fallidos: $failed";
  }
  return "Job Finalizado. Copiados: $copied | Ya existían: $existed | Fallidos: 0";
}

bool lanFinalIsRed({required bool mobile, required int failed}) =>
    mobile && failed > 0;

int lanUploadHttpStatus({
  required bool mobile,
  required bool denied,
  required bool writeFailed,
}) {
  if (!mobile) return 200;
  if (denied) return 403;
  if (writeFailed) return 500;
  return 200;
}

bool lanUploadBlocked({required bool mobile, required bool storageGranted}) {
  if (!mobile) return false;
  return !storageGranted;
}

/// 100 % solo al cerrar el job. A mitad de archivo el avance es lo ya terminado.
double lanTransferProgress({
  required bool mobile,
  required int completed,
  required int total,
  required bool jobFinished,
  required bool cancelled,
}) {
  if (!mobile) {
    if (jobFinished) return 1;
    if (total <= 0) return 0;
    return completed / total;
  }
  if (cancelled || !jobFinished) {
    if (total <= 0) return 0;
    return completed / total;
  }
  return 1;
}

List<String> orderRemoteFolders(List<String> folders, {required bool mobile}) {
  final List<String> sorted = <String>[...folders]..sort(
    (String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()),
  );
  if (!mobile) return sorted;
  final List<String> rest = sorted
      .where((String f) => f != lanMusicRootToken && f.isNotEmpty)
      .toList();
  return <String>[lanMusicRootToken, ...rest];
}

String? defaultRemoteSelection(List<String> folders, {required bool mobile}) {
  if (mobile) return lanMusicRootToken;
  if (folders.isEmpty) return null;
  final List<String> sorted = orderRemoteFolders(folders, mobile: false);
  return sorted.first;
}

String lanRemoteLabel(String path) {
  if (path == lanMusicRootToken) return lanMusicRootLabel;
  return path.split('/').last;
}

List<String> withMusicRootFirst(List<String> visible, {required bool mobile}) {
  if (!mobile) return visible;
  final List<String> rest = visible
      .where((String p) => p != lanMusicRootToken)
      .toList();
  return <String>[lanMusicRootToken, ...rest];
}

String? pickLanIpv4(
  List<({String name, List<String> addresses})> interfaces, {
  required bool preferWlan,
}) {
  String? first;
  String? wlan;
  for (final ({String name, List<String> addresses}) interface in interfaces) {
    final String name = interface.name.toLowerCase();
    if (name.contains('virtual') || name == 'lo') continue;
    if (interface.addresses.isEmpty) continue;
    final String address = interface.addresses.first;
    // 3.1.05: 169.254.x (sin DHCP) no es la LAN.
    if (address.startsWith('169.254.')) continue;
    first ??= address;
    if (preferWlan && lanIsWlanName(name)) {
      wlan ??= address;
    }
  }
  if (preferWlan && wlan != null) return wlan;
  return first;
}

/// Un intento y 3 reintentos. Las esperas son 1 s, 2 s y 4 s.
/// 403 no se reintenta. 200 termina. El resto y los errores de red sí.
Future<int> lanSendWithRetry(
  Future<int> Function() attempt, {
  Duration timeout = lanSendTimeout,
  List<Duration> backoff = lanSendBackoff,
  int maxAttempts = lanSendMaxAttempts,
  Future<void> Function(Duration delay)? wait,
}) async {
  final Future<void> Function(Duration delay) pause =
      wait ?? (Duration delay) => Future<void>.delayed(delay);
  Object? lastError;
  for (var attemptIndex = 0; attemptIndex < maxAttempts; attemptIndex++) {
    if (attemptIndex > 0) {
      await pause(backoff[attemptIndex - 1]);
    }
    try {
      final int code = await attempt().timeout(timeout);
      if (code == 200 || code == 403 || attemptIndex == maxAttempts - 1) {
        return code;
      }
    } catch (e) {
      lastError = e;
      if (attemptIndex == maxAttempts - 1) rethrow;
    }
  }
  throw lastError ?? StateError('lan send');
}

/// 3.1.07: un intento de subida (escritorio). Arma el multipart en cada
/// intento y vacia la respuesta para que el socket vuelva al pool (Keep-Alive).
Future<int> lanUploadOnce(http.Client client, Uri uri, String path) async {
  final http.MultipartRequest request = http.MultipartRequest('POST', uri);
  request.files.add(await http.MultipartFile.fromPath('file', path));
  final http.StreamedResponse response = await client.send(request);
  final int status = response.statusCode;
  await response.stream.drain<void>();
  return status;
}

/// 3.1.17: guarda en el `.gatomix.json` del receptor el BPM que llego por
/// LAN Sync, con la ruta local y el mtime del archivo ya escrito. Gana el
/// destino ([lanBpmToSave]); solo `.mp3`. Un fallo no corta la transferencia.
Future<void> lanSaveIncomingBpm(Map<String, Object?> incoming) async {
  final List<TrackMusic> items = <TrackMusic>[];
  incoming.forEach((String path, Object? raw) {
    if (!path.toLowerCase().endsWith('.mp3')) return;
    final double bpm = lanBpmToSave(localBpm: knownBpm(path), incoming: raw);
    if (bpm > 0) items.add((path: path, bpm: bpm, camelot: null));
  });
  if (items.isEmpty) return;
  try {
    await saveTrackMusicBatch(items, stampMtime: true);
  } catch (e) {
    debugPrint('[LAN] BPM no guardado: $e');
  }
}

class LanSyncWorkspace extends ConsumerStatefulWidget {
  const LanSyncWorkspace({super.key});

  @override
  ConsumerState<LanSyncWorkspace> createState() => _LanSyncWorkspaceState();
}

class _LanSyncWorkspaceState extends ConsumerState<LanSyncWorkspace>
    with SingleTickerProviderStateMixin {
  String _localIp = "Buscando red...";
  final int _restPort = 55055;

  HttpServer? _server;
  bool _isSweeping = true;
  bool _isManualSweeping = false;

  final Map<String, String> _discoveredDevices = {};
  String? _selectedDeviceIp;
  String? _selectedDeviceName;

  List<String> _localFolderPaths = [];
  final Set<String> _expandedLocalPaths = {};
  String? _selectedLocalPath;
  List<File> _currentLocalFiles = [];
  final Set<String> _selectedFilesToTransfer = {};

  List<String> _remoteFolderPaths = [];
  final Set<String> _expandedRemotePaths = {};
  String? _selectedRemotePath;

  // 🛠️ REFACTOR ESTRUCTURAL: Ahora soporta metadata estructurada JSON
  List<dynamic> _currentRemoteFiles = [];

  bool _isTransferring = false;
  bool _cancelRequested = false;
  bool _overwriteExisting = false;
  bool _isPushMode = true;
  bool _sendKaraoke = true; // 3.1.15: enviar/extraer tambien los _K.mp3
  double _transferProgress = 0.0;
  String _currentLog = "Iniciando protocolos de seguridad y red...";
  int _totalFiles = 0;
  int _currentFileIndex = 0;
  int _successfulTransfers = 0;
  int _skippedTransfers = 0;
  int _existedTransfers = 0;
  int _failedTransfers = 0;
  final List<File> _retryPush = <File>[];
  final List<String> _retryPull = <String>[];
  bool _lanFinalRed = false;

  bool get _lanMobile => Platform.isAndroid || Platform.isIOS;

  // 🎤 KARAOKE STATE MANAGER
  final List<Map<String, dynamic>> _karaokeQueue = [];
  final Map<String, int> _currentVotes = {'🔥': 0, '💩': 0, '👏': 0};

  late AnimationController _radarController;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    ); // 3.1.18: gira solo durante un barrido (_radarSpin).

    _bootSequence();
  }

  @override
  void dispose() {
    _radarController.dispose();
    _isSweeping = false;
    _server?.close(force: true);
    super.dispose();
  }

  // 🛠️ UTILIDADES DE FORMATEO (Explorador Profesional)
  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
  }

  String _formatDate(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    return "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}";
  }

  String _getBaseMusicPath() {
    if (Platform.isIOS) return IphoneLibrary.musicRoot;
    return Platform.isWindows
        ? '${Platform.environment['USERPROFILE']}\\Music'
        : (Platform.isAndroid
              ? '/storage/emulated/0/Music'
              : '${Platform.environment['HOME']}/Music');
  }

  Future<void> _bootSequence() async {
    if (_lanMobile) {
      _scanLocalMusicFolders();
      await _bootRestServer();
      if (_server != null) _startNetworkSweeper();
      await _ensurePermissionsAndFirewall();
      if (_server == null) {
        await _bootRestServer();
        if (_server != null) _startNetworkSweeper();
      }
      return;
    }
    await _ensurePermissionsAndFirewall();
    _scanLocalMusicFolders();
    await _bootRestServer();
    _startNetworkSweeper();
  }

  Future<void> _ensurePermissionsAndFirewall() async {
    if (Platform.isAndroid) {
      setState(() => _currentLog = "⚙️ Solicitando permisos de Android...");
      await Permission.audio.request();
      await Permission.storage.request();
      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
      }
    }

    if (Platform.isWindows) {
      try {
        setState(() => _currentLog = "⚙️ Auditando Windows Defender...");
        const oldRule =
            'DJ'
            'Studio'
            ' REST Server';
        const newRule = 'GatoMix REST Server';
        final oldCmd = await Process.run('powershell', [
          '-Command',
          'Get-NetFirewallRule -DisplayName "$oldRule" -ErrorAction SilentlyContinue',
        ]);
        final newCmd = await Process.run('powershell', [
          '-Command',
          'Get-NetFirewallRule -DisplayName "$newRule" -ErrorAction SilentlyContinue',
        ]);
        final hadOld = oldCmd.stdout.toString().contains(oldRule);
        final hasNew = newCmd.stdout.toString().contains(newRule);
        if (hadOld || !hasNew) {
          setState(
            () => _currentLog = "⚠️ Escalando privilegios (Acepte el UAC)...",
          );
          final script = StringBuffer();
          if (hadOld) {
            script.write(
              "Remove-NetFirewallRule -DisplayName '$oldRule' -ErrorAction SilentlyContinue; ",
            );
          }
          if (!hasNew) {
            script.write(
              "New-NetFirewallRule -DisplayName '$newRule' -Direction Inbound -LocalPort $_restPort -Protocol TCP -Action Allow",
            );
          }
          final addCmd =
              '''
          Start-Process powershell -Verb runAs -WindowStyle Hidden -ArgumentList "-Command ${script.toString().trim()}"
          ''';
          await Process.run('powershell', ['-Command', addCmd]);
          await Future.delayed(const Duration(seconds: 2));
        }
      } catch (_) {}
    }
    setState(() => _currentLog = "✅ Permisos nativos asegurados.");
  }

  List<String> _crawlFolders(Directory dir, int currentDepth, int maxDepth) {
    if (currentDepth > maxDepth) return [];
    List<String> paths = [];
    try {
      final entities = dir.listSync(recursive: false, followLinks: false);
      for (var e in entities) {
        if (e is Directory) {
          final name = e.path.split(Platform.pathSeparator).last;
          if (!name.startsWith('.') && !name.startsWith('\$')) {
            paths.add(e.path);
            paths.addAll(_crawlFolders(e, currentDepth + 1, maxDepth));
          }
        }
      }
    } catch (_) {}
    return paths;
  }

  void _showDidacticSuccessModal() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF101010),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFF39FF14), width: 3),
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Column(
            children: [
              Icon(Icons.rocket_launch, color: Color(0xFF39FF14), size: 60),
              SizedBox(height: 15),
              Text(
                "¡CLONACIÓN EXITOSA!",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF39FF14),
                  fontWeight: FontWeight.w900,
                  fontSize: 24,
                ),
              ),
            ],
          ),
          content: const Text(
            "La base de datos (Laptop) ha terminado de transmitir la música. \n\nHe refrescado automáticamente la memoria de este dispositivo.\n\n🎵 La pista de baile está lista.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 16, height: 1.5),
          ),
          actions: [
            Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF39FF14),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 15,
                  ),
                ),
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text(
                  "¡ENTENDIDO!",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _scanLocalMusicFolders() {
    final baseDir = Directory(_getBaseMusicPath());
    if (baseDir.existsSync()) {
      final paths = _crawlFolders(baseDir, 0, 4);
      paths.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      setState(() => _localFolderPaths = paths);
    }
  }

  void _loadFilesInFolder(String path) {
    setState(() {
      _selectedLocalPath = path;
      try {
        _currentLocalFiles = Directory(path)
            .listSync(recursive: false, followLinks: false)
            .whereType<File>()
            .where((f) {
              return lanSyncable(f.path);
            })
            .toList();
        _currentLocalFiles.sort(
          (a, b) => a.uri.pathSegments.last.toLowerCase().compareTo(
            b.uri.pathSegments.last.toLowerCase(),
          ),
        );
      } catch (_) {
        _currentLocalFiles = [];
      }
      _selectedFilesToTransfer.clear();
    });
  }

  List<File> _getFilesRecursively(Directory dir, [int depth = 0]) {
    if (depth > 5) return [];
    List<File> result = [];
    try {
      final entities = dir.listSync(recursive: false, followLinks: false);
      for (var e in entities) {
        if (e is File) {
          if (lanSyncable(e.path) && (_sendKaraoke || !lanIsKaraokeMp3(e.path))) {
            result.add(e);
          }
        } else if (e is Directory) {
          final name = e.path.split(Platform.pathSeparator).last;
          if (!name.startsWith('.') && !name.startsWith('\$')) {
            result.addAll(_getFilesRecursively(e, depth + 1));
          }
        }
      }
    } catch (_) {}
    return result;
  }

  void _toggleSelectAllFiles() {
    setState(() {
      if (_selectedFilesToTransfer.length == _currentLocalFiles.length) {
        _selectedFilesToTransfer.clear();
      } else {
        _selectedFilesToTransfer.addAll(_currentLocalFiles.map((f) => f.path));
      }
    });
  }

  Future<bool> _lanStorageGranted() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    if (await Permission.audio.isGranted) return true;
    return false;
  }

  // 🛠️ API CORE: Endpoints de Aniquilación y Metadata Inyectados
  Future<void> _bootRestServer() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      // 3.1.05: escritorio y movil eligen la IP igual (prefiere Wi-Fi).
      final String? ip = pickLanIpv4(
        <({String name, List<String> addresses})>[
          for (final NetworkInterface interface in interfaces)
            (
              name: interface.name,
              addresses: <String>[
                for (final InternetAddress address in interface.addresses)
                  address.address,
              ],
            ),
        ],
        preferWlan: true,
      );
      if (ip != null) _localIp = ip;

      _server = await HttpServer.bind(InternetAddress.anyIPv4, _restPort);
      _server!.listen(_handleRestRequests);
      setState(
        () => _currentLog = "✅ Servidor REST activo en $_localIp:$_restPort",
      );
    } catch (e) {
      setState(() => _currentLog = "🔴 Error bind puerto $_restPort: $e");
    }
  }

  String _resolvePath(String relativePath) {
    String base = _getBaseMusicPath();
    if (relativePath.isEmpty || relativePath == 'ROOT') return base;
    if (relativePath.startsWith('ROOT/')) {
      relativePath = relativePath.substring(5);
    }
    return '$base${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}';
  }

  void _handleRestRequests(HttpRequest request) async {
    final path = request.uri.path;
    final query = request.uri.queryParameters;

    try {
      if (request.method == 'GET' && path == '/api/whoami') {
        final osInfo = Platform.operatingSystem.toUpperCase();
        final hostInfo = Platform.localHostname;
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({"name": "$osInfo - $hostInfo"}))
          ..close();
        return;
      }

      if (request.method == 'GET' && path == '/api/tree') {
        final baseMusicPath = _getBaseMusicPath();
        final folderNames = _localFolderPaths.map((p) {
          String rel = p.replaceFirst(baseMusicPath, '');
          if (rel.startsWith(Platform.pathSeparator)) rel = rel.substring(1);
          return rel.replaceAll('\\', '/');
        }).toList();
        folderNames.removeWhere((n) => n.isEmpty);
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(folderNames))
          ..close();
        return;
      }

      if (request.method == 'GET' && path == '/api/files') {
        final targetPath = _resolvePath(query['dir'] ?? 'ROOT');
        List<Map<String, dynamic>> filesMetadata = [];
        final dir = Directory(targetPath);

        if (dir.existsSync()) {
          for (var f in dir.listSync(recursive: false).whereType<File>()) {
            if (lanSyncable(f.path)) {
              // 3.1.17: BPM ya resuelto (sin decodificar), nunca la ruta.
              final double bpm = f.path.toLowerCase().endsWith('.mp3')
                  ? lanBpm(knownBpm(f.path))
                  : 0;
              filesMetadata.add({
                "name": f.uri.pathSegments.last,
                "size_bytes": f.lengthSync(),
                "modified_ms": f.lastModifiedSync().millisecondsSinceEpoch,
                if (bpm > 0) "bpm": bpm,
              });
            }
          }
        }
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(filesMetadata))
          ..close();
        return;
      }

      // 🔍 NUEVO: Catálogo Recursivo para el Motor de Búsqueda del Karaoke
      if (request.method == 'GET' && path == '/api/catalog') {
        final targetPath = _resolvePath('ReGenial');
        List<Map<String, dynamic>> fullCatalog = [];
        final dir = Directory(targetPath);

        if (dir.existsSync()) {
          for (var f in dir.listSync(recursive: true).whereType<File>()) {
            if (f.path.toLowerCase().endsWith('.mp3')) {
              // Extraer nombre y género (nombre de la carpeta padre)
              final fileName = f.uri.pathSegments.last;
              final parentFolder = f.parent.uri.pathSegments.last;

              fullCatalog.add({
                "name": fileName.replaceAll('.mp3', ''),
                "genre": parentFolder,
                "path": f.path, // Ruta absoluta para el reproductor
              });
            }
          }
        }
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(fullCatalog))
          ..close();
        return;
      }

      if (request.method == 'GET' && path == '/api/download') {
        final targetPath = _resolvePath(query['file'] ?? '');
        final file = File(targetPath);
        if (file.existsSync()) {
          final isAudio = targetPath.toLowerCase().endsWith('.mp3');
          request.response
            ..headers.contentType = isAudio
                ? ContentType('audio', 'mpeg')
                : ContentType('text', 'plain')
            ..headers.add('content-length', file.lengthSync().toString())
            ..addStream(file.openRead()).then((_) => request.response.close());
        } else {
          request.response
            ..statusCode = 404
            ..close();
        }
        return;
      }

      if (request.method == 'POST' && path == '/api/upload') {
        final bool lanMobile = Platform.isAndroid || Platform.isIOS;
        if (lanUploadBlocked(
          mobile: lanMobile,
          storageGranted: lanMobile ? await _lanStorageGranted() : true,
        )) {
          request.response
            ..statusCode = lanUploadHttpStatus(
              mobile: true,
              denied: true,
              writeFailed: false,
            )
            ..write('permiso de almacenamiento')
            ..close();
          return;
        }
        var writeFailed = false;
        Object? writeError;
        final targetDir = _resolvePath(query['dir'] ?? 'ROOT');
        final relFolder = query['rel'] ?? '';

        String finalDirPath = targetDir;
        if (relFolder.isNotEmpty) {
          finalDirPath =
              '$targetDir${Platform.pathSeparator}${relFolder.replaceAll('\\', '/').replaceAll('/', Platform.pathSeparator)}';
        }

        final dir = Directory(finalDirPath);
        try {
          if (!dir.existsSync()) dir.createSync(recursive: true);
        } catch (e) {
          if (lanMobile) {
            request.response
              ..statusCode = lanUploadHttpStatus(
                mobile: true,
                denied: false,
                writeFailed: true,
              )
              ..write('escritura: $e')
              ..close();
            return;
          }
          rethrow;
        }

        final boundary = request.headers.contentType?.parameters['boundary'];
        // 3.1.17: mp3 recibidos; su BPM llega en `?bpm=` de la URL.
        final List<String> receivedMp3 = <String>[];
        if (boundary != null) {
          final transformer = MimeMultipartTransformer(boundary);
          final bodyStream = request.cast<List<int>>().transform(transformer);

          await for (final part in bodyStream) {
            final contentDisposition = part.headers['content-disposition'];
            if (contentDisposition != null &&
                contentDisposition.contains('filename=')) {
              final match = RegExp(
                r'filename="([^"]+)"',
              ).firstMatch(contentDisposition);
              if (match != null) {
                try {
                  final List<String> present = await dir
                      .list(followLinks: false)
                      .where((e) => e is File)
                      .map((e) => lanBaseName(e.path))
                      .toList();
                  final savePath =
                      '${dir.path}${Platform.pathSeparator}${lanResolveName(present, match.group(1)!)}';
                  if (savePath.toLowerCase().endsWith('.lrc')) {
                    // 1.0.20+38: la letra confirmada gana; nunca vuelve a
                    // aproximada ([gmx_approx]).
                    final bytes = <int>[];
                    await for (final c in part) {
                      bytes.addAll(c);
                    }
                    final incoming = utf8.decode(bytes, allowMalformed: true);
                    final dest = File(savePath);
                    final existing = dest.existsSync()
                        ? await dest.readAsString().catchError((_) => '')
                        : null;
                    if (lrcSyncShouldReplace(
                      existing: existing,
                      incoming: incoming,
                      overwrite: query['ow'] != '0',
                    )) {
                      await dest.writeAsBytes(bytes);
                      approxLyricRevision.value++;
                    }
                    continue;
                  }
                  // 3.1.05: escritura atomica; un .part viejo se sobrescribe.
                  final File tmp = File('$savePath$lanPartSuffix');
                  final sink = tmp.openWrite();
                  await part.pipe(sink);
                  await sink.close();
                  await tmp.rename(savePath);
                  if (savePath.toLowerCase().endsWith('.mp3')) {
                    receivedMp3.add(savePath);
                  }
                } catch (e) {
                  if (lanMobile) {
                    writeFailed = true;
                    writeError = e;
                    break;
                  }
                  rethrow;
                }
              }
            }
          }
          if (writeFailed && lanMobile) {
            request.response
              ..statusCode = lanUploadHttpStatus(
                mobile: true,
                denied: false,
                writeFailed: true,
              )
              ..write('escritura: $writeError')
              ..close();
            return;
          }
          request.response
            ..statusCode = 200
            ..write("OK")
            ..close();
          if (receivedMp3.isNotEmpty && query['bpm'] != null) {
            await lanSaveIncomingBpm(<String, Object?>{
              for (final String p in receivedMp3) p: query['bpm'],
            });
          }
          _scanLocalMusicFolders();
          if (_selectedLocalPath != null) {
            _loadFilesInFolder(_selectedLocalPath!);
          }
          return;
        }
      }

      if (request.method == 'DELETE' && path == '/api/delete') {
        final targetPath = _resolvePath(query['target'] ?? '');
        final type = query['type'];

        if (type == 'file') {
          final file = File(targetPath);
          if (file.existsSync()) file.deleteSync();
        } else if (type == 'folder') {
          final dir = Directory(targetPath);
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        }

        request.response
          ..statusCode = 200
          ..write(jsonEncode({"status": "DELETED"}))
          ..close();
        _scanLocalMusicFolders();
        return;
      }

      if (request.method == 'DELETE' && path == '/api/wipe') {
        final baseMusicPath = _getBaseMusicPath();
        final rootDir = Directory(baseMusicPath);

        if (rootDir.existsSync()) {
          rootDir.deleteSync(recursive: true);
          rootDir.createSync(recursive: true);
        }

        request.response
          ..statusCode = 200
          ..write(jsonEncode({"status": "WIPED_CLEAN"}))
          ..close();
        _scanLocalMusicFolders();
        return;
      }

      if (request.method == 'POST' && path == '/api/sync_complete') {
        request.response
          ..statusCode = 200
          ..write("OK")
          ..close();
        Future.microtask(() {
          _scanLocalMusicFolders();
          if (_selectedLocalPath != null) {
            _loadFilesInFolder(_selectedLocalPath!);
          }
          if (mounted) _showDidacticSuccessModal();
        });
        return;
      }

      // 🎤 KARAOKE WEB INTERFACE (FRONT-END SPA)
      if (request.method == 'GET' && path == '/karaoke') {
        const String htmlPayload = r'''
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>GatoMix Karaoke</title>
  <style>
    :root { --bg: #0a0a0a; --neon: #39ff14; --dark: #1a1a1a; --text: #fff; --subtext: #888; }
    body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; margin: 0; padding: 20px; }
    h2 { text-align: center; margin-bottom: 25px; display: flex; align-items: center; justify-content: center; gap: 10px; }
    
    .input-group { margin-bottom: 15px; }
    input { width: 100%; padding: 16px; background: var(--dark); color: var(--neon); border: 1px solid #333; border-radius: 12px; font-size: 16px; box-sizing: border-box; outline: none; transition: border-color 0.2s; }
    input:focus { border-color: var(--neon); }
    input::placeholder { color: #555; }
    
    .catalog-container { background: var(--dark); border-radius: 12px; border: 1px solid #333; overflow: hidden; display: flex; flex-direction: column; margin-bottom: 20px; }
    .search-box { padding: 15px; border-bottom: 1px solid #333; background: #111; }
    .search-box input { padding: 12px; border-radius: 8px; background: #000; border: 1px solid #222; }
    
    .song-list { max-height: 40vh; overflow-y: auto; padding: 5px; }
    .song-list::-webkit-scrollbar { width: 6px; }
    .song-list::-webkit-scrollbar-thumb { background: #333; border-radius: 4px; }
    
    .song-item { padding: 15px; border-bottom: 1px solid #222; cursor: pointer; transition: background 0.2s; border-radius: 8px; }
    .song-item:active { background: #222; }
    .song-item.selected { background: rgba(57, 255, 20, 0.1); border: 1px solid var(--neon); }
    .song-title { font-weight: bold; font-size: 15px; margin-bottom: 4px; }
    .song-genre { font-size: 12px; color: var(--subtext); text-transform: uppercase; letter-spacing: 1px; }
    .empty-state { text-align: center; padding: 30px; color: var(--subtext); }

    button { width: 100%; padding: 18px; border: none; border-radius: 12px; font-size: 16px; font-weight: bold; cursor: pointer; transition: transform 0.1s; }
    button:active { transform: scale(0.98); }
    .btn-primary { background: var(--neon); color: #000; margin-bottom: 15px; box-shadow: 0 4px 15px rgba(57, 255, 20, 0.2); }
    .btn-primary:disabled { background: #333; color: #666; box-shadow: none; cursor: not-allowed; }
    .btn-secondary { background: transparent; border: 1px solid #444; color: #aaa; }
    
    .votes { display: flex; justify-content: space-between; margin-top: 20px; gap: 10px; }
    .vote-btn { flex: 1; background: var(--dark); font-size: 28px; padding: 15px 0; border: 1px solid #333; border-radius: 12px; }
  </style>
</head>
<body>
  <div id="catalogView">
  <h2>🎤 Selecciona tu pista</h2>
  
  <div class="input-group">
    <input type="text" id="userName" placeholder="¿Quién canta? (Tu nombre)" oninput="validateForm()">
  </div>

  <div class="catalog-container">
    <div class="search-box">
      <input type="text" id="searchInput" placeholder="🔍 Buscar por canción, artista o género..." oninput="filterCatalog()">
    </div>
    <div class="song-list" id="resultsList">
      <div class="empty-state">Cargando biblioteca...</div>
    </div>
  </div>

  <button class="btn-primary" id="sendBtn" onclick="sendToQueue()" disabled>ENVIAR A LA COLA</button>
  <button class="btn-secondary" onclick="requestWishlist()">¿No está tu canción? Pídela aquí</button>
  </div>

  <div id="voteView" style="display:none;">
    <h2>CALIFICACIÓN</h2>
    <p id="voteSinger" style="text-align:center;color:#00ffff;font-weight:bold;"></p>
    <p id="voteTimer" style="text-align:center;color:#39ff14;font-size:42px;margin:10px 0;"></p>
    <div class="votes">
      <button class="vote-btn" onclick="vote('👏')">👏</button>
      <button class="vote-btn" onclick="vote('🔥')">🔥</button>
      <button class="vote-btn" onclick="vote('💩')">💩</button>
    </div>
  </div>

  <script>
    let catalog = [];
    let selectedSongPath = null;

    // Inicialización
    fetch('/api/catalog')
      .then(r => r.json())
      .then(data => {
        catalog = data;
        renderList(catalog);
      })
      .catch(e => {
        document.getElementById('resultsList').innerHTML = '<div class="empty-state">Error conectando con la base de datos.</div>';
      });

    // Motor de búsqueda en memoria
    function filterCatalog() {
      const q = document.getElementById('searchInput').value.toLowerCase();
      const filtered = catalog.filter(s => 
        s.name.toLowerCase().includes(q) || 
        s.genre.toLowerCase().includes(q)
      );
      renderList(filtered);
    }

    // Renderizado del DOM
    function renderList(items) {
      const list = document.getElementById('resultsList');
      if (items.length === 0) {
        list.innerHTML = '<div class="empty-state">No se encontraron resultados.</div>';
        return;
      }
      
      list.innerHTML = items.map((song, index) => `
        <div class="song-item ${song.path === selectedSongPath ? 'selected' : ''}" onclick="selectSong('${encodeURIComponent(song.path)}')">
          <div class="song-title">${song.name}</div>
          <div class="song-genre">📂 ${song.genre}</div>
        </div>
      `).join('');
    }

    // Lógica de Selección
    function selectSong(encodedPath) {
      selectedSongPath = decodeURIComponent(encodedPath);
      filterCatalog(); // Re-render para aplicar el estilo 'selected'
      validateForm();
    }

    // Validador de formulario reactivo
    function validateForm() {
      const user = document.getElementById('userName').value.trim();
      const btn = document.getElementById('sendBtn');
      if (user.length > 0 && selectedSongPath) {
        btn.disabled = false;
      } else {
        btn.disabled = true;
      }
    }

    // Acciones de Red
    function sendToQueue() {
      const user = document.getElementById('userName').value.trim();
      if(!user || !selectedSongPath) return;
      
      fetch('/api/queue/add?user=' + encodeURIComponent(user) + '&song=' + encodeURIComponent(selectedSongPath), { method: 'POST' })
        .then(() => {
          alert('¡Agregada a la cola!');
          selectedSongPath = null;
          document.getElementById('searchInput').value = '';
          filterCatalog();
          validateForm();
        })
        .catch(e => alert('Error de conexión.'));
    }

    function requestWishlist() {
      const requested = prompt("¿Qué canción o artista te gustaría cantar la próxima vez?");
      if(requested && requested.trim().length > 0) {
        fetch('/api/wishlist?song=' + encodeURIComponent(requested.trim()), { method: 'POST' })
          .then(() => alert('¡Anotado! La descargaremos para la próxima.'))
          .catch(e => alert('Error de conexión.'));
      }
    }

    function vote(type) {
      fetch('/api/vote?type=' + encodeURIComponent(type), { method: 'POST' });
    }

    function applyPhase(state) {
      const voting = state.phase === 'voting';
      document.getElementById('catalogView').style.display = voting ? 'none' : 'block';
      document.getElementById('voteView').style.display = voting ? 'block' : 'none';
      if (!voting) return;
      document.getElementById('voteSinger').textContent =
        (state.singer || 'Cantante') + ' — ' + (state.track || '');
      document.getElementById('voteTimer').textContent = (state.seconds_left || 0) + 's';
    }

    function pollStage() {
      fetch('/api/karaoke/state')
        .then(r => r.json())
        .then(applyPhase)
        .catch(() => {});
    }
    pollStage();
    setInterval(pollStage, 800);
  </script>
</body>
</html>
''';

        request.response
          ..headers.contentType = ContentType.html
          ..write(htmlPayload)
          ..close();
        return;
      }

      // 🎤 ENDPOINTS DEL KARAOKE CONECTADOS AL SINGLETON
      if (request.method == 'POST' && path == '/api/queue/add') {
        final user = query['user'] ?? 'Anónimo';
        final song = query['song'] ?? '';
        if (song.isNotEmpty) KaraokeCore().addToQueue(user, song);
        request.response
          ..statusCode = 200
          ..write("OK")
          ..close();
        return;
      }

      if (request.method == 'POST' && path == '/api/vote') {
        final type = query['type'];
        if (type != null) KaraokeCore().addVote(type);
        request.response
          ..statusCode = 200
          ..write("OK")
          ..close();
        return;
      }

      if (request.method == 'GET' && path == '/api/karaoke/state') {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(KaraokeCore().publicState()))
          ..close();
        return;
      }

      // 📝 ENDPOINT: Persistencia de Wishlist
      if (request.method == 'POST' && path == '/api/wishlist') {
        final song = query['song'] ?? '';
        if (song.isNotEmpty) {
          try {
            final targetPath = _resolvePath('ReGenial');
            final wishlistFile = File(
              '$targetPath${Platform.pathSeparator}wishlist_pedidos.txt',
            );
            if (!wishlistFile.existsSync()) {
              wishlistFile.createSync(recursive: true);
            }

            final timestamp = DateTime.now().toString().split('.').first;
            wishlistFile.writeAsStringSync(
              '[$timestamp] - $song\n',
              mode: FileMode.append,
            );
          } catch (e) {
            debugPrint("🔴 Error escribiendo en wishlist: $e");
          }
        }
        request.response
          ..statusCode = 200
          ..write("OK")
          ..close();
        return;
      }

      request.response
        ..statusCode = 404
        ..close();
    } catch (e) {
      debugPrint("🔴 [REST API FATAL ERROR]: $e");
      request.response
        ..statusCode = 500
        ..close();
    }
  }

  // 3.1.18: el radar solo gira mientras hay un barrido activo (pasivo o
  // manual); entre barridos queda quieto y no pide cuadros.
  int _radarBusy = 0;

  void _radarSpin(bool on) {
    _radarBusy = on ? _radarBusy + 1 : (_radarBusy > 0 ? _radarBusy - 1 : 0);
    if (!mounted) return;
    if (_radarBusy > 0) {
      if (!_radarController.isAnimating) _radarController.repeat();
    } else {
      _radarController.stop();
    }
  }

  Future<void> _startNetworkSweeper() async {
    final subnetParts = _localIp.split('.');
    if (subnetParts.length != 4) return;
    final subnet = '${subnetParts[0]}.${subnetParts[1]}.${subnetParts[2]}';

    while (mounted && _isSweeping) {
      _radarSpin(true);
        // 3.1.05: primero el ultimo equipo que respondio (400 ms).
        final String? lastPeer = _lanLastPeerIp;
        if (lastPeer != null && lastPeer != _localIp) {
          await _probeDeviceHttp(
            lastPeer,
            timeout: const Duration(milliseconds: 400),
          );
        }
      for (int i = 1; i <= 254; i += 50) {
        if (!mounted) break;
        List<Future<void>> batch = [];

        for (int j = 0; j < 50; j++) {
          int target = i + j;
          if (target > 254) break;
          final targetIp = '$subnet.$target';
          if (targetIp == _localIp) continue;
          batch.add(_probeDeviceHttp(targetIp));
        }

        await Future.wait(batch);
      }
      _radarSpin(false);
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _forceNetworkSweep() async {
    if (_isManualSweeping) return;
    setState(() {
      _isManualSweeping = true;
      _currentLog = "📡 Disparando escaneo de radar (Batches de 50 nodos)...";
    });

    _radarSpin(true);
    final subnetParts = _localIp.split('.');
    if (subnetParts.length == 4) {
      final subnet = '${subnetParts[0]}.${subnetParts[1]}.${subnetParts[2]}';
      // 3.1.05: primero el ultimo equipo que respondio (400 ms).
      final String? lastPeer = _lanLastPeerIp;
      if (lastPeer != null && lastPeer != _localIp) {
        await _probeDeviceHttp(
          lastPeer,
          timeout: const Duration(milliseconds: 400),
        );
      }
      for (int i = 1; i <= 254; i += 50) {
        if (!mounted) break;
        List<Future<void>> batch = [];
        for (int j = 0; j < 50; j++) {
          int target = i + j;
          if (target > 254) break;
          final targetIp = '$subnet.$target';
          if (targetIp == _localIp) continue;
          batch.add(_probeDeviceHttp(targetIp));
        }
        await Future.wait(batch);
      }
    }

    _radarSpin(false);
    if (mounted) {
      setState(() {
        _isManualSweeping = false;
        _currentLog =
            "✅ Barrido de radar completado. Nodos activos: ${_discoveredDevices.length}";
      });
    }
  }

  Future<void> _probeDeviceHttp(
    String targetIp, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    try {
      final response = await http
          .get(Uri.parse('http://$targetIp:$_restPort/api/whoami'))
          .timeout(timeout);

      if (response.statusCode == 200) {
        _lanLastPeerIp = targetIp; // 3.1.05: fast-path de reconexion
        final data = jsonDecode(response.body);
        if (mounted && _discoveredDevices[targetIp] != data['name']) {
          setState(() => _discoveredDevices[targetIp] = data['name']);
        }
      }
    } catch (_) {}
  }

  void _promptManualConnection() {
    final ipController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Color(0xFF00FFFF)),
          borderRadius: BorderRadius.circular(8),
        ),
        title: const Text(
          "Conexión Manual REST",
          style: TextStyle(color: Color(0xFF00FFFF)),
        ),
        content: TextField(
          controller: ipController,
          style: const TextStyle(color: Colors.white, fontFamily: 'Consolas'),
          decoration: const InputDecoration(
            hintText: "Ej: 192.168.1.8",
            hintStyle: TextStyle(color: Colors.white24),
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              final ip = ipController.text.trim();
              if (ip.isNotEmpty) {
                Navigator.pop(ctx);
                setState(() {
                  _discoveredDevices[ip] = "Dispositivo Manual";
                  _selectedDeviceIp = ip;
                  _selectedDeviceName = "Dispositivo Manual";
                });
                _fetchRemoteDirectoryTree(ip);
                _probeDeviceHttp(ip);
              }
            },
            child: const Text("ENLAZAR"),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchRemoteDirectoryTree(String targetIp) async {
    setState(
      () => _currentLog = "📡 Solicitando árbol de directorios a $targetIp...",
    );
    try {
      final response = await http
          .get(Uri.parse('http://$targetIp:$_restPort/api/tree'))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(response.body);
        final folders = jsonList.map((e) => e.toString()).toList();
        if (mounted) {
          setState(() {
            folders.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
            _remoteFolderPaths = orderRemoteFolders(folders, mobile: false);
            _currentLog =
                "✅ Árbol remoto obtenido: ${folders.length} carpetas.";
            if (_selectedRemotePath == null) {
              final String? sel = defaultRemoteSelection(
                folders,
                mobile: _lanMobile,
              );
              if (sel != null) {
                _selectedRemotePath = sel;
                _fetchRemoteFiles(targetIp, sel);
              } else {
                _currentLog =
                    "⚠️ HTTP 200 OK: La app remota respondió, pero su carpeta Music está VACÍA o no diste permiso en pantalla.";
              }
            }
          });
        }
      } else {
        setState(
          () => _currentLog =
              "🔴 ERROR HTTP ${response.statusCode}: ${response.body}",
        );
      }
    } catch (e) {
      setState(() {
        _remoteFolderPaths = [];
        _selectedRemotePath = null;
        _currentLog = "🔴 TRACKER EXCEPTION (Tree): $e";
      });
    }
  }

  Future<void> _fetchRemoteFiles(String targetIp, String remotePath) async {
    setState(() {
      _currentRemoteFiles = [];
      _currentLog = "📡 Solicitando metadata estructurada de $remotePath...";
    });
    try {
      final response = await http
          .get(
            Uri.parse(
              'http://$targetIp:$_restPort/api/files?dir=${Uri.encodeComponent(remotePath)}',
            ),
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        // 🛠️ REFACTOR ESTRUCTURAL: Parseo del JSON de Alto Nivel
        final List<dynamic> jsonList = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            jsonList.sort(
              (a, b) => a['name'].toString().toLowerCase().compareTo(
                b['name'].toString().toLowerCase(),
              ),
            );
            _currentRemoteFiles = jsonList;
            _currentLog =
                "✅ ${jsonList.length} archivos obtenidos con metadata de $remotePath.";
          });
        }
      } else {
        setState(() => _currentLog = "🔴 ERROR HTTP ${response.statusCode}");
      }
    } catch (e) {
      setState(() => _currentLog = "🔴 TRACKER EXCEPTION (Files): $e");
    }
  }

  // 🛠️ CONTROLADORES CRUD LOCAL Y REMOTO
  void _deleteLocalFile(File file) {
    try {
      file.deleteSync();
      _loadFilesInFolder(_selectedLocalPath!);
      setState(() => _currentLog = "✅ Archivo local eliminado.");
    } catch (e) {
      setState(() => _currentLog = "🔴 Error al borrar local: $e");
    }
  }

  Future<void> _deleteRemoteFile(String fileName) async {
    if (_selectedDeviceIp == null || _selectedRemotePath == null) return;
    try {
      setState(
        () => _currentLog = "🗑️ Solicitando borrado remoto de $fileName...",
      );
      final response = await http
          .delete(
            Uri.parse(
              'http://$_selectedDeviceIp:$_restPort/api/delete?target=${Uri.encodeComponent("$_selectedRemotePath/$fileName")}&type=file',
            ),
          )
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        _fetchRemoteFiles(_selectedDeviceIp!, _selectedRemotePath!);
      }
    } catch (e) {
      setState(() => _currentLog = "🔴 ERROR de red en borrado: $e");
    }
  }

  void _promptWipeConfirmation() {
    if (_selectedDeviceIp == null) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A0505), // Tono alerta
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Colors.redAccent, width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        title: const Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.redAccent,
              size: 28,
            ),
            SizedBox(width: 10),
            Text(
              "WIPE & PUSH ATÓMICO",
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          "⚠️ ESTA ACCIÓN ES DESTRUCTIVA.\n\n"
          "Se aniquilará por completo el directorio Music del nodo [$_selectedDeviceName] "
          "y será reemplazado por un clon exacto de tu Carpeta Local Origen.\n\n"
          "¿Proceder con la sobreescritura total?",
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              "CANCELAR",
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _executeRemoteWipe();
            },
            child: const Text("ANIQUILAR Y REEMPLAZAR"),
          ),
        ],
      ),
    );
  }

  Future<void> _executeRemoteWipe() async {
    setState(() {
      _isTransferring = true;
      _currentLog = "☢️ EJECUTANDO HARD RESET DEL FILESYSTEM REMOTO...";
      // 🛠️ FIX 1: Purgar el estado de destino. Obliga al Push a ir a la RAÍZ (Music/)
      _selectedRemotePath = null;
    });

    try {
      final response = await http
          .delete(Uri.parse('http://$_selectedDeviceIp:$_restPort/api/wipe'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        setState(() {
          _currentLog = "✅ WIPE COMPLETADO. Iniciando clonación PUSH masiva...";
        });
        _isPushMode = true;
        _executeTransferJob(true);
      } else {
        setState(() {
          _isTransferring = false;
          _currentLog = "🔴 ERROR EN WIPE: Código ${response.statusCode}";
        });
      }
    } catch (e) {
      setState(() {
        _isTransferring = false;
        _currentLog = "🔴 FALLO DE RED EN WIPE: $e";
      });
    }
  }

  Future<void> _executeTransferJob(
    bool isDirectoryClone, {
    List<File>? onlyPush,
    List<String>? onlyPull,
  }) async {
    setState(() {
      _isTransferring = true;
      _cancelRequested = false;
      _transferProgress = 0.0;
      _currentFileIndex = 0;
      _successfulTransfers = 0;
      _skippedTransfers = 0;
      _existedTransfers = 0;
      _failedTransfers = 0;
      _lanFinalRed = false;
      _retryPush.clear();
      _retryPull.clear();
      _currentLog = "Iniciando Job REST (Evaluando metadatos y colisiones)...";
    });

    if (_isPushMode) {
      late final List<File> files;
      if (onlyPush != null) {
        files = List<File>.from(onlyPush);
      } else {
        Set<String> pushQueue = {};
        if (isDirectoryClone) {
          pushQueue.addAll(
            _getFilesRecursively(
              Directory(_selectedLocalPath!),
            ).map((f) => f.path),
          );
        } else {
          final Map<String, List<String>> dirNames = <String, List<String>>{};
          for (String path in _selectedFilesToTransfer) {
            pushQueue.add(path);
            if (path.toLowerCase().endsWith('.mp3')) {
              // 3.1.05: hermanos .lrc/.txt/_K sin distinguir mayusculas; nunca .part.
              final Directory parent = File(path).parent;
              if (!dirNames.containsKey(parent.path)) {
                List<String> names = <String>[];
                try {
                  names = await parent
                      .list(followLinks: false)
                      .where((e) => e is File)
                      .map((e) => lanBaseName(e.path))
                      .toList();
                } catch (_) {}
                dirNames[parent.path] = names;
              }
              for (final String name in lanCompanions(
                lanBaseName(path),
                dirNames[parent.path]!,
                withKaraoke: _sendKaraoke,
              )) {
                pushQueue.add('${parent.path}${Platform.pathSeparator}$name');
              }
            }
          }
        }
        files = pushQueue.map((p) => File(p)).toList();
      }
      setState(() => _totalFiles = files.length);

      final localBaseDirPath = Directory(_selectedLocalPath!).path;
      final rootFolderName = localBaseDirPath
          .split(Platform.pathSeparator)
          .last;

      final http.Client lanClient = http.Client(); // 3.1.05: Keep-Alive
      final Stopwatch lanWatch = Stopwatch()..start();
      int sentBytes = 0;
      for (int i = 0; i < files.length; i++) {
        if (_cancelRequested) break;
        final file = files[i];
        final fileName = file.uri.pathSegments.last;

        String relativeFolder = '';
        if (isDirectoryClone) {
          String relPath = file.path.replaceFirst(localBaseDirPath, '');
          if (relPath.startsWith(Platform.pathSeparator)) {
            relPath = relPath.substring(1);
          }
          int lastSeparator = relPath.lastIndexOf(Platform.pathSeparator);
          if (lastSeparator != -1) {
            relativeFolder = relPath.substring(0, lastSeparator);
          }

          relativeFolder = relativeFolder.isEmpty
              ? rootFolderName
              : '$rootFolderName${Platform.pathSeparator}$relativeFolder';
        }

        setState(() {
          _currentFileIndex = i + 1;
          if (!_lanMobile) {
            _transferProgress = (_currentFileIndex - 1) / _totalFiles;
          }
        });

        final bool isLrc = fileName.toLowerCase().endsWith('.lrc');
        if (lanRemoteHas(_currentRemoteFiles, fileName)) {
          if (!_overwriteExisting &&
              !isLrc &&
              lanAlreadyThere(_currentRemoteFiles, fileName, file.lengthSync())) {
            setState(() {
              _currentLog = "⏩ SALTADO (Ya existe): $fileName";
              if (_lanMobile) {
                _existedTransfers++;
                _transferProgress = lanTransferProgress(
                  mobile: true,
                  completed: i + 1,
                  total: _totalFiles,
                  jobFinished: false,
                  cancelled: false,
                );
              } else {
                _skippedTransfers++;
              }
            });
            continue;
          } else {
            setState(() => _currentLog = "🔄 REEMPLAZANDO: $fileName");
          }
        } else {
          setState(() => _currentLog = "⬆️ ENVIANDO: $fileName");
        }

        // 3.1.17: BPM resuelto en la URL (no en el multipart).
        final String bpmQuery = file.path.toLowerCase().endsWith('.mp3')
            ? lanBpmQuery(knownBpm(file.path))
            : '';
        if (_lanMobile) {
          try {
            final int code = await lanSendWithRetry(() async {
              final request = http.MultipartRequest(
                'POST',
                Uri.parse(
                  'http://$_selectedDeviceIp:$_restPort/api/upload?dir=${Uri.encodeComponent(_selectedRemotePath ?? "ROOT")}&rel=${Uri.encodeComponent(relativeFolder)}&ow=${_overwriteExisting ? 1 : 0}$bpmQuery',
                ),
              );
              request.files.add(
                await http.MultipartFile.fromPath('file', file.path),
              );
              final http.StreamedResponse response = await lanClient.send(request);
              final int status = response.statusCode;
              await response.stream.drain<void>();
              return status;
            });
            final LanFileResult result = lanClassifyStatus(code);
            if (result == LanFileResult.copied) {
              _successfulTransfers++;
              sentBytes += file.lengthSync();
            } else {
              _failedTransfers++;
              _retryPush.add(file);
              final String? notice = lanFailureNotice(code, fileName);
              if (notice != null) {
                _currentLog = notice;
                if (code == 403 || code == 500) {
                  if (!mounted) return;
                  ScaffoldMessenger.maybeOf(
                    context,
                  )?.showSnackBar(SnackBar(content: Text(notice)));
                }
              }
            }
          } catch (_) {
            _failedTransfers++;
            _retryPush.add(file);
            _currentLog = 'Falló el envío: $fileName';
          }
          if (mounted) {
            setState(() {
              _transferProgress = lanTransferProgress(
                mobile: true,
                completed: i + 1,
                total: _totalFiles,
                jobFinished: false,
                cancelled: false,
              );
            });
          }
        } else {
          // 3.1.07: reintento transparente (1 + 3, esperas 1/2/4 s) sobre el
          // mismo cliente; solo cuenta en Saltados/Fallos si fallan todos.
          try {
            final Uri uploadUri = Uri.parse(
              'http://$_selectedDeviceIp:$_restPort/api/upload?dir=${Uri.encodeComponent(_selectedRemotePath ?? "ROOT")}&rel=${Uri.encodeComponent(relativeFolder)}&ow=${_overwriteExisting ? 1 : 0}$bpmQuery',
            );
            final int code = await lanSendWithRetry(
              () => lanUploadOnce(lanClient, uploadUri, file.path),
            );
            if (code == 200) {
              _successfulTransfers++;
              sentBytes += file.lengthSync();
            } else {
              _skippedTransfers++;
            }
          } catch (_) {
            _skippedTransfers++;
          }
        }

        await Future.delayed(const Duration(milliseconds: 15));
      }
      lanClient.close();
      final double lanSecs = lanWatch.elapsedMilliseconds / 1000.0;
      final double lanMb = sentBytes / (1024 * 1024);
      debugPrint(
        "[LAN] Envio: ${lanMb.toStringAsFixed(1)} MB en ${lanSecs.toStringAsFixed(1)} s (${lanSecs > 0 ? (lanMb / lanSecs).toStringAsFixed(2) : '0'} MB/s)",
      );

      // 📡 WEBHOOK TRIGGER (Notificamos a la App destino que terminó)
      if (_successfulTransfers > 0 && !_cancelRequested) {
        try {
          await http
              .post(
                Uri.parse(
                  'http://$_selectedDeviceIp:$_restPort/api/sync_complete',
                ),
              )
              .timeout(const Duration(seconds: 5));
        } catch (e) {
          debugPrint("🔴 Error notificando finalización al remoto: $e");
        }
      }
    } else {
      final files = onlyPull != null
          ? <dynamic>[
              for (final String name in onlyPull)
                <String, dynamic>{'name': name},
            ]
          : _remoteToPull();
      setState(() => _totalFiles = files.length);

      final localDir = Directory(_selectedLocalPath!);
      final HttpClient client = HttpClient(); // 3.1.05: Keep-Alive
      // 3.1.17: BPM de `/api/files` por pista recibida (ruta local).
      final Map<String, Object?> pulledBpm = <String, Object?>{};
      List<String> localNames = <String>[];
      try {
        localNames = await localDir
            .list(followLinks: false)
            .where((e) => e is File)
            .map((e) => lanBaseName(e.path))
            .toList();
      } catch (_) {}
      for (int i = 0; i < files.length; i++) {
        if (_cancelRequested) break;
        final fileName = files[i]['name'];

        setState(() {
          _currentFileIndex = i + 1;
          if (!_lanMobile) {
            _transferProgress = (_currentFileIndex - 1) / _totalFiles;
          }
        });

        final dynamic remoteSize = (files[i] as Map)['size_bytes'];
        final saveFile = File(
          '${localDir.path}${Platform.pathSeparator}${lanResolveName(localNames, '$fileName')}',
        );

        final bool isLrc = '$fileName'.toLowerCase().endsWith('.lrc');
        if (saveFile.existsSync()) {
          if (!_overwriteExisting &&
              !isLrc &&
              (remoteSize == null || saveFile.lengthSync() == remoteSize)) {
            setState(() {
              _currentLog = "⏩ SALTADO (Ya existe): $fileName";
              if (_lanMobile) {
                _existedTransfers++;
                _transferProgress = lanTransferProgress(
                  mobile: true,
                  completed: i + 1,
                  total: _totalFiles,
                  jobFinished: false,
                  cancelled: false,
                );
              } else {
                _skippedTransfers++;
              }
            });
            continue;
          } else {
            setState(() => _currentLog = "🔄 REEMPLAZANDO: $fileName");
          }
        } else {
          setState(() => _currentLog = "⬇️ EXTRAYENDO: $fileName");
        }

        try {
          final request = await client.getUrl(
            Uri.parse(
              'http://$_selectedDeviceIp:$_restPort/api/download?file=${Uri.encodeComponent("$_selectedRemotePath/$fileName")}',
            ),
          );
          final response = await request.close();
          if (response.statusCode == 200 && isLrc) {
            final bytes = <int>[];
            await for (final c in response) {
              bytes.addAll(c);
            }
            final existing = saveFile.existsSync()
                ? await saveFile.readAsString().catchError((_) => '')
                : null;
            if (lrcSyncShouldReplace(
              existing: existing,
              incoming: utf8.decode(bytes, allowMalformed: true),
              overwrite: _overwriteExisting,
            )) {
              await saveFile.writeAsBytes(bytes);
              approxLyricRevision.value++;
              _successfulTransfers++;
            } else if (_lanMobile) {
              _existedTransfers++;
            } else {
              _skippedTransfers++;
            }
          } else if (response.statusCode == 200) {
            // 3.1.05: escritura atomica (.part y rename).
            final File tmp = File('${saveFile.path}$lanPartSuffix');
            await response.pipe(tmp.openWrite());
            await tmp.rename(saveFile.path);
            _successfulTransfers++;
            final Object? remoteBpm = (files[i] as Map)['bpm'];
            if (remoteBpm != null) pulledBpm[saveFile.path] = remoteBpm;
          } else if (_lanMobile) {
            _failedTransfers++;
            _retryPull.add('$fileName');
            final String? notice = lanFailureNotice(
              response.statusCode,
              '$fileName',
            );
            if (notice != null) {
              _currentLog = notice;
              if (response.statusCode == 403 || response.statusCode == 500) {
                if (!mounted) return;
                ScaffoldMessenger.maybeOf(
                  context,
                )?.showSnackBar(SnackBar(content: Text(notice)));
              }
            }
          } else {
            _skippedTransfers++;
          }
        } catch (_) {
          if (_lanMobile) {
            _failedTransfers++;
            _retryPull.add('$fileName');
            _currentLog = 'Falló el envío: $fileName';
          } else {
            _skippedTransfers++;
          }
        }

        if (_lanMobile && mounted) {
          setState(() {
            _transferProgress = lanTransferProgress(
              mobile: true,
              completed: i + 1,
              total: _totalFiles,
              jobFinished: false,
              cancelled: false,
            );
          });
        }

        await Future.delayed(const Duration(milliseconds: 15));
      }
      client.close();
      if (pulledBpm.isNotEmpty) await lanSaveIncomingBpm(pulledBpm);
      _scanLocalMusicFolders();
      _loadFilesInFolder(_selectedLocalPath!);
    }

    setState(() {
      _transferProgress = _lanMobile
          ? lanTransferProgress(
              mobile: true,
              completed: _currentFileIndex,
              total: _totalFiles,
              jobFinished: true,
              cancelled: _cancelRequested,
            )
          : 1.0;
      _isTransferring = false;
      _lanFinalRed = lanFinalIsRed(mobile: _lanMobile, failed: _failedTransfers);
      _currentLog = lanFinalLog(
        mobile: _lanMobile,
        copied: _successfulTransfers,
        existed: _existedTransfers,
        failed: _failedTransfers,
        skippedMixed: _skippedTransfers,
      );
      _selectedFilesToTransfer.clear();
    });

    if (_selectedDeviceIp != null) {
      _fetchRemoteDirectoryTree(_selectedDeviceIp!);
    }
  }

  /// 3.1.15: lo que se extrae del remoto, con o sin los _K.mp3.
  List<dynamic> _remoteToPull() => _currentRemoteFiles
      .where((dynamic r) => _sendKaraoke || !lanIsKaraokeMp3('${r['name']}'))
      .toList();

  void _retryFailed() {
    final List<File> push = List<File>.from(_retryPush);
    final List<String> pull = List<String>.from(_retryPull);
    if (push.isNotEmpty) {
      _executeTransferJob(false, onlyPush: push);
    } else if (pull.isNotEmpty) {
      _executeTransferJob(false, onlyPull: pull);
    }
  }

  void _promptTransferConfirmation() {
    if (_selectedDeviceIp == null ||
        _selectedRemotePath == null ||
        _selectedLocalPath == null) {
      return;
    }

    bool isDirectoryClone = _selectedFilesToTransfer.isEmpty;
    int targetFilesCount = _isPushMode
        ? (isDirectoryClone
              ? _getFilesRecursively(Directory(_selectedLocalPath!)).length
              : _selectedFilesToTransfer.length)
        : _remoteToPull().length;

    if (targetFilesCount == 0) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: _isPushMode
                ? const Color(0xFF39FF14)
                : const Color(0xFF00FFFF),
          ),
        ),
        title: Text(
          _isPushMode ? "INICIAR PUSH" : "INICIAR PULL",
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          "Procesando ~$targetFilesCount pistas vía API REST.\nHost: $_selectedDeviceName",
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _isPushMode
                  ? const Color(0xFF39FF14)
                  : const Color(0xFF00FFFF),
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _executeTransferJob(isDirectoryClone);
            },
            child: const Text("AUTORIZAR"),
          ),
        ],
      ),
    );
  }

  Widget _buildTransferOverlay() {
    if (!_isTransferring &&
        _transferProgress == 0.0 &&
        _successfulTransfers == 0 &&
        _skippedTransfers == 0 &&
        _existedTransfers == 0 &&
        _failedTransfers == 0) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.90),
        child: Center(
          child: Container(
            width: 400,
            padding: const EdgeInsets.all(25),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0A0A),
              border: Border.all(
                color: _isPushMode
                    ? const Color(0xFF39FF14)
                    : const Color(0xFF00FFFF),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _isTransferring
                      ? "REST I/O EN PROGRESO"
                      : "OPERACIÓN FINALIZADA",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  _currentLog,
                  style: TextStyle(
                    color: _lanFinalRed
                        ? Colors.redAccent
                        : (_isPushMode
                              ? const Color(0xFF39FF14)
                              : const Color(0xFF00FFFF)),
                    fontFamily: 'Consolas',
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  value: _transferProgress,
                  color: _isPushMode
                      ? const Color(0xFF39FF14)
                      : const Color(0xFF00FFFF),
                ),
                const SizedBox(height: 25),
                if (_isTransferring)
                  ElevatedButton(
                    onPressed: () => setState(() => _cancelRequested = true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                    ),
                    child: const Text("KILL SWITCH"),
                  )
                else
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_lanMobile &&
                          (_retryPush.isNotEmpty || _retryPull.isNotEmpty))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ElevatedButton(
                            onPressed: _retryFailed,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(48, 48),
                            ),
                            child: const Text(
                              'Reintentar fallidos',
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                        ),
                      ElevatedButton(
                        onPressed: () => setState(() {
                          _transferProgress = 0.0;
                          _successfulTransfers = 0;
                          _skippedTransfers = 0;
                          _existedTransfers = 0;
                          _failedTransfers = 0;
                          _lanFinalRed = false;
                          _retryPush.clear();
                          _retryPull.clear();
                        }),
                        child: const Text("CERRAR TERMINAL"),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLocalTree(List<String> visibleLocalPaths, String basePath) {
    return Material(
      color: const Color(0xFF0A0A0A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            color: Colors.black,
            child: const Text(
              "ORIGEN (Local)",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: visibleLocalPaths.length,
              itemBuilder: (context, index) {
                final path = visibleLocalPaths[index];
                final isSelected = _selectedLocalPath == path;
                String rel = path.replaceFirst(basePath, '');
                if (rel.startsWith(Platform.pathSeparator)) {
                  rel = rel.substring(1);
                }
                final depth = rel.isEmpty
                    ? 0
                    : rel.split(Platform.pathSeparator).length - 1;
                final hasChildren = _localFolderPaths.any(
                  (p) =>
                      p.startsWith(path + Platform.pathSeparator) && p != path,
                );
                final isExpanded = _expandedLocalPaths.contains(path);

                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -4),
                  contentPadding: EdgeInsets.only(
                    left: 10.0 + (depth * 15.0),
                    right: 10.0,
                  ),
                  tileColor: isSelected
                      ? const Color(0xFF00FFFF).withValues(alpha: 0.1)
                      : null,
                  leading: Icon(
                    hasChildren
                        ? (isExpanded ? Icons.folder_open : Icons.folder)
                        : Icons.folder,
                    color: isSelected
                        ? const Color(0xFF00FFFF)
                        : Colors.white38,
                    size: 18,
                  ),
                  title: Text(
                    path.split(Platform.pathSeparator).last,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                  ),
                  onTap: () {
                    setState(() {
                      if (hasChildren) {
                        isExpanded
                            ? _expandedLocalPaths.remove(path)
                            : _expandedLocalPaths.add(path);
                      }
                      _loadFilesInFolder(path);
                    });
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // 🛠️ REFACTOR ESTRUCTURAL: Explorador Local Avanzado (Metadata + Menú Contextual)
  Widget _buildLocalFiles() {
    return Material(
      color: const Color(0xFF101010),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(5),
            color: const Color(0xFF1A1A1A),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "${_selectedFilesToTransfer.length} seleccionados",
                  style: const TextStyle(
                    color: Color(0xFF00FFFF),
                    fontSize: 10,
                  ),
                ),
                TextButton(
                  onPressed: _toggleSelectAllFiles,
                  child: const Text(
                    "Marcar Todo",
                    style: TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _currentLocalFiles.length,
              itemBuilder: (context, index) {
                final file = _currentLocalFiles[index];
                final isSelected = _selectedFilesToTransfer.contains(file.path);

                final size = _formatSize(file.lengthSync());
                final date = _formatDate(
                  file.lastModifiedSync().millisecondsSinceEpoch,
                );

                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: 2),
                  leading: Checkbox(
                    value: isSelected,
                    activeColor: const Color(0xFF00FFFF),
                    onChanged: (v) => setState(
                      () => v == true
                          ? _selectedFilesToTransfer.add(file.path)
                          : _selectedFilesToTransfer.remove(file.path),
                    ),
                  ),
                  title: Text(
                    file.uri.pathSegments.last,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    "$date  •  $size",
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(
                      Icons.more_vert,
                      color: Colors.white54,
                      size: 18,
                    ),
                    color: const Color(0xFF1A1A1A),
                    onSelected: (value) {
                      if (value == 'delete') _deleteLocalFile(file);
                    },
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<String>>[
                          const PopupMenuItem<String>(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                  size: 18,
                                ),
                                SizedBox(width: 10),
                                Text(
                                  "Eliminar",
                                  style: TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                        ],
                  ),
                  onTap: () => setState(
                    () => isSelected
                        ? _selectedFilesToTransfer.remove(file.path)
                        : _selectedFilesToTransfer.add(file.path),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteTree(List<String> visibleRemotePaths) {
    if (_selectedDeviceIp == null) {
      return Material(
        color: const Color(0xFF0A0A0A),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              color: Colors.black,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "NODOS REST",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isManualSweeping)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            color: Color(0xFF39FF14),
                            strokeWidth: 2,
                          ),
                        )
                      else
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(
                            Icons.search,
                            color: Color(0xFF39FF14),
                            size: 18,
                          ),
                          tooltip: "Radar: Escaneo Rápido de Red",
                          onPressed: _forceNetworkSweep,
                        ),
                      const SizedBox(width: 12),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(
                          Icons.add_link,
                          color: Color(0xFF00FFFF),
                          size: 18,
                        ),
                        tooltip: "Conexión Manual",
                        onPressed: _promptManualConnection,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _discoveredDevices.length,
                itemBuilder: (context, index) {
                  final ip = _discoveredDevices.keys.elementAt(index);
                  final name = _discoveredDevices[ip]!;
                  return ListTile(
                    leading: const Icon(
                      Icons.computer,
                      color: Color(0xFF39FF14),
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    subtitle: Text(
                      ip,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                    onTap: () => setState(() {
                      _selectedDeviceIp = ip;
                      _selectedDeviceName = name;
                      _fetchRemoteDirectoryTree(ip);
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

    return Material(
      color: const Color(0xFF0A0A0A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            color: Colors.black,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => setState(() {
                    _selectedDeviceIp = null;
                    _selectedRemotePath = null;
                    _currentRemoteFiles.clear();
                  }),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "DESTINO",
                      style: TextStyle(color: Colors.white, fontSize: 10),
                    ),
                    Text(
                      _selectedDeviceName!,
                      style: const TextStyle(
                        color: Color(0xFF39FF14),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: visibleRemotePaths.length,
              itemBuilder: (context, index) {
                final path = visibleRemotePaths[index];
                final isSelected = _selectedRemotePath == path;
                final depth = path.split('/').length - 1;
                final hasChildren = _remoteFolderPaths.any(
                  (p) => p.startsWith('$path/'),
                );
                final isExpanded = _expandedRemotePaths.contains(path);

                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -4),
                  contentPadding: EdgeInsets.only(
                    left: 10.0 + (depth * 15.0),
                    right: 10.0,
                  ),
                  tileColor: isSelected
                      ? const Color(0xFF39FF14).withValues(alpha: 0.1)
                      : null,
                  leading: Icon(
                    hasChildren
                        ? (isExpanded ? Icons.folder_open : Icons.folder)
                        : Icons.folder,
                    color: isSelected
                        ? const Color(0xFF39FF14)
                        : Colors.white38,
                    size: 18,
                  ),
                  title: Text(
                    lanRemoteLabel(path),
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                  ),
                  onTap: () {
                    setState(() {
                      if (hasChildren) {
                        isExpanded
                            ? _expandedRemotePaths.remove(path)
                            : _expandedRemotePaths.add(path);
                      }
                      _selectedRemotePath = path;
                    });
                    _fetchRemoteFiles(_selectedDeviceIp!, path);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // 🛠️ REFACTOR ESTRUCTURAL: Explorador Remoto Avanzado (JSON + Menú Contextual)
  Widget _buildRemoteFiles() {
    return Material(
      color: const Color(0xFF101010),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF1A1A1A),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "${_currentRemoteFiles.length} remotos",
                  style: const TextStyle(
                    color: Color(0xFF39FF14),
                    fontSize: 10,
                  ),
                ),
                // Botón Auxiliar de Wipe Integrado en la Vista Remota
                if (_selectedDeviceIp != null)
                  InkWell(
                    onTap: _promptWipeConfirmation,
                    child: const Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.redAccent,
                          size: 14,
                        ),
                        SizedBox(width: 4),
                        Text(
                          "Wipe Device",
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _currentRemoteFiles.length,
              itemBuilder: (context, index) {
                final fileMeta = _currentRemoteFiles[index];
                final fileName = fileMeta['name'];
                final size = _formatSize(fileMeta['size_bytes']);
                final date = _formatDate(fileMeta['modified_ms']);

                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: 2),
                  leading: const Icon(
                    Icons.audiotrack,
                    color: Color(0xFF39FF14),
                    size: 20,
                  ),
                  title: Text(
                    fileName,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    "$date  •  $size",
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(
                      Icons.more_vert,
                      color: Colors.white54,
                      size: 18,
                    ),
                    color: const Color(0xFF1A1A1A),
                    onSelected: (value) {
                      if (value == 'delete') _deleteRemoteFile(fileName);
                    },
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<String>>[
                          const PopupMenuItem<String>(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                  size: 18,
                                ),
                                SizedBox(width: 10),
                                Text(
                                  "Eliminar Remoto",
                                  style: TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                        ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final basePath = _getBaseMusicPath();

    List<String> visibleLocalPaths = [];
    for (String path in _localFolderPaths) {
      String rel = path.replaceFirst(basePath, '');
      if (rel.startsWith(Platform.pathSeparator)) rel = rel.substring(1);
      List<String> parts = rel.split(Platform.pathSeparator);
      if (parts.length <= 1) {
        visibleLocalPaths.add(path);
      } else {
        bool allExpanded = true;
        String cp = basePath;
        for (int i = 0; i < parts.length - 1; i++) {
          cp += Platform.pathSeparator + parts[i];
          if (!_expandedLocalPaths.contains(cp)) {
            allExpanded = false;
            break;
          }
        }
        if (allExpanded) visibleLocalPaths.add(path);
      }
    }

    List<String> visibleRemotePaths = [];
    for (String path in _remoteFolderPaths) {
      List<String> parts = path.split('/');
      if (parts.length <= 1) {
        visibleRemotePaths.add(path);
      } else {
        bool allExpanded = true;
        String cp = '';
        for (int i = 0; i < parts.length - 1; i++) {
          cp += (i == 0 ? '' : '/') + parts[i];
          if (!_expandedRemotePaths.contains(cp)) {
            allExpanded = false;
            break;
          }
        }
        if (allExpanded) visibleRemotePaths.add(path);
      }
    }
    visibleRemotePaths = withMusicRootFirst(
      visibleRemotePaths,
      mobile: _lanMobile,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobile = constraints.maxWidth < 850;
        Widget headerTelemetry = Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF050505),
            border: Border(
              bottom: BorderSide(
                color: const Color(0xFF00FFFF).withValues(alpha: 0.3),
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  RotationTransition(
                    turns: _radarController,
                    child: const Icon(
                      Icons.radar,
                      color: Color(0xFF00FFFF),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "RED P2P REST",
                        style: TextStyle(
                          color: Color(0xFF00FFFF),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        "$_localIp | Nodos: ${_discoveredDevices.length}",
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (!isMobile)
                Row(
                  children: [
                    const Text(
                      "Sobrescribir",
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    Switch(
                      value: _overwriteExisting,
                      activeThumbColor: const Color(0xFFFF007F),
                      onChanged: _isTransferring
                          ? null
                          : (v) => setState(() => _overwriteExisting = v),
                    ),
                  ],
                ),
            ],
          ),
        );

        return Stack(
          children: [
            Column(
              children: [
                headerTelemetry,
                Container(
                  color: const Color(0xFF101010),
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ChoiceChip(
                        selectedColor: const Color(
                          0xFF39FF14,
                        ).withValues(alpha: 0.2),
                        backgroundColor: Colors.black,
                        side: BorderSide(
                          color: _isPushMode
                              ? const Color(0xFF39FF14)
                              : Colors.white10,
                        ),
                        label: const Text(
                          "ENVIAR PUSH",
                          style: TextStyle(color: Colors.white, fontSize: 11),
                        ),
                        selected: _isPushMode,
                        onSelected: (v) => setState(() => _isPushMode = true),
                      ),
                      const SizedBox(width: 10),
                      ChoiceChip(
                        selectedColor: const Color(
                          0xFF00FFFF,
                        ).withValues(alpha: 0.2),
                        backgroundColor: Colors.black,
                        side: BorderSide(
                          color: !_isPushMode
                              ? const Color(0xFF00FFFF)
                              : Colors.white10,
                        ),
                        label: const Text(
                          "EXTRAER PULL",
                          style: TextStyle(color: Colors.white, fontSize: 11),
                        ),
                        selected: !_isPushMode,
                        onSelected: (v) => setState(() => _isPushMode = false),
                      ),
                      const SizedBox(width: 10),
                      // 3.1.15: transferir con o sin las pistas karaoke (_K.mp3).
                      FilterChip(
                        selectedColor: const Color(
                          0xFFFF00FF,
                        ).withValues(alpha: 0.2),
                        backgroundColor: Colors.black,
                        label: const Text(
                          "CON _K",
                          style: TextStyle(color: Colors.white, fontSize: 11),
                        ),
                        selected: _sendKaraoke,
                        onSelected: _isTransferring
                            ? null
                            : (v) => setState(() => _sendKaraoke = v),
                      ),
                      const SizedBox(width: 25),
                      // 🛠️ BOTÓN DE WIPE RÁPIDO
                      ElevatedButton.icon(
                        onPressed: _selectedDeviceIp != null && !_isTransferring
                            ? _promptWipeConfirmation
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(color: Colors.redAccent),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        icon: const Icon(Icons.delete_sweep, size: 16),
                        label: const Text(
                          "WIPE & PUSH",
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: isMobile
                      ? DefaultTabController(
                          length: 2,
                          child: Column(
                            children: [
                              const TabBar(
                                labelColor: Colors.white,
                                unselectedLabelColor: Colors.white38,
                                indicatorColor: Color(0xFF00FFFF),
                                tabs: [
                                  Tab(text: "ORIGEN (Local)"),
                                  Tab(text: "DESTINO (Remoto)"),
                                ],
                              ),
                              Expanded(
                                child: TabBarView(
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _buildLocalTree(
                                            visibleLocalPaths,
                                            basePath,
                                          ),
                                        ),
                                        Expanded(child: _buildLocalFiles()),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _buildRemoteTree(
                                            visibleRemotePaths,
                                          ),
                                        ),
                                        Expanded(child: _buildRemoteFiles()),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                width: double.infinity,
                                color: const Color(0xFF050505),
                                padding: const EdgeInsets.all(10),
                                child: ElevatedButton.icon(
                                  onPressed:
                                      (_selectedDeviceIp != null &&
                                          _selectedRemotePath != null &&
                                          _selectedLocalPath != null &&
                                          !_isTransferring)
                                      ? _promptTransferConfirmation
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _isPushMode
                                        ? const Color(0xFF39FF14)
                                        : const Color(0xFF00FFFF),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 15,
                                    ),
                                  ),
                                  icon: Icon(
                                    _isPushMode ? Icons.upload : Icons.download,
                                  ),
                                  label: Text(
                                    _isPushMode
                                        ? "TRANSFERIR (PUSH)"
                                        : "TRANSFERIR (PULL)",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: _buildLocalTree(
                                visibleLocalPaths,
                                basePath,
                              ),
                            ),
                            const VerticalDivider(
                              width: 1,
                              color: Colors.white10,
                            ),
                            Expanded(flex: 4, child: _buildLocalFiles()),
                            const VerticalDivider(
                              width: 1,
                              color: Colors.white10,
                            ),
                            Expanded(
                              flex: 1,
                              child: Container(
                                color: const Color(0xFF050505),
                                child: Center(
                                  child: ElevatedButton(
                                    onPressed:
                                        (_selectedDeviceIp != null &&
                                            _selectedRemotePath != null &&
                                            _selectedLocalPath != null &&
                                            !_isTransferring)
                                        ? _promptTransferConfirmation
                                        : null,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _isPushMode
                                          ? const Color(0xFF39FF14)
                                          : const Color(0xFF00FFFF),
                                      foregroundColor: Colors.black,
                                      shape: const CircleBorder(),
                                      padding: const EdgeInsets.all(20),
                                    ),
                                    child: Icon(
                                      _isPushMode
                                          ? Icons.double_arrow
                                          : Icons.keyboard_double_arrow_left,
                                      size: 28,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const VerticalDivider(
                              width: 1,
                              color: Colors.white10,
                            ),
                            Expanded(
                              flex: 3,
                              child: _buildRemoteTree(visibleRemotePaths),
                            ),
                            const VerticalDivider(
                              width: 1,
                              color: Colors.white10,
                            ),
                            Expanded(flex: 4, child: _buildRemoteFiles()),
                          ],
                        ),
                ),
              ],
            ),
            _buildTransferOverlay(),
          ],
        );
      },
    );
  }

  Map<Duration, String> _parseLrcFile(File lrcFile) {
    if (!lrcFile.existsSync()) return {};

    final Map<Duration, String> lyrics = {};
    final lines = lrcFile.readAsLinesSync();

    final RegExp timeRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

    for (var line in lines) {
      final match = timeRegex.firstMatch(line);
      if (match != null) {
        final int minutes = int.parse(match.group(1)!);
        final int seconds = int.parse(match.group(2)!);
        final String msStr = match.group(3)!;

        final int milliseconds = msStr.length == 2
            ? int.parse(msStr) * 10
            : int.parse(msStr);

        final duration = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        );
        final text = match.group(4)!.trim();

        if (text.isNotEmpty) {
          lyrics[duration] = text;
        }
      }
    }
    return lyrics;
  }
}
