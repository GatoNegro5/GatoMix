import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;

// 🛠️ PATRÓN MUTEX: Gobernador de Hardware
final hardwareGovernorProvider =
    StateNotifierProvider<HardwareGovernor, GovernorState>((ref) {
      return HardwareGovernor();
    });

class GovernorState {
  final bool isLiveDjActive;
  final int availableCores;

  GovernorState({required this.isLiveDjActive, required this.availableCores});
}

class HardwareGovernor extends StateNotifier<GovernorState> {
  HardwareGovernor()
    : super(
        GovernorState(
          isLiveDjActive: false,
          availableCores: Platform.numberOfProcessors,
        ),
      );

  // Llama a esto cuando el usuario de Play en el Live DJ
  void lockForLivePerformance() {
    state = GovernorState(
      isLiveDjActive: true,
      availableCores: state.availableCores,
    );
  }

  // Llama a esto cuando el usuario detenga la música
  void releaseLock() {
    state = GovernorState(
      isLiveDjActive: false,
      availableCores: state.availableCores,
    );
  }
}

/// 3.1.19: candado termico global para trabajos pesados offline (DSP, backfill
/// de BPM, karaoke). Jamas corren 2 a la vez: cada trabajo espera su turno en
/// orden de llegada (FIFO). Se toma por pista, nunca anidado (se trabaria).
/// `AdaptiveEq` queda fuera a proposito: la sonoridad de la pista siguiente no
/// puede esperar detras de un karaoke. Limite: solo cubre este proceso (los
/// modos headless corren en otro proceso).
class HeavyWorkGate {
  HeavyWorkGate._();

  static Future<void> _tail = Future<void>.value();
  static String? _holder;
  static int _waiting = 0;

  /// Etiqueta del trabajo que tiene el candado (null = libre).
  static String? get holder => _holder;

  /// Trabajos esperando turno.
  static int get waiting => _waiting;

  /// Corre [job] cuando no hay otro trabajo pesado en curso. Un error de
  /// [job] se propaga y el candado se libera igual.
  static Future<T> run<T>(String label, Future<T> Function() job) async {
    final Future<void> prev = _tail;
    final Completer<void> done = Completer<void>();
    _tail = done.future;
    _waiting++;
    try {
      await prev;
    } finally {
      _waiting--;
    }
    _holder = label;
    try {
      return await job();
    } finally {
      _holder = null;
      done.complete();
    }
  }
}

// 1. Nuevo Servicio de Infraestructura (Separación de Concerns)
class MediaProcessKiller {
  /// Ejecuta un SIGKILL a nivel OS. Úsese con precaución ya que afecta a procesos globales.
  static void executeGlobalHardAbort() {
    try {
      if (Platform.isWindows) {
        Process.run('taskkill', ['/F', '/IM', 'yt-dlp.exe']);
      } else {
        Process.run('killall', ['-9', 'yt-dlp']);
      }
    } catch (_) {}
  }
}

class PipelineState {
  final bool isIdle;
  final int current;
  final int total;
  final String fileName;
  final String moduleStatus;
  final List<String> quarantinedTracks;
  final bool isAborted; // Bandera atómica de cancelación

  PipelineState({
    this.isIdle = true,
    this.current = 0,
    this.total = 0,
    this.fileName = "",
    this.moduleStatus = "",
    this.quarantinedTracks = const [],
    this.isAborted = false,
  });

  PipelineState copyWith({
    bool? isIdle,
    int? current,
    int? total,
    String? fileName,
    String? moduleStatus,
    List<String>? quarantinedTracks,
    bool? isAborted,
  }) {
    return PipelineState(
      isIdle: isIdle ?? this.isIdle,
      current: current ?? this.current,
      total: total ?? this.total,
      fileName: fileName ?? this.fileName,
      moduleStatus: moduleStatus ?? this.moduleStatus,
      quarantinedTracks: quarantinedTracks ?? this.quarantinedTracks,
      isAborted: isAborted ?? this.isAborted,
    );
  }
}

class PipelineNotifier extends Notifier<PipelineState> {
  @override
  PipelineState build() => PipelineState();

  void updateProgress(
    int current,
    int total,
    String fileName,
    String moduleStatus,
  ) {
    if (state.isAborted) return; // Bloqueo de actualizaciones si está abortado
    state = state.copyWith(
      isIdle: false,
      current: current,
      total: total,
      fileName: fileName,
      moduleStatus: moduleStatus,
    );
  }

  void addQuarantine(String trackPath) {
    state = state.copyWith(
      quarantinedTracks: [...state.quarantinedTracks, trackPath],
    );
  }

  void clearQuarantine() {
    state = state.copyWith(quarantinedTracks: []);
  }

  // La X. Activa la bandera de Rust y deja isAborted para el hueco
  // entre canciones. El texto «cancelado» lo pone confirmCancelled
  // cuando el hilo de la canción ya terminó.
  void abort() {
    state = state.copyWith(isAborted: true);
    unawaited(rust_dsp.masterCancel());
    MediaProcessKiller.executeGlobalHardAbort();
  }

  void confirmCancelled() {
    state = state.copyWith(isAborted: true, moduleStatus: 'cancelado');
  }

  void reset() {
    // 🛠️ FIX: Restaurar completamente a isIdle = true y apagar el aborto
    state = PipelineState(
      isIdle: true,
      isAborted: false,
      quarantinedTracks: state.quarantinedTracks,
    );
  }
}

final pipelineProvider = NotifierProvider<PipelineNotifier, PipelineState>(
  PipelineNotifier.new,
);
