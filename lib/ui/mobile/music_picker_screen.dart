import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../core/audio_path.dart';
import '../../core/lan_sync_plan.dart';
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

/// 3.1.38: carpetas tecnicas del selector (fuera del total de "Musica").
/// Mismo conjunto que DESTINO de LAN Sync: Descargas, DjPlaylists y LAB.
bool musicPickerTechFolder(String path) =>
    lanHiddenDestFolders.contains(_pickerName(path).toLowerCase());

String _pickerParent(String path) {
  final int cut = path.lastIndexOf(Platform.pathSeparator);
  return cut <= 0 ? path : path.substring(0, cut);
}

/// 3.1.38: crate de primer nivel bajo [root] que contiene [path]; null si
/// [path] es la raiz o esta fuera.
String? musicPickerTopCrate(String root, String path, String sep) {
  if (path == root || !path.startsWith('$root$sep')) return null;
  final String rel = path.substring(root.length + sep.length);
  final int cut = rel.indexOf(sep);
  return '$root$sep${cut < 0 ? rel : rel.substring(0, cut)}';
}

/// 3.1.38: orden de la cinta: "Musica" (raiz), ReGenial, generos con pistas,
/// Descargas y al final las tecnicas (DjPlaylists, LAB); sin carpetas con 0
/// canciones. Las subcarpetas de [parent] van justo despues de el (con
/// conteo aun sin llegar se muestran; con 0 se ocultan).
List<String> musicPickerCrates({
  required String root,
  required List<String> top,
  required Map<String, int> counts,
  String? parent,
  List<String> subs = const <String>[],
}) {
  int rank(String p) {
    final String n = _pickerName(p).toLowerCase();
    if (n == 'regenial') return 0;
    if (n == 'descargas') return 2;
    if (musicPickerTechFolder(p)) return 3;
    return 1;
  }

  final List<String> level =
      top.where((String p) => (counts[p] ?? 0) > 0).toList()
        ..sort((String a, String b) {
          final int r = rank(a).compareTo(rank(b));
          return r != 0 ? r : _pickerCompare(a, b);
        });
  final List<String> out = <String>[root];
  for (final String p in level) {
    out.add(p);
    if (p == parent) {
      out.addAll(subs.where((String s) => (counts[s] ?? 1) > 0));
    }
  }
  return out;
}

/// 3.1.38: biblioteca limpia para el crate "Musica" (total y Mezclar todo):
/// sin pistas dentro de Descargas, DjPlaylists ni LAB.
List<File> musicPickerCleanLibrary(List<File> all, String root) {
  final String sep = Platform.pathSeparator;
  return all.where((File f) {
    final String? top = musicPickerTopCrate(root, f.path, sep);
    return top == null || f.path == top || !musicPickerTechFolder(top);
  }).toList();
}

/// 3.1.25: ancho del panel lateral (45 % de la pantalla, 340..420 dp).
double musicPickerPanelWidth(double screenWidth) =>
    (screenWidth * 0.45).clamp(340.0, 420.0).toDouble();

