import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/brand_paths.dart';
import '../core/lab_quarantine.dart';
import '../core/song_watchdog.dart';
import '../providers/pipeline_provider.dart';
import 'workspaces/dsp_workspace.dart';

/// Ventana mínima para `--master-folder <ruta>`: corre el Masterizar normal
/// (mismo código y checkpoint) y anota el avance en
/// `<carpeta>/.gatomix_master_headless.log`. Al terminar cierra la app.
///
/// 1.0.13: `autoLab` → al terminar, las letras en FAIL van al Laboratorio;
/// `labRescue` → [folder] es el LAB: tras masterizar, las que quedaron bien
/// vuelven a su carpeta original (por quarantine_registry.json).
class HeadlessMasterApp extends StatelessWidget {
  final String folder;
  final bool autoLab;
  final bool labRescue;
  const HeadlessMasterApp({
    super.key,
    required this.folder,
    this.autoLab = false,
    this.labRescue = false,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: HeadlessMasterPage(
      folder: folder,
      autoLab: autoLab,
      labRescue: labRescue,
    ),
  );
}

class HeadlessMasterPage extends ConsumerStatefulWidget {
  final String folder;
  final bool autoLab;
  final bool labRescue;
  const HeadlessMasterPage({
    super.key,
    required this.folder,
    this.autoLab = false,
    this.labRescue = false,
  });

  @override
  ConsumerState<HeadlessMasterPage> createState() => _HeadlessMasterPageState();
}

class _HeadlessMasterPageState extends ConsumerState<HeadlessMasterPage> {
  late final File _log = File(
    '${widget.folder}${Platform.pathSeparator}.gatomix_master_headless.log',
  );
  String _last = '';
  DateTime _progressAt = DateTime.now();
  Timer? _watchdog;

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
    _watchdog = Timer.periodic(const Duration(minutes: 1), (_) {
      if (headlessStalled(_progressAt, DateTime.now())) {
        _write('ERROR watchdog: sin progreso en $_last');
        _watchdog?.cancel();
        exit(3);
      }
    });
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
      if (widget.autoLab && !widget.labRescue) {
        final String lab = labFolder(Directory(widget.folder).parent.path);
        for (final LabMove m in moveFailsToLab(widget.folder, lab)) {
          _write('LAB ${m.fileName} ${m.reason}');
        }
      }
      if (widget.labRescue) {
        for (final String back in restoreFixedFromLab(widget.folder)) {
          _write('DEVUELTA $back');
        }
      }
      _write('FIN');
    } catch (e) {
      _write('ERROR $e');
    }
    _watchdog?.cancel();
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PipelineState>(pipelineProvider, (prev, next) {
      final key = '${next.current}/${next.total} ${next.fileName}';
      if (key != _last && next.total > 0) {
        _last = key;
        _progressAt = DateTime.now();
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
