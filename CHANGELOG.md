# CHANGELOG

![GatoMix](assets/branding/gatomix_logo.png)

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
