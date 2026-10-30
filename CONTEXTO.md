# CONTEXTO — GatoMix

Fuente única. Cursor inyecta este archivo + `.cursor/rules/contexto.mdc` (alwaysApply) en cada turno. Gabriel no repite nada. Silencio ≠ permiso; "arregla/urgente" no derogan leyes.

| Campo | Valor |
|---|---|
| Repo | GatoNegro5/GatoMix |
| Stack | Flutter/Dart + Riverpod · media_kit/libmpv · Rust (symphonia, LAME, ort/tract) vía FFI |
| Plataformas | Windows · Android · macOS · iPhone (`lib/djiphone/`) |
| Carpeta | `C:\GatoMix`, UNA sola rama. Respaldos en carpeta aparte |
| Integración | Gabriel fusiona a `qa/v20` y crea los tags. El agente nunca |
| Ahora | **@3.0.31+50** · commit `c46705b` · PR #11 |

Rutas IndexedStack: 0 Automix · 1 Masterizar · 2 Descargas YT · 3 Laboratorio · 4 LAN Sync · 5 Live DJ · 6 Karaoke. Voz y FiestaDJ eliminadas: no reintroducir.

## Leyes de Gabriel
1. Calidad premium: causa raíz, medición exacta. Sin parches, topes ni heurísticas.
2. Medir exacto: nada redondeado, nunca confiar en etiquetas viejas (TBPM, TLEN).
3. Nunca borrar música: los originales se mueven a `C:\Users\ASUS\GatoMix_Respaldo\audio_pegado`. No se borran mp3, `.lrc` ni `_K`.
4. Nunca desinstalar la app ni borrar sus datos.
5. Versiones de una en una (3.0.N → 3.0.N+1), pubspec = tag.
6. Todo cambio audible necesita OK de Gabriel. Diagnosticar con él primero.
7. Cero regresiones y cero borrado colateral: el diff toca solo lo nombrado; si algo se perdió, reponer primero. `Se elimina: NADA` por defecto.
8. Nunca force-push. Nunca ramas adicionales. No push sin orden de Gabriel.
9. Todo cambio cubre las 4 plataformas; si una queda fuera, decirlo explícito.
10. UI: primero LOG CAMBIO, diff solo tras OK. Sustituir un widget = borrarlo. Cero overflow; nunca quitar hijos para que quepa.
11. SOLO 2 decks. Nunca un 3.er `Player` para medir (canción fantasma en Android). Medir con Rust/symphonia.
12. FFmpeg erradicado: nada de `ffmpeg/ffprobe` desde Dart. No borrar `rust/vendor/mp3lame-sys`, el `[patch]` ni su bit +x.
13. Zero-touch sin autorización: `automixProvider`, `liveDjProvider`, rueda LRC, SET IN/OUT, candado, Sync I/O, cola, Cartridge, sidebar 160 px, menú ☰ (7 módulos), paleta Traktor (`GatoMixTheme`).
14. Secretos nunca en chat ni en repo (`%USERPROFILE%\gatomix-keys`). No commitear los plugin registrants generados.

## Reglas de mezcla
- **Beat matching es lo más importante.**
- **Tempo:** A y B se encuentran en m=(a+b)/2. A llega a m en pasos antes del cruce; B arranca en m, en fase, y vuelve a su BPM. d≤8: 2 pasos a −10/−5 s y +5/+10 s. 8<d≤12: pesos 1-1-2-2 a −12/−9/−6/−3 s y +5/+10/+14 s. d>12: más pasos. Rate fuera de 0.88–1.12 se anota, no se inventa. `setRate` no mueve volumen.
- **Phase lock:** empuje ≤1 % hasta desfase <5 ms (`phase_lock.dart`).
- **DNA (`dna_mix.dart`, `decideDna`):** mezcla entre 60 % y 80 % de la duración efectiva; el fade completo termina antes del fin de la canción. Perfil por género Remix/EDM 65 · Tropical 80 · resto 75. Cue-in 10 s (pista >30 s), fade 18 s.
- **TIPO DE MEZCLA 1→2→3:** DNA · Phrase 8 (snap 8 compases) · Stealth (entra 5–10 %, cruza ~60 %). No borrar ninguno.
- **Pausa** congela todo, también a mitad de mezcla: ambos decks, fade, rampas y timers de fase (`mix_pause.dart`).
- **Crossfade DAWN:** logarítmico, sin sin/cos en la ganancia. Nunca cortar audio.
- **Duración real:** `exact_duration_ms` (Rust) manda barra, línea roja y disparo. Masterizar reescribe TLEN; >10 s de diferencia → `GMX_LEN_MISMATCH`, sin recortar.
- **BPM exacto (Masterizar, LAB, Descargas YT y barrido):** recta por mínimos cuadrados sobre los golpes; hipótesis de octava ×2, ×½, ×4/3, ×3/4. Grid segmentado si deriva >0,02 BPM o residuo >60 ms. Etiquetas `GMX_GRID` (ancla;periodo + segmentos), `GMX_ANALYSIS=3031`, TBPM con punto y 2 decimales. Versión 3031 = salto rápido; versión vieja = solo re-mide BPM/grid/TLEN sin tocar audio; archivo nuevo = masterizado completo. TBPM legado (`17312`, `144`, UTF-16) se lee pero no se cree.
- **Masterizado no destructivo:** BS.1770/ReplayGain y silencios a ID3; no recodificar salvo −14 LUFS fuera de ±0,3 (un solo encode). Una canción a la vez, prioridad baja, sin afinidad manual.
- **EQ adaptativa + sonoridad:** `AdaptiveEq`, 10 bandas `equalizer` (±3 dB máx.), sonoridad desplazando bandas; toda cadena `af` pasa por `AfCaps.sanitize`.
- **Letras:** matcher LRCLIB único (Automix y Letras), duración ±2 s. Fuera de `GatoMix_LAB` nunca se pisa un `.lrc`; dentro, reemplazo con `.lrc.bak`.
- **Cola estable:** añadir solo anexa; shuffle solo con el botón; cruce quita por ruta, no por índice.

