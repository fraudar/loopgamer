import 'package:flutter/material.dart';
import '../models/emulation_game.dart';
import '../services/rom_download_service.dart';
import 'explore_screen.dart';

/// Helper modal para exibir a ficha de detalhes de um jogo, garantindo que
/// o bottom sheet seja fechado antes de iniciar o emulador.
class GameDetailScreen {
  GameDetailScreen._();

  static Future<void> showAsModal(
    BuildContext context, {
    required EmulationGame game,
    required RomDownloadService downloadService,
    required RomDownloadStatus initialStatus,
    required ValueChanged<RomDownloadStatus> onStatusChanged,
    required ValueChanged<String> onPlayPressed,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => GameDetailSheet(
        game: game,
        downloadService: downloadService,
        initialStatus: initialStatus,
        onStatusChanged: onStatusChanged,
        onPlayPressed: (romPath) {
          Navigator.of(sheetContext).pop();
          onPlayPressed(romPath);
        },
      ),
    );
  }
}
