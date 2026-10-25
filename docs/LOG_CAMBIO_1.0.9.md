## LOG CAMBIO 1.0.9+23 — Masterizar revisa el tiempo de la letra
- Pedido (Gabriel, 2026-10-24): que Masterizar detecte letras que terminan a la mitad, que pasan del final o que empiezan tarde/antes de la voz, y las corrija.
- Qué hace: tras el audio, mide el .lrc contra la duración real. Avisa si: último verso < 70 % de la canción Y faltan > 45 s; último verso > duración + 2 s; primer verso > 40 % y > 45 s; primer verso < 3 s pero la voz entra > 8 s.
- Si falla: busca otra versión en LRCLIB (con respaldos sin año / intercambiado), le aplica el recorte del audio y solo la usa si pasa el mismo chequeo. Marca GMX_LYR_CHECK=FIXED. Si no hay, deja la letra intacta, GMX_LYR_CHECK=REVIEW y sale en la lista final "Revisar en Laboratorio". Las sanas: OK.
- Corre también en canciones ya masterizadas (no reprocesa el audio).
- Se conserva: letra anterior en .lrc.bak (nunca se pisa un .bak existente); letras manuales [gmx_manual] nunca se reemplazan (quedan en REVIEW); _K.lrc recibe la misma letra con su .bak.
- Se mueve: nada. Se elimina: NADA.
- Plataformas: Windows, Android, macOS, iPhone (lógica Dart compartida + clave GMX_LYR_CHECK permitida en Rust).
- Riesgo: el inicio de voz se estima por energía en los primeros 40 s; en intros con coros o mucha percusión puede fallar (por eso solo avisa con voz > 8 s y letra < 3 s).

### Menos canciones a "Revisar en Laboratorio" (mismo 1.0.9+23)
- Antes de marcar REVIEW, Masterizar prueba la letra de Automix y además TODOS los candidatos sincronizados de LRCLIB (misma búsqueda del botón del LAB, con respaldos sin año / artista-título intercambiados), descartando los dudosos. Aplica el recorte (`shiftLrcText`) y se queda con el primero que pasa el chequeo.
- Si ninguno sirve y la letra está completa pero corrida (arranca antes de la voz, o tarde pero cabe), se mueve entera para que el primer verso caiga donde entra la voz (`lyricVoiceOnsetMs`). Solo se acepta si después pasa el chequeo. Se conserva `[gmx_shift:]`.
- Al reemplazar: `.lrc.bak` solo si no existía; se sincroniza el `_K.lrc`; `GMX_LYR_CHECK=FIXED`. Letras `[gmx_manual]` nunca se tocan.
- Código Dart puro, igual en Windows, Android, macOS e iPhone. Sin cambios en liveDjProvider ni automixProvider.
- Nuevas funciones: `firstPassingLyric`, `realignLrcToVoice` (lib/core/lyric_timing_check.dart), `syncedLyricCandidates` (nlp_provider). 9 tests nuevos.

## 1.0.11+25 — Masterizar sin clics
- Nuevo: `gatomix_player.exe --master-folder "<carpeta>"` corre el mismo Masterizar (mismo código y mismo checkpoint `.dj_master_checkpoint.json`) sin el aviso previo, anota el avance en `<carpeta>/.gatomix_master_headless.log` y cierra la app al terminar.
- Sin el argumento la app arranca igual que antes (UI sin cambios). Aplica a las 4 plataformas (solo se usa si se pasa el argumento).
- Prueba: `test/headless_args_test.dart`.
