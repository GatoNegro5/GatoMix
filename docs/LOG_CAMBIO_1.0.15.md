# LOG CAMBIO 1.0.15+29 — Descargas YT en Android

**Problema:** en Android, "Ingestar" quedaba >10 min en "Descargando stream crudo de máxima calidad..." (Windows rápido).

**Causa raíz:** en móvil se usa youtube_explode_dart (no se puede ejecutar yt-dlp). Su `streamsClient.get()`:
1. YouTube entrega solo ~1 MB de las URL del cliente ANDROID sin PO token y luego responde 403.
2. Ante el 403 la librería pide un manifiesto nuevo y reintenta *sin límite* (`continue` en `_getStream`) → bucle infinito, sin timeout ni progreso, y además martilla a YouTube hasta que bloquea la IP por rate limit.
Windows/macOS usan yt-dlp, que no tiene ese bucle.

**Arreglo:** `lib/core/yt_chunked_download.dart` — descarga por trozos de 1 MB, 2 en paralelo, timeout 25 s por trozo, máx. 3 reintentos con backoff exponencial (1-2-4 s), máx. 4 refrescos de URL compartidos tras 403 rotando clientes (androidSdkless/android/ios), rate limit (RequestLimitExceeded/429) se corta al instante con mensaje "YouTube limitó temporalmente... reintenta en unos minutos", tope de 3 min con error claro, y progreso visible (% y MB). Solo afecta la rama Android/iOS de `yt_workspace.dart`; Windows/macOS siguen con yt-dlp sin cambios. Test: `test/yt_chunked_download_test.dart`.