## Consumo de agentes (ley)
- Solo Grok 4.7 **Medium**, 256K, Fast apagado. High/500K solo con OK de Gabriel. Nunca Claude ni otro modelo.
- Ningún agente arranca sin OK. Un agente por cambio; máximo 5 soluciones por chat, luego chat nuevo.
- Mientras itera, probar solo lo tocado; suite completa (Flutter + Rust) una vez al final. La prueba real es con Gabriel.
- No releer archivos, Grep/Read con offset, respuestas cortas, un diff. Archivar el agente al terminar.
- Al resolver algo: actualizar este CONTEXTO.md (LOG CAMBIO con OK de Gabriel).

## Casos verificados
- Robert Palmer, *Bad Case Of Loving You*: TBPM 144, medido **146,7**. Kiss: 146,7 vs 144,7. 2 BPM de error rompen el empate → BPM exacto en 3.0.31.
- Auditoría 80s Inglés (196): ≤0,1 BPM 66 · 0,1–0,5 67 · 0,5–1 32 · 1–2 18 · >2 7. Peor: Sandra *Maria Magdalena* 119 → 104,09. Octava: *Words Fell Down* 173,12 → 86,56.

## Pendiente
- Tras masterizar 80s Inglés con 3.0.31: re-auditar BPM, meta ±0,05.
- Revisar umbrales 0,05 (onset) y 60 ms (residuo); archivos >26 MB y megamixes >15 min no se miden completos.
- `nlp_provider.dart:152` `totalMs-4000`. Probar en celular: LAME Android, EQ adaptativa, duración exacta.

## LOG CAMBIO
```
Pedido: …
Se conserva: lista literal
Se mueve/compacta: …
Se elimina: NADA | lo que Gabriel nombró
Riesgo: 1920px / Mac 13" / móvil / audible
```
- 3.0.30+49 (`003aafb`): phase lock ≤1 %/<5 ms; pausa congela ambos decks y fade.
- 3.0.31+50 (`c46705b`): BPM por recta + GMX_GRID/GMX_ANALYSIS=3031; DNA 60–80 % con fade dentro de la canción.
- 3.0.32+51: pausa entre arm y el play del entrante espera; no corre mudo.
  Se conserva: mezcla sin pausa, pausa durante el fundido, DNA / Phrase 8 / Stealth, cue-in 10 s.
  Se elimina: NADA
- 3.0.33+52: Radio elige 3 próximas por adelantado (segundo plano, tras encender/cambiar género/mezcla); el armado usa la ya elegida sin await.
  Se conserva: DNA / Phrase 8 / Stealth, cue-in 10 s, fade 18 s, plan y memoria de Radio, pausa de mezcla.
  Se elimina: NADA
- 3.0.34+53: Radio = UN plan con todas las pistas del filtro (Todo = todo ReGenial); la cola muestra el plan entero desde su posición; solo la próxima se precalcula; al terminar se rearma con orden distinto y con todas.
  Se conserva: DNA / Phrase 8 / Stealth, cue-in 10 s, fade 18 s, memoria de Radio por filtro, pausa de mezcla.
  Se elimina: NADA (el tope de 3 próximas de 3.0.33 se quita por pedido)
- 3.0.35+54: cuelgue al cargar carpeta: `saveTrackMusicBatch` (una lectura y una escritura asíncrona atómica por carpeta) en `_insertLiveRandom`/`addAllTracks`; `_applyLiveShuffleBank` (migrar, BPM, ola, orden armónico, memoria de Shuffle) y los `existsSync` de `loadPlaylist` van fuera del hilo de la interfaz. Radio: al encender o cambiar filtro, un plan guardado con menos pistas que el pool se rearma con todo el pool (`_ensureRadioAssemble` con replace). BPM del Live DJ en la fila y el distintivo se muestra entero (`bpm.round()`). Shuffle deja el modo random al instante y la lista entra al terminar. Las pruebas usan raíz, JSON de radio, sesión y trace temporales.
  Se conserva: DNA / Phrase 8 / Stealth, cue-in 10 s, fade 18 s, memoria de Radio por filtro, pausa de mezcla, cola estable (lo añadido durante el armado del Shuffle se anexa).
  Se elimina: NADA
  Riesgo: UI solo el texto del BPM (entero, más corto; sin overflow); las 4 plataformas comparten el código (Windows, Android, macOS, iPhone); no cambia audio.
