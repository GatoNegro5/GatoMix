import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/audio_path.dart';
import '../../core/track_name_clean.dart';
import '../../djiphone/iphone_library.dart';

const Color _bg = Color(0xFF121212);
const Color _card = Color(0xFF1E1E1E);
const Color _text = Color(0xFFFFFFFF);
const Color _muted = Color(0xFFB3B3B3);

const TextStyle _titleStyle = TextStyle(color: _text, fontSize: 16);
const TextStyle _metaStyle = TextStyle(color: _muted, fontSize: 14);

String gatomixMusicRoot() {
  if (Platform.isIOS) return IphoneLibrary.musicRoot;
  if (Platform.isWindows) {
    final String? userProfile = Platform.environment['USERPROFILE'];
    return userProfile != null ? '$userProfile\\Music' : 'C:\\Music';
  }
  if (Platform.isAndroid) return '/storage/emulated/0/Music';
  final String? home = Platform.environment['HOME'];
  return home != null ? '$home/Music' : '/';
}

bool musicPickerShowsFile(String path) {
  final String lower = path.toLowerCase();
  final bool audio =
      lower.endsWith('.mp3') ||
      lower.endsWith('.m4a') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.webm');
  if (!audio) return false;
  return !isKaraokeAudioPath(path);
}

bool musicPickerHasLrc(String path) {
  final String lrc = path.replaceFirst(RegExp(r'\.[^.]+$'), '.lrc');
  return File(lrc).existsSync();
}

String musicPickerTitle(String path) {
  final String name = path.split(Platform.pathSeparator).last;
  final int dot = name.lastIndexOf('.');
  if (dot <= 0) return name;
  return name.substring(0, dot);
}

List<String> queueWithPlayNext(
  List<String> queue,
  String? current,
  String path,
) {
  final List<String> next = <String>[
    for (final String item in queue)
      if (!sameAudioPath(item, path)) item,
  ];
  var at = next.length;
  if (current != null && !sameAudioPath(current, path)) {
    final int i = next.indexWhere((String item) => sameAudioPath(item, current));
    if (i >= 0) at = i + 1;
  }
  next.insert(at, path);
  return next;
}

List<File> musicPickerSongsUnder(Directory dir, {int depth = 0}) {
  if (depth > 8) return <File>[];
  final List<File> out = <File>[];
  List<FileSystemEntity> entities;
  try {
    entities = dir.listSync(followLinks: false);
  } catch (_) {
    return out;
  }
  for (final FileSystemEntity entity in entities) {
    if (entity is Directory) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.') || name.startsWith(r'$')) continue;
      out.addAll(musicPickerSongsUnder(entity, depth: depth + 1));
    } else if (entity is File && musicPickerShowsFile(entity.path)) {
      out.add(entity);
    }
  }
  out.sort(
    (File a, File b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
  );
  return out;
}

File? musicPickerCover(File audio) {
  final String stem = audio.path.replaceFirst(RegExp(r'\.[^.]+$'), '');
  for (final String ext in <String>['.jpg', '.jpeg', '.png', '.webp']) {
    final File image = File('$stem$ext');
    if (image.existsSync()) return image;
  }
  return null;
}

class MusicPickerScreen extends StatefulWidget {
  final String rootPath;
  final List<String> queuePaths;
  final void Function(File file) onEnqueue;
  final void Function(File file) onUndo;
  final void Function(File file) onPlayNext;
  final void Function(List<File> files) onAddFolder;
  final Future<void> Function(List<File> files) onMixFolder;

  const MusicPickerScreen({
    super.key,
    required this.rootPath,
    required this.queuePaths,
    required this.onEnqueue,
    required this.onUndo,
    required this.onPlayNext,
    required this.onAddFolder,
    required this.onMixFolder,
  });

  @override
  State<MusicPickerScreen> createState() => _MusicPickerScreenState();
}

class _MusicPickerScreenState extends State<MusicPickerScreen> {
  late String _current;
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _current = widget.rootPath;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> get _crumbs {
    final String sep = Platform.pathSeparator;
    final String root = widget.rootPath;
    if (_current == root || !_current.startsWith(root)) {
      return <String>[root];
    }
    String rest = _current.substring(root.length);
    if (rest.startsWith(sep)) rest = rest.substring(1);
    final List<String> parts = rest.split(sep).where((String p) => p.isNotEmpty).toList();
    final List<String> paths = <String>[root];
    var acc = root;
    for (final String part in parts) {
      acc = '$acc$sep$part';
      paths.add(acc);
    }
    return paths;
  }

  String _label(String path) {
    if (path == widget.rootPath) return 'Música';
    return path.split(Platform.pathSeparator).last;
  }

