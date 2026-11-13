# CONTEXTO — GatoMix

Fuente única. Cursor inyecta este archivo + `.cursor/rules/contexto.mdc` (alwaysApply). Gabriel no repite nada. Silencio ≠ permiso; "arregla/urgente" no derogan leyes.
Revisado 4-nov-2026 contra git y código. "(no verificable)" = no se pudo comprobar.

| Campo | Valor |
|---|---|
| Repo | GatoNegro5/GatoMix · Flutter/Dart + Riverpod · media_kit/libmpv · Rust (symphonia, LAME, ort/tract) vía FFI |
| Plataformas | Windows · Android · macOS · iPhone (`lib/djiphone/`) |
| Carpeta | `C:\GatoMix` (laptop) · `/workspace/GatoMix` (box) |
| Integración | Gabriel fusiona a `qa/v20`/`main` y crea los tags. Ningún agente ni bot |
| Publicada | **v3.0.47+66** · `b522a40` · tag `v3.0.47` (sin prueba en celular; explorador roto) |
| Local laptop (sin push) | **3.1.08** (pubspec `3.1.8+30108`) · HEAD de `v3029` · sin push ni tag |
| Rama de trabajo | `cursor/v3029-bpm-duracion-radio` (todo el trabajo desde 3.0.29) |
| main | `origin/main` en `6ca12f4`, **93 commits atrás**; `qa/v20` sin fusiones |
| Ramas viejas (7) | `cursor/contexto-lecciones`, `cursor/masterizar-dispositivo-0119`, `cursor/music-library-discovery-734a`, `cursor/pull-release-assets-a1da`, `cursor/radio-lista-3025-3b35`, `fix/dup-3022`, `qa/v20` — limpiar solo con OK de Gabriel |
| Tags 3.0.4x | v3.0.41, v3.0.43, v3.0.44, v3.0.47. **Faltan v3.0.42, v3.0.45, v3.0.46** |
| PR | (no verificable: gh sin sesión) |

Rutas IndexedStack (no verificado en detalle): 0 Automix · 1 Masterizar · 2 Descargas YT · 3 Laboratorio · 4 LAN Sync · 5 Live DJ · 6 Karaoke. Voz y FiestaDJ eliminadas: no reintroducir.
Android/iOS: orientación forzada a horizontal y wakelock activo (`lib/main.dart:128-136`).

## Leyes de Gabriel
1. Calidad premium: causa raíz, medición exacta. Sin parches, topes ni heurísticas.
2. Medir exacto: nada redondeado, nunca confiar en etiquetas viejas (TBPM, TLEN).
3. Nunca borrar música: los originales se mueven a `C:\Users\ASUS\GatoMix_Respaldo\audio_pegado`. No se borran mp3, `.lrc` ni `_K`.
4. Nunca desinstalar la app ni borrar sus datos.
5. Versiones de una en una: 3.X.01 a 3.X.99 y luego 3.(X+1).01. Vista, tags y docs = 3.X.YY sin +N; pubspec = 3.X.Y+build con build = 3·10000 + X·100 + YY (3.1.01 = `3.1.1+30101`; siempre sube, sin VERSION_DOWNGRADE). Tag = v3.X.YY.
6. Todo cambio audible necesita OK de Gabriel. Diagnosticar con él primero.
7. Cero regresiones y cero borrado colateral: el diff toca solo lo nombrado; si algo se perdió, reponer primero. `Se elimina: NADA` por defecto.
8. Nunca force-push. Nunca ramas adicionales. No push sin orden de Gabriel.
8b. **Tags: SOLO Gabriel crea tags.** Ningún agente ni bot crea, mueve ni sube tags (v3.0.44 y v3.0.47 los creó un bot: no repetir).
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
- **Antes de pedirle a Gabriel que baje una versión: instalación limpia en Android (emulador o celular) y recorrido completo.**
- Mientras itera, probar solo lo tocado; suite completa (Flutter + Rust) una vez al final. La prueba real es con Gabriel.
- No releer archivos, Grep/Read con offset, respuestas cortas, un diff. Archivar el agente al terminar.
- Al resolver algo: actualizar este CONTEXTO.md (LOG CAMBIO con OK de Gabriel).

## Casos verificados
- Robert Palmer, *Bad Case Of Loving You*: TBPM 144, medido **146,7**. Kiss: 146,7 vs 144,7. 2 BPM de error rompen el empate → BPM exacto en 3.0.31.
- Auditoría 80s Inglés (196): ≤0,1 BPM 66 · 0,1–0,5 67 · 0,5–1 32 · 1–2 18 · >2 7. Peor: Sandra *Maria Magdalena* 119 → 104,09. Octava: *Words Fell Down* 173,12 → 86,56.

