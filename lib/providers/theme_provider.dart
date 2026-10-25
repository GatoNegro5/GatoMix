import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class GatoMixTheme {
  // Traktor / Native Instruments (cabina “lab”)
  static const Color bgDark = Color(0xFF0E1014); // Carbón NI
  static const Color bgPanel = Color(0xFF1A1E26); // Panel elevado

  static const Color deckA = Color(0xFF2E9BFF); // Deck A azul Traktor
  static const Color deckB = Color(0xFFF05A22); // Naranja Native Instruments
  static const Color cyanAccent = Color(0xFFF05A22); // Acento de marca / hover

  // Estados Críticos del Sistema
  static const Color syncActive = Color(
    0xFF00E676,
  ); // Verde Neón (Sync/Beatmatch)
  static const Color masterPeak = Color(
    0xFFFFC400,
  ); // Ámbar/Oro (Alertas/Master)
  static const Color alertCritical = Color(
    0xFFFF1744,
  ); // Rojo Escarlata (On Air/Errores)

  // Tipografía con tintes profesionales (Cero transparencias sucias)
  static const Color textMain = Color(0xFFF8F9FA); // Blanco Ártico puro
  static const Color textMuted = Color(
    0xFF8A93A2,
  ); // Gris Técnico (Mejor contraste que white54)
  static const Color textHidden = Color(
    0xFF3E4551,
  ); // Gris Oscuro para elementos deshabilitados

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,
      fontFamily: 'Consolas',
      colorScheme: const ColorScheme.dark(
        primary: syncActive,
        secondary: cyanAccent,
        surface: bgPanel,
        error: alertCritical,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: bgPanel,
          foregroundColor: textMain,
          side: const BorderSide(
            color: Color(0xFF2A2E37),
          ), // Borde sutil arquitectónico
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          elevation: 0,
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: syncActive,
        inactiveTrackColor: Color(
          0xFF2A2E37,
        ), // Track inactivo más oscuro y elegante
        thumbColor: textMain,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: textMuted,
        textColor: textMain,
      ),
      iconTheme: const IconThemeData(color: textMuted),
    );
  }
}

final themeProvider = Provider<ThemeData>((ref) => GatoMixTheme.darkTheme);

final mobileNavOpenProvider = StateProvider<bool>((ref) => false);

class GatoMixMobileModeBar extends StatelessWidget {
  final String title;
  final Color accent;
  final bool open;
  final VoidCallback onTap;
  final bool expand;

  const GatoMixMobileModeBar({
    super.key,
    required this.title,
    required this.accent,
    required this.open,
    required this.onTap,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: GatoMixTheme.bgDark,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 36,
          width: expand ? double.infinity : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Icon(open ? Icons.close : Icons.menu, size: 18, color: accent),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    color: accent,
                    fontFamily: 'Consolas',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: GatoMixTheme.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
