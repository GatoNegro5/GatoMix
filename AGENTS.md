# AGENTS.md — GatoMix

**Lee `CONTEXTO.md` completo primero.** Es la fuente única de reglas; este archivo es un resumen y no lo sustituye. Responde en español.

## Reglas duras
1. Todo cambio cubre las 4 plataformas: Windows, Android, macOS e iPhone (`lib/djiphone/`). Si una queda fuera, dilo explícito.
2. Cambios de UI: primero `LOG CAMBIO` (formato en CONTEXTO.md §0) y esperar OK de Gabriel.
3. Cero borrado colateral: "Se elimina: NADA" salvo lo que Gabriel nombró. Si un parche quitó líneas, reponer primero.
4. No tocar `automixProvider` ni `liveDjProvider` sin autorización explícita.
5. Nunca push, tag ni merge a `main` sin orden explícita. Commits en la rama del PR sí.
6. Nunca desinstalar la app ni borrar sus datos (se pierde Isar). Instalar con `adb install -r`.
7. Solo 2 decks; medir audio en Rust/symphonia, nunca con un 3er `Player` ni FFmpeg.
8. Nunca secretos/llaves en el repo ni en el chat.
9. Prohibido fijar valores (BPM, offsets, LUFS…) por nombre de archivo o título.

## Cursor Cloud specific instructions
- Rust: `cd rust && cargo test --locked --lib`
- Flutter: `flutter analyze` y `flutter test`
- No cambiar la API Dart↔Rust (flutter_rust_bridge) sin pedido; si cambia, regenerar bindings.
- No commitear `GeneratedPluginRegistrant.swift`, `generated_plugin_registrant.cc`, `generated_plugins.cmake`.
- Probar con 1 canción real antes de cualquier lote; las pruebas sintéticas no bastan.

### Criterios de aceptación de audio (medidos en el MP3 final)
- True peak ≤ −1 dBTP.
- Sonoridad −14 LUFS ±0.3 (medida tras el encode).
- Gapless ≤ 1 ms (delay LAME + padding quitados).
- Bitrate nunca sube: ≤160→192, 161–255→256, ≥256→320; una sola codificación LAME.
- Duración medida decodificando, no con ffprobe/cabecera.
- `TBPM` existente no se sobrescribe; con errores de decodificación no se recodifica (`GMX_REASON=decode_errors=N`).
- Letra re-sincronizada: desplazamiento `.lrc` = `TRIM_MS` y `LYR=SYNC`.

### Corpus real de BPM (±2 BPM, plegado ×2/÷2 a 60–180)
| Canción | BPM |
|---|---|
| Lionel Richie — Hello | ~62 |
| a-ha — Take On Me | ~169 |
| Los Mirlos | ~89–92 |
| Glenn Frey — The Heat Is On | ~148 |
| Kool & The Gang | ~110 |
| Diana Ross | ~108 |
| Samantha Fox | ~105 |

Habrá canciones de reserva no listadas: el método debe generalizar (Davies & Plumbley / Ellis, como Mixxx), no ajustarse a esta tabla.

### Ante un fallo
No inventar: adoptar el método probado de software establecido (Rekordbox, Serato, Mixxx…), revisar licencia y escribirlo desde cero si no se puede copiar.