## Errores que ya regresaron
| Error | Versiones | Archivo / función | Causa | Prueba automática | Prueba manual en celular |
|---|---|---|---|---|---|
| Radio repite canción / no avanza | 3.0.25, 3.0.33, 3.0.34, 3.0.35, 3.0.43, 3.0.44 | `lib/core/gatomix_radio.dart` (`syncRadioPlan`, `radioPlanNext`, `advanceRadioPlan`), `lib/core/livedj_next.dart`, `lib/providers/livedj_provider.dart` | Estado repartido en 3 archivos; tareas en 2.º plano con carreras (3.0.44: pending = la que acaba de sonar) | `radio_loop_3025`, `radio_off_3025`, `radio_ahead_3033`, `gatomix_radio_test`, `livedj_arm_race_3043`, `livedj_radio_pending_3044` | Radio ON en Live DJ, 10 mezclas seguidas: ninguna repetida ni "una sí, una no"; apagar radio no toca el deck |
| YouTube 403 / descarga Android | 1.0.15, 3.0.38, 3.0.45, 3.0.46 | `lib/ui/workspaces/yt_workspace.dart`, `lib/core/yt_chunked_download.dart`, NewPipe en `android/.../MainActivity.kt` | Cambios de YouTube; se probaba en PC y no en Android | `yt_403_resume_3045`, `yt_chunked_download`, `yt_preview_timeout_3046`. **NewPipe (3a2843b): SIN PRUEBA — falta** | Vista previa suena; Ingestar "Camilo - Manos de Tijera" baja MP3 completo |
| Explorador móvil / poner canciones | 3.0.45, 3.0.47, 3.0.48 | `lib/ui/mobile/music_picker_screen.dart`, `livedj_workspace.dart`, `automix_workspace.dart` | Widget viejo no se borró (ley 10); 3.0.47 publicada sin probar en celular | `music_picker_3045`, `mobile_explorer_3048`, `music_picker_recursive_3048`. Hoja 3.0.47 y botón radio: **SIN PRUEBA — falta** | Automix y Live DJ: "+ Agregar canciones" → buscar, encolar 4, suenan; no queda columna vieja ni disco verde |
| Letras (LRCLIB, alineación, .lrc) | ~15 commits 1.0.x → 3.0.47 | `lib/core/lyric_match.dart`, `lib/services/lyric_retry_queue.dart`, `lib/providers/nlp_provider.dart` | Heurísticas acumuladas; LRCLIB 503 confundido con bug | `lyric_*_test` (match, approx, variants, timing_check, shift_on_trim, retry_queue…) | Ingestar sin red de letras: MP3 queda, aparece aviso y luego "Letra agregada" |
| Cuelgues / CPU en UI | 3.0.23, 3.0.24, 3.0.35 | `livedj_provider.dart` (`_insertLiveRandom`, `_applyLiveShuffleBank`), `gatomix_store.dart` (`saveTrackMusicBatch`) | Trabajo pesado reintroducido en el hilo de UI | `radio_cpu_3022`, `tick_work_3024`, `batch_save_3035` | Cargar carpeta grande y Shuffle: la pantalla no se congela, el celular no calienta |

## Fixes sin prueba de regresión
- 3.0.41 (`0f87fe1`, limitador/BPM en Rust): sin test Dart; tests Rust internos (no verificable).
- 3.0.46 NewPipe solo M4A + wakelock (`3a2843b`).
- 3.0.47 hoja del explorador y botón PRENDE/APAGA MODO RADIO (`734caff`); YT encola letra (`b522a40`).
- 3.0.48 letra Automix 80 dp (`5dddcbc`).
- Ninguna versión tiene prueba de extremo a extremo en Android.

