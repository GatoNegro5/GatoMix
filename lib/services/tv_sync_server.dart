import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TvSyncServer {
  HttpServer? _server;
  final List<WebSocket> _clients = [];
  final int port = 55056;
  void Function(Map<String, dynamic> message)? onTvMessage;
  void Function()? onTvJoined;

  bool get hasTvClient =>
      _clients.any((client) => client.readyState == WebSocket.open);

  Future<void> start() async {
    try {
      // 0.0.0.0 expone el puerto a toda tu red LAN (WiFi)
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      debugPrint("🟢 [TV SYNC] Nodo Emisor WebSocket activo en puerto $port");

      _server!.listen((HttpRequest request) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          WebSocketTransformer.upgrade(request).then((WebSocket ws) {
            _clients.add(ws);
            debugPrint(
              "🟢 [TV SYNC] TV Conectada. Clientes activos: ${_clients.length}",
            );
            onTvJoined?.call();

            ws.listen(
              (data) {
                try {
                  final decoded = jsonDecode('$data');
                  if (decoded is Map<String, dynamic>) {
                    onTvMessage?.call(decoded);
                  }
                } catch (_) {}
              },
              onDone: () {
                _clients.remove(ws);
                debugPrint("🔴 [TV SYNC] TV Desconectada.");
              },
              onError: (e) {
                _clients.remove(ws);
              },
            );
          });
        } else {
          _serveKaraokeFile(request);
        }
      });
    } catch (e) {
      debugPrint("🔴 [TV SYNC FATAL] Fallo al iniciar puerto $port: $e");
    }
  }

  // Método genérico para disparar payloads JSON a la TV
  void broadcastPayload(Map<String, dynamic> payload) {
    if (_clients.isEmpty) return;

    final String msg = jsonEncode(payload);
    for (var ws in _clients) {
      if (ws.readyState == WebSocket.open) {
        ws.add(msg);
      }
    }
  }

  // Dispara el archivo LRC completo cuando cargas una canción
  void broadcastLrcTrack(String trackName, String lrcContent) {
    broadcastPayload({
      'type': 'LRC_LOAD',
      'track': trackName,
      'payload': lrcContent,
    });
  }

  // Dispara el reloj (Ping de sincronización)
  void broadcastSyncPing(int positionMs, bool isPlaying) {
    broadcastPayload({
      'type': 'SYNC_PING',
      'positionMs': positionMs,
      'isPlaying': isPlaying,
    });
  }

  void broadcastEdgeExecute({
    required String mp3Url,
    required String lrcUrl,
    required String trackName,
    required String singer,
  }) {
    broadcastPayload({
      'type': 'EDGE_EXECUTE',
      'mp3_url': mp3Url,
      'lrc_url': lrcUrl,
      'track_name': trackName,
      'singer': singer,
    });
  }

  void broadcastEdgePreload({
    required String mp3Url,
    required String lrcUrl,
    required String trackName,
    required String singer,
  }) {
    broadcastPayload({
      'type': 'EDGE_PRELOAD',
      'mp3_url': mp3Url,
      'lrc_url': lrcUrl,
      'track_name': trackName,
      'singer': singer,
    });
  }

  void broadcastScoreboard({
    required String singer,
    required String trackName,
    required Map<String, int> votes,
    String? nextSinger,
    String? nextTrack,
  }) {
    broadcastPayload({
      'type': 'SCOREBOARD',
      'singer': singer,
      'track_name': trackName,
      'votes': votes,
      'next_singer': nextSinger,
      'next_track': nextTrack,
    });
  }

  void broadcastEdgePause() {
    broadcastPayload({'type': 'EDGE_PAUSE'});
  }

  void broadcastEdgeResume() {
    broadcastPayload({'type': 'EDGE_RESUME'});
  }

  void broadcastEdgeStop() {
    broadcastPayload({'type': 'EDGE_STOP'});
  }

  void broadcastSessionEnd() {
    broadcastPayload({'type': 'SESSION_END'});
  }

  void broadcastStageState({
    required List<Map<String, String>> queue,
    required Map<String, String> current,
    required Map<String, int> votes,
    required bool sessionActive,
    required bool paused,
    required String qrUrl,
  }) {
    broadcastPayload({
      'type': 'STAGE_STATE',
      'queue': queue,
      'current': current,
      'votes': votes,
      'session': sessionActive,
      'paused': paused,
      'qr_url': qrUrl,
    });
  }

  Future<void> _serveKaraokeFile(HttpRequest request) async {
    try {
      if (request.method != 'GET') {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..close();
        return;
      }

      if (request.uri.path == '/api/whoami' || request.uri.path == '/whoami') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({'role': 'gatomix-karaoke', 'service': 'tv-sync'}),
          );
        await request.response.close();
        return;
      }

      final raw = request.uri.queryParameters['p'];
      if (raw == null || raw.isEmpty) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..close();
        return;
      }

      final file = File(raw);
      final lower = raw.toLowerCase();
      final allowed =
          (lower.endsWith('.mp3') || lower.endsWith('.lrc')) &&
          file.existsSync();
      if (!allowed) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..close();
        return;
      }

      request.response.headers.contentType = lower.endsWith('.lrc')
          ? ContentType('text', 'plain', charset: 'utf-8')
          : ContentType('audio', 'mpeg');
      await request.response.addStream(file.openRead());
      await request.response.close();
    } catch (e) {
      debugPrint('🔴 [TV SYNC] HTTP $e');
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..close();
      } catch (_) {}
    }
  }

  void stop() {
    for (var ws in _clients) {
      ws.close();
    }
    _clients.clear();
    _server?.close(force: true);
    debugPrint("🔴 [TV SYNC] Nodo Emisor destruido.");
  }
}

// Inyección en Riverpod para que viva de forma global
final tvSyncProvider = Provider<TvSyncServer>((ref) {
  final server = TvSyncServer();
  server.start();

  ref.onDispose(() {
    server.stop();
  });

  return server;
});
