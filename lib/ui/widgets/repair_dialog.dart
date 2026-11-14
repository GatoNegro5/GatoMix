import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class TrackRepairDialog extends StatefulWidget {
  final String queryName;
  final String targetDirectory;

  const TrackRepairDialog({
    super.key,
    required this.queryName,
    required this.targetDirectory,
  });

  @override
  State<TrackRepairDialog> createState() => _TrackRepairDialogState();
}

class _TrackRepairDialogState extends State<TrackRepairDialog> {
  final YoutubeExplode _yt = YoutubeExplode();
  final Player _previewPlayer = Player();

  List<Video> _results = [];
  bool _isSearching = true;
  String? _currentlyPlayingId;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _executeSearch();
  }

  @override
  void dispose() {
    _previewPlayer.dispose();
    _yt.close();
    super.dispose();
  }

  Future<void> _executeSearch() async {
    try {
      // Optimizador algorítmico: Forzamos audio oficial para evadir covers/lives
      final searchResult = await _yt.search.search(
        '${widget.queryName} official audio',
      );
      setState(() {
        _results = searchResult.take(4).toList();
        _isSearching = false;
      });
    } catch (e) {
      setState(() => _isSearching = false);
    }
  }

  // Pre-escucha en RAM vía HLS/DASH (Cero escrituras en disco)
  Future<void> _previewAudio(String videoId) async {
    if (_currentlyPlayingId == videoId) {
      await _previewPlayer.stop();
      setState(() => _currentlyPlayingId = null);
      return;
    }

    setState(() => _currentlyPlayingId = videoId);
    final manifest = await _yt.videos.streamsClient.getManifest(videoId);
    final audioStream = manifest.audioOnly.withHighestBitrate();

    await _previewPlayer.open(Media(audioStream.url.toString()));
    await _previewPlayer.play();
  }

  Future<void> _commitAndDownload(Video video) async {
    await _previewPlayer.stop();
    setState(() => _isDownloading = true);

    try {
      final tempDir = Directory.systemTemp;
      final ytdlpPath = '${tempDir.path}${Platform.pathSeparator}yt-dlp.exe';

      final outPath =
          '${widget.targetDirectory}${Platform.pathSeparator}${widget.queryName}.mp3';

      // yt-dlp baja el AAC crudo; el MP3 lo codifica Rust/LAME (sin FFmpeg).
      final rawPath =
          '${tempDir.path}${Platform.pathSeparator}repair_raw_${video.id}.m4a';
      if (File(rawPath).existsSync()) File(rawPath).deleteSync();
      final process = await Process.start(ytdlpPath, [
        '-f',
        '140/bestaudio[ext=m4a]/bestaudio',
        '-o',
        rawPath,
        'https://youtube.com/watch?v=${video.id}',
      ]);

      int exitCode = await process.exitCode;
      if (exitCode == 0 && File(rawPath).existsSync()) {
        try {
          await rust_dsp.encodeToMp3(
            inputPath: rawPath,
            outputPath: outPath,
            bitrateKbps: 320,
            master: false,
          );
        } catch (_) {
          exitCode = 1;
        }
        try {
          File(rawPath).deleteSync();
        } catch (_) {}
      }
      if (exitCode == 0) {
        if (mounted) {
          Navigator.pop(
            context,
            outPath,
          ); // Retorna la ruta validada al Pipeline
        }
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF121212),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF00FFFF)),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Resolución de Pista Corrupta",
            style: TextStyle(
              color: Color(0xFF00FFFF),
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            "Target: ${widget.queryName}",
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
      content: SizedBox(
        width: 600,
        height: 400,
        child: _isSearching
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF00FFFF)),
              )
            : _isDownloading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF39FF14)),
                    SizedBox(height: 20),
                    Text(
                      "Reconstruyendo MP3...",
                      style: TextStyle(
                        color: Color(0xFF39FF14),
                        fontFamily: 'Consolas',
                      ),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final video = _results[index];
                  final isPlaying = _currentlyPlayingId == video.id.value;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isPlaying
                            ? const Color(0xFF39FF14)
                            : Colors.white10,
                      ),
                    ),
                    child: ListTile(
                      leading: IconButton(
                        icon: Icon(
                          isPlaying
                              ? Icons.stop_circle
                              : Icons.play_circle_fill,
                          color: isPlaying
                              ? const Color(0xFFFF007F)
                              : const Color(0xFF00FFFF),
                          size: 35,
                        ),
                        onPressed: () => _previewAudio(video.id.value),
                      ),
                      title: Text(
                        video.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        "${video.author} • ${video.duration?.inMinutes ?? 0}:${(video.duration?.inSeconds ?? 0) % 60}",
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                      trailing: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF39FF14),
                          foregroundColor: Colors.black,
                        ),
                        onPressed: () => _commitAndDownload(video),
                        child: const Text("Usar Esta"),
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        if (!_isDownloading)
          TextButton(
            onPressed: () {
              _previewPlayer.stop();
              Navigator.pop(context, null); // Abortar
            },
            child: const Text(
              "Descartar Pista",
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
      ],
    );
  }
}