## Pendiente
1. **Explorador móvil: Gabriel quiere rediseñarlo con él antes de más cambios.** No tocarlo sin su OK.
2. Decidir con Gabriel si la app sigue siempre acostada (`lib/main.dart:130-133`); hoy no hay vertical.
3. 3.0.48: probar en celular real; push y tag solo por orden de Gabriel (el tag lo crea él). Detalle: el aviso de cola tapa la última fila 1,5 s.
4. Confirmar en celular: YT/NewPipe 3.0.46, radio 3.0.44, letra en 2.º plano 3.0.47 (no verificable si ya se hizo).
5. Fusionar la rama a `qa/v20`/`main` y limpiar las 7 ramas viejas (decide Gabriel).
6. Bajón de volumen en la primera mezcla de Live DJ (no verificable). ¿MP3 320 kbps en móvil? (no verificable).
7. Re-auditar BPM de 80s Inglés tras 3.0.31 (meta ±0,05); umbrales 0,05 (onset) y 60 ms (residuo); megamixes >=15 min: streaming de envolvente en Rust (Opcion B) y quitar la marca de masterizado falsa de los megamixes ya marcados.
8. Probar en celular: LAME Android, EQ adaptativa, duración exacta.
9. Lote de karaoke `_K` en la laptop: estado desconocido.
10. Cerrado en 3.1.05: LAN Sync: copiar archivos sin _K y con _K/_k (case-insensitive en las 4 plataformas) y acelerar descubrimiento/transferencia en el mismo Wi-Fi.
11. Camino A cerrado en 3.1.08: guardia >30 min en `karaoke_separate` y en `KaraokeEngine.run()`; los 6 _K truncados a 30:00 (Cumbancheros, Tierra Canela, Hora Loca, Salsa Brava, Juan Gabriel, Rumbero) se conservan y quedan para el Pendiente 15.
12. Cerrado en 3.1.08 (datos, sin codigo): 4 mp3 de ReGenial (Oscar D Leon - Lloraras, David Zahan - Nunca Te Quedas, Gerardo Moran - No Voy A Llorar, Zz Top - Tush) tenian bloques de ceros entre frames; compactados con frames y exactDurationMs identicos y respaldo .bak en `C:\Users\ASUS\GatoMix_Respaldo\t1308_ceros`.
13. Cerrado en 3.1.06 (archivos huerfanos eliminados): errores preexistentes de `dart analyze` en `lib/providers/pipeline_controller.dart` (imports inexistentes core_metadata/core_dsp/core_nlp/core_bpm) y `lib/src/rust/api/simple.dart` (crateApiSimpleGreet), sin cambios desde `3105b64`.
14. Cerrado en 3.1.07: reintento transparente en el bucle de envio de LAN Sync escritorio usando `lanSendWithRetry` por debajo, sin tocar ningun widget ni texto de la UI.
15. Camino B de karaoke: separacion por ventanas/streaming en Rust para pistas de >30 min sin pasar el tope de RAM (~635 MB decodificados a 1800 s, estimado). Al cerrarlo, regenerar los 6 _K truncados del Pendiente 11 (hoy se omiten con `>30 min (pendiente streaming)`).

## Notas de entorno (box)
- Emulador: `chmod 666 /dev/kvm`; `~/Android/emulator/emulator -avd gm34 -no-window -gpu swiftshader_indirect -no-audio -no-snapshot -memory 2048 -cores 4`. Para x64 hace falta la lib Rust x86_64 (cambio temporal en `rust_builder/cargokit/gradle/plugin.gradle` `resolvePlatforms` y `abiFilters`, luego revertir).
- Gabriel no puede pagar Sonnet: solo Grok Medium o arreglos hechos en la box.

