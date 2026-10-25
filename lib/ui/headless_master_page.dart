import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/pipeline_provider.dart';
import 'workspaces/dsp_workspace.dart';

/// Ventana mínima para `--master-folder <ruta>`: corre el Masterizar normal
/// (mismo código y checkpoint) y anota el avance en
/// `<carpeta>/.gatomix_master_headless.log`. Al terminar cierra la app.
class HeadlessMasterApp extends StatelessWidget {
  final String folder;
  const HeadlessMasterApp({super.key, required this.folder});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: HeadlessMasterPage(folder: folder),
  );
}

class HeadlessMasterPage extends ConsumerStatefulWidget {
  final String folder;
  const HeadlessMasterPage({super.key, required this.folder});

  @override
  ConsumerState<HeadlessMasterPage> createState() => _HeadlessMasterPageState();
}

class _HeadlessMasterPageState extends ConsumerState<HeadlessMasterPage> {
  late final File _log = File(
    '${widget.folder}${Platform.pathSeparator}.gatomix_master_headless.log',
  );
  String _last = '';

  void _write(String line) {
    try {
      _log.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    _write('INICIO ${widget.folder}');
    try {
      await const DspNlpWorkspace().runHeadlessMaster(
        context,
        ref,
        widget.folder,
      );
      _write('FIN');
    } catch (e) {
      _write('ERROR $e');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PipelineState>(pipelineProvider, (prev, next) {
      final key = '${next.current}/${next.total} ${next.fileName}';
      if (key != _last && next.total > 0) {
        _last = key;
        _write('PISTA $key');
      }
    });
    final s = ref.watch(pipelineProvider);
    return Scaffold(
      body: Center(
        child: Text(
          'Masterizar (sin clics)\n${widget.folder}\n'
          '${s.current}/${s.total} ${s.fileName}\n${s.moduleStatus}',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
