# CHANGELOG

## 3.0.30+49 — empate de golpe en lazo cerrado y pausa total en la mezcla

- **Fase.** Live DJ (DNA, Phrase 8 y Stealth) y Automix leen la posición oída (`audio-pts`, si no `time-pos`, si no el último dato más el tiempo medido). La espera al golpe resta la latencia de arranque medida en ese dispositivo (promedio móvil). Sin medida todavía, usa el retardo de salida de libmpv (`time-pos − audio-pts`) o cero, y el lazo corrige. Durante la mezcla se mide el desfase de los dos decks y, si pasa de 5 ms, la entrante se mueve como mucho un 1 % encima del rate de la rampa, sin sustituirlo. La bitácora anota `PHASE inicial=… final=… latencia=… pasos=…`.
- **Pausa.** En medio de la mezcla, pausa congela los dos decks, el fundido, la rampa de BPM, el lazo de fase y el resto de relojes de la mezcla en ese instante. Play sigue desde ese punto: mismos volúmenes y rates, con el tiempo de pausa fuera de los relojes. No abre otra mezcla ni salta de canción. La bitácora anota `PAUSA en mezcla t=… fade=… rampa=…` y `REANUDA …`. Fuera de la mezcla, la pausa, la reanudación tras una llamada, la Radio, el seek y el salto manual siguen como estaban.
- API Dart–Rust: no cambia.
- Igual en Windows, Android, macOS e iPhone: el código vive en `lib/providers` y `lib/core/audio`, y el iPhone entra por `lib/djiphone/`.

## 3.0.29+48 — rampa de BPM al punto medio, duración real, lista de Radio

- **Tempo.** Live DJ (DNA, incluido eco y filtro, Phrase 8 y Stealth) y Automix igualan en el punto medio: la saliente llega ahí antes del cruce y la entrante arranca ahí, en fase, y vuelve a su BPM después. Si el rate queda fuera de 0.88–1.12 se anota en la bitácora y no se recorta. `setRate` no cambia el volumen; el cruce sigue con la curva `pow`.
- **Duración.** La barra, la línea roja y el disparo usan solo `exact_duration_ms`. Se quitó la red que mezclaba a 25 s del final. Si la pista termina sin mezcla, suena la precargada y queda en `gatomix_livedj_trace.txt`. Masterizar reescribe el TLEN con la duración medida. Si difiere más de 10 s, marca `GMX_LEN_MISMATCH` y el resumen lista «posible audio pegado / versión distinta». No recorta el audio. «Revisar duraciones» recorre la carpeta, respalda en `.gatomix_original/` y solo escribe la etiqueta.
- **Radio.** Al encender «Todo» el panel muestra la lista completa. El armado ya no se descarta a los 90 s ni por un plan que no cubre la biblioteca. La bitácora anota inicio, fin y fallo con tiempo y tamaño del pool. Apagar Radio no corta el audio.
- API Dart–Rust: nueva `rewrite_tlen` (solo TLEN). El resto de la API no cambia.
- Igual en Windows, Android, macOS e iPhone: el código vive en `lib/providers`, `lib/core` y Rust, y el iPhone entra por `lib/djiphone/`.



![GatoMix](assets/branding/gatomix_logo.png)

## 1.0.14+28 — LOG CAMBIO (Masterizar: ninguna canción cuelga un lote)

- **Tope de 20 minutos por canción en Rust.** El reloj arranca al entrar a cada canción. Al pasar el tope, la canción sale con `Tiempo agotado por canción`, se borra el temporal y el original queda intacto. `GMX_SONG_TIMEOUT_S` lo cambia para pruebas.
- **Vigilante del lote sin clics** (`lib/core/song_watchdog.dart`). Si ninguna pista avanza en 30 minutos, se escribe `ERROR watchdog` en el log y el proceso sale con código 3, así el runner sigue con la carpeta siguiente.
- **Caso Kool & The Gang (2) (GMX_TEST/damaged):** no era un bucle infinito. Es un MP3 de 376 kbps y 5:55 que necesita hasta 4 pasadas de codificación y medición para el pico real y los −14 LUFS: 267 s en el box y unos 13 min en la laptop, mientras corría otro lote. Terminó solo, sin que hubiera que matar nada.
- Funciona igual en Windows, Android, macOS e iPhone.

## 1.0.13+27 — LOG CAMBIO (Masterizar: letras con transcriptor y Laboratorio automático)

