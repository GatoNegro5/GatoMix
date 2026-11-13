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

String _pickerName(String path) => path.split(Platform.pathSeparator).last;

bool _pickerHidden(String path) {
  final String name = _pickerName(path);
  return name.startsWith('.') || name.startsWith(r'$');
}

int _pickerCompare(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());

/// 3.1.24: carpeta leida fuera del hilo de UI (subcarpetas, canciones
/// directas, portada y .lrc de cada cancion).
class MusicPickerListing {
  final bool readable;
  final List<String> folders;
  final List<String> songs;
  final Map<String, String?> covers;
  final Set<String> lrc;

  const MusicPickerListing({
    required this.readable,
    required this.folders,
    required this.songs,
    required this.covers,
    required this.lrc,
  });
}

/// 3.1.24: canciones recursivas de una carpeta y de cada subcarpeta.
class MusicPickerDeepScan {
  final List<String> all;
  final Map<String, List<String>> byFolder;
  final Map<String, String?> covers;
  final Set<String> lrc;

  const MusicPickerDeepScan({
    required this.all,
    required this.byFolder,
    required this.covers,
    required this.lrc,
  });
}

/// Portada y .lrc a partir del listado ya leido: 0 llamadas extra a disco.
/// Windows y macOS no distinguen mayusculas, igual que el `existsSync` de
/// antes.
void _pickerSidecars(
  List<FileSystemEntity> entities,
  Map<String, String?> covers,
  Set<String> lrc,
) {
  final bool fold = Platform.isWindows || Platform.isMacOS;
  final Map<String, String> files = <String, String>{};
  for (final FileSystemEntity entity in entities) {
    if (entity is File) {
      files[fold ? entity.path.toLowerCase() : entity.path] = entity.path;
    }
  }
  String? find(String path) => files[fold ? path.toLowerCase() : path];
  for (final FileSystemEntity entity in entities) {
    if (entity is! File || !musicPickerShowsFile(entity.path)) continue;
    final String stem = entity.path.replaceFirst(RegExp(r'\.[^.]+$'), '');
    String? cover;
    for (final String ext in <String>['.jpg', '.jpeg', '.png', '.webp']) {
      cover = find('$stem$ext');
      if (cover != null) break;
    }
    covers[entity.path] = cover;
    if (find('$stem.lrc') != null) lrc.add(entity.path);
  }
}

MusicPickerListing musicPickerReadFolder(String dirPath) {
  final Directory dir = Directory(dirPath);
  if (!dir.existsSync()) {
    return const MusicPickerListing(
      readable: false,
      folders: <String>[],
      songs: <String>[],
      covers: <String, String?>{},
      lrc: <String>{},
    );
  }
  List<FileSystemEntity> entities;
  try {
    entities = dir.listSync(followLinks: false);
  } catch (_) {
    entities = <FileSystemEntity>[];
  }
  entities.sort(
    (FileSystemEntity a, FileSystemEntity b) => _pickerCompare(a.path, b.path),
  );
  final List<String> folders = <String>[];
  final List<String> songs = <String>[];
  for (final FileSystemEntity entity in entities) {
    if (_pickerHidden(entity.path)) continue;
    if (entity is Directory) {
      folders.add(entity.path);
    } else if (entity is File && musicPickerShowsFile(entity.path)) {
      songs.add(entity.path);
    }
  }
  final Map<String, String?> covers = <String, String?>{};
  final Set<String> lrc = <String>{};
  _pickerSidecars(entities, covers, lrc);
  return MusicPickerListing(
    readable: true,
    folders: folders,
    songs: songs,
    covers: covers,
    lrc: lrc,
  );
}

void _pickerWalk(
  Directory dir,
  int depth,
  List<String> out,
  Map<String, String?> covers,
  Set<String> lrc,
) {
  if (depth > 8) return;
  List<FileSystemEntity> entities;
  try {
    entities = dir.listSync(followLinks: false);
  } catch (_) {
    return;
  }
  _pickerSidecars(entities, covers, lrc);
  for (final FileSystemEntity entity in entities) {
    if (entity is Directory) {
      if (_pickerHidden(entity.path)) continue;
      _pickerWalk(entity, depth + 1, out, covers, lrc);
    } else if (entity is File && musicPickerShowsFile(entity.path)) {
      out.add(entity.path);
    }
  }
}

