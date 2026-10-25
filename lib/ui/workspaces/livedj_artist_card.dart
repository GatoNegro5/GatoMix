import 'dart:io';
import 'package:flutter/material.dart';

import '../../core/net/artist_info.dart';

/// Tarjeta del artista a la derecha del título (foto, nombre, fans). Sin
/// internet o sin dato no se muestra nada: NOW PLAYING queda como siempre.
class LiveDjArtistCard extends StatelessWidget {
  final String? path;
  final bool compact;
  const LiveDjArtistCard({super.key, required this.path, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final p = path;
    if (p == null) return const SizedBox.shrink();
    final artist = artistFromPath(p);
    if (artist.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<ArtistInfo?>(
      key: ValueKey(artist),
      future: loadArtistInfo(artist),
      builder: (context, snap) {
        final info = snap.data;
        if (info == null) return const SizedBox.shrink();
        final double r = compact ? 14 : 20;
        final avatar = CircleAvatar(
          radius: r,
          backgroundColor: Colors.white10,
          backgroundImage:
              (info.photoPath != null && File(info.photoPath!).existsSync())
              ? FileImage(File(info.photoPath!))
              : null,
          child: info.photoPath == null
              ? Icon(Icons.person, size: r, color: Colors.white38)
              : null,
        );
        final tip = [
          info.name,
          if (formatFans(info.fans).isNotEmpty) formatFans(info.fans),
          if (info.bio.isNotEmpty) info.bio,
        ].join('\n');
        if (compact) {
          return Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Tooltip(message: tip, child: avatar),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(left: 10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Tooltip(
              message: tip,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  avatar,
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          info.bio.isNotEmpty
                              ? info.bio
                              : formatFans(info.fans),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
