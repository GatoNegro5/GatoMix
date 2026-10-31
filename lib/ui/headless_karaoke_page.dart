import 'dart:io';

import 'package:flutter/material.dart';

import '../core/gatomix_store.dart';
import '../services/karaoke_engine.dart';

/// Ventana mínima para `--karaoke-folder <ruta>`: corre [KaraokeEngine.run]
/// (mismo motor de la app) y anota el avance en `<carpeta>/.gatomix.log`
/// y en stdout. Al terminar cierra la app.
class HeadlessKaraokeApp extends StatelessWidget {
  final String folder;
  const HeadlessKaraokeApp({super.key, required this.folder});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: HeadlessKaraokePage(folder: folder),
  );
}

class HeadlessKaraokePage extends StatefulWidget {
  final String folder;
  const HeadlessKaraokePage({super.key, required this.folder});

  @override
  State<HeadlessKaraokePage> createState() => _HeadlessKaraokePageState();
}

class _HeadlessKaraokePageState extends State<HeadlessKaraokePage> {
  String _status = '';
  int _done = 0;

  void _log(String line) {
    GatomixLog.append(widget.folder, line);
    stdout.writeln('${DateTime.now().toIso8601String()} $line');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    var n = 0;
    try {
      n = await KaraokeEngine.run(
        widget.folder,
        onStatus: (s) {
          _log(s);
          if (!mounted) return;
          setState(() {
            _status = s;
            if (s.startsWith('¡Instrumental Listo')) _done++;
          });
        },
      );
    } catch (e) {
      _log('ERROR $e');
    }
    if (mounted) setState(() => _done = n);
    _log('KARAOKE_FOLDER fin: n=$n');
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Text(
          'Karaoke (sin clics)\n${widget.folder}\n'
          'listos: $_done\n$_status',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