/// Mismo recorrido que [musicPickerSongsUnder] (8 niveles por subcarpeta).
MusicPickerDeepScan musicPickerDeepScan(String dirPath) {
  final Map<String, String?> covers = <String, String?>{};
  final Set<String> lrc = <String>{};
  final Map<String, List<String>> byFolder = <String, List<String>>{};
  final List<String> all = <String>[];
  List<FileSystemEntity> entities;
  try {
    entities = Directory(dirPath).listSync(followLinks: false);
  } catch (_) {
    entities = <FileSystemEntity>[];
  }
  _pickerSidecars(entities, covers, lrc);
  for (final FileSystemEntity entity in entities) {
    if (entity is Directory) {
      if (_pickerHidden(entity.path)) continue;
      final List<String> songs = <String>[];
      _pickerWalk(entity, 0, songs, covers, lrc);
      songs.sort(_pickerCompare);
      byFolder[entity.path] = songs;
      all.addAll(songs);
    } else if (entity is File && musicPickerShowsFile(entity.path)) {
      all.add(entity.path);
    }
  }
  all.sort(_pickerCompare);
  return MusicPickerDeepScan(
    all: all,
    byFolder: byFolder,
    covers: covers,
    lrc: lrc,
  );
}

Future<MusicPickerListing> musicPickerReadFolderAsync(String dirPath) =>
    Isolate.run(() => musicPickerReadFolder(dirPath));

Future<MusicPickerDeepScan> musicPickerDeepScanAsync(String dirPath) =>
    Isolate.run(() => musicPickerDeepScan(dirPath));

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

class _PickerFolder {
  final bool readable;
  final List<String> folders;
  final List<File> songs;

  const _PickerFolder(this.readable, this.folders, this.songs);
}

class _MusicPickerScreenState extends State<MusicPickerScreen> {
  late String _current;
  final TextEditingController _search = TextEditingController();
  int _tab = 0;

  // 3.1.24: todo lo que lee disco corre en Isolate y build() solo lee estos
  // mapas en memoria. _loadEpoch descarta respuestas de una carpeta que ya se
  // dejo (o del widget cerrado).
  int _loadEpoch = 0;
  final Map<String, _PickerFolder> _folders = <String, _PickerFolder>{};
  final Map<String, List<File>> _deep = <String, List<File>>{};
  final Set<String> _scanned = <String>{};
  final Map<String, int> _counts = <String, int>{};
  final Map<String, File?> _covers = <String, File?>{};
  final Set<String> _lrc = <String>{};
  final Set<String> _mixing = <String>{};

  @override
  void initState() {
    super.initState();
    _current = widget.rootPath;
    _load();
  }

  @override
  void dispose() {
    _loadEpoch++;
    _search.dispose();
    super.dispose();
  }

  bool get _atRoot {
    final String root = widget.rootPath;
    return _current == root || !_current.startsWith(root);
  }

  void _absorb(Map<String, String?> covers, Set<String> lrc) {
    covers.forEach((String song, String? cover) {
      _covers[song] = cover == null ? null : File(cover);
    });
    _lrc.addAll(lrc);
  }

