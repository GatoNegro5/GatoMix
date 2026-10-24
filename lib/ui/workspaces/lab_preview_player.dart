import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'package:gatomix/core/lyric_match.dart';
import 'package:gatomix/providers/automix_provider.dart';
import 'package:gatomix/providers/livedj_provider.dart';

/// `mm:ss` de una posición en milisegundos.
String labClock(int ms) {
  if (ms < 0) ms = 0;
  final int m = ms ~/ 60000;
  final int s = (ms % 60000) ~/ 1000;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// Destino de un salto ±N ms, dentro de [0, durMs] (si se conoce la duración).
int labSeekTarget(int posMs, int deltaMs, int durMs) {
  final int t = posMs + deltaMs;
  if (t < 0) return 0;
  if (durMs > 0 && t > durMs) return durMs;
  return t;
}

/// Índice de la línea activa de una letra sincronizada (-1 si plana o antes
/// de la primera línea).
int labActiveLine(String lrcText, int posMs) {
  var idx = -1;
  final List<LyricStampLine> lines = parseLyricStampLines(lrcText);
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].ms <= posMs) idx = i;
  }
  return idx;
}

/// True si un deck (Live DJ o Automix) está sonando. Solo lectura.
bool labDeckBusy(WidgetRef ref) {
  try {
    if (ref.read(liveDjProvider).isPlaying) return true;
  } catch (_) {}
  try {
    if (ref.read(automixProvider).isPlaying) return true;
  } catch (_) {}
  return false;
}

/// Quién está sonando ahora: solo una vista previa a la vez (editor o diálogo).
final ValueNotifier<Object?> labPreviewOwner = ValueNotifier<Object?>(null);

/// Reproductor de previsualización del LAB: su propio `Player` ligero,
/// independiente de los decks. Se detiene al desmontarse (cerrar diálogo,
/// cambiar de canción con otra `key`, o salir del LAB).
class LabPreviewPlayer extends ConsumerStatefulWidget {
  const LabPreviewPlayer({
    super.key,
    required this.audioPath,
    this.onPosition,
    this.compact = false,
  });

  final String audioPath;
  final ValueChanged<int>? onPosition;
  final bool compact;

  @override
  ConsumerState<LabPreviewPlayer> createState() => _LabPreviewPlayerState();
}

class _LabPreviewPlayerState extends ConsumerState<LabPreviewPlayer> {
  final Player _player = Player();
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _guard;
  bool _opened = false;
  bool _playing = false;
  int _posMs = 0;
  int _durMs = 0;

  void _onOwner() {
    if (labPreviewOwner.value != this && _playing) _player.pause();
  }

  @override
  void initState() {
    super.initState();
    labPreviewOwner.addListener(_onOwner);
    _subs.add(
      _player.stream.position.listen((Duration p) {
        if (!mounted) return;
        setState(() => _posMs = p.inMilliseconds);
        widget.onPosition?.call(_posMs);
      }),
    );
    _subs.add(
      _player.stream.duration.listen((Duration d) {
        if (mounted) setState(() => _durMs = d.inMilliseconds);
      }),
    );
    _subs.add(
      _player.stream.playing.listen((bool v) {
        if (mounted) setState(() => _playing = v);
      }),
    );
  }

  @override
  void dispose() {
    labPreviewOwner.removeListener(_onOwner);
    if (labPreviewOwner.value == this) labPreviewOwner.value = null;
    _guard?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  void _warnDeck() {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'Hay un deck sonando: la vista previa queda en pausa para no sonar encima.',
        ),
      ),
    );
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    if (labDeckBusy(ref)) {
      _warnDeck();
      return;
    }
    if (!_opened) {
      await _player.open(Media(widget.audioPath), play: false);
      _opened = true;
    }
    labPreviewOwner.value = this;
    await _player.play();
    _guard?.cancel();
    _guard = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_playing && labDeckBusy(ref)) {
        _player.pause();
        _warnDeck();
      }
    });
  }

  Future<void> _seekTo(int ms) async {
    if (!_opened) return;
    await _player.seek(Duration(milliseconds: ms));
  }

  @override
  Widget build(BuildContext context) {
    final double max = _durMs > 0 ? _durMs.toDouble() : 1;
    final double val = _posMs.clamp(0, max.toInt()).toDouble();
    const TextStyle t = TextStyle(color: Colors.white70, fontSize: 11);
    final double ic = widget.compact ? 20 : 24;
    return Row(
      children: [
        IconButton(
          tooltip: _playing ? 'Pausa' : 'Play',
          icon: Icon(
            _playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
            color: Colors.orangeAccent,
            size: ic + 8,
          ),
          visualDensity: VisualDensity.compact,
          onPressed: _toggle,
        ),
        IconButton(
          tooltip: '−10 s',
          icon: Icon(Icons.replay_10, color: Colors.white70, size: ic),
          visualDensity: VisualDensity.compact,
          onPressed: () => _seekTo(labSeekTarget(_posMs, -10000, _durMs)),
        ),
        IconButton(
          tooltip: '+10 s',
          icon: Icon(Icons.forward_10, color: Colors.white70, size: ic),
          visualDensity: VisualDensity.compact,
          onPressed: () => _seekTo(labSeekTarget(_posMs, 10000, _durMs)),
        ),
        Text(labClock(_posMs), style: t),
        Expanded(
          child: Slider(
            value: val,
            max: max,
            activeColor: Colors.orangeAccent,
            onChanged: _durMs > 0 ? (v) => _seekTo(v.toInt()) : null,
          ),
        ),
        Text(labClock(_durMs), style: t),
      ],
    );
  }
}
