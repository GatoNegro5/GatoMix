# LOG CAMBIO 1.0.16+30 — Live DJ / Automix: orden, sesión que sobrevive updates, Shuffle por grupos

**Pedido (Gabriel, autorizado tocar Live DJ solo para esto):**
1. Elegir el orden de la cola en Secuencial: BPM ascendente, BPM descendente o A-Z.
2. Al entrar a Live DJ o Automix, todo igual que al salir (cola, Shuffle/Secuencial, orden, canción y posición), también después de instalar una versión nueva.
3. Shuffle: grupos de 20 con BPM subiendo, el siguiente bajando, y que los grupos nunca se repitan al volver a apretar Shuffle.

**Hallazgos:**
1. En Live DJ ese selector nunca existió en el historial de git; existía (y existe) solo en Automix (`TrackSortMode`, ícono "Ordenar"), en memoria: se perdía al cerrar.
2. La sesión ya se guardaba en `Music/DjPlaylists` (fuera de la carpeta de la app, no depende de la versión). Pero:
   - se escribía con `writeAsString` sin ser atómico ni en fila: dos guardados seguidos (cada 15 s + al añadir/quitar) o un cierre/kill durante la instalación dejaban JSON dañado → al abrir, el `catch` silencioso dejaba la cola vacía y el modo por defecto (Secuencial);
   - toda pista cuyo archivo cambió de nombre (Masterizar limpia nombres) se descartaba en silencio;
   - Automix solo restauraba Shuffle/Secuencial si había pista actual.
3. Shuffle Live DJ: armaba grupos por bandas de ≤10 BPM (no siempre de 20) y usaba 10 bancos fijos que se repetían cada 10 pulsaciones; con bandas pequeñas los grupos salían idénticos siempre. El primer grupo a veces bajaba.

**Cambios:**
- `lib/core/session_store.dart`: guardado atómico (tmp + rename), en fila por archivo, copia `.bak` del último válido y lectura con respaldo; `resolveSessionPaths` reencuentra pistas renombradas en su carpeta.
- Live DJ (`livedj_provider.dart`): `sortMode` en estado y sesión (`schema: 2`, compatible con sesiones viejas); `setSortMode`; se aplica al volver a Secuencial y a lo que se añada. Shuffle nuevo (`lib/core/livedj_order.dart`): grupos de 20 vecinos en BPM, 1º sube / 2º baja / …, sin BPM al final; historial de firmas de grupos en `_livedj_shuffle_banks.json` para no repetir. Botón "Orden" (`livedj_sort_button.dart`) junto al botón de modo en las 3 vistas.
- Automix (`automix_provider.dart`, solo persistencia): sesión/cola/escuchadas atómicas y con pistas renombradas; modo restaurado siempre; orden (`TrackSortMode`) guardado en `_automix_sort.json`.

**Se conserva:** mezcla intacta (puntos de mix-out, cue-in, fundidos, duraciones, Stealth, Radio), rutas de sesión, formato anterior de sesión (se lee igual).
**Se elimina:** NADA de funciones. Los bancos fijos de Shuffle se reemplazan por el armado nuevo (la clave vieja `lists` se descarta del archivo de bancos).
**Plataformas:** Windows, Android, macOS, iPhone (código Dart común; rutas por plataforma sin cambio).
**Riesgo:** bajo. Tests: `test/livedj_state_shuffle_test.dart`.