  void _load() {
    final int epoch = ++_loadEpoch;
    final String path = _current;
    if (!_folders.containsKey(path)) {
      musicPickerReadFolderAsync(path).then(
        (MusicPickerListing data) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _folders[path] = _PickerFolder(data.readable, data.folders, <File>[
              for (final String song in data.songs) File(song),
            ]);
            _absorb(data.covers, data.lrc);
          });
        },
        onError: (Object _) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _folders[path] = const _PickerFolder(false, <String>[], <File>[]);
          });
        },
      );
    }
    if (!_scanned.contains(path)) {
      musicPickerDeepScanAsync(path).then(
        (MusicPickerDeepScan scan) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _scanned.add(path);
            _deep[path] = <File>[for (final String song in scan.all) File(song)];
            scan.byFolder.forEach((String folder, List<String> songs) {
              _deep[folder] = <File>[
                for (final String song in songs) File(song),
              ];
              _counts[folder] = songs.length;
            });
            _absorb(scan.covers, scan.lrc);
          });
        },
        onError: (Object _) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _scanned.add(path);
            _deep[path] = <File>[];
          });
        },
      );
    }
  }

  void _enqueue(File file) {
    widget.onEnqueue(file);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        persist: false,
        duration: const Duration(milliseconds: 1500),
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

  /// Usa la lista ya leida; si aun no llego, la lee en Isolate. Un segundo
  /// toque mientras resuelve se ignora (sin doble toque).
  Future<void> _mix(String path) async {
    if (_mixing.contains(path)) return;
    setState(() => _mixing.add(path));
    try {
      final List<File> files =
          _deep[path] ?? await musicPickerSongsUnderAsync(path);
      if (!mounted) return;
      await widget.onMixFolder(List<File>.of(files));
    } finally {
      if (mounted) setState(() => _mixing.remove(path));
    }
  }

  void _up() {
    final String root = widget.rootPath;
    String parent = Directory(_current).parent.path;
    if (parent != root && !parent.startsWith(root)) parent = root;
    setState(() {
      _current = parent;
      _tab = 0;
    });
    _load();
  }

  void _openFolder(String path) {
    setState(() {
      _current = path;
      _tab = 1;
      _search.clear();
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final String query = _search.text.trim().toLowerCase();
    final _PickerFolder? folder = _folders[_current];
    final bool readable = folder?.readable ?? true;
    final List<String> folders = <String>[];
    final List<File> songs = <File>[];
    if (folder != null) {
      for (final String path in folder.folders) {
        if (query.isEmpty || _pickerName(path).toLowerCase().contains(query)) {
          folders.add(path);
        }
      }
      for (final File song in folder.songs) {
        if (query.isEmpty ||
            _pickerName(song.path).toLowerCase().contains(query)) {
          songs.add(song);
        }
      }
    }

    final bool showFolders = _tab == 0 && query.isEmpty;
    bool pending = folder == null;
    if (readable && (query.isNotEmpty || (_atRoot && _tab == 1))) {
      final List<File>? deep = _deep[_current];
      songs.clear();
      if (deep == null) {
        pending = true;
      } else {
        songs.addAll(musicPickerFilterSongs(deep, _current, query));
      }
    }
    final String here = _atRoot ? 'Música' : _pickerName(_current);

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
          else if (pending)
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
                final String path = folders[index];
                final int? n = _counts[path];
                final bool mixing = _mixing.contains(path);
                return ListTile(
                  leading: const Icon(Icons.folder, color: _text, size: 28),
                  title: Text(
                    _pickerName(path),
                    style: _titleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    n == null ? '...' : '$n canciones',
                    style: _metaStyle,
                  ),
                  trailing: TextButton(
                    style: TextButton.styleFrom(
                      // Gris mientras resuelve; el boton sigue tomando el
                      // toque para que no abra la carpeta por debajo.
                      foregroundColor: mixing ? _muted : _text,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () => _mix(path),
                    child: const Text('Mezclar todo', maxLines: 1),
                  ),
                  onTap: () => _openFolder(path),
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
                  cover: _covers[song.path],
                  lrc: _lrc.contains(song.path),
                  onTap: () => _enqueue(song),
                  onPlayNext: () => widget.onPlayNext(song),
                );
              }, childCount: songs.length),
            ),
          // Espacio para que el aviso "Agregada a la cola" no tape la última
          // canción.
          const SliverToBoxAdapter(child: SizedBox(height: 72)),
        ],
      ),
    );
  }

  Widget _tabButton(String label, int index) {
    final bool selected = _tab == index;
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: selected ? _text : _muted,
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      onPressed: () => setState(() => _tab = index),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// 3.1.24: portada y .lrc llegan ya resueltos (sin disco en build).
class _SongRow extends StatelessWidget {
  final File file;
  final File? cover;
  final bool lrc;
  final VoidCallback onTap;
  final VoidCallback onPlayNext;

  const _SongRow({
    required this.file,
    required this.cover,
    required this.lrc,
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
    final File? image = cover;

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
                  child: image == null
                      ? const ColoredBox(
                          color: _card,
                          child: Icon(
                            Icons.music_note,
                            color: _muted,
                            size: 22,
                          ),
                        )
                      : Image.file(image, fit: BoxFit.cover),
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
