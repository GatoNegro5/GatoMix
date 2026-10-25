import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../brand_paths.dart';

/// Info pública del artista (foto, fans, mini biografía). Fuentes gratuitas
/// sin clave: Deezer (foto y fans) y Wikipedia (biografía). Con caché en disco:
/// sin internet se ve igual lo ya consultado; sin dato devuelve null y la UI
/// queda como siempre (nunca lanza error).
class ArtistInfo {
  final String name;
  final String? photoPath; // archivo local en caché
  final int fans;
  final String bio;

  const ArtistInfo({
    required this.name,
    this.photoPath,
    this.fans = 0,
    this.bio = '',
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'photoPath': photoPath,
    'fans': fans,
    'bio': bio,
  };

  static ArtistInfo fromJson(Map<String, dynamic> j) => ArtistInfo(
    name: (j['name'] ?? '').toString(),
    photoPath: j['photoPath'] as String?,
    fans: (j['fans'] as num?)?.toInt() ?? 0,
    bio: (j['bio'] ?? '').toString(),
  );
}

/// Artista = texto antes de " - " del nombre de archivo; solo el principal.
String artistFromPath(String path) {
  var name = path.replaceAll('\\', '/').split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  final i = name.indexOf(' - ');
  if (i <= 0) return '';
  var a = name.substring(0, i).trim();
  a = a
      .split(
        RegExp(
          r'\s*(?:,|&|\bft\.?\b|\bfeat\.?\b|\bx\b| y )\s*',
          caseSensitive: false,
        ),
      )
      .first;
  return a.trim();
}

final Map<String, Future<ArtistInfo?>> _mem = {};

Directory _cacheDir() {
  final base = Platform.isWindows
      ? (Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path)
      : Directory.systemTemp.path;
  final d = Directory(
    '${ensureBrandDataDir(base).path}${Platform.pathSeparator}artists',
  );
  d.createSync(recursive: true);
  return d;
}

String _key(String artist) =>
    artist.toLowerCase().replaceAll(RegExp(r'[^a-z0-9áéíóúñü]+'), '_');

Future<ArtistInfo?> loadArtistInfo(String artist) {
  final a = artist.trim();
  if (a.isEmpty) return Future.value(null);
  return _mem
      .putIfAbsent(a.toLowerCase(), () async {
        final dir = _cacheDir();
        final meta = File(
          '${dir.path}${Platform.pathSeparator}${_key(a)}.json',
        );
        try {
          if (meta.existsSync()) {
            final cached = ArtistInfo.fromJson(
              jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>,
            );
            if (cached.photoPath == null ||
                File(cached.photoPath!).existsSync()) {
              return cached;
            }
          }
        } catch (_) {}

        try {
          final r = await http
              .get(
                Uri.parse(
                  'https://api.deezer.com/search/artist?q=${Uri.encodeQueryComponent(a)}&limit=1',
                ),
              )
              .timeout(const Duration(seconds: 6));
          if (r.statusCode != 200) return null;
          final data = (jsonDecode(r.body)['data'] as List?) ?? const [];
          if (data.isEmpty) return null;
          final d = data.first as Map<String, dynamic>;
          final String shown = (d['name'] ?? a).toString();
          final int fans = (d['nb_fan'] as num?)?.toInt() ?? 0;
          final String? picUrl =
              (d['picture_medium'] ?? d['picture_big'] ?? d['picture'])
                  ?.toString();

          String? photoPath;
          if (picUrl != null && picUrl.isNotEmpty) {
            try {
              final img = await http
                  .get(Uri.parse(picUrl))
                  .timeout(const Duration(seconds: 8));
              if (img.statusCode == 200 && img.bodyBytes.isNotEmpty) {
                photoPath =
                    '${dir.path}${Platform.pathSeparator}${_key(a)}.jpg';
                File(photoPath).writeAsBytesSync(img.bodyBytes);
              }
            } catch (_) {}
          }

          final String bio = await _wikiBio(shown);
          final info = ArtistInfo(
            name: shown,
            photoPath: photoPath,
            fans: fans,
            bio: bio,
          );
          try {
            meta.writeAsStringSync(jsonEncode(info.toJson()));
          } catch (_) {}
          return info;
        } catch (_) {
          // Sin internet / certificado / límite: la UI queda como siempre.
          return null;
        }
      })
      .then((v) {
        if (v == null) {
          // No se recuerda el fallo: al volver el internet se reintenta.
          _mem.remove(a.toLowerCase());
        }
        return v;
      });
}

Future<String> _wikiBio(String name) async {
  for (final lang in const ['es', 'en']) {
    try {
      final r = await http
          .get(
            Uri.parse(
              'https://$lang.wikipedia.org/api/rest_v1/page/summary/'
              '${Uri.encodeComponent(name.replaceAll(' ', '_'))}',
            ),
          )
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) continue;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (j['type'] == 'disambiguation') continue;
      final ex = (j['extract'] ?? '').toString().trim();
      if (ex.isNotEmpty) return ex;
    } catch (_) {}
  }
  return '';
}

String formatFans(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)} M fans';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)} K fans';
  return n > 0 ? '$n fans' : '';
}
