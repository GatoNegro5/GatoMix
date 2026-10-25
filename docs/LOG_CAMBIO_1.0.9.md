## LOG CAMBIO 1.0.9+23 — Masterizar revisa el tiempo de la letra
- Pedido (Gabriel, 2026-10-24): que Masterizar detecte letras que terminan a la mitad, que pasan del final o que empiezan tarde/antes de la voz, y las corrija.
- Qué hace: tras el audio, mide el .lrc contra la duración real. Avisa si: último verso < 70 % de la canción Y faltan > 45 s; último verso > duración + 2 s; primer verso > 40 % y > 45 s; primer verso < 3 s pero la voz entra > 8 s.
- Si falla: busca otra versión en LRCLIB (con respaldos sin año / intercambiado), le aplica el recorte del audio y solo la usa si pasa el mismo chequeo. Marca GMX_LYR_CHECK=FIXED. Si no hay, deja la letra intacta, GMX_LYR_CHECK=REVIEW y sale en la lista final "Revisar en Laboratorio". Las sanas: OK.
- Corre también en canciones ya masterizadas (no reprocesa el audio).
- Se conserva: letra anterior en .lrc.bak (nunca se pisa un .bak existente); letras manuales [gmx_manual] nunca se reemplazan (quedan en REVIEW); _K.lrc recibe la misma letra con su .bak.
- Se mueve: nada. Se elimina: NADA.
- Plataformas: Windows, Android, macOS, iPhone (lógica Dart compartida + clave GMX_LYR_CHECK permitida en Rust).
- Riesgo: el inicio de voz se estima por energía en los primeros 40 s; en intros con coros o mucha percusión puede fallar (por eso solo avisa con voz > 8 s y letra < 3 s).