- **Letras corregidas con palabras con tiempo** (`lib/core/lyric_ai_align.dart`). Usa el archivo opcional `<canción>.gmx_words.json`, que genera `tool/gmx_whisper_words.py` (faster-whisper, offline, solo en escritorio). Sin ese archivo, todo sigue igual que antes.
  - **Desfase constante confirmado:** la letra se mueve entera. Marca `GMX_RESCUE_LYR=LYRIC_FIXED:ai_constantShift`.
  - **Desfase por bloques** (puentes o intros alargadas): cada bloque se mueve con su propio desfase. Marca `LYRIC_FIXED:ai_segments`. Se rechaza si el orden se rompe o si el resultado no pasa el chequeo.
  - **Letra de otra canción:** queda la marca `FAIL:lyric_wrong_song,cov=X`, incluso cuando los tiempos parecen correctos.
  - **Casos dudosos:** quedan como `FAIL:lyric_ai_unsure,<motivo>`. Nunca se inventan tiempos.
  - **Medido en las 26 letras en REVISAR de GMX_TEST:** antes 0/26 corregidas. Ahora 7 corregidas: 4 por desfase constante y 3 por bloques, y al revisarlas de nuevo el desfase da 0 en las 7. Otras 6 quedan como letra de otra canción y 13 como dudosas con motivo.
- **Laboratorio automático:**
  - Con `--master-folder <carpeta> --auto-lab`, las letras en FAIL pasan a GatoMix_LAB junto con sus archivos compañeros (.lrc, .lrc.bak, _K, .gmx_words.json). El origen queda anotado en `quarantine_registry.json`, así que se puede revertir. Nunca se sobrescribe ningún archivo.
  - Con `--lab-rescue <LAB>`, se masteriza el Laboratorio y las pistas que quedan bien vuelven a su carpeta original.
  - El diario de fallos se guarda en `<carpeta>/.gatomix_lyric_fail.json`.
- **Rust:** nuevo test de la regla de bordes en silencio. El test `un_paquete_roto_no_recodifica_y_deja_el_motivo` ahora se llama `un_paquete_roto_se_repara_sin_perdida_y_masteriza`.
- Funciona igual en Windows, Android, macOS e iPhone (Dart puro). El transcriptor es opcional y solo para escritorio.

## 1.0.12+26 — LOG CAMBIO (Masterizar, Etapa 2 de rescate)

- **Audio dañado ya no se salta de oficio.** Los errores de "main_data offset" (reservorio de bits) que caen en silencio digital al inicio o al final (< −60 dBFS, con 250 ms de guarda) ya no bloquean el −14 LUFS. Errores con audio fuerte siguen bloqueando.
- **Reparación sin pérdida antes de rendirse** (`rust/src/mp3_repair.rs`): quita basura pegada entre/tras los cuadros, resincroniza y rehace Xing. Guarda `<archivo>.prerepair.bak` (una sola vez) y deja `GMX_RESCUE=REPAIR:<resumen> errors A->B`. Si no ayuda: `GMX_RESCUE=FAIL:repair_no_help,decode_errors=N` y el archivo no se toca.
- **Letras: más variantes en LRCLIB.** Título limpio (sin `_K`, `(Remix)`, `(Official Video)`, `- 2015 Remaster`, "Original Aspect Ratio…", `ft.`…) y artista principal (corta en ft./feat./vs./x; no en `&` ni `,`).
- **Letra que no se pudo rescatar queda marcada con motivo**: `GMX_RESCUE_LYR=FAIL:lyric_version_mismatch,audio=Xs,lrc=A-Bs` (letra de radio edit sobre un extended/remix DJ), `FAIL:lyric_before_voice` o `FAIL:manual_lyric_untouched`. Rescate exitoso: `GMX_RESCUE_LYR=LYRIC_FIXED`. Nunca se inventan tiempos.
- Medido en GMX_TEST/damaged (8 copias): antes 0/8 a −14 LUFS por `decode_errors`; ahora 7/8 (Earth, Wind & Fire/Indeep queda FAIL: corrupción real desde 171,5 s, necesita otra descarga).
- Igual en Windows, Android, macOS e iPhone (Rust + Dart puros, sin E/S nueva por plataforma).

## 1.0.0

El producto pasa a llamarse GatoMix. La app de TV pasa a llamarse GatoMix Karaoke.

Esto reemplaza el nombre anterior DjStudio (paquete `djstudio_player`, carpeta `djstudio_tv`, ejecutable `djstudio_player.exe`, APK `djstudio-tv.apk`, rol de red `djstudio-karaoke`, laboratorio `DjStudio_LAB`, caché `%LOCALAPPDATA%\DJStudio`, crate `rust_lib_djstudio_player`, tema `DjStudioTheme`).

La app sigue leyendo las etiquetas ID3 viejas `DJS_*` y, si hace falta borrarlas, también los frames `DjStudio_M3` y `DjStudio_M3_V2`. Las nuevas se escriben `GMX_*`. La carpeta de caché y el laboratorio se renombran solos si todavía existe la carpeta anterior. La regla de firewall anterior (`DjStudio REST Server` y `DjStudio TV Sync`) se quita si sigue presente.

El `applicationId` es `com.gatonegro5.gatomix` (TV: `com.gatonegro5.gatomix.tv`). Hay que desinstalar la app anterior una vez. La contraseña de la firma nueva no está en el repositorio: va en los secretos de GitHub y, en local, en `android/key.properties`.