## LOG CAMBIO
```
Pedido: …
Se conserva: lista literal
Se mueve/compacta: …
Se elimina: NADA | lo que Gabriel nombró
Riesgo: 1920px / Mac 13" / móvil / audible
Plataformas (Win | Mac | Android | iPhone): .
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
- 3.0.36+55 (`3105b64`): los archivos de una pista (mp3, .lrc, _K) viajan juntos al LAB.
  Se conserva: cuarentena LAB, .lrc.bak. Se elimina: NADA
- 3.0.37+56 (`aa628e3`, `284da20`): GatomixLog reemplaza el log oculto (Windows); prueba de versión lee pubspec.
  Se conserva: logs existentes. Se elimina: log oculto viejo (sustituido)
- 3.0.38+57 (`ddb1487`): descarga YT, re-descarga desde LAB, aviso BPM 0, errores de rescate visibles, acompañantes LAB.
  Se conserva: flujo YT y LAB. Se elimina: NADA
- 3.0.39 (`f0a76b6`): BPM estimado por carpeta; rescate LAB prefiere m4a.
  Se conserva: BPM exacto 3031. Se elimina: NADA
- 3.0.40 (`533ab68`): detector BPM robusto, sin promedio por carpeta (revierte el de 3.0.39); Masterizar 1 decode / 1 encode.
  Se conserva: BPM por recta, masterizado no destructivo. Se elimina: promedio por carpeta de 3.0.39
- 3.0.41 (`0f87fe1`, tag v3.0.41): limitador O(1), un solo encode, bitrate VBR, BPM Adele/Despacito (Rust).
  Se conserva: −14 LUFS ±0,3. Se elimina: NADA
- 3.0.42 (`bef2235`, sin tag): `--karaoke-folder` headless.
  Se conserva: Karaoke UI. Se elimina: NADA
- 3.0.43 (`5d12cc6`, tag v3.0.43): Live DJ no mezcla una pista consigo misma (`livedj_next.dart`, `livedj_provider.dart`).
  Se conserva: DNA / Phrase 8 / Stealth, cola estable. Se elimina: NADA
- 3.0.44+63 (`e6fe616`, tag v3.0.44): radio repetía "una sí, una no": el pending solo se usa si no es la que suena ni la anterior.
  Se conserva: plan y memoria de Radio. Se elimina: NADA
- 3.0.45 (`2707591`, `4dbc163`, sin tag): LAN destino Música (raíz), picker solo móvil, `moveFile`, resume YT tras 403; fix de compilación del const de clientes YT.
  Se conserva: LAN Sync, yt-dlp en Windows. Se elimina: NADA
- 3.0.46+65 (`aa7966f`, `3a2843b`, sin tag): Android usa NewPipe para vista previa e Ingestar (solo M4A); Windows sigue con yt-dlp; wakelock 1.3.3. "Probado en celular": no verificable.
  Se conserva: yt-dlp Windows. Se elimina: NADA
- 3.0.47+66 (`734caff`, `b522a40`, tag v3.0.47 creado por bot — no repetir): botón "PRENDE / APAGA MODO RADIO" (`livedj_workspace.dart:447`, `livedj_folder_playlist.dart:630`); explorador móvil en hoja "+ Agregar canciones"; cola de reintento de letras (`lib/services/lyric_retry_queue.dart`, cada 1 min, aviso "Letra agregada"; causa LRCLIB 503). **Falló en celular:** quedaban la columna vieja y el disco verde (viola ley 10).
  Se conserva: cola, Cartridge, radio. Se elimina: NADA (debió eliminar el explorador viejo)
- 3.0.48+67 (`054686b`, `8468d77`, `65fe2ae`, `5dddcbc`, local, sin push ni tag): en móvil se quitan la columna vieja y el disco verde, solo "+ Agregar canciones"; aviso de cola 1,5 s no persistente; Canciones y búsqueda recursivas desde la raíz; letra Automix horizontal 80 dp. Probado solo en emulador `gm34`, horizontal.
  Se conserva: escritorio sin cambios, cola, Cartridge. Se elimina: columna vieja de carpeta y disco verde en móvil (pedido de Gabriel)
- Infra (sin cambio de versión, local, sin push ni tag): CI `release.yml` con job `test` (`flutter test` + `cargo test` en rust/) que bloquea build y release si falla. `integration_test/simple_test.dart` (plantilla) → `smoke_app_test.dart` (arranca motores reales, Automix, "+ Agregar canciones", Live DJ "MODO RADIO"). `GATOMIX_EMU=1` agrega x86_64 (app y Cargokit) solo para el emulador `gm34`; el release sigue arm64. Estado al commit: `flutter test` 401 OK / **2 fallan preexistentes** (`mobile_explorer_3048_test`: "hoja 360x800 / 800x400: tocar canción la encola", no encuentra "Cancion") → **CI quedará en rojo hasta arreglarlos**; `cargo test` 42 OK, 6 ignorados. Humo en gm34 **FALLA por 2 bugs reales de la app**: (1) `LiveDjNotifier._initPersistence` sin sesión guardada (instalación nueva) llama `_schedulePhraseNeighbors` dentro de `build` → "uninitialized provider" (`livedj_provider.dart` ≈1103/312); (2) sin permiso de almacenamiento, `LabWorkspace._loadRegistry` (`lab_workspace.dart:140`) hace `writeAsStringSync` sin try en `initState` → PathAccessException. Correr: `GATOMIX_EMU=1 flutter test integration_test -d emulator-5554` (antes: `adb shell appops set com.gatonegro5.gatomix MANAGE_EXTERNAL_STORAGE allow` con la app instalada).
- 3.0.48 fixes (`73a4ca3`, `87080f4`, `3df1aec`, sin tag): la prueba 3048 espera la búsqueda async; Live DJ difiere `_schedulePhraseNeighbors` hasta después de `build()`; Lab no tumba la app sin permiso de almacenamiento. No verificado en celular.
  Se elimina: NADA
- 3.1.01 (pubspec `3.1.1+30101`, `7c0e261`): nuevo versionado 3.X.YY sin +N (Ley 5); `AppVersionLabel.format()` muestra `3.1.01 (sha)`.
  Se conserva: firma de `format()`, estilo 11 px white38, entradas 3.0.xx+N. Se elimina: NADA (solo el texto "build N" visible)
- 3.1.02 (pubspec `3.1.2+30102`, `85ab67e`): cues automáticos de la letra con la duración exacta en ms (sin redondeo a segundos); reglas en `lib/core/vocal_bounds.dart` (+ test con datos reales). Letra con última línea >= duración real (otra versión) no escribe cues en Isar. Rama <3 s: `exactMs - 4000` (antes `totalRound - 4000`).
  Se conserva: ramas >15 s y normal, salida con cues manuales, `isManualCue: false`, `_getLocalDurationSec` para matching de letra, exact_mix/Automix/Live DJ. Se elimina: NADA
- 3.1.03 (pubspec `3.1.3+30103`, `520a512`): Automix ignora la última línea de la letra si llega o pasa la duración exacta (`lyricPastAudio` en `vocal_bounds.dart`) y decide el ADN; antes el mixOut quedaba tras el final (Bacilos 286880 vs 254783) y sin plan no había crossfade.
- 3.1.04 (pubspec `3.1.4+30104`, `e169c1e`, base `8c00387`): el DSP decide por duracion exacta de Rust (`fitsAnalysisWindow` < 900 s, `lib/core/analysis_window.dart`) y no por tamano (> 26 MB) en `dsp_provider.dart` (cache, lote y `analyzeTrack`); los megamixes >= 15 min devuelven `false` y ya no reciben marca de agua falsa. Paso 0: 7 pistas > 26 MB y < 15 min ahora se miden; 18 megamixes quedan para streaming.
- 3.1.05 (pubspec `3.1.5+30105`, `a7e5cf5`): LAN Sync (`lan_sync_workspace.dart`, autorizado Zero-Touch Sync I/O) con reglas puras en `lib/core/lan_sync_plan.dart`: hermanos `.lrc`/`.txt`/`_K`/`_k` sin distinguir mayusculas, "ya existe" = mismo nombre y mismo tamano (los parciales se reenvian), receptor y descarga escriben en `.part` y renombran (un `.part` viejo se sobrescribe; nunca se lista), destino reutiliza el nombre con otras mayusculas, escritorio elige IP como el movil (prefiere Wi-Fi, ignora 169.254), ultimo equipo probado primero (400 ms), un solo cliente HTTP por tanda (Keep-Alive) y log de MB/s.
- 3.1.06 (pubspec `3.1.6+30106`, `c130b23`): se eliminan 2 archivos huerfanos que nunca compilaron y nadie importaba: `lib/providers/pipeline_controller.dart` (copia muerta; importaba core_metadata/core_dsp/core_nlp/core_bpm inexistentes; `3105b64` la edito por error, la cuarentena con companionsOf vive en `lib/core/lab_quarantine.dart`) y `lib/src/rust/api/simple.dart` (plantilla `greet` de flutter_rust_bridge sin `simple.rs`). El controlador vivo es `lib/core/pipeline_controller.dart`.
- 3.1.07 (pubspec `3.1.7+30107`, `8949427`): LAN Sync escritorio reintenta cada subida con `lanSendWithRetry` (1 + 3, esperas 1/2/4 s, 403 sin reintento) sobre el mismo `http.Client`, via `lanUploadOnce` que vacia la respuesta (`drain`) para que el socket vuelva al pool (Keep-Alive real). Solo suma a Saltados/Fallos si fallan todos los intentos. Rama movil, textos y widgets sin cambios.
- 3.1.08 (pubspec `3.1.8+30108`): `karaoke_separate` decodifica hasta 1801 s y devuelve `Err(">30 min (pendiente streaming)")` antes de crear el `Mp3Sink` si la pista pasa de 1800 s (tope de RAM intacto, sin _K parcial). `KaraokeEngine.run()` mide `exactDurationMs` de cada pista antes de separar y omite las de >=30 min con status `Omitida (>30 min, pendiente streaming)`; `_collect` solo manda a revisar los _K usables de >=72.000.000 B (1800 s a 320 kbps), asi los otros _K no pagan I/O. Los 6 _K truncados se conservan hasta el Camino B (Pendiente 15). Datos: 4 mp3 de ReGenial compactados (bloques de ceros entre frames; frames y exactDurationMs identicos; respaldo en `GatoMix_Respaldo\t1308_ceros`). Plataformas (Win | Mac | Android | iPhone): las 4, logica comun Rust/Dart sin codigo de plataforma; requiere recompilar la libreria nativa.
  Se conserva: `lastLyricMs + 1500` en letras sanas, rama ADN, SET IN/OUT, plan del outro (clamp 1040), disparos 1790/1852. Se elimina: NADA
