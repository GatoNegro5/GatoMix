import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gatomix/core/lyric_files.dart';
import 'package:gatomix/core/lyric_match.dart';
import 'package:gatomix/core/track_name_clean.dart';
import 'package:gatomix/providers/automix_provider.dart';
import 'package:gatomix/providers/nlp_provider.dart';
import 'lab_preview_player.dart';

/// Artista y título con los que abre "Buscar letra" en el Laboratorio.
class LabDialogNames {
  final String artist;
  final String title;
  const LabDialogNames(this.artist, this.title);
}

/// Separa `Artista - Título` del nombre de archivo, con o sin espacios
/// alrededor del guion (`Medardo -Casarme No`, `Medardo-La Revancha`).
LabDialogNames labNamesFromFile(String fileName) {
  final CleanTrackName clean = cleanTrackFileName(fileName);
  if (clean.artist.trim().isNotEmpty && clean.title.trim().isNotEmpty) {
    return LabDialogNames(clean.artist.trim(), clean.title.trim());
  }
  var stem = fileName.trim().replaceAll('\\', '/');
  final int slash = stem.lastIndexOf('/');
  if (slash >= 0) stem = stem.substring(slash + 1);
  stem = stem.replaceFirst(
    RegExp(r'\.(mp3|m4a|webm|wav|flac)$', caseSensitive: false),
    '',
  );
  final int dash = stem.indexOf('-');
  if (dash > 0 && dash < stem.length - 1) {
    final String a = stem.substring(0, dash).trim();
    final String t = stem.substring(dash + 1).trim();
    if (a.isNotEmpty && t.isNotEmpty) return LabDialogNames(a, t);
  }
  final String t = clean.title.trim().isNotEmpty ? clean.title.trim() : stem;
  return LabDialogNames('', t.trim());
}

/// ID3 primero (Unknown/Desconocido cuentan como vacío) y el nombre de
/// archivo rellena lo que falte. Si el título ID3 es de otra canción (no se
/// parece al nombre del archivo), manda el archivo: es lo que el usuario ve
/// seleccionado en el Laboratorio.
LabDialogNames labDialogNames({
  required String fileName,
  String id3Artist = '',
  String id3Title = '',
}) {
  final LabDialogNames file = labNamesFromFile(fileName);
  final String tagArtist = lyricFieldBlank(id3Artist) ? '' : id3Artist.trim();
  final String tagTitle = lyricFieldBlank(id3Title) ? '' : id3Title.trim();
  final bool tagIsOtherSong =
      tagTitle.isNotEmpty &&
      file.title.isNotEmpty &&
      lyricTitleScore(tagTitle, file.title) < kLyricTitleMin;
  if (tagIsOtherSong) return file;
  return LabDialogNames(
    tagArtist.isNotEmpty ? tagArtist : file.artist,
    tagTitle.isNotEmpty ? tagTitle : file.title,
  );
}

/// Mensaje cuando LRCLIB no trae nada para lo escrito.
String labNotFoundMessage(String artist, String title) {
  final String a = artist.trim();
  final String t = title.trim();
  final String who = [a, t].where((String x) => x.isNotEmpty).join(' – ');
  return 'No se encontró letra${who.isEmpty ? '' : ' para «$who»'}.\n'
      'Corrige Artista o Título y pulsa «Buscar de nuevo».';
}

/// Líneas de una letra plana para la vista previa, sin marcas `[gmx_...]`.
List<String> labPlainPreviewLines(String fileText) {
  return fileText
      .split('\n')
      .map((String l) => l.trimRight())
      .where(
        (String l) => !RegExp(r'^\[gmx_[a-z]+:\s*\d+\]$').hasMatch(l.trim()),
      )
      .toList();
}

/// `mm:ss.cc` para mostrar los tiempos de una letra sincronizada.
String labStamp(int ms) {
  final int m = ms ~/ 60000;
  final int s = (ms % 60000) ~/ 1000;
  final int cs = (ms % 1000) ~/ 10;
  String two(int v) => v.toString().padLeft(2, '0');
  return '[${two(m)}:${two(s)}.${two(cs)}]';
}

/// Encabezado de la vista previa del resultado elegido.
String labPreviewHeader(LyricCandidate hit, String fileText) {
  final int n = hit.synced
      ? parseLyricStampLines(fileText).length
      : labPlainPreviewLines(
          fileText,
        ).where((String l) => l.trim().isNotEmpty).length;
  return 'Vista previa · ${hit.artist} — ${hit.title} · '
      '${hit.synced ? 'SINCRONIZADA' : 'PLANA'} · $n líneas';
}

/// Lo que el Laboratorio escribe al cerrar la búsqueda.
class LyricSearchResult {
  final String text;
  final int? lrclibId;
  final bool noLyric;

