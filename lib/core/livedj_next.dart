import 'audio_path.dart';
import 'gatomix_radio.dart';

/// Índice de la cabeza de la cola: la primera pista que no es la que suena.
/// Con la radio apagada esa cabeza es la siguiente, en DNA, Phrase y Stealth.
int queueHeadIndex(List<String> paths, String? currentPath) {
  for (var i = 0; i < paths.length; i++) {
    if (currentPath == null || currentPath.isEmpty) return i;
    if (!sameAudioPath(paths[i], currentPath)) return i;
  }
  return -1;
}

/// Lo que muestra la barra «siguiente».
///
/// Radio encendida: la pista que la radio ya eligió. Radio apagada y con
/// una canción sonando: la cabeza de la cola. Si todavía no hay canción
/// sonando, la cola muestra la primera como actual y la barra la segunda.
String? liveDjFollowingLabel({
  required bool radioOn,
  required String? radioNextPath,
  required List<String> queuePaths,
  required String? currentPath,
}) {
  if (radioOn) {
    if (radioNextPath == null || radioNextPath.isEmpty) {
      return 'RADIO ▸ eligiendo…';
    }
    return 'RADIO ▸ ${_base(radioNextPath)}';
  }
  if (queuePaths.isEmpty) return null;
  if (currentPath == null || currentPath.isEmpty) {
    if (queuePaths.length < 2) return null;
    return _base(queuePaths[1]);
  }
  final int i = queueHeadIndex(queuePaths, currentPath);
  if (i < 0) return null;
  return _base(queuePaths[i]);
}

/// Panel derecho. Radio encendida: la lista de la opción, ya en memoria.
/// Radio apagada: la cola de Live DJ, intacta.
List<String> liveDjSidePaths({
  required bool radioOn,
  required List<String> queuePaths,
  required List<String> radioUpcoming,
}) {
  if (radioOn) return radioUpcoming;
  return queuePaths;
}

/// Siguientes de la radio desde la posición del plan (la que dice la barra).
/// No incluye lo ya consumido. Sin plan, solo la próxima si ya se eligió.
List<String> radioUpcomingPaths({RadioPlan? plan, String? nextPath}) {
  if (plan != null && plan.order.isNotEmpty && !plan.finished) {
    final int start = plan.position.clamp(0, plan.order.length);
    if (start < plan.order.length) {
      return List<String>.from(plan.order.sublist(start));
    }
  }
  if (nextPath != null && nextPath.isNotEmpty) return <String>[nextPath];
  return const <String>[];
}

/// Un armado de radio que ya salió no puede cambiar la siguiente.
bool radioArmStillValid({
  required bool radioOn,
  required int epoch,
  required int armEpoch,
}) {
  return radioOn && epoch == armEpoch;
}

/// Efecto de apagar la radio. No toca el deck: la canción que suena sigue,
/// la cola congelada vuelve a ser la visible y la siguiente es su cabeza.
class RadioOffEffect {
  final bool touchDeck;
  final List<String> deckCommands;
  final bool radioOn;
  final List<String> queue;
  final String? playing;
  final String? nextPath;

  const RadioOffEffect({
    required this.touchDeck,
    required this.deckCommands,
    required this.radioOn,
    required this.queue,
    required this.playing,
    required this.nextPath,
  });
}

RadioOffEffect effectOfRadioOff({
  required List<String> queue,
  required List<String>? frozenQueue,
  required String? playing,
}) {
  final List<String> kept = frozenQueue ?? queue;
  final int i = queueHeadIndex(kept, playing);
  return RadioOffEffect(
    touchDeck: false,
    deckCommands: const <String>[],
    radioOn: false,
    queue: kept,
    playing: playing,
    nextPath: i < 0 ? null : kept[i],
  );
}

String _base(String path) => path.replaceAll('\\', '/').split('/').last;
