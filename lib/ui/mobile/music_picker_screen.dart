import 'dart:io';
import 'dart:isolate';

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
    final int i = next.indexWhere(
      (String item) => sameAudioPath(item, current),
    );
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

/// Filtra canciones (lista recursiva) por texto en la ruta relativa a [base].
List<File> musicPickerFilterSongs(List<File> all, String base, String query) {
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) return List<File>.of(all);
  return all.where((File f) {
    String rel = f.path;
    if (rel.startsWith(base)) rel = rel.substring(base.length);
    return rel.toLowerCase().contains(q);
  }).toList();
}

/// Lista recursiva fuera del hilo de UI.
Future<List<File>> musicPickerSongsUnderAsync(String dirPath) async {
  final List<String> paths = await Isolate.run(
    () => musicPickerSongsUnder(
      Directory(dirPath),
    ).map((File f) => f.path).toList(),
  );
  return paths.map((String p) => File(p)).toList();
}

File? musicPickerCover(File audio) {
  final String stem = audio.path.replaceFirst(RegExp(r'\.[^.]+$'), '');
  for (final String ext in <String>['.jpg', '.jpeg', '.png', '.webp']) {
    final File image = File('$stem$ext');
    if (image.existsSync()) return image;
  }
  return null;
}

Future<void> showMusicPickerSheet(
  BuildContext context, {
  required Widget Function(ScrollController controller) child,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: _bg,
    builder: (BuildContext ctx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        minChildSize: 0.25,
        maxChildSize: 0.92,
        builder: (BuildContext context, ScrollController controller) {
          return child(controller);
        },
      );
    },
  );
}

class MusicPickerScreen extends StatefulWidget {
  final String rootPath;
  final List<String> queuePaths;
  final ScrollController? scrollController;
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
    this.scrollController,
  });

  @override
  State<MusicPickerScreen> createState() => _MusicPickerScreenState();
}

class _MusicPickerScreenState extends State<MusicPickerScreen> {
  late String _current;
  final TextEditingController _search = TextEditingController();
  int _tab = 0;
  final Map<String, List<File>> _deep = <String, List<File>>{};
  final Set<String> _deepLoading = <String>{};

  List<File>? _deepSongs(String path) {
    final List<File>? cached = _deep[path];
    if (cached != null) return cached;
    if (_deepLoading.add(path)) {
      musicPickerSongsUnderAsync(path).then((List<File> list) {
        if (!mounted) return;
        setState(() {
          _deep[path] = list;
          _deepLoading.remove(path);
        });
      });
    }
    return null;
  }

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

  bool get _atRoot {
    final String root = widget.rootPath;
    return _current == root || !_current.startsWith(root);
  }

  void _enqueue(File file) {
    widget.onEnqueue(file);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        persist: false,
        duration: const Duration(seconds: 2),
        content: const Text(
          'Agregada a la cola',
          style: TextStyle(fontSize: 14),
        ),
        action: SnackBarAction(
          label: 'Deshacer',
          onPressed: () => widget.onUndo(file),
        ),
      ),
    );
  }

  void _up() {
    final String root = widget.rootPath;
    String parent = Directory(_current).parent.path;
    if (parent != root && !parent.startsWith(root)) parent = root;
    setState(() {
      _current = parent;
      _tab = 0;
    });
  }

  void _openFolder(Directory folder) {
    setState(() {
      _current = folder.path;
      _tab = 1;
      _search.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final String query = _search.text.trim().toLowerCase();
    final List<Directory> folders = <Directory>[];
    final List<File> songs = <File>[];
    final Directory dir = Directory(_current);
    final bool readable = dir.existsSync();
    if (readable) {
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

    final bool showFolders = _tab == 0 && query.isEmpty;
    bool deepPending = false;
    if (readable && (query.isNotEmpty || (_atRoot && _tab == 1))) {
      final List<File>? deep = _deepSongs(_current);
      if (deep == null) {
        deepPending = true;
        songs.clear();
      } else {
        songs
          ..clear()
          ..addAll(musicPickerFilterSongs(deep, _current, query));
      }
    }
    final String here = _atRoot
        ? 'Música'
        : _current.split(Platform.pathSeparator).last;

    return Scaffold(
      backgroundColor: _bg,
      body: CustomScrollView(
        controller: widget.scrollController,
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Padding(
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
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                onChanged: (String v) => setState(() {
                  if (v.trim().isNotEmpty) _tab = 1;
                }),
              ),
            ),
          ),
          if (!_atRoot)
            SliverToBoxAdapter(
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: 'Atrás',
                    onPressed: _up,
                    icon: const Icon(Icons.arrow_back, color: _text),
                  ),
                  Expanded(
                    child: Text(
                      here,
                      style: _titleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          SliverToBoxAdapter(
            child: Row(
              children: <Widget>[
                Expanded(child: _tabButton('Carpetas', 0)),
                Expanded(child: _tabButton('Canciones', 1)),
              ],
            ),
          ),
          if (!readable)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  'No se pudo leer la carpeta de música',
                  style: _metaStyle,
                ),
              ),
            )
          else if (deepPending)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(color: _muted)),
              ),
            )
          else if (showFolders)
            SliverList(
              delegate: SliverChildBuilderDelegate((
                BuildContext context,
                int index,
              ) {
                final Directory folder = folders[index];
                final int n = musicPickerSongsUnder(folder).length;
                final String name = folder.path
                    .split(Platform.pathSeparator)
                    .last;
                return ListTile(
                  leading: const Icon(Icons.folder, color: _text, size: 28),
                  title: Text(
                    name,
                    style: _titleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('$n canciones', style: _metaStyle),
                  trailing: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: _text,
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () {
                      widget.onMixFolder(musicPickerSongsUnder(folder));
                    },
                    child: const Text('Mezclar todo', maxLines: 1),
                  ),
                  onTap: () => _openFolder(folder),
                );
              }, childCount: folders.length),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((
                BuildContext context,
                int index,
              ) {
                final File song = songs[index];
                return _SongRow(
                  file: song,
                  onTap: () => _enqueue(song),
                  onPlayNext: () => widget.onPlayNext(song),
                );
              }, childCount: songs.length),
            ),
        ],
      ),
    );
  }

  Widget _tabButton(String label, int index) {
    final bool selected = _tab == index;
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: selected ? _text : _muted,
        minimumSize: const Size(48, 44),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      onPressed: () => setState(() => _tab = index),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
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

    return Material(
      color: _bg,
      child: InkWell(
        onTap: onTap,
        onLongPress: onPlayNext,
        child: SizedBox(
          height: 64,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: cover == null
                      ? const ColoredBox(
                          color: _card,
                          child: Icon(
                            Icons.music_note,
                            color: _muted,
                            size: 22,
                          ),
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
                  padding: EdgeInsets.only(right: 12),
                  child: Text('🎤', style: TextStyle(fontSize: 18)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