  const LyricSearchResult({
    required this.text,
    this.lrclibId,
    this.noLyric = false,
  });
}

/// Búsqueda manual al estilo de LRCGET: puntaje, vista previa y aplicar.
class LabLyricSearch extends ConsumerStatefulWidget {
  final String audioPath;
  final String artist;
  final String title;
  final int durationSec;
  final bool medley;
  final String fileQuery;

  const LabLyricSearch({
    super.key,
    required this.audioPath,
    required this.artist,
    required this.title,
    required this.durationSec,
    required this.fileQuery,
    this.medley = false,
  });

  @override
  ConsumerState<LabLyricSearch> createState() => _LabLyricSearchState();
}

class _LabLyricSearchState extends ConsumerState<LabLyricSearch> {
  late final TextEditingController _artist;
  late final TextEditingController _title;
  final ScrollController _lyricScroll = ScrollController();
  int _lastActive = -1;
  static const double _lineH = 22;

  List<LyricCandidate> _rows = const [];
  bool _loading = true;
  bool _unavailable = false;

  /// -1 = ningún resultado elegido: Aplicar queda apagado.
  int _selected = -1;
  String _preview = '';
  int _posMs = 0;

  @override
  void initState() {
    super.initState();
    _artist = TextEditingController(text: widget.artist);
    _title = TextEditingController(text: widget.title);
    _run();
  }