/// 3.1.25: explorador movil como panel derecho de alto completo. La barrera
/// translucida deja ver el deck y tocar fuera cierra. El panel trae su propio
/// ScaffoldMessenger para que "Deshacer" salga dentro del panel.
Future<void> showMusicPickerPanel(
  BuildContext context, {
  required Widget Function(VoidCallback onClose) child,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Cerrar',
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (BuildContext ctx, Animation<double> _, Animation<double> _) {
      final double width = musicPickerPanelWidth(MediaQuery.sizeOf(ctx).width);
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: ScaffoldMessenger(
            child: Scaffold(
              backgroundColor: _bg,
              body: SafeArea(
                left: false,
                child: child(() => Navigator.of(ctx).pop()),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder:
        (
          BuildContext ctx,
          Animation<double> animation,
          Animation<double> _,
          Widget panel,
        ) {
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
            child: panel,
          );
        },
  );
}

/// 3.1.25: "+ Agregar canciones" de 48 px para la fila de cabecera de
/// Automix y Live DJ (sin densidad compacta).
class MusicPickerAddButton extends StatelessWidget {
  final VoidCallback onPressed;

  const MusicPickerAddButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
      child: const Text(
        '+ Agregar canciones',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class MusicPickerScreen extends StatefulWidget {
  final String rootPath;
  final List<String> queuePaths;
  final ScrollController? scrollController;
  final void Function(File file) onEnqueue;
  final void Function(File file) onUndo;
  final void Function(File file) onPlayNext;
  final Future<void> Function(List<File> files) onMixFolder;
  final VoidCallback? onClose;

  const MusicPickerScreen({
    super.key,
    required this.rootPath,
    required this.queuePaths,
    required this.onEnqueue,
    required this.onUndo,
    required this.onPlayNext,
    required this.onMixFolder,
    this.scrollController,
    this.onClose,
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
  // 3.1.38: carpeta (crate) activa; la raiz es el crate "Musica".
  late String _current;
  final TextEditingController _search = TextEditingController();

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

  void _absorb(Map<String, String?> covers, Set<String> lrc) {
    covers.forEach((String song, String? cover) {
      _covers[song] = cover == null ? null : File(cover);
    });
    _lrc.addAll(lrc);
  }

  /// 3.1.38: crate de primer nivel que contiene a [_current] (null en raiz).
  String? get _parentCrate =>
      musicPickerTopCrate(widget.rootPath, _current, Platform.pathSeparator);

  /// 3.1.38: carga el crate activo y, si es una subcarpeta, tambien su crate
  /// padre (para las subcarpetas de la cinta), con el mismo epoch.
  void _load() {
    final int epoch = ++_loadEpoch;
    final String? parent = _parentCrate;
    for (final String path in <String>{widget.rootPath, ?parent, _current}) {
      _loadPath(path, epoch);
    }
  }

  void _loadPath(String path, int epoch) {
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
            _deep[path] = <File>[
              for (final String song in scan.all) File(song),
            ];
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

  /// 3.1.38: pistas de un crate; en "Musica" la biblioteca limpia (sin
  /// Descargas, DjPlaylists ni LAB). null mientras el escaneo no llega.
  List<File>? _crateSongs(String path) {
    final List<File>? deep = _deep[path];
    if (deep == null) return null;
    if (path != widget.rootPath) return deep;
    return musicPickerCleanLibrary(deep, widget.rootPath);
  }

  /// Usa la lista ya leida; si aun no llego, la lee en Isolate. Un segundo
  /// toque mientras resuelve se ignora (sin doble toque).
  Future<void> _mix(String path) async {
    if (_mixing.contains(path)) return;
    setState(() => _mixing.add(path));
    try {
      List<File>? files = _crateSongs(path);
      if (files == null) {
        final List<File> read = await musicPickerSongsUnderAsync(path);
        files = path == widget.rootPath
            ? musicPickerCleanLibrary(read, widget.rootPath)
            : read;
      }
      if (!mounted) return;
      await widget.onMixFolder(List<File>.of(files));
    } finally {
      if (mounted) setState(() => _mixing.remove(path));
    }
  }

  void _selectCrate(String path) {
    if (path == _current) return;
    setState(() => _current = path);
    _load();
  }

  int? _crateCount(String path) =>
      path == widget.rootPath ? _crateSongs(path)?.length : _counts[path];

  @override
  Widget build(BuildContext context) {
    final String root = widget.rootPath;
    final String query = _search.text.trim().toLowerCase();
    final _PickerFolder? rootFolder = _folders[root];
    final bool readable = rootFolder?.readable ?? true;
    final String? parent = _parentCrate;
    final List<String> crates = musicPickerCrates(
      root: root,
      top: rootFolder?.folders ?? const <String>[],
      counts: _counts,
      parent: parent,
      subs: parent == null
          ? const <String>[]
          : (_folders[parent]?.folders ?? const <String>[]),
    );
    final List<File>? crateSongs = _crateSongs(_current);
    final bool pending = rootFolder == null || crateSongs == null;
    final List<File> songs = crateSongs == null
        ? const <File>[]
        : musicPickerFilterSongs(crateSongs, _current, query);
    final String here = _current == root
        ? 'M\u00fasica'
        : _pickerName(_current);

    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: <Widget>[
          // 3.1.38: barra de 48 px (buscador y Cerrar); sin pestanas.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: SizedBox(
              height: 48,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _search,
                      style: _titleStyle,
                      cursorColor: _text,
                      decoration: InputDecoration(
                        hintText: 'Buscar en $here',
                        hintStyle: _metaStyle.copyWith(
                          overflow: TextOverflow.ellipsis,
                        ),
                        hintMaxLines: 1,
                        prefixIcon: const Icon(
                          Icons.search,
                          color: _muted,
                          size: 20,
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        filled: true,
                        fillColor: _card,
                        border: const OutlineInputBorder(
                          borderSide: BorderSide.none,
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                        ),
                      ),
                      onChanged: (String _) => setState(() {}),
                    ),
                  ),
                  if (widget.onClose != null)
                    IconButton(
                      tooltip: 'Cerrar',
                      onPressed: widget.onClose,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(Icons.close, color: _text),
                    ),
                ],
              ),
            ),
          ),
          // 3.1.38: cinta horizontal de crates (56 px).
          SizedBox(
            height: 56,
            child: ListView.builder(
              key: const ValueKey<String>('crate-strip'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemCount: crates.length,
              itemBuilder: (BuildContext context, int index) =>
                  _crateChip(crates[index], parent),
            ),
          ),
          Expanded(
            child: CustomScrollView(
              controller: widget.scrollController,
              slivers: <Widget>[
                if (!readable)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        'No se pudo leer la carpeta de m\u00fasica',
                        style: _metaStyle,
                      ),
                    ),
                  )
                else if (pending)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: CircularProgressIndicator(color: _muted),
                      ),
                    ),
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
                // Espacio para que el aviso "Agregada a la cola" no tape la
                // ultima cancion.
                const SliverToBoxAdapter(child: SizedBox(height: 72)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 3.1.38: crate de la cinta: nombre + "N canciones"; el activo trae
  /// "Mezclar todo" (48 px, toma el toque aunque este resolviendo).
  Widget _crateChip(String path, String? parent) {
    final bool active = path == _current;
    final bool isRoot = path == widget.rootPath;
    final bool isSub =
        !isRoot &&
        parent != null &&
        path != parent &&
        _pickerParent(path) == parent;
    final int? n = _crateCount(path);
    final bool mixing = _mixing.contains(path);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
      child: Material(
        color: active ? _card : _bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: active ? _text : const Color(0xFF333333)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _selectCrate(path),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(width: 10),
                Icon(
                  isRoot
                      ? Icons.library_music
                      : (isSub ? Icons.subdirectory_arrow_right : Icons.album),
                  color: active ? _text : _muted,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        isRoot ? 'M\u00fasica' : _pickerName(path),
                        style: TextStyle(
                          color: active ? _text : _muted,
                          fontSize: 14,
                          fontWeight: active
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        n == null ? '...' : '$n canciones',
                        style: const TextStyle(color: _muted, fontSize: 12),
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
                if (active)
                  TextButton(
                    style: TextButton.styleFrom(
                      // Gris mientras resuelve; el boton sigue tomando el
                      // toque para que no cambie de crate por debajo.
                      foregroundColor: mixing ? _muted : _text,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(48, 48),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => _mix(path),
                    child: const Text('Mezclar todo', maxLines: 1),
                  )
                else
                  const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
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
          height: 56,
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
