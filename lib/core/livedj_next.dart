import '../providers/mix_formula.dart';

import 'audio_path.dart';
import 'gatomix_radio.dart';
import 'gatomix_store.dart';

/// Índice de la cabeza de la cola: la primera pista que no es la que suena.
/// Con la radio apagada esa cabeza es la siguiente en DNA y Phrase 8.
/// Stealth usa [offAirNextIndex].
int queueHeadIndex(List<String> paths, String? currentPath) {
  for (var i = 0; i < paths.length; i++) {
    if (currentPath == null || currentPath.isEmpty) return i;
    if (!sameAudioPath(paths[i], currentPath)) return i;
  }
  return -1;
}

/// Siguiente con la radio apagada.
/// DNA y Phrase 8: cabeza. Stealth: [pickStealthNextIndex] (BPM más cercano
/// al de la que suena; las que no tienen BPM quedan al final). -1 si no hay cola.
int offAirNextIndex({
  required List<String> paths,
  required String? currentPath,
  required bool stealth,
  required double Function(String path) bpmOf,
}) {
  if (paths.isEmpty) return -1;
  if (!stealth || currentPath == null) {
    return queueHeadIndex(paths, currentPath);
  }
  final int picked = pickStealthNextIndex(
    remaining: paths,
    currentPath: currentPath,
    bpmOf: bpmOf,
  );
  return picked < 0 ? 0 : picked;
}

/// Lo que muestra la barra «siguiente».
///
/// Radio encendida: la pista que la radio ya eligió. Radio apagada, DNA y
/// Phrase 8: la cabeza de la cola. Radio apagada y Stealth: el BPM más
/// cercano. Si todavía no hay canción sonando, la cola muestra la primera
/// como actual y la barra la segunda.
String? liveDjFollowingLabel({
  required bool radioOn,
  required String? radioNextPath,
  required List<String> queuePaths,
  required String? currentPath,
  bool stealth = false,
  double Function(String path)? bpmOf,
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
  final int i = (stealth && bpmOf != null)
      ? offAirNextIndex(
          paths: queuePaths,
          currentPath: currentPath,
          stealth: true,
          bpmOf: bpmOf,
        )
      : queueHeadIndex(queuePaths, currentPath);
  if (i < 0 || i >= queuePaths.length) return null;
  return _base(queuePaths[i]);
}

/// Barra «siguiente». En Stealth el BPM se consulta una vez por pista, cola
/// y generación del JSON: el rebuild del reloj no vuelve a abrir el archivo.
class LiveDjNextLabel {
  String? _key;
  String? _name;

  String? text({
    required bool radioOn,
    required String? radioNextPath,
    required List<String> queuePaths,
    required String? currentPath,
    required bool stealth,
    required double Function(String path) bpmOf,
  }) {
    if (radioOn || !stealth || currentPath == null || currentPath.isEmpty) {
      _key = null;
      return liveDjFollowingLabel(
        radioOn: radioOn,
        radioNextPath: radioNextPath,
        queuePaths: queuePaths,
        currentPath: currentPath,
      );
    }
    final String key =
        '${GatomixStore.generation}|$currentPath|${queuePaths.join('|')}';
    if (_key != key) {
      _key = key;
      _name = liveDjFollowingLabel(
        radioOn: false,
        radioNextPath: radioNextPath,
        queuePaths: queuePaths,
        currentPath: currentPath,
        stealth: true,
        bpmOf: bpmOf,
      );
    }
    return _name;
  }
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

/// Fin sin mezcla: si el deck de espera ya tiene la siguiente, se cruza a ESA
/// pista. Sin armado, el que llama usa forceNext.
///
/// Radio apagada: la pista armada tiene que seguir en la cola de Live DJ y no
/// puede ser la que está sonando. Radio encendida: la armada es la de la radio
/// (no tiene que estar en la cola).
bool handoffToArmedDeck({
  required bool standbyArmed,
  required String? armedPath,
  required bool radioOn,
  required bool armedIsCurrent,
  required bool armedInQueue,
}) {
  if (!standbyArmed) return false;
  if (armedPath == null || armedPath.isEmpty) return false;
  if (armedIsCurrent) return false;
  if (!radioOn && !armedInQueue) return false;
  return true;
}

/// Efecto de apagar la radio. No toca el deck: la canción que suena sigue
/// y la cola congelada vuelve a ser la visible. [nextPath] es la cabeza de
/// esa cola; si el tipo es Stealth el motor vuelve a elegir por BPM.
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