  void _enqueue(File file) {
    widget.onEnqueue(file);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Deshacer', style: TextStyle(fontSize: 14)),
        action: SnackBarAction(
          label: 'Deshacer',
          onPressed: () => widget.onUndo(file),
        ),
      ),
    );
  }

  void _openQueue() {
    final List<String> paths = widget.queuePaths;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      builder: (BuildContext ctx) {
        if (paths.isEmpty) {
          return const SizedBox(
            height: 80,
            child: Center(
              child: Text('0 canciones', style: _metaStyle),
            ),
          );
        }
        return SafeArea(
          child: ListView(
            children: <Widget>[
              for (final String path in paths)
                ListTile(
                  minTileHeight: 48,
                  title: Text(
                    musicPickerTitle(path),
                    style: _titleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final String query = _search.text.trim().toLowerCase();
    final List<Directory> folders = <Directory>[];
    final List<File> songs = <File>[];
    final Directory dir = Directory(_current);
    if (dir.existsSync()) {
      try {
        final List<FileSystemEntity> entities = dir.listSync(followLinks: false)
          ..sort(
            (FileSystemEntity a, FileSystemEntity b) =>
                a.path.toLowerCase().compareTo(b.path.toLowerCase()),
          );
        for (final FileSystemEntity entity in entities) {
          final String name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.') || name.startsWith(r'$')) continue;
          if (query.isNotEmpty && !name.toLowerCase().contains(query)) {
            continue;
          }
          if (entity is Directory) {
            folders.add(entity);
          } else if (entity is File && musicPickerShowsFile(entity.path)) {
            songs.add(entity);
          }
        }
      } catch (_) {}
    }

    final int count = widget.queuePaths.length;
    final String queueLabel = count == 1
        ? '1 canción · toca para ver'
        : '$count canciones · toca para ver';

    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _search,
              style: _titleStyle,
              cursorColor: _text,
              decoration: const InputDecoration(
                hintText: 'Buscar',
                hintStyle: _metaStyle,
                prefixIcon: Icon(Icons.search, color: _muted),
                filled: true,
                fillColor: _card,
                border: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
                isDense: false,
                contentPadding: EdgeInsets.symmetric(vertical: 14),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: <Widget>[
                for (final String crumb in _crumbs)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: crumb == _current ? _text : _muted,
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    onPressed: () => setState(() => _current = crumb),
                    child: Text(_label(crumb)),
                  ),
              ],
            ),
          ),
          Expanded(
            child: !dir.existsSync()
                ? const Center(
                    child: Text(
                      'No se pudo leer la carpeta de música',
                      style: _metaStyle,
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 8),
                    children: <Widget>[
                      for (final Directory folder in folders)
                        _FolderCard(
                          folder: folder,
                          onMix: () {
                            widget.onMixFolder(musicPickerSongsUnder(folder));
                          },
                          onAdd: () {
                            widget.onAddFolder(musicPickerSongsUnder(folder));
                          },
                          onOpen: () => setState(() {
                            _current = folder.path;
                            _search.clear();
                          }),
                        ),
                      for (final File song in songs)
                        _SongRow(
                          file: song,
                          onTap: () => _enqueue(song),
                          onPlayNext: () => widget.onPlayNext(song),
                        ),
                    ],
                  ),
          ),
          Material(
            color: _card,
            child: InkWell(
              onTap: _openQueue,
              child: SizedBox(
                height: 56,
                child: Center(
                  child: Text(queueLabel, style: _titleStyle),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  final Directory folder;
  final VoidCallback onMix;
  final VoidCallback onAdd;
  final VoidCallback onOpen;

  const _FolderCard({
    required this.folder,
    required this.onMix,
    required this.onAdd,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final String name = folder.path.split(Platform.pathSeparator).last;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 12),
          const Icon(Icons.folder, color: _text, size: 28),
          Expanded(
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: SizedBox(
                  height: 48,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      name,
                      style: _titleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: _text,
              textStyle: const TextStyle(fontSize: 14),
            ),
            onPressed: onMix,
            child: const Text('▶ Mezclar'),
          ),
          InkWell(
            onTap: onAdd,
            child: const SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: Text('＋', style: TextStyle(color: _text, fontSize: 22)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  final File file;
  final VoidCallback onTap;
  final VoidCallback onPlayNext;

  const _SongRow({
    required this.file,
    required this.onTap,
    required this.onPlayNext,
  });

  @override
  Widget build(BuildContext context) {
    final CleanTrackName meta = cleanTrackFileName(file.path);
    final double? bpm = meta.bpmHint;
    String bpmText = '';
    if (bpm != null && bpm > 0) {
      bpmText = bpm == bpm.roundToDouble()
          ? '${bpm.toStringAsFixed(0)} BPM'
          : '${bpm.toStringAsFixed(1)} BPM';
    }
    final String key = meta.camelot ?? '';
    final String metaLine = <String>[
      if (bpmText.isNotEmpty) bpmText,
      if (key.isNotEmpty) key,
    ].join('  ·  ');
    final File? cover = musicPickerCover(file);
    final bool lrc = musicPickerHasLrc(file.path);

    return Dismissible(
      key: ValueKey<String>(file.path),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) async {
        onPlayNext();
        return false;
      },
      background: Container(
        color: _card,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 16),
        child: const Text('A continuación', style: _titleStyle),
      ),
      child: Material(
        color: _bg,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 64,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: cover == null
                        ? const ColoredBox(
                            color: _card,
                            child: Icon(Icons.music_note, color: _muted),
                          )
                        : Image.file(cover, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        musicPickerTitle(file.path),
                        style: _titleStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (metaLine.isNotEmpty)
                        Text(
                          metaLine,
                          style: _metaStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (lrc)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('🎤', style: TextStyle(fontSize: 18)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
