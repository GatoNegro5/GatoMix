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
  double _transferProgress = 0.0;
  String _currentLog = "Iniciando protocolos de seguridad y red...";
  int _totalFiles = 0;
  int _currentFileIndex = 0;
  int _successfulTransfers = 0;
  int _skippedTransfers = 0;

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
    )..repeat();

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
              final ext = f.path.toLowerCase();
              return ext.endsWith('.mp3') ||
                  ext.endsWith('.lrc') ||
                  ext.endsWith('.txt');
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
          final ext = e.path.toLowerCase();
          if (ext.endsWith('.mp3') ||
              ext.endsWith('.lrc') ||
              ext.endsWith('.txt')) {
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

  // 🛠️ API CORE: Endpoints de Aniquilación y Metadata Inyectados
  Future<void> _bootRestServer() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (var interface in interfaces) {
        if (!interface.name.toLowerCase().contains('virtual') &&
            interface.name != 'lo') {
          _localIp = interface.addresses.first.address;
          break;
        }
      }

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
            final ext = f.path.toLowerCase();
            if (ext.endsWith('.mp3') ||
                ext.endsWith('.lrc') ||
                ext.endsWith('.txt')) {
              filesMetadata.add({
                "name": f.uri.pathSegments.last,
                "size_bytes": f.lengthSync(),
                "modified_ms": f.lastModifiedSync().millisecondsSinceEpoch,
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
        final targetDir = _resolvePath(query['dir'] ?? 'ROOT');
        final relFolder = query['rel'] ?? '';

        String finalDirPath = targetDir;
        if (relFolder.isNotEmpty) {
          finalDirPath =
              '$targetDir${Platform.pathSeparator}${relFolder.replaceAll('\\', '/').replaceAll('/', Platform.pathSeparator)}';
        }

        final dir = Directory(finalDirPath);
        if (!dir.existsSync()) dir.createSync(recursive: true);

        final boundary = request.headers.contentType?.parameters['boundary'];
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
                final savePath =
                    '${dir.path}${Platform.pathSeparator}${match.group(1)}';
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
                final sink = File(savePath).openWrite();
                await part.pipe(sink);
                await sink.close();
              }
            }
          }
          request.response
            ..statusCode = 200
            ..write("OK")
            ..close();
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

  Future<void> _startNetworkSweeper() async {
    final subnetParts = _localIp.split('.');
    if (subnetParts.length != 4) return;
    final subnet = '${subnetParts[0]}.${subnetParts[1]}.${subnetParts[2]}';

    while (mounted && _isSweeping) {
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
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _forceNetworkSweep() async {
    if (_isManualSweeping) return;
    setState(() {
      _isManualSweeping = true;
      _currentLog = "📡 Disparando escaneo de radar (Batches de 50 nodos)...";
    });

    final subnetParts = _localIp.split('.');
    if (subnetParts.length == 4) {
      final subnet = '${subnetParts[0]}.${subnetParts[1]}.${subnetParts[2]}';
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

    if (mounted) {
      setState(() {
        _isManualSweeping = false;
        _currentLog =
            "✅ Barrido de radar completado. Nodos activos: ${_discoveredDevices.length}";
      });
    }
  }

  Future<void> _probeDeviceHttp(String targetIp) async {
    try {
      final response = await http
          .get(Uri.parse('http://$targetIp:$_restPort/api/whoami'))
          .timeout(const Duration(milliseconds: 1500));

      if (response.statusCode == 200) {
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
            _remoteFolderPaths = folders;
            _currentLog =
                "✅ Árbol remoto obtenido: ${folders.length} carpetas.";
            if (_selectedRemotePath == null && folders.isNotEmpty) {
              _selectedRemotePath = folders.first;
              _fetchRemoteFiles(targetIp, _selectedRemotePath!);
            } else if (folders.isEmpty) {
              _currentLog =
                  "⚠️ HTTP 200 OK: La app remota respondió, pero su carpeta Music está VACÍA o no diste permiso en pantalla.";
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

  Future<void> _executeTransferJob(bool isDirectoryClone) async {
    setState(() {
      _isTransferring = true;
      _cancelRequested = false;
      _transferProgress = 0.0;
      _currentFileIndex = 0;
      _successfulTransfers = 0;
      _skippedTransfers = 0;
      _currentLog = "Iniciando Job REST (Evaluando metadatos y colisiones)...";
    });

    if (_isPushMode) {
      Set<String> pushQueue = {};
      if (isDirectoryClone) {
        pushQueue.addAll(
          _getFilesRecursively(
            Directory(_selectedLocalPath!),
          ).map((f) => f.path),
        );
      } else {
        for (String path in _selectedFilesToTransfer) {
          pushQueue.add(path);
          if (path.toLowerCase().endsWith('.mp3')) {
            final lrcPath = '${path.substring(0, path.length - 4)}.lrc';
            final txtPath = '${path.substring(0, path.length - 4)}.txt';
            if (File(lrcPath).existsSync()) pushQueue.add(lrcPath);
            if (File(txtPath).existsSync()) pushQueue.add(txtPath);
          }
        }
      }

      final files = pushQueue.map((p) => File(p)).toList();
      setState(() => _totalFiles = files.length);

      final localBaseDirPath = Directory(_selectedLocalPath!).path;
      final rootFolderName = localBaseDirPath
          .split(Platform.pathSeparator)
          .last;

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
          _transferProgress = (_currentFileIndex - 1) / _totalFiles;
        });

        final bool isLrc = fileName.toLowerCase().endsWith('.lrc');
        if (_currentRemoteFiles.any((f) => f['name'] == fileName)) {
          if (!_overwriteExisting && !isLrc) {
            setState(() => _currentLog = "⏩ SALTADO (Ya existe): $fileName");
            _skippedTransfers++;
            continue;
          } else {
            setState(() => _currentLog = "🔄 REEMPLAZANDO: $fileName");
          }
        } else {
          setState(() => _currentLog = "⬆️ ENVIANDO: $fileName");
        }

        try {
          final request = http.MultipartRequest(
            'POST',
            Uri.parse(
              'http://$_selectedDeviceIp:$_restPort/api/upload?dir=${Uri.encodeComponent(_selectedRemotePath ?? "ROOT")}&rel=${Uri.encodeComponent(relativeFolder)}&ow=${_overwriteExisting ? 1 : 0}',
            ),
          );
          request.files.add(
            await http.MultipartFile.fromPath('file', file.path),
          );
          final response = await request.send();
          if (response.statusCode == 200) {
            _successfulTransfers++;
          } else {
            _skippedTransfers++;
          }
        } catch (_) {
          _skippedTransfers++;
        }

        await Future.delayed(const Duration(milliseconds: 15));
      }

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
      final files = _currentRemoteFiles;
      setState(() => _totalFiles = files.length);

      final localDir = Directory(_selectedLocalPath!);
      for (int i = 0; i < files.length; i++) {
        if (_cancelRequested) break;
        final fileName = files[i]['name'];

        setState(() {
          _currentFileIndex = i + 1;
          _transferProgress = (_currentFileIndex - 1) / _totalFiles;
        });

        final saveFile = File(
          '${localDir.path}${Platform.pathSeparator}$fileName',
        );

        final bool isLrc = '$fileName'.toLowerCase().endsWith('.lrc');
        if (saveFile.existsSync()) {
          if (!_overwriteExisting && !isLrc) {
            setState(() => _currentLog = "⏩ SALTADO (Ya existe): $fileName");
            _skippedTransfers++;
            continue;
          } else {
            setState(() => _currentLog = "🔄 REEMPLAZANDO: $fileName");
          }
        } else {
          setState(() => _currentLog = "⬇️ EXTRAYENDO: $fileName");
        }

        try {
          final client = HttpClient();
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
            } else {
              _skippedTransfers++;
            }
          } else if (response.statusCode == 200) {
            await response.pipe(saveFile.openWrite());
            _successfulTransfers++;
          } else {
            _skippedTransfers++;
          }
          client.close();
        } catch (_) {
          _skippedTransfers++;
        }

        await Future.delayed(const Duration(milliseconds: 15));
      }
      _scanLocalMusicFolders();
      _loadFilesInFolder(_selectedLocalPath!);
    }

    setState(() {
      _transferProgress = 1.0;
      _isTransferring = false;
      _currentLog =
          "✅ Job Finalizado. Éxito: $_successfulTransfers | Saltados/Fallos: $_skippedTransfers";
      _selectedFilesToTransfer.clear();
    });

    if (_selectedDeviceIp != null) {
      _fetchRemoteDirectoryTree(_selectedDeviceIp!);
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
        : _currentRemoteFiles.length;

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
        _skippedTransfers == 0) {
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
                    color: _isPushMode
                        ? const Color(0xFF39FF14)
                        : const Color(0xFF00FFFF),
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
                  ElevatedButton(
                    onPressed: () => setState(() {
                      _transferProgress = 0.0;
                      _successfulTransfers = 0;
                      _skippedTransfers = 0;
                    }),
                    child: const Text("CERRAR TERMINAL"),
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
                    path.split('/').last,
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
