# LOG CAMBIO 1.0.17+31 (2026-10-25)

Version de release para pruebas en Android y iPhone. Junta todo lo de qa/v20:

- Masterizar 1.0.12 - 1.0.14: Laboratorio --auto-lab / --lab-rescue, timeout por cancion (Rust) y watchdog headless.
- 1.0.15: Descargas YT en Android sin cuelgue. Antes, youtube_explode_dart 3.1.0 recibia ~1 MB y luego HTTP 403;
  su bucle interno (HttpClient._getStream) re-pedia el manifiesto (watch page + player API) y reintentaba sin tope
  ni espera, generando cientos de peticiones por una sola "Ingestar" hasta RequestLimitExceeded.
  Ahora: trozos de 1 MB, 2 en paralelo, timeout 25 s, 3 reintentos con backoff 1/2/4 s, max 4 refrescos de URL,
  tope total 3 min, mensaje amable de rate-limit y progreso en % y MB.
- 1.0.16: Live DJ/Automix orden Secuencial, sesion atomica, Shuffle por grupos de 20.