  @override
  void dispose() {
    _lyricScroll.dispose();
    _artist.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _unavailable = false;
    });
    final got = await ref
        .read(nlpWorkerProvider)
        .searchManualLyrics(
          artist: _artist.text.trim(),
          title: _title.text.trim(),
          durationSec: widget.durationSec,
          query: widget.fileQuery,
          medley: widget.medley,
          audioPath: widget.audioPath,
        );
    if (!mounted) return;
    setState(() {
      _rows = got.rows;
      _unavailable = got.unavailable;
      _loading = false;
      _selected = -1;
      _preview = '';
    });
  }

  List<LyricLine> get _lines {
    return parseLyricStampLines(_preview)
        .map(
          (LyricStampLine s) => LyricLine(
            timestamp: Duration(milliseconds: s.ms),
            text: s.text,
          ),
        )
        .toList();
  }

  int get _active {
    final List<LyricLine> lines = _lines;
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].timestamp.inMilliseconds <= _posMs) idx = i;
    }
    return idx;
  }

  void _onPos(int ms) {
    setState(() => _posMs = ms);
    final int a = labActiveLine(_preview, ms);
    if (a != _lastActive && a >= 0 && _lyricScroll.hasClients) {
      final double target = ((a - 2) * _lineH).clamp(
        0,
        _lyricScroll.position.maxScrollExtent,
      );
      _lyricScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    _lastActive = a;
  }

  void _shift(int deltaMs) {
    setState(() => _preview = shiftLyricStamps(_preview, deltaMs));
  }

  void _align() {
    setState(() => _preview = alignFirstLyricLine(_preview, _posMs));
  }

  Future<void> _open(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final bool mobile = MediaQuery.sizeOf(context).width < 700;
    final LyricCandidate? hit = (_selected >= 0 && _selected < _rows.length)
        ? _rows[_selected]
        : null;
    return AlertDialog(
      backgroundColor: const Color(0xFF121212),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Colors.orangeAccent),
        borderRadius: BorderRadius.circular(8),
      ),
      title: const Text(
        '🔎 Buscar letra',
        style: TextStyle(color: Colors.orangeAccent, fontSize: 16),
      ),
      // Contenido con scroll: con el teclado abierto (celular en horizontal)
      // los campos siguen visibles y editables, y la lista no queda en 0 px.
      scrollable: true,
      content: SizedBox(
        width: mobile ? MediaQuery.sizeOf(context).width * 0.92 : 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_unavailable)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'LRCLIB no disponible',
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(child: _field(_artist, 'Artista')),
                const SizedBox(width: 8),
                Expanded(child: _field(_title, 'Título')),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _loading ? null : _run,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00FFFF),
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Buscar de nuevo'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: mobile ? 150 : 260,
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Colors.orangeAccent,
                      ),
                    )
                  : _rows.isEmpty
                  ? _empty()
                  : ListView.builder(
                      itemCount: _rows.length,
                      itemBuilder: (BuildContext ctx, int i) {
                        final LyricCandidate row = _rows[i];
                        final bool on = i == _selected;
                        final String band = lyricDeltaBand(row.deltaSec);
                        final Color durColor = band == 'green'
                            ? const Color(0xFF39FF14)
                            : band == 'amber'
                            ? Colors.orangeAccent
                            : Colors.white54;
                        return ListTile(
                          selected: on,
                          selectedTileColor: Colors.white10,
                          dense: true,
                          title: Text(
                            '${i == 0 ? '★ Recomendada · ' : ''}${row.artist} — ${row.title}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Text(
                            '${row.synced ? 'SYNC' : 'PLANA'} · ${row.durationSec}s · ${row.deltaSec}s'
                            '${row.doubtful ? ' · ${row.warning}' : ''}',
                            style: TextStyle(color: durColor, fontSize: 11),
                          ),
                          onTap: () => setState(() {
                            _selected = i;
                            _preview = row.fileText;
                          }),
                        );
                      },
                    ),
            ),
            if (hit != null && !_loading) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  labPreviewHeader(hit, _preview),
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              LabPreviewPlayer(
                audioPath: widget.audioPath,
                compact: mobile,
                onPosition: _onPos,
              ),
              Container(
                height: mobile ? 220 : 240,
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                color: Colors.black,
                child: _karaoke(),
              ),
              Wrap(
                spacing: 6,
                children: [
                  if (hit.synced) ...[
                    _chip('−1 s', () => _shift(-1000)),
                    _chip('−100 ms', () => _shift(-100)),
                    _chip('+100 ms', () => _shift(100)),
                    _chip('+1 s', () => _shift(1000)),
                    _chip('auto-alinear primera línea', _align),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar', style: TextStyle(color: Colors.white54)),
        ),
        if (_rows.isEmpty && !_loading)
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              LyricSearchResult(text: '$kLyricNoneMark\n', noLyric: true),
            ),
            child: const Text(
              'Marcar sin letra',
              style: TextStyle(color: Colors.orangeAccent),
            ),
          ),
        if (_rows.isNotEmpty)
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              foregroundColor: Colors.black,
            ),
            // Solo con un resultado elegido; aplica ESE (con sus ajustes).
            onPressed: (hit == null || _loading || _preview.trim().isEmpty)
                ? null
                : () => Navigator.pop(
                    context,
                    LyricSearchResult(text: _preview, lrclibId: hit.lrclibId),
                  ),
            child: Text(hit == null ? 'Elige un resultado' : 'Aplicar'),
          ),
      ],
    );
  }

  Widget _field(TextEditingController c, String hint) {
    return TextField(
      key: ValueKey<String>('lab-lyric-$hint'),
      controller: c,
      enabled: true,
      readOnly: false,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) {
        if (!_loading) _run();
      },
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: Colors.black,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _chip(String label, void Function() onTap) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      backgroundColor: const Color(0xFF1A1A1A),
      labelStyle: const TextStyle(color: Colors.white),
      onPressed: onTap,
    );
  }

  Widget _karaoke() {
    final List<LyricLine> lines = _lines;
    final int active = _active;
    if (lines.isEmpty) {
      // Plana: se ve la letra completa (sin la marca interna) para revisarla.
      final List<String> plain = labPlainPreviewLines(_preview);
      if (plain.isEmpty) {
        return const Text(
          'Este resultado no trae texto.',
          style: TextStyle(color: Colors.white38),
        );
      }
      return Scrollbar(
        child: ListView.builder(
          itemCount: plain.length,
          itemBuilder: (BuildContext ctx, int i) => Text(
            plain[i],
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _lyricScroll,
      itemExtent: _lineH,
      itemCount: lines.length,
      itemBuilder: (BuildContext ctx, int i) {
        final bool on = i == active;
        return Text(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          '${labStamp(lines[i].timestamp.inMilliseconds)}  ${lines[i].text}',
          style: TextStyle(
            color: on ? const Color(0xFF00FFFF) : Colors.white54,
            fontSize: on ? 15 : 13,
            fontWeight: on ? FontWeight.bold : FontWeight.normal,
          ),
        );
      },
    );
  }

  Widget _empty() {
    final String q = Uri.encodeComponent(
      '${_artist.text.trim()} ${_title.text.trim()}'.trim(),
    );
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          labNotFoundMessage(_artist.text, _title.text),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            _link('Genius', 'https://genius.com/search?q=$q'),
            _link('Musixmatch', 'https://www.musixmatch.com/search/$q'),
            _link('LRC Maker', 'https://lrc-maker.github.io/'),
          ],
        ),
      ],
    );
  }

  Widget _link(String label, String url) {
    return TextButton(onPressed: () => _open(url), child: Text(label));
  }
}

/// Escribe la letra elegida con `.bak` y la anota como manual.
Future<bool> commitLyricSearch({
  required WidgetRef ref,
  required String lrcPath,
  required LyricSearchResult result,
}) async {
  await writeLrcKeepingBak(lrcPath, result.text);
  await ref
      .read(nlpWorkerProvider)
      .rememberManualLyric(lrcPath, lrclibId: result.lrclibId);
  return lrcBakExists(lrcPath);
}
