import 'package:audio_service/audio_service.dart';

late DjAudioHandler globalAudioHandler;

Future<void> initGlobalAudioService() async {
  globalAudioHandler = await AudioService.init(
    builder: () => DjAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.gatonegro5.gatomix.channel.audio',
      androidNotificationChannelName: 'GatoMix',
      // 🛠️ FIX ARQUITECTÓNICO: Se elimina androidNotificationOngoing.
      // Al mantener StopForegroundOnPause en false, la notificación
      // asume el estado persistente automáticamente sin romper la aserción de compilación.
      androidStopForegroundOnPause: false,
    ),
  );
}

class DjAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  // Callbacks inyectados desde Riverpod
  void Function()? onPlayPause;
  void Function()? onNext;
  void Function()? onPrevious;
  void Function(Duration)? onSeek;

  /// Solo recents/cerrar tarea. Home/minimizar no dispara esto.
  Future<void> Function()? onAppDismissed;

  DjAudioHandler() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  // --- Dueño del control externo (notificación / pantalla de bloqueo) ---
  // Automix y Live DJ comparten esta única sesión de medios. El motor que
  // suena la reclama (`claim`) y solo el dueño puede escribir título,
  // posición y estado. Así el icono exterior siempre muestra la canción real
  // y sus botones mandan al motor correcto, también estando en pausa.
  String? _owner;
  String? _osTitle;
  Duration _osDuration = Duration.zero;
  bool Function()? isOwnerPlaying;
  Future<void> Function()? onPause;
  DateTime _lastBackgroundAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// La app pasó a segundo plano. Un `pause` del SO justo después es del
  /// minimizar, no del usuario, y se ignora (el DJ no se detiene).
  void noteAppBackgrounded() => _lastBackgroundAt = DateTime.now();

  void claim(
    String owner, {
    required void Function() onPlayPause,
    required Future<void> Function() onPause,
    required void Function() onNext,
    required void Function() onPrevious,
    required void Function(Duration) onSeek,
    required bool Function() isPlaying,
  }) {
    _owner = owner;
    this.onPlayPause = onPlayPause;
    this.onPause = onPause;
    this.onNext = onNext;
    this.onPrevious = onPrevious;
    this.onSeek = onSeek;
    isOwnerPlaying = isPlaying;
  }

  /// Sincroniza título, duración, posición y estado con el SO. Los motores
  /// que no son dueños y están detenidos no pueden pisar al dueño.
  void syncOs({
    required String owner,
    required String? path,
    required Duration duration,
    required bool playing,
    required Duration position,
  }) {
    if (_owner != null && _owner != owner) {
      if (!playing) return;
      _owner = owner;
    }
    if (playing) _owner = owner;

    if (path != null && path.isNotEmpty) {
      final title = path.replaceAll('\\', '/').split('/').last;
      if (title != _osTitle ||
          (duration.inMilliseconds > 0 && duration != _osDuration)) {
        _osTitle = title;
        if (duration.inMilliseconds > 0) _osDuration = duration;
        mediaItem.add(
          MediaItem(
            id: title,
            album: 'GatoMix',
            title: title,
            duration: _osDuration,
          ),
        );
      }
    }
    updateOsPlaybackState(playing, position);
  }

  @override
  Future<void> play() async {
    // Si ya suena, "play" no debe pausar (el icono exterior puede ir atrasado).
    if (isOwnerPlaying?.call() == true) return;
    onPlayPause?.call();
  }

  @override
  Future<void> pause() async {
    // Home/minimizar puede disparar MediaSession.pause: eso no detiene al DJ.
    if (DateTime.now().difference(_lastBackgroundAt) <
        const Duration(seconds: 2)) {
      return;
    }
    // Pausa real desde la notificación, pantalla de bloqueo o auriculares.
    if (isOwnerPlaying?.call() != true) return;
    final hook = onPause;
    if (hook != null) {
      await hook();
    } else {
      onPlayPause?.call();
    }
  }

  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrevious?.call();

  @override
  Future<void> seek(Duration position) async => onSeek?.call(position);

  @override
  Future<void> stop() async {
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
    );
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    final hook = onAppDismissed;
    if (hook != null) {
      await hook();
      return;
    }
    await stop();
  }

  void updateOsMetadata({required String title, required Duration duration}) {
    mediaItem.add(
      MediaItem(id: title, album: 'GatoMix', title: title, duration: duration),
    );
  }

  void updateOsPlaybackState(bool isPlaying, Duration position) {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          isPlaying ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        playing: isPlaying,
        updatePosition: position,
        processingState: AudioProcessingState.ready,
      ),
    );
  }
}
